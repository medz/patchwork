import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../error.dart';

/// Reads user-owned `dependency_overrides` entries from a project pubspec.
final class PubspecDependencyOverrides {
  /// Creates a pubspec dependency override reader.
  const PubspecDependencyOverrides();

  /// Returns whether [packageRootPath]/`pubspec.yaml` overrides [package].
  bool hasOverride({required String packageRootPath, required String package}) {
    final pubspecPath = p.join(packageRootPath, 'pubspec.yaml');
    if (!File(pubspecPath).existsSync()) {
      return false;
    }
    final pubspec = _read(pubspecPath);
    final dependencyOverrides = pubspec['dependency_overrides'];
    if (dependencyOverrides == null) {
      return false;
    }
    if (dependencyOverrides is! YamlMap) {
      throw PatchworkException(
        'pubspec.yaml dependency_overrides is malformed.',
        code: 'pub.malformed_pubspec',
        location: pubspecPath,
      );
    }

    for (final entry in dependencyOverrides.entries) {
      final name = entry.key;
      if (name is! String) {
        throw PatchworkException(
          'pubspec.yaml dependency_overrides contains a non-string package name.',
          code: 'pub.malformed_pubspec',
          location: pubspecPath,
        );
      }
      if (name == package) {
        return true;
      }
    }
    return false;
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
