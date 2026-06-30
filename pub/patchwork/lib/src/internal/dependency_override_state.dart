import 'package:path/path.dart' as p;

import '../applied_marker.dart';
import '../pub/pubspec_dependency_overrides.dart';
import '../pub/pubspec_overrides.dart';

/// Read-only snapshot of dependency override state across Patchwork roots.
///
/// Pub gives `pubspec_overrides.yaml` precedence over `pubspec.yaml` for one
/// root, so callers need both maps together to decide whether an override is
/// active, user-owned, or safe for Patchwork to replace.
final class DependencyOverrideState {
  DependencyOverrideState._({
    required this.rootPath,
    required List<_OverrideRootState> roots,
    required _OverrideRootState root,
  }) : _roots = roots,
       _root = root;

  /// Reads override state for the Patchwork state root and all pub roots.
  factory DependencyOverrideState.read({
    required String rootPath,
    required Iterable<String> overrideRootPaths,
    required PubspecOverrides pubspecOverrides,
    required PubspecDependencyOverrides pubspecDependencyOverrides,
  }) {
    final paths = <String>[...overrideRootPaths];
    if (!paths.any((path) => p.equals(path, rootPath))) {
      paths.insert(0, rootPath);
    }
    final roots = [
      for (final path in paths)
        _OverrideRootState(
          path: path,
          pubspecOverrides: pubspecOverrides.readDependencyOverrides(
            workspaceRootPath: path,
          ),
          pubspecDependencyOverrides: pubspecDependencyOverrides,
        ),
    ];
    final root = roots.firstWhere((state) => p.equals(state.path, rootPath));
    return DependencyOverrideState._(
      rootPath: rootPath,
      roots: roots,
      root: root,
    );
  }

  /// Patchwork state root.
  final String rootPath;

  final List<_OverrideRootState> _roots;
  final _OverrideRootState _root;

  /// Returns a conflicting user-owned override, if Patchwork cannot write one.
  DependencyOverrideConflict? blockingConflict({
    required String package,
    required String targetPath,
    bool replaceRootOverride = false,
  }) {
    for (final root in _roots) {
      final canReplaceHere =
          replaceRootOverride && p.equals(root.path, rootPath);
      if (_hasBlockingPathOverride(
        workspaceRootPath: root.path,
        dependencyOverrides: root.pubspecOverrideDependencyOverrides,
        package: package,
        path: targetPath,
        replaceExisting: canReplaceHere,
      )) {
        return DependencyOverrideConflict(
          fileName: 'pubspec_overrides.yaml',
          path: p.join(root.path, 'pubspec_overrides.yaml'),
        );
      }
      if (root.hasPubspecOverrideDependencyOverrides) {
        continue;
      }
      if (root.pubspecDependencyOverrideValues.containsKey(package)) {
        return DependencyOverrideConflict(
          fileName: 'pubspec.yaml',
          path: p.join(root.path, 'pubspec.yaml'),
        );
      }
    }
    return null;
  }

  /// Whether any active project override points at [absoluteAppliedPath].
  bool hasActiveAppliedOverride(
    AppliedMarker marker, {
    required String absoluteAppliedPath,
  }) {
    for (final root in _roots) {
      if (_overrideValuePointsToPath(
        workspaceRootPath: root.path,
        value: root.pubspecOverrideDependencyOverrides[marker.package],
        path: absoluteAppliedPath,
      )) {
        return true;
      }
      if (root.hasPubspecOverrideDependencyOverrides) {
        continue;
      }
      if (_overrideValuePointsToPath(
        workspaceRootPath: root.path,
        value: root.pubspecDependencyOverrideValues[marker.package],
        path: absoluteAppliedPath,
      )) {
        return true;
      }
    }
    return false;
  }

  /// Returns user-owned override state that still references applied output.
  DependencyOverrideConflict? userOwnedAppliedOverride(
    AppliedMarker marker, {
    required String absoluteAppliedPath,
  }) {
    for (final root in _roots) {
      if (!p.equals(root.path, rootPath) &&
          _overrideValuePointsToPath(
            workspaceRootPath: root.path,
            value: root.pubspecOverrideDependencyOverrides[marker.package],
            path: absoluteAppliedPath,
          )) {
        return DependencyOverrideConflict(
          fileName: 'pubspec_overrides.yaml',
          path: p.join(root.path, 'pubspec_overrides.yaml'),
        );
      }

      if (_overrideValuePointsToPath(
        workspaceRootPath: root.path,
        value: root.pubspecDependencyOverrideValues[marker.package],
        path: absoluteAppliedPath,
      )) {
        return DependencyOverrideConflict(
          fileName: 'pubspec.yaml',
          path: p.join(root.path, 'pubspec.yaml'),
        );
      }
    }
    return null;
  }

