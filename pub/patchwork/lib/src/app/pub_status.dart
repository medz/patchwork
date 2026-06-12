import 'package:path/path.dart' as p;

import '../diagnostics/diagnostic.dart';
import '../pub/package_resolution.dart';
import '../pub/pubspec_overrides.dart';
import '../store/patchwork_manifest.dart';
import '../store/patchwork_store.dart';
import '../target/target_parser.dart';

enum PubPatchStatusState { clean, stale, missing, unapplied, broken }

final class PubStatusResult {
  const PubStatusResult._({
    this.workspaceRootPath,
    this.patches = const [],
    this.diagnostic,
  });

  factory PubStatusResult.success({
    required String workspaceRootPath,
    required List<PubPatchStatus> patches,
  }) {
    return PubStatusResult._(
      workspaceRootPath: workspaceRootPath,
      patches: List.unmodifiable(patches),
    );
  }

  factory PubStatusResult.failure(Diagnostic diagnostic) {
    return PubStatusResult._(diagnostic: diagnostic);
  }

  final String? workspaceRootPath;
  final List<PubPatchStatus> patches;
  final Diagnostic? diagnostic;

  bool get hasBrokenState {
    return patches.any((patch) => patch.state != PubPatchStatusState.clean);
  }
}

final class PubPatchStatus {
  const PubPatchStatus({
    required this.target,
    required this.state,
    required this.patchPath,
    required this.manifestHash,
    required this.patchState,
    this.actualHash,
    this.packageName,
    this.storePath,
    this.storeCurrent = false,
    this.overridePath,
    this.overrideCurrent = false,
    this.diagnostic,
  });

  final String target;
  final PubPatchStatusState state;
  final String patchPath;
  final String manifestHash;
  final PatchworkManifestPatchState patchState;
  final String? actualHash;
  final String? packageName;
  final String? storePath;
  final bool storeCurrent;
  final String? overridePath;
  final bool overrideCurrent;
  final Diagnostic? diagnostic;
}

final class PubStatus {
  const PubStatus({
    this.resolutionReader = const PubResolutionReader(),
    this.manifestStore = const PatchworkManifestStore(),
    this.overridesStore = const PubspecOverridesStore(),
    this.store = const PatchworkStore(),
    this.targetParser = const TargetParser(),
  });

  final PubResolutionReader resolutionReader;
  final PatchworkManifestStore manifestStore;
  final PubspecOverridesStore overridesStore;
  final PatchworkStore store;
  final TargetParser targetParser;

  PubStatusResult read({required String currentDirectory}) {
    final resolutionResult = resolutionReader.readFromDirectory(
      currentDirectory,
    );
    final resolutionDiagnostic = resolutionResult.diagnostic;
    if (resolutionDiagnostic != null) {
      return PubStatusResult.failure(resolutionDiagnostic);
    }

    final resolution = resolutionResult.resolution!;
    final workspaceRootPath = resolution.workspace.rootPath;
    final inspectionResult = manifestStore.inspectPatchFiles(
      workspaceRootPath: workspaceRootPath,
    );
    final inspectionDiagnostic = inspectionResult.diagnostic;
    if (inspectionDiagnostic != null) {
      return PubStatusResult.failure(inspectionDiagnostic);
    }

    final overridesResult = overridesStore.readDependencyOverridePaths(
      workspaceRootPath: workspaceRootPath,
    );
    final overridesDiagnostic = overridesResult.diagnostic;
    if (overridesDiagnostic != null) {
      return PubStatusResult.failure(overridesDiagnostic);
    }
    final overridePaths = overridesResult.paths;

    final patches = <PubPatchStatus>[];
    for (final inspection in inspectionResult.patches) {
      patches.add(
        _inspectPatch(
          workspaceRootPath: workspaceRootPath,
          resolution: resolution,
          inspection: inspection,
          overridePaths: overridePaths,
        ),
      );
    }

    return PubStatusResult.success(
      workspaceRootPath: workspaceRootPath,
      patches: patches,
    );
  }

