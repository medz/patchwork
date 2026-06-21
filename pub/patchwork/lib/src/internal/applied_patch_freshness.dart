import 'dart:io';

import '../applied_marker.dart';
import '../model.dart';
import 'applied_path_policy.dart';
import 'dependency_override_state.dart';

/// Whether an applied output is missing, stale, or no longer wired into pub.
bool appliedPatchNeedsRefresh({
  required String package,
  required String version,
  required String patchSha256,
  required PackageSource source,
  required AppliedMarker? applied,
  required AppliedPathPolicy appliedPaths,
  required DependencyOverrideState overrideState,
}) {
  if (applied == null) {
    return true;
  }
  final appliedPath = appliedPaths.patchworkAppliedPath(
    package,
    version,
    applied.path,
  );
  if (appliedPath == null) {
    return false;
  }

  return !Directory(appliedPath).existsSync() ||
      !overrideState.rootOverridePointsToPath(
        package: package,
        path: applied.path,
      ) ||
      applied.patchSha256 != patchSha256 ||
      (applied.source != null && applied.source != source);
}
