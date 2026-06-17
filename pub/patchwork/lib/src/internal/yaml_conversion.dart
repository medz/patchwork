import 'package:yaml/yaml.dart';

/// Converts a YAML map into plain Dart collections with string map keys.
Map<String, Object?> yamlMapToStringKeyedMap(YamlMap map) {
  final result = <String, Object?>{};
  for (final entry in map.entries) {
    final key = entry.key;
    if (key is! String) {
      throw const FormatException('YAML map contains a non-string key.');
    }
    result[key] = yamlValueToDart(entry.value);
  }
  return result;
}

/// Converts YAML collection nodes into plain Dart maps and lists.
Object? yamlValueToDart(Object? value) {
  if (value is YamlMap) {
    return yamlMapToStringKeyedMap(value);
  }
  if (value is YamlList) {
    return [for (final item in value.nodes) yamlValueToDart(item.value)];
  }
  if (value == null || value is String || value is num || value is bool) {
    return value;
  }
  return value.toString();
}
