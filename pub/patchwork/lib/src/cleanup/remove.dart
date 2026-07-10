import 'dart:io';

import '../error.dart';
import '../pub/resolution.dart';
import '../state/applied_marker.dart';
import '../state/artifact_identity.dart';
import '../state/artifact_inventory.dart';
import '../state/dependency_override_state.dart';
import '../state/path_layout.dart';
import 'applied.dart';
import 'model.dart';
import 'plan.dart';

/// Plans `patchwork remove` without mutating files.
final class RemovePlanner {
  /// Creates a remove planner for one Patchwork project.
  const RemovePlanner({
    required this.layout,
    required this.appliedMarkerStore,
    required this.readResolution,
    required this.readOverrideState,
    required this.appliedCleanup,
  });

  /// Patchwork artifact paths.
  final PathLayout layout;

  /// Applied output marker store.
  final AppliedMarkerStore appliedMarkerStore;

  /// Reads the current pub resolution.
  final PubResolution Function() readResolution;

  /// Reads dependency override state.
  final DependencyOverrideState Function() readOverrideState;

  /// Applied-output cleanup policy.
  final AppliedCleanup appliedCleanup;

  /// Plans removal of one package version.
  CleanupPlan plan(
    String package, {
    String? version,
    bool dryRun = false,
    bool force = false,
  }) {
    final inventory = PatchworkArtifactInventory.read(layout);
    final selectedVersion = _removeVersion(package, version, inventory);
    final plan = CleanupPlanBuilder(
      command: CleanupCommand.remove,
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
      appliedCleanup.rejectUserOwnedOverride(
        marker,
        command: 'remove',
        code: 'remove.active_override',
        overrideState: overrideState,
      );
      appliedCleanup.addChanges(plan, marker, overrideState);
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
      // Cleanup can still target stale files when the package no longer resolves.
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
}
