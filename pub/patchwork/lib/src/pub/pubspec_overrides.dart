import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../error.dart';
import '../internal/yaml_writer.dart';
import '../io/atomic_file_writer.dart';

/// Reads and updates dependency overrides in `pubspec_overrides.yaml`.
///
/// Patchwork writes only generated path overrides for patched packages. The
/// file can also contain user-owned overrides, so removal and replacement
/// methods verify the existing path before mutating a package entry.
final class PubspecOverrides {
  /// Creates an overrides helper with an injectable file writer.
  const PubspecOverrides({this.fileWriter = const AtomicFileWriter()});

  /// The writer used to persist overrides updates.
  final AtomicFileWriter fileWriter;

  /// Inserts or replaces the path override for [package].
  ///
  /// The resulting override is written under `dependency_overrides` and points
  /// at [path], usually a project-relative `.dart_tool/patchwork/...` path.
  void upsertPathOverride({
    required String workspaceRootPath,
    required String package,
    required String path,
    Map<String, Object?> pubspecDependencyOverrides = const {},
  }) {
    final overrides = _read(workspaceRootPath);
    final dependencyOverrides = _dependencyOverrides(
      overrides,
      workspaceRootPath,
    )..addAll(pubspecDependencyOverrides);
    dependencyOverrides[package] = {'path': path};
    overrides['dependency_overrides'] = dependencyOverrides;
    _write(workspaceRootPath, overrides);
  }

  /// Returns whether an existing override blocks writing [path] for [package].
  ///
  /// When [replaceExisting] is true, an override that already points to [path]
  /// is considered Patchwork-owned and therefore non-blocking. Any other
  /// same-package override is treated as user-owned state.
  bool hasBlockingPathOverride({
    required String workspaceRootPath,
    required String package,
    required String path,
    required bool replaceExisting,
  }) {
    final overrides = _read(workspaceRootPath);
    final dependencyOverrides = _dependencyOverrides(
      overrides,
      workspaceRootPath,
    );
    final existing = dependencyOverrides[package];
    if (existing == null) {
      return false;
    }
    if (replaceExisting &&
        existing is Map<String, Object?> &&
        existing['path'] is String) {
      final existingPath = existing['path'] as String;
      if (_pathsPointToSameLocation(workspaceRootPath, existingPath, path)) {
        return false;
      }
    }

    return true;
  }

  /// Returns whether any override entry exists for [package].
  bool hasOverride({
    required String workspaceRootPath,
    required String package,
  }) {
    final dependencyOverrides = _dependencyOverrides(
      _read(workspaceRootPath),
      workspaceRootPath,
    );
    return dependencyOverrides.containsKey(package);
  }

  /// Returns whether `pubspec_overrides.yaml` defines `dependency_overrides`.
  bool hasDependencyOverrides({required String workspaceRootPath}) {
    final overrides = _read(workspaceRootPath);
    if (!overrides.containsKey('dependency_overrides')) {
      return false;
    }
    _dependencyOverrides(overrides, workspaceRootPath);
    return true;
  }

  /// Removes the override for [package] only if it still points at [path].
  ///
  /// This protects user edits made after Patchwork applied a package.
  bool removePathOverrideIfMatches({
    required String workspaceRootPath,
    required String package,
    required String path,
  }) {
    final overrides = _read(workspaceRootPath);
    final dependencyOverrides = _dependencyOverrides(
      overrides,
      workspaceRootPath,
    );
    final existing = dependencyOverrides[package];
    if (existing is! Map<String, Object?> || existing['path'] is! String) {
      return false;
    }

    final existingPath = existing['path'] as String;
    if (!_pathsPointToSameLocation(workspaceRootPath, existingPath, path)) {
      return false;
    }

    dependencyOverrides.remove(package);
    if (dependencyOverrides.isEmpty) {
      overrides.remove('dependency_overrides');
    } else {
      overrides['dependency_overrides'] = dependencyOverrides;
    }
    _write(workspaceRootPath, overrides);
    return true;
  }

  /// Returns whether the override for [package] points at [path].
  bool pointsToPath({
    required String workspaceRootPath,
    required String package,
    required String path,
  }) {
    final dependencyOverrides = _dependencyOverrides(
      _read(workspaceRootPath),
      workspaceRootPath,
    );
    final existing = dependencyOverrides[package];
    return existing is Map<String, Object?> &&
        existing['path'] is String &&
        _pathsPointToSameLocation(
          workspaceRootPath,
          existing['path'] as String,
          path,
        );
  }

  Map<String, Object?> _read(String workspaceRootPath) {
    final file = File(_path(workspaceRootPath));
    if (!file.existsSync()) {
      return <String, Object?>{};
    }

    try {
      final content = file.readAsStringSync();
      if (content.trim().isEmpty) {
        return <String, Object?>{};
      }
      final decoded = loadYaml(content);
      if (decoded == null) {
        return <String, Object?>{};
      }
      if (decoded is! YamlMap) {
        throw PatchworkException(
          'pubspec_overrides.yaml must contain a YAML object.',
          code: 'pub.overrides_malformed',
          location: file.path,
        );
      }
      return _toStringKeyedMap(decoded, file.path);
    } on YamlException catch (error) {
      throw PatchworkException(
        'pubspec_overrides.yaml is malformed.',
        code: 'pub.overrides_malformed',
        hint: error.message,
        location: file.path,
      );
    } on FileSystemException catch (error) {
      throw PatchworkException(
        'Could not read pubspec_overrides.yaml.',
        code: 'pub.overrides_unreadable',
        hint: error.message,
        location: file.path,
      );
    }
  }

  Map<String, Object?> _dependencyOverrides(
    Map<String, Object?> overrides,
    String workspaceRootPath,
  ) {
    final existing = overrides['dependency_overrides'];
    if (existing == null) {
      return <String, Object?>{};
    }
    if (existing is! Map<String, Object?>) {
      throw PatchworkException(
        'pubspec_overrides.yaml dependency_overrides is malformed.',
        code: 'pub.overrides_malformed',
        location: _path(workspaceRootPath),
      );
    }
    return Map<String, Object?>.of(existing);
  }

  void _write(String workspaceRootPath, Map<String, Object?> overrides) {
    final path = _path(workspaceRootPath);
    try {
      if (overrides.isEmpty) {
        final file = File(path);
        if (file.existsSync()) {
          file.deleteSync();
        }
        return;
      }
      fileWriter.writeString(path, formatYamlMap(overrides));
    } on FileSystemException catch (error) {
      throw PatchworkException(
        'Could not write pubspec_overrides.yaml.',
        code: 'pub.overrides_unwritable',
        hint: error.message,
        location: path,
      );
    }
  }
}

String _path(String workspaceRootPath) {
  return p.join(workspaceRootPath, 'pubspec_overrides.yaml');
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

Map<String, Object?> _toStringKeyedMap(YamlMap map, String location) {
  final result = <String, Object?>{};
  for (final entry in map.entries) {
    final key = entry.key;
    if (key is! String) {
      throw PatchworkException(
        'pubspec_overrides.yaml contains a non-string key.',
        code: 'pub.overrides_malformed',
        location: location,
      );
    }
    result[key] = _convertYamlValue(entry.value, location);
  }
  return result;
}

Object? _convertYamlValue(Object? value, String location) {
  if (value is YamlMap) {
    return _toStringKeyedMap(value, location);
  }
  if (value is YamlList) {
    return [
      for (final item in value.nodes) _convertYamlValue(item.value, location),
    ];
  }
  if (value == null || value is String || value is num || value is bool) {
    return value;
  }
  return value.toString();
}
