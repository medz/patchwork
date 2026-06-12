import 'dart:io';

import 'package:path/path.dart' as p;

import '../diagnostics/diagnostic.dart';
import '../patch/patch_file.dart';
import '../pub/package_resolution.dart';
import '../pub/pubspec_overrides.dart';
import '../store/patchwork_manifest.dart';
import '../store/patchwork_store.dart';
import '../target/target.dart';
import '../target/target_parser.dart';

final class PubPatchApplyResult {
  const PubPatchApplyResult._({this.applied = const [], this.diagnostic});

  factory PubPatchApplyResult.success(List<AppliedPubPatch> applied) {
    return PubPatchApplyResult._(applied: List.unmodifiable(applied));
  }

  factory PubPatchApplyResult.failure(Diagnostic diagnostic) {
    return PubPatchApplyResult._(diagnostic: diagnostic);
  }

  final List<AppliedPubPatch> applied;
  final Diagnostic? diagnostic;

  bool get isSuccess => diagnostic == null;
}

final class AppliedPubPatch {
  const AppliedPubPatch({
    required this.target,
    required this.hash,
    required this.storePath,
    required this.rebuilt,
  });

  final String target;
  final String hash;
  final String storePath;
  final bool rebuilt;
}

final class ApplyPatches {
  const ApplyPatches({
    this.resolutionReader = const PubResolutionReader(),
    this.store = const PatchworkStore(),
    this.manifestStore = const PatchworkManifestStore(),
    this.pubspecOverridesStore = const PubspecOverridesStore(),
    this.targetParser = const TargetParser(),
    this.patchApplier = const PatchApplier(),
  });

  final PubResolutionReader resolutionReader;
  final PatchworkStore store;
  final PatchworkManifestStore manifestStore;
  final PubspecOverridesStore pubspecOverridesStore;
  final TargetParser targetParser;
  final PatchApplier patchApplier;

  PubPatchApplyResult apply({
    PubTarget? target,
    required String currentDirectory,
  }) {
    final resolutionResult = resolutionReader.readFromDirectory(
      currentDirectory,
    );
    final resolutionDiagnostic = resolutionResult.diagnostic;
    if (resolutionDiagnostic != null) {
      return PubPatchApplyResult.failure(resolutionDiagnostic);
    }

    final resolution = resolutionResult.resolution!;
    final workspaceRootPath = resolution.workspace.rootPath;
    final inspectionResult = manifestStore.inspectPatchFiles(
      workspaceRootPath: workspaceRootPath,
    );
    final inspectionDiagnostic = inspectionResult.diagnostic;
    if (inspectionDiagnostic != null) {
      return PubPatchApplyResult.failure(inspectionDiagnostic);
    }

    final selectedEntriesResult = _selectEntries(
      resolution: resolution,
      inspections: inspectionResult.patches,
      target: target,
    );
    final selectedEntriesDiagnostic = selectedEntriesResult.diagnostic;
    if (selectedEntriesDiagnostic != null) {
      return PubPatchApplyResult.failure(selectedEntriesDiagnostic);
    }

    final selectedEntries = selectedEntriesResult.entries;
    final applied = <AppliedPubPatch>[];
    final overridePaths = <String, String>{};

    for (final selected in selectedEntries) {
      final inspection = selected.inspection;
      final stateDiagnostic = inspection.diagnostic;
      if (stateDiagnostic != null) {
        return PubPatchApplyResult.failure(stateDiagnostic);
      }
      if (inspection.state != PatchworkManifestPatchState.current) {
        return PubPatchApplyResult.failure(
          Diagnostic(
            code: 'patchwork.patch_not_current',
            message: 'Patch file is not current.',
            location: _manifestEntryAbsolutePath(
              workspaceRootPath: workspaceRootPath,
              entry: inspection.entry,
            ),
          ),
        );
      }

      final entry = inspection.entry;
      final package = selected.package;
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
      final isCurrentStoreCopy = store.pubPatchStoreMatchesHash(
        storePath: storePath,
        patchHash: entry.hash,
      );
      if (!isCurrentStoreCopy) {
        final sourcePackagePathResult = _sourcePackagePath(
          workspaceRootPath: workspaceRootPath,
          package: package,
        );
        final sourcePackagePathDiagnostic = sourcePackagePathResult.diagnostic;
        if (sourcePackagePathDiagnostic != null) {
          return PubPatchApplyResult.failure(sourcePackagePathDiagnostic);
        }
        final materializeDiagnostic = _materializeStoreCopy(
          workspaceRootPath: workspaceRootPath,
          sourcePackagePath: sourcePackagePathResult.path!,
          storePath: storePath,
          patchPath: _manifestEntryAbsolutePath(
            workspaceRootPath: workspaceRootPath,
            entry: entry,
          ),
          patchHash: entry.hash,
        );
        if (materializeDiagnostic != null) {
          return PubPatchApplyResult.failure(materializeDiagnostic);
        }
      }

      overridePaths[package.name] = relativeStorePath;
      applied.add(
        AppliedPubPatch(
          target: entry.target,
          hash: entry.hash,
          storePath: storePath,
          rebuilt: !isCurrentStoreCopy,
        ),
      );
    }

    final overridesDiagnostic = _updateDependencyOverrides(
      workspaceRootPath: workspaceRootPath,
      dependencyOverridePaths: overridePaths,
      removeStaleManagedOverrides: target == null,
    );
    if (overridesDiagnostic != null) {
      return PubPatchApplyResult.failure(overridesDiagnostic);
    }

    return PubPatchApplyResult.success(applied);
  }

