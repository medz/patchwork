import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../diagnostics/diagnostic.dart';

final class PubspecOverridesStore {
  const PubspecOverridesStore();

  PubspecOverridePathsReadResult readDependencyOverridePaths({
    required String workspaceRootPath,
  }) {
    final overridesPath = p.join(workspaceRootPath, 'pubspec_overrides.yaml');
    final Map<String, Object?> overrides;
    try {
      overrides = _readPubspecOverrides(overridesPath);
    } on PubspecOverridesException catch (error) {
      return PubspecOverridePathsReadResult.failure(error.diagnostic);
    }
    final existingDependencyOverrides = overrides['dependency_overrides'];
    if (existingDependencyOverrides == null) {
      return PubspecOverridePathsReadResult.success(const {});
    }
    if (existingDependencyOverrides is! Map<String, Object?>) {
      return PubspecOverridePathsReadResult.failure(
        Diagnostic(
          code: 'pub.overrides_malformed',
          message: 'pubspec_overrides.yaml dependency_overrides is malformed.',
          location: overridesPath,
        ),
      );
    }

    final paths = <String, String>{};
    for (final entry in existingDependencyOverrides.entries) {
      final value = entry.value;
      if (value is Map<String, Object?>) {
        final path = value['path'];
        if (path is String) {
          paths[entry.key] = path;
        }
      }
    }

    return PubspecOverridePathsReadResult.success(paths);
  }

  bool isManagedPatchworkStoreOverride({
    required String workspaceRootPath,
    required String path,
  }) {
    return _isManagedPatchworkStoreOverride({
      'path': path,
    }, workspaceRootPath: workspaceRootPath);
  }

  void updateDependencyOverrides({
    required String workspaceRootPath,
    required Map<String, String> dependencyOverridePaths,
    bool removeStaleManagedOverrides = true,
  }) {
    final overridesPath = p.join(workspaceRootPath, 'pubspec_overrides.yaml');
    final overridesFile = File(overridesPath);
    if (dependencyOverridePaths.isEmpty && !overridesFile.existsSync()) {
      return;
    }

    final overrides = _readPubspecOverrides(overridesPath);
    final existingDependencyOverrides = overrides['dependency_overrides'];
    final dependencyOverrides = <String, Object?>{};
    if (existingDependencyOverrides != null) {
      if (existingDependencyOverrides is! Map<String, Object?>) {
        throw PubspecOverridesException(
          Diagnostic(
            code: 'pub.overrides_malformed',
            message:
                'pubspec_overrides.yaml dependency_overrides is malformed.',
            location: overridesPath,
          ),
        );
      }
      for (final entry in existingDependencyOverrides.entries) {
        if (dependencyOverridePaths.containsKey(entry.key)) {
          continue;
        }
        if (removeStaleManagedOverrides &&
            _isManagedPatchworkStoreOverride(
              entry.value,
              workspaceRootPath: workspaceRootPath,
            )) {
          continue;
        }
        dependencyOverrides[entry.key] = entry.value;
      }
    }

    for (final entry in dependencyOverridePaths.entries) {
      dependencyOverrides[entry.key] = {'path': entry.value};
    }
    overrides['dependency_overrides'] = dependencyOverrides;

    overridesFile.writeAsStringSync(
      _formatPubspecOverrides(overrides),
      flush: true,
    );
  }
}

final class PubspecOverridePathsReadResult {
  const PubspecOverridePathsReadResult._({
    this.paths = const {},
    this.diagnostic,
  });

  factory PubspecOverridePathsReadResult.success(Map<String, String> paths) {
    return PubspecOverridePathsReadResult._(paths: Map.unmodifiable(paths));
  }

  factory PubspecOverridePathsReadResult.failure(Diagnostic diagnostic) {
    return PubspecOverridePathsReadResult._(diagnostic: diagnostic);
  }

  final Map<String, String> paths;
  final Diagnostic? diagnostic;
}

bool _isManagedPatchworkStoreOverride(
  Object? value, {
  required String workspaceRootPath,
}) {
  if (value is! Map<String, Object?>) {
    return false;
  }

  final path = value['path'];
  if (path is! String) {
    return false;
  }

  final normalizedPath = p.posix.normalize(path.replaceAll('\\', '/'));
  if (normalizedPath == '.dart_tool/patchwork/store/pub' ||
      normalizedPath.startsWith('.dart_tool/patchwork/store/pub/')) {
    return true;
  }

  final patchworkStoreRoot = p.normalize(
    p.absolute(workspaceRootPath, '.dart_tool', 'patchwork', 'store', 'pub'),
  );
  final absolutePath = p.isAbsolute(path)
      ? p.normalize(path)
      : p.normalize(p.absolute(workspaceRootPath, path));
  return p.equals(patchworkStoreRoot, absolutePath) ||
      p.isWithin(patchworkStoreRoot, absolutePath);
}