  PubPatchStatus _inspectPatch({
    required String workspaceRootPath,
    required PubResolution resolution,
    required PatchworkManifestPatchInspection inspection,
    required Map<String, String> overridePaths,
  }) {
    final entry = inspection.entry;
    final patchPath = p.joinAll([workspaceRootPath, ...entry.path.split('/')]);
    final patchDiagnostic = inspection.diagnostic;
    if (inspection.state != PatchworkManifestPatchState.current) {
      return PubPatchStatus(
        target: entry.target,
        state: _statusStateForPatchState(inspection.state),
        patchPath: patchPath,
        manifestHash: entry.hash,
        patchState: inspection.state,
        actualHash: inspection.actualHash,
        diagnostic: patchDiagnostic,
      );
    }

    final targetResult = targetParser.parsePubTarget(entry.target);
    final targetDiagnostic = targetResult.diagnostic;
    if (targetDiagnostic != null) {
      return PubPatchStatus(
        target: entry.target,
        state: PubPatchStatusState.broken,
        patchPath: patchPath,
        manifestHash: entry.hash,
        patchState: inspection.state,
        actualHash: inspection.actualHash,
        diagnostic: targetDiagnostic,
      );
    }

    final packageResult = resolution.resolve(targetResult.target!);
    final packageDiagnostic = packageResult.diagnostic;
    if (packageDiagnostic != null) {
      return PubPatchStatus(
        target: entry.target,
        state: PubPatchStatusState.broken,
        patchPath: patchPath,
        manifestHash: entry.hash,
        patchState: inspection.state,
        actualHash: inspection.actualHash,
        diagnostic: packageDiagnostic,
      );
    }

    final package = packageResult.package!;
    final storePath = store.pubPatchStorePath(
      workspaceRootPath: workspaceRootPath,
      package: package,
      patchHash: entry.hash,
    );
    final relativeStorePath = store.pubPatchStoreRelativePath(
      workspaceRootPath: workspaceRootPath,
      package: package,
      patchHash: entry.hash,
    );
    final storeCurrent = store.pubPatchStoreMatchesHash(
      storePath: storePath,
      patchHash: entry.hash,
    );
    final overridePath = overridePaths[package.name];
    final overrideCurrent =
        overridePath != null &&
        _sameOverridePath(
          workspaceRootPath: workspaceRootPath,
          expectedPath: relativeStorePath,
          actualPath: overridePath,
        );

    return PubPatchStatus(
      target: entry.target,
      state: storeCurrent && overrideCurrent
          ? PubPatchStatusState.clean
          : PubPatchStatusState.unapplied,
      patchPath: patchPath,
      manifestHash: entry.hash,
      patchState: inspection.state,
      actualHash: inspection.actualHash,
      packageName: package.name,
      storePath: storePath,
      storeCurrent: storeCurrent,
      overridePath: overridePath,
      overrideCurrent: overrideCurrent,
    );
  }

  PubPatchStatusState _statusStateForPatchState(
    PatchworkManifestPatchState state,
  ) {
    return switch (state) {
      PatchworkManifestPatchState.current => PubPatchStatusState.clean,
      PatchworkManifestPatchState.missing => PubPatchStatusState.missing,
      PatchworkManifestPatchState.stale => PubPatchStatusState.stale,
      PatchworkManifestPatchState.unreadable ||
      PatchworkManifestPatchState.invalid => PubPatchStatusState.broken,
    };
  }

  bool _sameOverridePath({
    required String workspaceRootPath,
    required String expectedPath,
    required String actualPath,
  }) {
    final expectedAbsolute = _absolutePath(workspaceRootPath, expectedPath);
    final actualAbsolute = _absolutePath(workspaceRootPath, actualPath);
    return p.equals(expectedAbsolute, actualAbsolute);
  }

  String _absolutePath(String workspaceRootPath, String path) {
    return p.isAbsolute(path)
        ? p.normalize(path)
        : p.normalize(p.absolute(workspaceRootPath, path));
  }
}