  _SelectedEntriesResult _selectEntries({
    required PubResolution resolution,
    required List<PatchworkManifestPatchInspection> inspections,
    PubTarget? target,
  }) {
    if (target != null) {
      final packageResult = resolution.resolve(target);
      final packageDiagnostic = packageResult.diagnostic;
      if (packageDiagnostic != null) {
        return _SelectedEntriesResult.failure(packageDiagnostic);
      }

      final package = packageResult.package!;
      final resolvedTarget = PubTarget(
        name: package.name,
        versionConstraint: package.version,
      ).toString();
      for (final inspection in inspections) {
        if (inspection.entry.target == resolvedTarget) {
          return _SelectedEntriesResult.success([
            _SelectedEntry(inspection: inspection, package: package),
          ]);
        }
      }

      return _SelectedEntriesResult.failure(
        Diagnostic(
          code: 'pub.patch_not_found',
          message: 'No committed pub patch found for "$resolvedTarget".',
          hint: 'Run patchwork patch --commit ${package.name} first.',
        ),
      );
    }

    final selected = <_SelectedEntry>[];
    for (final inspection in inspections) {
      final targetResult = targetParser.parsePubTarget(inspection.entry.target);
      final targetDiagnostic = targetResult.diagnostic;
      if (targetDiagnostic != null) {
        return _SelectedEntriesResult.failure(targetDiagnostic);
      }

      final packageResult = resolution.resolve(targetResult.target!);
      final packageDiagnostic = packageResult.diagnostic;
      if (packageDiagnostic != null) {
        return _SelectedEntriesResult.failure(packageDiagnostic);
      }

      selected.add(
        _SelectedEntry(inspection: inspection, package: packageResult.package!),
      );
    }

    return _SelectedEntriesResult.success(selected);
  }

