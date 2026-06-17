import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../error.dart';
import '../internal/yaml_conversion.dart';
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
  Map<String, Object?> upsertPathOverride({
    required String workspaceRootPath,
    required String package,
    required String path,
    Map<String, Object?> pubspecDependencyOverrides = const {},
    Map<String, Object?> mirroredPubspecDependencyOverrides = const {},
  }) {
    final overrides = _read(workspaceRootPath);
    final hasActiveDependencyOverrides = overrides.containsKey(
      'dependency_overrides',
    );
    final dependencyOverrides = _dependencyOverrides(
      overrides,
      workspaceRootPath,
    );
    _removeMirroredPubspecDependencyOverrides(
      dependencyOverrides,
      mirroredPubspecDependencyOverrides,
      workspaceRootPath,
    );

    final canIntroduceMirrors =
        !hasActiveDependencyOverrides ||
        _hasOnlyPatchworkPathOverrides(dependencyOverrides, workspaceRootPath);
    final nextMirroredPubspecDependencyOverrides =
        _restoreMirroredPubspecDependencyOverrides(
          dependencyOverrides: dependencyOverrides,
          pubspecDependencyOverrides: pubspecDependencyOverrides,
          mirroredPubspecDependencyOverrides:
              mirroredPubspecDependencyOverrides,
          workspaceRootPath: workspaceRootPath,
          canIntroduceMirrors: canIntroduceMirrors,
          retainPreviousMirrors: true,
        );
    dependencyOverrides[package] = {'path': path};
    overrides['dependency_overrides'] = dependencyOverrides;
    _write(workspaceRootPath, overrides);
    return nextMirroredPubspecDependencyOverrides;
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
  ///
  /// Returns the next Patchwork-owned mirror set that should remain while other
  /// Patchwork overrides keep `pubspec_overrides.yaml` active.
  Map<String, Object?> removePathOverrideIfMatches({
    required String workspaceRootPath,
    required String package,
    required String path,
    Map<String, Object?> pubspecDependencyOverrides = const {},
    Map<String, Object?> mirroredPubspecDependencyOverrides = const {},
  }) {
    final overrides = _read(workspaceRootPath);
    final dependencyOverrides = _dependencyOverrides(
      overrides,
      workspaceRootPath,
    );
    final existing = dependencyOverrides[package];
    if (existing is Map<String, Object?> && existing['path'] is String) {
      final existingPath = existing['path'] as String;
      if (_pathsPointToSameLocation(workspaceRootPath, existingPath, path)) {
        dependencyOverrides.remove(package);
      }
    }
    _removeMirroredPubspecDependencyOverrides(
      dependencyOverrides,
      mirroredPubspecDependencyOverrides,
      workspaceRootPath,
    );
    final hasPatchworkPathOverride = _hasPatchworkPathOverride(
      dependencyOverrides,
      workspaceRootPath,
    );
    final nextMirroredPubspecDependencyOverrides =
        _restoreMirroredPubspecDependencyOverrides(
          dependencyOverrides: dependencyOverrides,
          pubspecDependencyOverrides: pubspecDependencyOverrides,
          mirroredPubspecDependencyOverrides:
              mirroredPubspecDependencyOverrides,
          workspaceRootPath: workspaceRootPath,
          canIntroduceMirrors: _hasOnlyPatchworkPathOverrides(
            dependencyOverrides,
            workspaceRootPath,
          ),
          retainPreviousMirrors: hasPatchworkPathOverride,
        );
    if (dependencyOverrides.isEmpty) {
      overrides.remove('dependency_overrides');
    } else {
      overrides['dependency_overrides'] = dependencyOverrides;
    }
    _write(workspaceRootPath, overrides);
    return nextMirroredPubspecDependencyOverrides;
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

Map<String, Object?> _restoreMirroredPubspecDependencyOverrides({
  required Map<String, Object?> dependencyOverrides,
  required Map<String, Object?> pubspecDependencyOverrides,
  required Map<String, Object?> mirroredPubspecDependencyOverrides,
  required String workspaceRootPath,
  required bool canIntroduceMirrors,
  required bool retainPreviousMirrors,
}) {
  final nextMirroredPubspecDependencyOverrides = <String, Object?>{};
  for (final entry in pubspecDependencyOverrides.entries) {
    if (dependencyOverrides.containsKey(entry.key)) {
      continue;
    }
    final wasMirrored = mirroredPubspecDependencyOverrides.containsKey(
      entry.key,
    );
    if (!canIntroduceMirrors && (!retainPreviousMirrors || !wasMirrored)) {
      continue;
    }
    dependencyOverrides[entry.key] = entry.value;
    nextMirroredPubspecDependencyOverrides[entry.key] = entry.value;
  }
  return nextMirroredPubspecDependencyOverrides;
}

void _removeMirroredPubspecDependencyOverrides(
  Map<String, Object?> dependencyOverrides,
  Map<String, Object?> mirroredPubspecDependencyOverrides,
  String workspaceRootPath,
) {
  for (final entry in mirroredPubspecDependencyOverrides.entries) {
    final existing = dependencyOverrides[entry.key];
    if (_sameOverrideValue(workspaceRootPath, existing, entry.value)) {
      dependencyOverrides.remove(entry.key);
    }
  }
}

bool _hasOnlyPatchworkPathOverrides(
  Map<String, Object?> dependencyOverrides,
  String workspaceRootPath,
) {
  return dependencyOverrides.isNotEmpty &&
      dependencyOverrides.values.every(
        (value) => _isPatchworkPathOverride(value, workspaceRootPath),
      );
}

bool _hasPatchworkPathOverride(
  Map<String, Object?> dependencyOverrides,
  String workspaceRootPath,
) {
  return dependencyOverrides.values.any(
    (value) => _isPatchworkPathOverride(value, workspaceRootPath),
  );
}

bool _isPatchworkPathOverride(Object? value, String workspaceRootPath) {
  if (value is! Map<String, Object?> || value['path'] is! String) {
    return false;
  }
  final path = value['path'] as String;
  final absolute = p.normalize(
    p.isAbsolute(path) ? path : p.absolute(workspaceRootPath, path),
  );
  final appliedRoot = p.normalize(
    p.absolute(workspaceRootPath, '.dart_tool', 'patchwork'),
  );
  return p.equals(absolute, appliedRoot) || p.isWithin(appliedRoot, absolute);
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

bool _sameOverrideValue(String workspaceRootPath, Object? left, Object? right) {
  if (left is Map<String, Object?> && right is Map<String, Object?>) {
    final leftPath = left['path'];
    final rightPath = right['path'];
    if (leftPath is String && rightPath is String) {
      final leftRest = Map<String, Object?>.of(left)..remove('path');
      final rightRest = Map<String, Object?>.of(right)..remove('path');
      return _pathsPointToSameLocation(
            workspaceRootPath,
            leftPath,
            rightPath,
          ) &&
          _sameOverrideValue(workspaceRootPath, leftRest, rightRest);
    }
    if (left.length != right.length) {
      return false;
    }
    for (final entry in left.entries) {
      if (!right.containsKey(entry.key) ||
          !_sameOverrideValue(
            workspaceRootPath,
            entry.value,
            right[entry.key],
          )) {
        return false;
      }
    }
    return true;
  }
  if (left is List<Object?> && right is List<Object?>) {
    if (left.length != right.length) {
      return false;
    }
    for (var index = 0; index < left.length; index += 1) {
      if (!_sameOverrideValue(workspaceRootPath, left[index], right[index])) {
        return false;
      }
    }
    return true;
  }
  return left == right;
}
