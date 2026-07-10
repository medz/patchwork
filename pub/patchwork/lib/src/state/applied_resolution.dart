import 'package:path/path.dart' as p;

import 'applied_marker.dart';
import '../pub/resolution.dart';
import 'applied_path_policy.dart';

/// Whether [resolved] points at Patchwork's generated output for [package].
bool resolvesToPatchworkAppliedPath({
  required String rootPath,
  required AppliedPathPolicy appliedPaths,
  required AppliedMarkerStore appliedMarkerStore,
  required String package,
  required String version,
  required ResolvedPubPackage resolved,
}) {
  final marker = appliedMarkerStore.read(package, version);
  if (marker == null) {
    return false;
  }
  final absoluteAppliedPath = appliedPaths.patchworkAppliedPathForMarker(
    marker,
  );
  return absoluteAppliedPath != null &&
      p.equals(
        p.normalize(p.absolute(rootPath, resolved.rootPath)),
        absoluteAppliedPath,
      );
}
