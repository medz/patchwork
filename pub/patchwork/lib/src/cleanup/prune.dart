import '../error.dart';
import '../pub/resolution.dart';
import '../state/applied_marker.dart';
import '../state/applied_marker_reader.dart';
import '../state/artifact_inventory.dart';
import '../state/dependency_override_state.dart';
import '../state/path_layout.dart';
import 'applied.dart';
import 'model.dart';
import 'plan.dart';

/// Plans `patchwork prune` without mutating files.
final class PrunePlanner {
  /// Creates a prune planner for one Patchwork project.
  const PrunePlanner({
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

  /// Plans stale artifact cleanup.
  CleanupPlan plan({bool dryRun = false, bool force = false}) {
    final plan = CleanupPlanBuilder(
      command: CleanupCommand.prune,
      dryRun: dryRun,
      force: force,
    );
    final inventory = PatchworkArtifactInventory.read(layout);
    final resolution = readResolution();
    DependencyOverrideState? overrideState;
    DependencyOverrideState readOverrides() {
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
      final activeReference =
          marker != null &&
          appliedCleanup.hasActiveOverride(marker, readOverrides());
      if (activeReference && !force) {
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
        appliedCleanup.rejectUserOwnedOverride(
          marker,
          command: 'prune',
          code: 'prune.active_override',
          overrideState: readOverrides(),
        );
      }
      if (marker != null && (force || !activeReference)) {
        appliedCleanup.addChanges(plan, marker, readOverrides());
        plan.addAppliedMarker(marker);
      }
    }

    for (final directory in inventory.appliedDirectories) {
      final marker = tryReadAppliedMarker(appliedMarkerStore, directory);
      if (marker == null ||
          appliedCleanup.hasActiveOverride(marker, readOverrides())) {
        continue;
      }
      appliedCleanup.addChanges(plan, marker, readOverrides());
      plan.addAppliedMarker(marker);
    }

    return plan.build();
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
      if (error.code == 'pub.package_not_found' ||
          error.code == 'pub.package_is_project' ||
          error.code == 'pub.unsupported_source') {
        return false;
      }
      rethrow;
    }
  }
}
