import '../applied_marker.dart';
import '../error.dart';
import 'path_layout.dart';

/// Reads the applied marker for [appliedDirectory], returning `null` when the
/// marker is absent or malformed.
///
/// This is used for cleanup and stale-state diagnostics where a malformed
/// marker should make the generated output non-prunable instead of aborting the
/// whole inspection.
AppliedMarker? tryReadAppliedMarker(
  AppliedMarkerStore store,
  PackageVersionPath appliedDirectory,
) {
  try {
    return store.read(appliedDirectory.package, appliedDirectory.version);
  } on PatchworkException {
    return null;
  }
}
