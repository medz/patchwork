import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';
import 'package:yaml_edit/yaml_edit.dart';

import '../error.dart';
import '../io/atomic_file_writer.dart';
import 'override_editor.dart';
import 'yaml.dart';

/// Reads and writes `pubspec_overrides.yaml` documents.
final class PubspecOverrides {
  /// Creates an overrides file helper with an injectable writer.
  const PubspecOverrides({this.fileWriter = const AtomicFileWriter()});

  /// The writer used to persist override updates.
  final AtomicFileWriter fileWriter;

  /// Opens one stateful editor after reading the file once.
  PubspecOverridesEditor edit({required String workspaceRootPath}) {
    final document = _read(workspaceRootPath);
    return PubspecOverridesEditor(
      workspaceRootPath: workspaceRootPath,
      document: document,
      dependencyOverrides: _dependencyOverrides(document, workspaceRootPath),
      hasDependencyOverrides: document.containsKey('dependency_overrides'),
      write: (nextDocument) => _write(workspaceRootPath, nextDocument),
    );
  }

  /// Reads the dependency override state from the file.
  PubspecOverridesSnapshot readDependencyOverrides({
    required String workspaceRootPath,
  }) {
    final document = _read(workspaceRootPath);
    return PubspecOverridesSnapshot(
      hasDependencyOverrides: document.containsKey('dependency_overrides'),
      dependencyOverrides: _dependencyOverrides(document, workspaceRootPath),
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
      try {
        return yamlMapToStringKeyedMap(decoded);
      } on FormatException catch (error) {
        throw PatchworkException(
          'pubspec_overrides.yaml contains a non-string key.',
          code: 'pub.overrides_malformed',
          hint: error.message,
          location: file.path,
        );
      }
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
    Map<String, Object?> document,
    String workspaceRootPath,
  ) {
    final existing = document['dependency_overrides'];
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

  void _write(String workspaceRootPath, Map<String, Object?> document) {
    final path = _path(workspaceRootPath);
    try {
      if (document.isEmpty) {
        final file = File(path);
        if (file.existsSync()) {
          file.deleteSync();
        }
        return;
      }
      final editor = YamlEditor('');
      editor.update([], document);
      fileWriter.writeString(path, '${editor.toString()}\n');
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

/// Parsed dependency override state from one `pubspec_overrides.yaml`.
final class PubspecOverridesSnapshot {
  /// Creates parsed dependency override state.
  PubspecOverridesSnapshot({
    required this.hasDependencyOverrides,
    required Map<String, Object?> dependencyOverrides,
  }) : dependencyOverrides = Map.unmodifiable(dependencyOverrides);

  /// Whether the file explicitly contains `dependency_overrides`.
  final bool hasDependencyOverrides;

  /// Parsed dependency override values.
  final Map<String, Object?> dependencyOverrides;
}

String _path(String workspaceRootPath) {
  return p.join(workspaceRootPath, 'pubspec_overrides.yaml');
}