  /// Whether an override already exists outside Patchwork-owned applied state.
  bool hasForeignOverride(String package, AppliedMarker? applied) {
    for (final root in _roots) {
      if (root.pubspecOverrideDependencyOverrides.containsKey(package)) {
        if (p.equals(root.path, rootPath) &&
            applied != null &&
            _overrideValuePointsToPath(
              workspaceRootPath: root.path,
              value: root.pubspecOverrideDependencyOverrides[package],
              path: applied.path,
            )) {
          continue;
        }
        return true;
      }
      if (root.hasPubspecOverrideDependencyOverrides) {
        continue;
      }
      if (root.pubspecDependencyOverrideValues.containsKey(package)) {
        return true;
      }
    }
    return false;
  }

  /// Whether the state-root `pubspec_overrides.yaml` points [package] at [path].
  bool rootOverridePointsToPath({
    required String package,
    required String path,
  }) {
    return _overrideValuePointsToPath(
      workspaceRootPath: rootPath,
      value: _root.pubspecOverrideDependencyOverrides[package],
      path: path,
    );
  }

  /// Dependency overrides from the root pubspec, normalized relative to root.
  Map<String, Object?> rootPubspecDependencyOverrides({
    String? skippedPackage,
  }) {
    final dependencyOverrides = <String, Object?>{};
    // `pubspec_overrides.yaml` replaces only the state-root pubspec fields.
    // Workspace member overrides remain active in their own pubspec files.
    for (final entry in _root.pubspecDependencyOverrideValues.entries) {
      if (entry.key == skippedPackage) {
        continue;
      }
      dependencyOverrides[entry.key] = _rootRelativePathOverride(entry.value);
    }
    return dependencyOverrides;
  }

  /// Patchwork-owned mirrors currently recorded by applied markers.
  static Map<String, Object?> mirroredPubspecDependencyOverrides(
    Iterable<AppliedMarker> markers,
  ) {
    final dependencyOverrides = <String, Object?>{};
    for (final marker in markers) {
      dependencyOverrides.addAll(marker.mirroredPubspecDependencyOverrides);
    }
    return dependencyOverrides;
  }

  /// Patchwork-owned overrides currently represented by applied markers.
  static Map<String, Object?> ownedPubspecDependencyOverrides(
    Iterable<AppliedMarker> markers,
  ) {
    final dependencyOverrides = <String, Object?>{};
    for (final marker in markers) {
      dependencyOverrides.addAll(marker.mirroredPubspecDependencyOverrides);
      dependencyOverrides[marker.package] = {'path': marker.path};
    }
    return dependencyOverrides;
  }

  Object? _rootRelativePathOverride(Object? value) {
    final path = _pathOverridePath(value);
    if (path == null) {
      return value;
    }
    final absolutePath = p.normalize(
      p.isAbsolute(path) ? path : p.absolute(rootPath, path),
    );
    final pathOverride = value as Map<String, Object?>;
    return {
      ...pathOverride,
      'path': p.posix.joinAll(
        p.split(p.relative(absolutePath, from: rootPath)),
      ),
    };
  }
}

/// A dependency override file that blocks Patchwork-owned updates.
final class DependencyOverrideConflict {
  /// Creates a dependency override conflict.
  const DependencyOverrideConflict({
    required this.fileName,
    required this.path,
  });

  /// Human-readable file name for diagnostics.
  final String fileName;

  /// Absolute path to the conflicting file.
  final String path;
}

final class _OverrideRootState {
  _OverrideRootState({
    required this.path,
    required this.pubspecOverrides,
    required this.pubspecDependencyOverrides,
  });

  final String path;
  final PubspecOverridesSnapshot pubspecOverrides;
  final PubspecDependencyOverrides pubspecDependencyOverrides;
  Map<String, Object?>? _pubspecDependencyOverrides;

  bool get hasPubspecOverrideDependencyOverrides =>
      pubspecOverrides.hasDependencyOverrides;

  Map<String, Object?> get pubspecOverrideDependencyOverrides =>
      pubspecOverrides.dependencyOverrides;

  Map<String, Object?> get pubspecDependencyOverrideValues {
    return _pubspecDependencyOverrides ??= pubspecDependencyOverrides
        .dependencyOverrides(packageRootPath: path);
  }
}

bool _hasBlockingPathOverride({
  required String workspaceRootPath,
  required Map<String, Object?> dependencyOverrides,
  required String package,
  required String path,
  required bool replaceExisting,
}) {
  final existing = dependencyOverrides[package];
  if (existing == null) {
    return false;
  }
  final existingPath = _pathOverridePath(existing);
  if (replaceExisting && existingPath != null) {
    if (_pathsPointToSameLocation(workspaceRootPath, existingPath, path)) {
      return false;
    }
  }

  return true;
}

bool _overrideValuePointsToPath({
  required String workspaceRootPath,
  required Object? value,
  required String path,
}) {
  final overridePath = _pathOverridePath(value);
  if (overridePath == null) {
    return false;
  }
  return _pathsPointToSameLocation(workspaceRootPath, overridePath, path);
}

String? _pathOverridePath(Object? value) {
  if (value is! Map<String, Object?>) {
    return null;
  }
  final path = value['path'];
  return path is String ? path : null;
}

bool _pathsPointToSameLocation(
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
