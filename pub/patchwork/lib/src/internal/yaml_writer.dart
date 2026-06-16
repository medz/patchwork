import 'dart:convert';

String formatYamlMap(Map<String, Object?> value) {
  final buffer = StringBuffer();
  for (final entry in value.entries) {
    writeYamlEntry(buffer, entry.key, entry.value, indent: 0);
  }
  return buffer.toString();
}

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
    var first = true;
    for (final entry in value.entries) {
      if (first) {
        buffer.writeln('$prefix- ${formatYamlKey(entry.key)}:');
        writeYamlNestedValue(buffer, entry.value, indent + 4);
        first = false;
      } else {
        writeYamlEntry(buffer, entry.key, entry.value, indent: indent + 2);
      }
    }
    return;
  }

  buffer.writeln('$prefix- ${formatYamlScalar(value)}');
}

void writeYamlNestedValue(StringBuffer buffer, Object? value, int indent) {
  if (value is Map<String, Object?>) {
    for (final entry in value.entries) {
      writeYamlEntry(buffer, entry.key, entry.value, indent: indent);
    }
    return;
  }
  buffer.writeln('${' ' * indent}${formatYamlScalar(value)}');
}

String formatYamlKey(String value) => formatYamlScalar(value);

String formatYamlScalar(Object? value) {
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
