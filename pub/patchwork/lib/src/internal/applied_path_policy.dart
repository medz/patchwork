import 'dart:io';

import 'package:path/path.dart' as p;

import '../applied_marker.dart';
import '../error.dart';
import 'path_layout.dart';

/// Validates Patchwork-generated applied output paths.
///
/// Applied output cleanup is intentionally conservative: paths must stay inside
/// the project, must not resolve to protected pub roots, and must match the
/// deterministic `.dart_tool/patchwork/<package>@<version>` location.
final class AppliedPathPolicy {
  /// Creates a policy for one Patchwork state root.
  const AppliedPathPolicy({
    required this.rootPath,
    required this.layout,
    required this.protectedRootPaths,
  });

  /// Patchwork state root.
  final String rootPath;

  /// Path layout used to compute deterministic applied output locations.
  final PathLayout layout;

  /// Pub roots that must never be deleted as generated output.
  final Set<String> protectedRootPaths;

  /// Returns [path] as an absolute path rooted at [rootPath] when relative.
  String absoluteFromRoot(String path) {
    final absolute = p.isAbsolute(path) ? path : p.absolute(rootPath, path);
    return p.normalize(absolute);
  }

  /// Returns [path] if it is a child of the project root.
  String? projectChildPath(String path) {
    final absolute = absoluteFromRoot(path);
    final root = p.normalize(p.absolute(rootPath));
    if (p.equals(root, absolute) || !p.isWithin(root, absolute)) {
      return null;
    }
    final canonical = _canonicalPathThroughExistingAncestors(absolute);
    final canonicalRoot = _canonicalPathThroughExistingAncestors(root);
    if (canonical == null ||
        canonicalRoot == null ||
        p.equals(canonicalRoot, canonical) ||
        !p.isWithin(canonicalRoot, canonical)) {
      return null;
    }
    return absolute;
  }

  /// Returns [path] if Patchwork can safely delete it as generated output.
  String? deletableProjectChildPath(String path) {
    final absolute = projectChildPath(path);
    if (absolute == null || isProtectedRootPath(absolute)) {
      return null;
    }
    return absolute;
  }

  /// Returns the absolute applied output path if [path] matches Patchwork's
  /// deterministic generated directory for [package] and [version].
  String? patchworkAppliedPath(String package, String version, String path) {
    final absolute = deletableProjectChildPath(path);
    if (absolute == null) {
      return null;
    }
    final expected = p.normalize(layout.appliedPath(package, version));
    if (!p.equals(absolute, expected)) {
      return null;
    }
    return absolute;
  }

  /// Returns the absolute applied output path recorded by [marker] if it still
  /// matches Patchwork's deterministic generated directory.
  String? patchworkAppliedPathForMarker(AppliedMarker marker) {
    return patchworkAppliedPath(marker.package, marker.version, marker.path);
  }

  /// Requires [path] to be Patchwork's deterministic applied output path.
  String requirePatchworkAppliedPath(
    String package,
    String version,
    String path, {
    required String code,
    required String message,
  }) {
    final absolute = patchworkAppliedPath(package, version, path);
    if (absolute == null) {
      throw PatchworkException(message, code: code, location: path);
    }
    return absolute;
  }

  /// Requires the path recorded by [marker] to be Patchwork's deterministic
  /// applied output path.
  String requirePatchworkAppliedPathForMarker(
    AppliedMarker marker, {
    required String code,
    required String message,
  }) {
    return requirePatchworkAppliedPath(
      marker.package,
      marker.version,
      marker.path,
      code: code,
      message: message,
    );
  }

  /// Whether [path] resolves to a protected pub root.
  bool isProtectedRootPath(String path) {
    final normalized = p.normalize(path);
    final canonical = _canonicalPathIfExists(path);
    for (final protectedRoot in protectedRootPaths) {
      if (p.equals(normalized, protectedRoot)) {
        return true;
      }
      final canonicalProtectedRoot = _canonicalPathIfExists(protectedRoot);
      if (canonical != null &&
          canonicalProtectedRoot != null &&
          p.equals(canonical, canonicalProtectedRoot)) {
        return true;
      }
    }
    return false;
  }
}

String? _canonicalPathIfExists(String path) {
  try {
    return p.normalize(_resolveExistingPath(path));
  } on FileSystemException {
    return null;
  }
}

String? _canonicalPathThroughExistingAncestors(String path) {
  final missingSegments = <String>[];
  var current = p.normalize(path);
  while (FileSystemEntity.typeSync(current, followLinks: false) ==
      FileSystemEntityType.notFound) {
    final parent = p.dirname(current);
    if (p.equals(parent, current)) {
      return null;
    }
    missingSegments.add(p.basename(current));
    current = parent;
  }

  try {
    var canonical = p.normalize(_resolveExistingPath(current));
    for (final segment in missingSegments.reversed) {
      canonical = p.join(canonical, segment);
    }
    return p.normalize(canonical);
  } on FileSystemException {
    return null;
  }
}

String _resolveExistingPath(String path) {
  return switch (FileSystemEntity.typeSync(path, followLinks: false)) {
    FileSystemEntityType.directory => Directory(
      path,
    ).resolveSymbolicLinksSync(),
    FileSystemEntityType.file => File(path).resolveSymbolicLinksSync(),
    FileSystemEntityType.link => Link(path).resolveSymbolicLinksSync(),
    _ => throw FileSystemException('Path cannot be resolved.', path),
  };
}
