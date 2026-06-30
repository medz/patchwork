import 'dart:io';

import 'package:path/path.dart' as p;

import '../applied_marker.dart';
import '../error.dart';
import '../model.dart';
import '../pub/package_resolution.dart';
import 'applied_marker_reader.dart';
import 'applied_path_policy.dart';
import 'artifact_identity.dart';
import 'artifact_inventory.dart';
import 'dependency_override_state.dart';
import 'path_layout.dart';

/// Plans Patchwork artifact cleanup without mutating files.
///
/// Cleanup commands are intentionally split into a conservative planning phase
/// and a separate execution phase so refusal conditions can be reasoned about
/// independently from filesystem deletion.
final class CleanupPlanner {
  /// Creates a cleanup planner for one Patchwork state root.
  const CleanupPlanner({
    required this.rootPath,
    required this.layout,
    required this.appliedPaths,
    required this.appliedMarkerStore,
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

  /// Reads the current pub resolution.
  final PubResolution Function() readResolution;

  /// Reads dependency override state across relevant pub roots.
  final DependencyOverrideState Function() readOverrideState;

  /// Error message for invalid applied marker paths.
  final String invalidAppliedPathMessage;

  /// Plans `patchwork remove`.
  CleanupPlan remove(
    String package, {
    String? version,
    bool dryRun = false,
    bool force = false,
  }) {
    final inventory = PatchworkArtifactInventory.read(layout);
    final selectedVersion = _removeVersion(package, version, inventory);
    final plan = _CleanupPlanBuilder(
      command: 'remove',
      dryRun: dryRun,
      force: force,
    );

    final patchPath = layout.patchPath(package, selectedVersion);
    if (File(patchPath).existsSync()) {
      plan.addChange(
        CleanupChange(
          kind: CleanupChangeKind.patchFile,
          package: package,
          version: selectedVersion,
          path: patchPath,
        ),
      );
    }

    final edit = inventory.edit(package, selectedVersion);
    if (edit != null) {
      if (!force) {
        throw PatchworkException(
          'Package "$package@$selectedVersion" has an open edit directory.',
          code: 'remove.open_edit',
          hint: 'Pass --force to discard the edit directory.',
          location: edit.path,
        );
      }
      plan.addChange(
        CleanupChange(
          kind: CleanupChangeKind.editDirectory,
          package: package,
          version: selectedVersion,
          path: edit.path,
        ),
      );
    }

    final marker = appliedMarkerStore.read(package, selectedVersion);
    if (marker != null) {
      final overrideState = readOverrideState();
      if (!force) {
        throw PatchworkException(
          'Package "$package@$selectedVersion" has applied Patchwork state.',
          code: 'remove.patch_applied',
          hint: 'Run patchwork undo $package first, or pass --force.',
          location: layout.appliedPath(package, selectedVersion),
        );
      }
      _rejectUserOwnedOverrideForAppliedCleanup(
        marker,
        command: 'remove',
        code: 'remove.active_override',
        overrideState: overrideState,
      );
      _addAppliedCleanupChanges(plan, marker, overrideState: overrideState);
      plan.addAppliedMarker(marker);
    }

    return plan.build();
  }

  /// Plans `patchwork prune`.
  CleanupPlan prune({bool dryRun = false, bool force = false}) {
    final plan = _CleanupPlanBuilder(
      command: 'prune',
      dryRun: dryRun,
      force: force,
    );
    final inventory = PatchworkArtifactInventory.read(layout);
    final resolution = readResolution();
    DependencyOverrideState? overrideState;
    DependencyOverrideState lazyOverrideState() {
      return overrideState ??= readOverrideState();
    }

    for (final patch in inventory.patchFiles) {
      if (_patchMatchesResolution(patch, resolution)) {
        continue;
      }
      final edit = inventory.edit(patch.package, patch.version);
      if (edit != null && !force) {
        throw PatchworkException(
          'Package "${patch.package}@${patch.version}" has an open edit directory.',
          code: 'prune.open_edit',
          hint: 'Pass --force to discard the edit directory.',
          location: edit.path,
        );
      }

      final marker = appliedMarkerStore.read(patch.package, patch.version);
      final activeAppliedReference =
          marker != null &&
          _appliedOutputHasActiveOverride(
            marker,
            overrideState: lazyOverrideState(),
          );
      if (activeAppliedReference && !force) {
        throw PatchworkException(
          'Package "${patch.package}@${patch.version}" has applied Patchwork state.',
          code: 'prune.patch_applied',
          hint: 'Run patchwork undo ${patch.package} first, or pass --force.',
          location: layout.appliedPath(patch.package, patch.version),
        );
      }

      plan.addChange(
        CleanupChange(
          kind: CleanupChangeKind.patchFile,
          package: patch.package,
          version: patch.version,
          path: patch.path,
        ),
      );
      if (edit != null) {
        plan.addChange(
          CleanupChange(
            kind: CleanupChangeKind.editDirectory,
            package: edit.package,
            version: edit.version,
            path: edit.path,
          ),
        );
      }
      if (marker != null && force) {
        _rejectUserOwnedOverrideForAppliedCleanup(
          marker,
          command: 'prune',
          code: 'prune.active_override',
          overrideState: lazyOverrideState(),
        );
      }
      if (marker != null && (force || !activeAppliedReference)) {
        _addAppliedCleanupChanges(
          plan,
          marker,
          overrideState: lazyOverrideState(),
        );
        plan.addAppliedMarker(marker);
      }
    }

    for (final appliedDirectory in inventory.appliedDirectories) {
      final marker = tryReadAppliedMarker(appliedMarkerStore, appliedDirectory);
      if (marker == null) {
        continue;
      }
      if (_appliedOutputHasActiveOverride(
        marker,
        overrideState: lazyOverrideState(),
      )) {
        continue;
      }
      _addAppliedCleanupChanges(
        plan,
        marker,
        overrideState: lazyOverrideState(),
      );
      plan.addAppliedMarker(marker);
    }

    return plan.build();
  }

  String _removeVersion(
    String package,
    String? version,
    PatchworkArtifactInventory inventory,
  ) {
    if (version != null) {
      checkSafePathSegment(
        version,
        label: 'Patch version',
        code: 'remove.version_invalid',
      );
      return version;
    }

    final versions = inventory.versionsFor(package);
    if (versions.isEmpty) {
      throw PatchworkException(
        'No Patchwork artifacts exist for "$package".',
        code: 'remove.artifact_missing',
        hint: 'Pass an explicit version if you expected a historical artifact.',
      );
    }

    try {
      final resolved = readResolution().resolvePackage(
        package,
        requireDirectDependency: false,
      );
      if (versions.contains(resolved.version)) {
        return resolved.version;
      }
    } on PatchworkException {
      // Fall back to artifact inventory below. Cleanup can still target stale
      // files when the package no longer resolves.
    }

    if (versions.length == 1) {
      return versions.single;
    }
    final sortedVersions = versions.toList()..sort();
    throw PatchworkException(
      'More than one Patchwork artifact version exists for "$package".',
      code: 'remove.ambiguous_version',
      hint:
          'Pass the version to remove, for example patchwork remove $package ${sortedVersions.first}.',
    );
  }

  bool _patchMatchesResolution(
    PackageVersionPath patch,
    PubResolution resolution,
  ) {
    try {
      final resolved = resolution.resolvePackage(
        patch.package,
        requireDirectDependency: false,
      );
      return resolved.version == patch.version;
    } on PatchworkException catch (error) {
      if (_isStalePatchResolutionError(error)) {
        return false;
      }
      rethrow;
    }
  }

  bool _isStalePatchResolutionError(PatchworkException error) {
    return error.code == 'pub.package_not_found' ||
        error.code == 'pub.package_is_project' ||
        error.code == 'pub.unsupported_source';
  }

  bool _appliedOutputHasActiveOverride(
    AppliedMarker marker, {
    required DependencyOverrideState overrideState,
  }) {
    final absoluteAppliedPath = _patchworkAppliedPath(marker);
    if (absoluteAppliedPath == null) {
      return false;
    }
    return overrideState.hasActiveAppliedOverride(
      marker,
      absoluteAppliedPath: absoluteAppliedPath,
    );
  }

  DependencyOverrideConflict? _userOwnedOverrideForAppliedOutput(
    AppliedMarker marker, {
    required DependencyOverrideState overrideState,
  }) {
    final absoluteAppliedPath = _patchworkAppliedPath(marker);
    if (absoluteAppliedPath == null) {
      return null;
    }
    return overrideState.userOwnedAppliedOverride(
      marker,
      absoluteAppliedPath: absoluteAppliedPath,
    );
  }

  void _rejectUserOwnedOverrideForAppliedCleanup(
    AppliedMarker marker, {
    required String command,
    required String code,
    required DependencyOverrideState overrideState,
  }) {
    final userOverride = _userOwnedOverrideForAppliedOutput(
      marker,
      overrideState: overrideState,
    );
    if (userOverride == null) {
      return;
    }
    throw PatchworkException(
      'Package "${marker.package}@${marker.version}" is still referenced by ${userOverride.fileName}.',
      code: code,
      hint:
          'Remove the dependency override that points at ${marker.path} before running patchwork $command --force.',
      location: userOverride.path,
    );
  }

  void _addAppliedCleanupChanges(
    _CleanupPlanBuilder plan,
    AppliedMarker marker, {
    required DependencyOverrideState overrideState,
  }) {
    final appliedPath = _requirePatchworkAppliedPath(
      marker,
      code: 'cleanup.applied_path_not_deletable',
    );
    plan.addChange(
      CleanupChange(
        kind: CleanupChangeKind.appliedDirectory,
        package: marker.package,
        version: marker.version,
        path: appliedPath,
      ),
    );
    if (overrideState.rootOverridePointsToPath(
          package: marker.package,
          path: marker.path,
        ) ||
        marker.mirroredPubspecDependencyOverrides.isNotEmpty) {
      plan.addChange(
        CleanupChange(
          kind: CleanupChangeKind.pubspecOverride,
          package: marker.package,
          version: marker.version,
          path: p.join(rootPath, 'pubspec_overrides.yaml'),
        ),
      );
    }
  }

  String? _patchworkAppliedPath(AppliedMarker marker) {
    return appliedPaths.patchworkAppliedPathForMarker(marker);
  }

  String _requirePatchworkAppliedPath(
    AppliedMarker marker, {
    required String code,
  }) {
    return appliedPaths.requirePatchworkAppliedPathForMarker(
      marker,
      code: code,
      message: invalidAppliedPathMessage,
    );
  }
}

final class _CleanupPlanBuilder {
  _CleanupPlanBuilder({
    required this.command,
    required this.dryRun,
    required this.force,
  });

  final String command;
  final bool dryRun;
  final bool force;

  final List<CleanupChange> _changes = [];
  final Set<(CleanupChangeKind, String)> _changeKeys = {};
  final List<AppliedMarker> _appliedMarkers = [];
  final Set<(String, String)> _appliedMarkerKeys = {};

  void addChange(CleanupChange change) {
    final key = (change.kind, change.path);
    if (_changeKeys.add(key)) {
      _changes.add(change);
    }
  }

  void addAppliedMarker(AppliedMarker marker) {
    final key = (marker.package, marker.version);
    if (_appliedMarkerKeys.add(key)) {
      _appliedMarkers.add(marker);
    }
  }

  CleanupPlan build() {
    return CleanupPlan(
      result: CleanupResult(
        command: command,
        dryRun: dryRun,
        force: force,
        changes: List.unmodifiable(_changes),
      ),
      appliedMarkers: _appliedMarkers,
    );
  }
}

/// A cleanup decision plus the applied markers needed to execute it.
final class CleanupPlan {
  /// Creates a cleanup plan.
  CleanupPlan({
    required this.result,
    required List<AppliedMarker> appliedMarkers,
  }) : appliedMarkers = List.unmodifiable(appliedMarkers);

  /// The public cleanup result to return to callers.
  final CleanupResult result;

  /// Applied markers selected for activation cleanup.
  final List<AppliedMarker> appliedMarkers;
}
