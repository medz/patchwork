import 'dart:convert';
import 'dart:io';

import '../state/applied_marker.dart';
import '../error.dart';
import '../pub/source.dart';
import '../patch/file.dart';
import '../pub/resolution.dart';
import '../state/applied_freshness.dart';
import '../state/applied_path_policy.dart';
import '../state/applied_resolution.dart';
import '../state/artifact_inventory.dart';
import '../state/dependency_override_guard.dart';
import '../state/dependency_override_state.dart';
import '../patch/hash.dart';
import '../state/path_layout.dart';

/// Plans Patchwork apply operations before generated output is written.
///
/// The planner owns state checks and patch selection. Callers can then execute
/// an [ApplyPlan] as a narrow filesystem operation.
final class ApplyPlanner {
  /// Creates an apply planner for one Patchwork state root.
  const ApplyPlanner({
    required this.rootPath,
    required this.layout,
    required this.appliedPaths,
    required this.appliedMarkerStore,
    required this.patchFile,
    required this.readResolution,
    required this.readOverrideState,
    required this.invalidAppliedPathMessage,
  });

  /// Patchwork state root.
  final String rootPath;

  /// Patchwork artifact paths.
  final PathLayout layout;

  /// Applied output path safety policy.
  final AppliedPathPolicy appliedPaths;

  /// Applied output marker store.
  final AppliedMarkerStore appliedMarkerStore;

  /// Patch validation helper.
  final PatchFile patchFile;

  /// Reads the current pub resolution.
  final PubResolution Function() readResolution;

  /// Reads dependency override state across relevant pub roots.
  final DependencyOverrideState Function() readOverrideState;

  /// Error message for invalid applied marker paths.
  final String invalidAppliedPathMessage;

  /// Plans every committed patch that currently needs generated output.
  ({List<ApplyPlan> plans, bool needsPubGet}) plansNeedingApply() {
    final inventory = PatchworkArtifactInventory.read(layout);
    final patches = inventory.patchFiles;
    if (patches.isEmpty) {
      return (plans: const [], needsPubGet: false);
    }

    final resolution = readResolution();
    final overrideState = readOverrideState();
    final plans = <ApplyPlan>[];
    var needsPubGet = false;
    for (final patch in patches) {
      final package = patch.package;
      late final ResolvedPubPackage resolved;
      try {
        resolved = resolution.resolvePackage(
          package,
          requireDirectDependency: false,
        );
      } on PatchworkException catch (error) {
        if (error.code == 'pub.package_not_found') {
          continue;
        }
        rethrow;
      }
      if (resolved.version != patch.version) {
        continue;
      }

      final planned = _planResolvedPackage(
        package: package,
        resolved: resolved,
        inventory: inventory,
        overrideState: overrideState,
        readCommittedPatch: () => _readPatchFile(patch.path),
      );
      if (planned.plan != null) {
        plans.add(planned.plan!);
      }
      needsPubGet = needsPubGet || planned.needsPubGet;
    }
    return (plans: List.unmodifiable(plans), needsPubGet: needsPubGet);
  }

  /// Plans a single package only when generated output needs refreshing.
  ({ApplyPlan? plan, bool needsPubGet}) planIfNeeded(String package) {
    final inventory = PatchworkArtifactInventory.read(layout);
    final resolution = readResolution();
    final resolved = resolution.resolvePackage(
      package,
      requireDirectDependency: false,
    );
    final overrideState = readOverrideState();
    return _planResolvedPackage(
      package: package,
      resolved: resolved,
      inventory: inventory,
      overrideState: overrideState,
      readCommittedPatch: () => _readCommittedPatch(package, resolved.version),
    );
  }

  ({ApplyPlan? plan, bool needsPubGet}) _planResolvedPackage({
    required String package,
    required ResolvedPubPackage resolved,
    required PatchworkArtifactInventory inventory,
    required DependencyOverrideState overrideState,
    required _CommittedPatch Function() readCommittedPatch,
  }) {
    _rejectOpenEdit(package, inventory);
    final applied = appliedMarkerStore.read(package, resolved.version);
    final appliedPath = _appliedOutputPath(package, resolved.version, applied);
    rejectBlockingOverride(
      overrideState: overrideState,
      package: package,
      command: 'apply',
      targetPath: appliedPath,
      replaceRootOverride: applied != null,
    );
    if (_pubResolvesToAppliedOutput(package, resolved.version, resolved)) {
      return (plan: null, needsPubGet: false);
    }
    _rejectUnownedAppliedOutput(
      package: package,
      appliedPath: appliedPath,
      existingApplied: applied,
    );

    final committedPatch = readCommittedPatch();
    final source = resolved.source;
    if (!appliedPatchNeedsRefresh(
      package: package,
      version: resolved.version,
      patchSha256: committedPatch.sha256,
      source: source,
      applied: applied,
      appliedPaths: appliedPaths,
      overrideState: overrideState,
    )) {
      return (
        plan: null,
        needsPubGet:
            applied != null &&
            overrideState.rootOverridePointsToPath(
              package: package,
              path: applied.path,
            ),
      );
    }
    patchFile.validate(
      sourcePath: resolved.rootPath,
      patchContent: committedPatch.content,
    );

    return (
      plan: _applyPlan(
        package: package,
        resolved: resolved,
        committedPatch: committedPatch,
        existingApplied: applied,
        appliedPath: appliedPath,
      ),
      needsPubGet: false,
    );
  }