  Diagnostic? _materializeStoreCopy({
    required String workspaceRootPath,
    required String sourcePackagePath,
    required String storePath,
    required String patchPath,
    required String patchHash,
  }) {
    String? stagingPath;
    try {
      stagingPath = store.createPatchworkTempDirectory(
        workspaceRootPath: workspaceRootPath,
        prefix: 'apply_pub_',
      );
      store.copyPubPackageToDirectory(
        workspaceRootPath: workspaceRootPath,
        sourcePath: sourcePackagePath,
        destinationPath: stagingPath,
      );
      final patchContent = File(patchPath).readAsStringSync();
      final applyResult = patchApplier.apply(
        packagePath: stagingPath,
        patchContent: patchContent,
      );
      final applyDiagnostic = applyResult.diagnostic;
      if (applyDiagnostic != null) {
        return applyDiagnostic;
      }
      store.writePubPatchStoreMarker(
        storePath: stagingPath,
        patchHash: patchHash,
      );
      store.replaceDirectory(
        sourcePath: stagingPath,
        destinationPath: storePath,
      );
      stagingPath = null;
      return null;
    } on FileSystemException catch (error) {
      return Diagnostic(
        code: 'pub.patch_apply_failed',
        message: 'Could not materialize a generated pub patch copy.',
        hint: error.message,
        location: error.path,
      );
    } finally {
      if (stagingPath != null) {
        store.deleteDirectory(stagingPath);
      }
    }
  }

  Diagnostic? _updateDependencyOverrides({
    required String workspaceRootPath,
    required Map<String, String> dependencyOverridePaths,
    required bool removeStaleManagedOverrides,
  }) {
    try {
      pubspecOverridesStore.updateDependencyOverrides(
        workspaceRootPath: workspaceRootPath,
        dependencyOverridePaths: dependencyOverridePaths,
        removeStaleManagedOverrides: removeStaleManagedOverrides,
      );
      return null;
    } on PubspecOverridesException catch (error) {
      return error.diagnostic;
    } on FileSystemException catch (error) {
      return Diagnostic(
        code: 'pub.overrides_write_failed',
        message: 'Could not write pubspec_overrides.yaml.',
        hint: error.message,
        location: error.path,
      );
    }
  }

  _SourcePackagePathResult _sourcePackagePath({
    required String workspaceRootPath,
    required ResolvedPubPackage package,
  }) {
    final baselinePath = store.pubPatchBaselinePath(
      workspaceRootPath: workspaceRootPath,
      package: package,
    );
    if (Directory(baselinePath).existsSync()) {
      return _SourcePackagePathResult.success(baselinePath);
    }

    if (store.isPubPatchStorePath(
      workspaceRootPath: workspaceRootPath,
      path: package.rootPath,
    )) {
      return _SourcePackagePathResult.failure(
        Diagnostic(
          code: 'pub.patch_source_missing',
          message:
              'Could not find an unpatched package source for "${package.name}".',
          hint:
              'Refresh pub resolution without Patchwork overrides or recreate the patch session before applying this patch.',
          location: package.rootPath,
        ),
      );
    }

    return _SourcePackagePathResult.success(package.rootPath);
  }
}

final class _SelectedEntry {
  const _SelectedEntry({required this.inspection, required this.package});

  final PatchworkManifestPatchInspection inspection;
  final ResolvedPubPackage package;
}

final class _SelectedEntriesResult {
  const _SelectedEntriesResult._({this.entries = const [], this.diagnostic});

  factory _SelectedEntriesResult.success(List<_SelectedEntry> entries) {
    return _SelectedEntriesResult._(entries: entries);
  }

  factory _SelectedEntriesResult.failure(Diagnostic diagnostic) {
    return _SelectedEntriesResult._(diagnostic: diagnostic);
  }

  final List<_SelectedEntry> entries;
  final Diagnostic? diagnostic;
}

final class _SourcePackagePathResult {
  const _SourcePackagePathResult._({this.path, this.diagnostic});

  factory _SourcePackagePathResult.success(String path) {
    return _SourcePackagePathResult._(path: path);
  }

  factory _SourcePackagePathResult.failure(Diagnostic diagnostic) {
    return _SourcePackagePathResult._(diagnostic: diagnostic);
  }

  final String? path;
  final Diagnostic? diagnostic;
}

String _manifestEntryAbsolutePath({
  required String workspaceRootPath,
  required PatchworkManifestPatch entry,
}) {
  return p.joinAll([workspaceRootPath, ...entry.path.split('/')]);
}
