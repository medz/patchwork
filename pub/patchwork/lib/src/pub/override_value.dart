import 'package:path/path.dart' as p;

/// Returns the path from one dependency override value, if present.
String? dependencyOverridePath(Object? value) {
  if (value is! Map<String, Object?>) {
    return null;
  }
  final path = value['path'];
  return path is String ? path : null;
}

/// Whether [value] points at [path] from [workspaceRootPath].
bool dependencyOverridePointsToPath({
  required String workspaceRootPath,
  required Object? value,
  required String path,
}) {
  final overridePath = dependencyOverridePath(value);
  return overridePath != null &&
      dependencyOverridePathsEqual(workspaceRootPath, overridePath, path);
}

/// Whether two paths resolve to the same location.
bool dependencyOverridePathsEqual(
  String workspaceRootPath,
  String left,
  String right,
) {
  final leftAbsolute = p.normalize(
    p.isAbsolute(left) ? left : p.absolute(workspaceRootPath, left),
  );
  final rightAbsolute = p.normalize(
    p.isAbsolute(right) ? right : p.absolute(workspaceRootPath, right),
  );
  return p.equals(leftAbsolute, rightAbsolute);
}

/// Deep equality for dependency override values with path normalization.
bool sameDependencyOverrideValue(
  String workspaceRootPath,
  Object? left,
  Object? right,
) {
  if (left is Map<String, Object?> && right is Map<String, Object?>) {
    final leftPath = left['path'];
    final rightPath = right['path'];
    if (leftPath is String && rightPath is String) {
      final leftRest = Map<String, Object?>.of(left)..remove('path');
      final rightRest = Map<String, Object?>.of(right)..remove('path');
      return dependencyOverridePathsEqual(
            workspaceRootPath,
            leftPath,
            rightPath,
          ) &&
          sameDependencyOverrideValue(workspaceRootPath, leftRest, rightRest);
    }
    if (left.length != right.length) {
      return false;
    }
    for (final entry in left.entries) {
      if (!right.containsKey(entry.key) ||
          !sameDependencyOverrideValue(
            workspaceRootPath,
            entry.value,
            right[entry.key],
          )) {
        return false;
      }
    }
    return true;
  }
  if (left is List<Object?> && right is List<Object?>) {
    if (left.length != right.length) {
      return false;
    }
    for (var index = 0; index < left.length; index += 1) {
      if (!sameDependencyOverrideValue(
        workspaceRootPath,
        left[index],
        right[index],
      )) {
        return false;
      }
    }
    return true;
  }
  return left == right;
}