final class PubspecOverridesException implements Exception {
  const PubspecOverridesException(this.diagnostic);

  final Diagnostic diagnostic;
}

Map<String, Object?> _readPubspecOverrides(String overridesPath) {
  final file = File(overridesPath);
  if (!file.existsSync()) {
    return <String, Object?>{};
  }

  try {
    final content = file.readAsStringSync();
    if (content.trim().isEmpty) {
      return <String, Object?>{};
    }
    final root = loadYaml(content);
    if (root == null) {
      return <String, Object?>{};
    }
    if (root is! YamlMap) {
      throw PubspecOverridesException(
        Diagnostic(
          code: 'pub.overrides_malformed',
          message: 'pubspec_overrides.yaml is malformed.',
          location: overridesPath,
        ),
      );
    }
    return _toStringKeyedMap(root, overridesPath);
  } on YamlException catch (error) {
    throw PubspecOverridesException(
      Diagnostic(
        code: 'pub.overrides_malformed',
        message: 'pubspec_overrides.yaml is malformed.',
        hint: error.message,
        location: overridesPath,
      ),
    );
  } on FormatException catch (error) {
    throw PubspecOverridesException(
      Diagnostic(
        code: 'pub.overrides_malformed',
        message: 'pubspec_overrides.yaml is malformed.',
        hint: error.message,
        location: overridesPath,
      ),
    );
  } on FileSystemException catch (error) {
    throw PubspecOverridesException(
      Diagnostic(
        code: 'pub.overrides_unreadable',
        message: 'Could not read pubspec_overrides.yaml.',
        hint: error.message,
        location: overridesPath,
      ),
    );
  }
}

Map<String, Object?> _toStringKeyedMap(YamlMap map, String location) {
  final result = <String, Object?>{};
  for (final entry in map.entries) {
    final key = entry.key;
    if (key is! String) {
      throw PubspecOverridesException(
        Diagnostic(
          code: 'pub.overrides_malformed',
          message: 'pubspec_overrides.yaml contains a non-string key.',
          location: location,
        ),
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

String _formatPubspecOverrides(Map<String, Object?> overrides) {
  final buffer = StringBuffer();
  for (final entry in overrides.entries) {
    _writeYamlEntry(buffer, entry.key, entry.value, indent: 0);
  }
  return buffer.toString();
}

void _writeYamlEntry(
  StringBuffer buffer,
  String key,
  Object? value, {
  required int indent,
}) {
  final prefix = ' ' * indent;
  if (value is Map<String, Object?>) {
    if (value.isEmpty) {
      buffer.writeln('$prefix${_formatYamlKey(key)}: {}');
      return;
    }
    buffer.writeln('$prefix${_formatYamlKey(key)}:');
    for (final entry in value.entries) {
      _writeYamlEntry(buffer, entry.key, entry.value, indent: indent + 2);
    }
    return;
  }

  if (value is List<Object?>) {
    if (value.isEmpty) {
      buffer.writeln('$prefix${_formatYamlKey(key)}: []');
      return;
    }
    buffer.writeln('$prefix${_formatYamlKey(key)}:');
    for (final item in value) {
      _writeYamlListItem(buffer, item, indent: indent + 2);
    }
    return;
  }

  buffer.writeln('$prefix${_formatYamlKey(key)}: ${_formatYamlScalar(value)}');
}

void _writeYamlListItem(
  StringBuffer buffer,
  Object? value, {
  required int indent,
}) {
  final prefix = ' ' * indent;
  if (value is Map<String, Object?>) {
    if (value.isEmpty) {
      buffer.writeln('$prefix- {}');
      return;
    }
    var first = true;
    for (final entry in value.entries) {
      if (first) {
        buffer.writeln('$prefix- ${_formatYamlKey(entry.key)}:');
        _writeYamlNestedValue(buffer, entry.value, indent + 4);
        first = false;
      } else {
        _writeYamlEntry(buffer, entry.key, entry.value, indent: indent + 2);
      }
    }
    return;
  }

  buffer.writeln('$prefix- ${_formatYamlScalar(value)}');
}

void _writeYamlNestedValue(StringBuffer buffer, Object? value, int indent) {
  if (value is Map<String, Object?>) {
    for (final entry in value.entries) {
      _writeYamlEntry(buffer, entry.key, entry.value, indent: indent);
    }
    return;
  }
  buffer.writeln('${' ' * indent}${_formatYamlScalar(value)}');
}

String _formatYamlKey(String value) => _formatYamlScalar(value);

String _formatYamlScalar(Object? value) {
  if (value == null) {
    return 'null';
  }
  if (value is num || value is bool) {
    return value.toString();
  }
  final string = value.toString();
  if (RegExp(r'^[A-Za-z0-9._/@:%+=-]+$').hasMatch(string)) {
    return string;
  }
  return jsonEncode(string);
}