  ApplyPlan _applyPlan({
    required String package,
    required ResolvedPubPackage resolved,
    required _CommittedPatch committedPatch,
    required AppliedMarker? existingApplied,
    String? appliedPath,
  }) {
    return ApplyPlan(
      package: package,
      version: resolved.version,
      sourcePath: resolved.rootPath,
      source: resolved.source,
      patchPath: committedPatch.path,
      patchContent: committedPatch.content,
      patchSha256: committedPatch.sha256,
      appliedRecordPath: layout.relativeAppliedPath(package, resolved.version),
      appliedPath:
          appliedPath ??
          _appliedOutputPath(package, resolved.version, existingApplied),
    );
  }

  bool _pubResolvesToAppliedOutput(
    String package,
    String version,
    ResolvedPubPackage resolved,
  ) {
    return resolvesToPatchworkAppliedPath(
      rootPath: rootPath,
      appliedPaths: appliedPaths,
      appliedMarkerStore: appliedMarkerStore,
      package: package,
      version: version,
      resolved: resolved,
    );
  }

  String _appliedOutputPath(
    String package,
    String version,
    AppliedMarker? applied,
  ) {
    if (applied == null) {
      return layout.appliedPath(package, version);
    }
    return appliedPaths.requirePatchworkAppliedPathForMarker(
      applied,
      code: 'apply.applied_path_not_deletable',
      message: invalidAppliedPathMessage,
    );
  }

  void _rejectOpenEdit(String package, PatchworkArtifactInventory inventory) {
    final openEdits = inventory.editsFor(package);
    if (openEdits.isEmpty) {
      return;
    }
    throw PatchworkException(
      'Package "$package" has an open edit directory.',
      code: 'apply.open_edit',
      hint: 'Run patchwork commit $package before applying.',
      location: openEdits.first.path,
    );
  }

  _CommittedPatch _readCommittedPatch(String package, String version) {
    final patchPath = layout.patchPath(package, version);
    final file = File(patchPath);
    if (!file.existsSync()) {
      throw PatchworkException(
        'No committed patch exists for "$package".',
        code: 'apply.patch_file_missing',
        hint: 'Run patchwork commit $package first.',
        location: patchPath,
      );
    }
    return _readPatchFile(patchPath);
  }

  _CommittedPatch _readPatchFile(String path) {
    final bytes = File(path).readAsBytesSync();
    return _CommittedPatch(
      path: path,
      content: utf8.decode(bytes),
      sha256: sha256Hex(bytes),
    );
  }

  void _rejectUnownedAppliedOutput({
    required String package,
    required String appliedPath,
    required AppliedMarker? existingApplied,
  }) {
    if (existingApplied != null || !Directory(appliedPath).existsSync()) {
      return;
    }
    throw PatchworkException(
      'Applied output path already exists for "$package".',
      code: 'apply.applied_path_exists',
      hint:
          'Patchwork cannot replace it without a matching applied output marker.',
      location: appliedPath,
    );
  }
}

final class _CommittedPatch {
  const _CommittedPatch({
    required this.path,
    required this.content,
    required this.sha256,
  });

  final String path;
  final String content;
  final String sha256;
}

/// A planned apply operation.
final class ApplyPlan {
  /// Creates an apply plan.
  ApplyPlan({
    required this.package,
    required this.version,
    required this.sourcePath,
    required this.source,
    required this.patchPath,
    required this.patchContent,
    required this.patchSha256,
    required this.appliedRecordPath,
    required this.appliedPath,
  });

  /// The dependency package to apply.
  final String package;

  /// The package version to apply.
  final String version;

  /// The resolved source package path.
  final String sourcePath;

  /// The resolved source package metadata.
  final PackageSource source;

  /// The committed patch file path.
  final String patchPath;

  /// The committed patch content.
  final String patchContent;

  /// SHA-256 digest of [patchContent] as stored on disk.
  final String patchSha256;

  /// Project-relative path recorded in applied marker and pub overrides.
  final String appliedRecordPath;

  /// Absolute generated output path.
  final String appliedPath;
}
