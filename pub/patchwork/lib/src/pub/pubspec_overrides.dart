import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../error.dart';
import '../internal/yaml_writer.dart';
import '../io/atomic_file_writer.dart';

final class PubspecOverrides {
  const PubspecOverrides({this.fileWriter = const AtomicFileWriter()});

  final AtomicFileWriter fileWriter;

  Map<String, String> readPathOverrides(String workspaceRootPath) {
    final overrides = _read(workspaceRootPath);
    final dependencyOverrides = overrides['dependency_overrides'];
    if (dependencyOverrides == null) {
      return const {};
    }
    if (dependencyOverrides is! Map<String, Object?>) {
      throw PatchworkException(
        'pubspec_overrides.yaml dependency_overrides is malformed.',
        code: 'pub.overrides_malformed',
        location: _path(workspaceRootPath),
      );
    }

    final paths = <String, String>{};
    for (final entry in dependencyOverrides.entries) {
      final value = entry.value;
      if (value is Map<String, Object?> && value['path'] is String) {
        paths[entry.key] = value['path'] as String;
      }
    }
    return paths;
  }

  void upsertPathOverride({
    required String workspaceRootPath,
    required String package,
    required String path,
  }) {
    final overrides = _read(workspaceRootPath);
    final dependencyOverrides = _dependencyOverrides(
      overrides,
      workspaceRootPath,
    );
    dependencyOverrides[package] = {'path': path};
    overrides['dependency_overrides'] = dependencyOverrides;
    _write(workspaceRootPath, overrides);
  }

  bool removePathOverrideIfMatches({
    required String workspaceRootPath,
    required String package,
    required String path,
  }) {
    final overrides = _read(workspaceRootPath);
    final dependencyOverrides = _dependencyOverrides(
      overrides,
      workspaceRootPath,
      create: false,
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

  bool pointsToPath({
    required String workspaceRootPath,
    required String package,
    required String path,
  }) {
    final pathOverrides = readPathOverrides(workspaceRootPath);
    final current = pathOverrides[package];
    return current != null &&
        _pathsPointToSameLocation(workspaceRootPath, current, path);
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
    String workspaceRootPath, {
    bool create = true,
  }) {
    final existing = overrides['dependency_overrides'];
    if (existing == null) {
      return create ? <String, Object?>{} : <String, Object?>{};
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
    if (overrides.isEmpty) {
      final file = File(path);
      if (file.existsSync()) {
        file.deleteSync();
      }
      return;
    }
    fileWriter.writeString(path, formatYamlMap(overrides));
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
