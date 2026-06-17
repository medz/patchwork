import 'dart:convert';

/// Formats a string-keyed map as deterministic YAML.
String formatYamlMap(Map<String, Object?> value) {
  final buffer = StringBuffer();
  for (final entry in value.entries) {
    writeYamlEntry(buffer, entry.key, entry.value, indent: 0);
  }
  return buffer.toString();
}

/// Writes one YAML map entry to [buffer].
void writeYamlEntry(
  StringBuffer buffer,
  String key,
  Object? value, {
  required int indent,
}) {
  final prefix = ' ' * indent;
  if (value is Map<String, Object?>) {
    if (value.isEmpty) {
      buffer.writeln('$prefix${formatYamlKey(key)}: {}');
      return;
    }
    buffer.writeln('$prefix${formatYamlKey(key)}:');
    for (final entry in value.entries) {
      writeYamlEntry(buffer, entry.key, entry.value, indent: indent + 2);
    }
    return;
  }

  if (value is List<Object?>) {
    if (value.isEmpty) {
      buffer.writeln('$prefix${formatYamlKey(key)}: []');
      return;
    }
    buffer.writeln('$prefix${formatYamlKey(key)}:');
    for (final item in value) {
      writeYamlListItem(buffer, item, indent: indent + 2);
    }
    return;
  }

  buffer.writeln('$prefix${formatYamlKey(key)}: ${formatYamlScalar(value)}');
}

/// Writes one YAML list item to [buffer].
void writeYamlListItem(
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
    buffer.writeln('$prefix-');
    for (final entry in value.entries) {
      writeYamlEntry(buffer, entry.key, entry.value, indent: indent + 2);
    }
    return;
  }

  buffer.writeln('$prefix- ${formatYamlScalar(value)}');
}

/// Formats a YAML key, quoting it only when required.
String formatYamlKey(String value) {
  if (RegExp(r'^[A-Za-z0-9._/@:%+=-]+$').hasMatch(value)) {
    return value;
  }
  return jsonEncode(value);
}

/// Formats a scalar YAML value.
String formatYamlScalar(Object? value) {
  if (value == null) {
    return 'null';
  }
  if (value is num || value is bool) {
    return value.toString();
  }
  if (value is String) {
    return jsonEncode(value);
  }
  return jsonEncode(value.toString());
}
