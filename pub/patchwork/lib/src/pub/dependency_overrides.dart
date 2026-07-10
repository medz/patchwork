import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../error.dart';

/// Reads user-owned `dependency_overrides` entries from a project pubspec.
final class PubspecDependencyOverrides {
  /// Creates a pubspec dependency override reader.
  const PubspecDependencyOverrides();

  /// Returns `dependency_overrides` from [packageRootPath]/`pubspec.yaml`.
  Map<String, Object?> dependencyOverrides({required String packageRootPath}) {
    final pubspecPath = p.join(packageRootPath, 'pubspec.yaml');
    if (!File(pubspecPath).existsSync()) {
      return const {};
    }
    final pubspec = _read(pubspecPath);
    final dependencyOverrides = pubspec['dependency_overrides'];
    if (dependencyOverrides == null) {
      return const {};
    }
    if (dependencyOverrides is! YamlMap) {
      throw PatchworkException(
        'pubspec.yaml dependency_overrides is malformed.',
        code: 'pub.malformed_pubspec',
        location: pubspecPath,
      );
    }

    return _toStringKeyedMap(dependencyOverrides, pubspecPath);
  }

  YamlMap _read(String pubspecPath) {
    final file = File(pubspecPath);
    try {
      final decoded = loadYaml(file.readAsStringSync());
      if (decoded is! YamlMap) {
        throw PatchworkException(
          'pubspec.yaml must contain a YAML object.',
          code: 'pub.malformed_pubspec',
          location: pubspecPath,
        );
      }
      return decoded;
    } on YamlException catch (error) {
      throw PatchworkException(
        'pubspec.yaml is malformed.',
        code: 'pub.malformed_pubspec',
        hint: error.message,
        location: pubspecPath,
      );
    } on FileSystemException catch (error) {
      throw PatchworkException(
        'Could not read pubspec.yaml.',
        code: 'pub.pubspec_not_readable',
        hint: error.message,
        location: pubspecPath,
      );
    }
  }
}

Map<String, Object?> _toStringKeyedMap(YamlMap map, String location) {
  final result = <String, Object?>{};
  for (final entry in map.entries) {
    final key = entry.key;
    if (key is! String) {
      throw PatchworkException(
        'pubspec.yaml dependency_overrides contains a non-string package name.',
        code: 'pub.malformed_pubspec',
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
