import '../state/applied_marker.dart';
import '../error.dart';

/// Plans `patchwork undo` before generated output is deleted.
///
/// Undo execution is still handled by [AppliedPatchActivation]. This planner
/// only chooses whether the command is a no-op, or which single applied marker
/// is safe to hand to execution.
final class UndoPlanner {
  /// Creates an undo planner for one Patchwork state root.
  const UndoPlanner({required this.appliedMarkerStore});

  /// Applied output marker store.
  final AppliedMarkerStore appliedMarkerStore;

  /// Plans `patchwork undo <package>`.
  UndoPlan plan(String package) {
    final applied = appliedMarkerStore
        .readAll()
        .where((marker) => marker.package == package)
        .toList();
    if (applied.isEmpty) {
      return UndoPlan(package: package, marker: null);
    }
    if (applied.length > 1) {
      throw PatchworkException(
        'More than one applied output marker exists for "$package".',
        code: 'undo.ambiguous_applied',
        hint:
            'Remove stale .dart_tool/patchwork/$package@<version> directories before undoing.',
      );
    }
    return UndoPlan(package: package, marker: applied.single);
  }
}

/// A checked undo decision.
final class UndoPlan {
  /// Creates an undo plan.
  const UndoPlan({required this.package, required this.marker});

  /// Package being unapplied.
  final String package;

  /// Marker to remove, or `null` when no applied Patchwork state exists.
  final AppliedMarker? marker;
}
