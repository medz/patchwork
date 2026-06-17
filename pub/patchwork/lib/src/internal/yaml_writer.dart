import 'dart:convert';

/// Formats a string-keyed map as the subset of YAML Patchwork writes.
///
/// The writer deliberately emits a small deterministic YAML shape instead of
/// preserving original formatting. It is used for Patchwork-owned files where
/// stable diffs are more important than round-tripping comments.
String formatYamlMap(Map<String, Object?> value) {
  final buffer = StringBuffer();
  for (final entry in value.entries) {
    writeYamlEntry(buffer, entry.key, entry.value, indent: 0);
  }
  return buffer.toString();
}

/// Writes one YAML map entry to [buffer] using [indent] spaces.
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

/// Writes one YAML list item to [buffer] using [indent] spaces.
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
///
/// Plain keys are kept readable; keys containing whitespace or other special
/// characters are JSON-escaped, which is valid YAML for this subset.
String formatYamlKey(String value) {
  if (RegExp(r'^[A-Za-z0-9._/@:%+=-]+$').hasMatch(value)) {
    return value;
  }
  return jsonEncode(value);
}

/// Formats a scalar YAML value.
///
/// Strings are always quoted through JSON escaping so paths and versions remain
/// unambiguous even when they contain characters YAML would otherwise interpret.
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
