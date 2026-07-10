import '../state/applied_marker.dart';
import 'model.dart';

/// Accumulates deduplicated cleanup changes and ownership markers.
final class CleanupPlanBuilder {
  /// Creates a builder for one cleanup command.
  CleanupPlanBuilder({
    required this.command,
    required this.dryRun,
    required this.force,
  });

  /// Command name recorded in the result.
  final CleanupCommand command;

  /// Whether execution should be skipped.
  final bool dryRun;

  /// Whether guarded local state may be discarded.
  final bool force;

  final List<CleanupChange> _changes = [];
  final Set<(CleanupChangeKind, String, String, String)> _changeKeys = {};
  final List<AppliedMarker> _appliedMarkers = [];
  final Set<(String, String)> _appliedMarkerKeys = {};

  /// Adds [change] unless the same kind and path were already planned.
  void addChange(CleanupChange change) {
    if (_changeKeys.add((
      change.kind,
      change.package,
      change.version,
      change.path,
    ))) {
      _changes.add(change);
    }
  }

  /// Adds [marker] unless the same package version was already planned.
  void addAppliedMarker(AppliedMarker marker) {
    if (_appliedMarkerKeys.add((marker.package, marker.version))) {
      _appliedMarkers.add(marker);
    }
  }

  /// Builds the immutable cleanup plan.
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
