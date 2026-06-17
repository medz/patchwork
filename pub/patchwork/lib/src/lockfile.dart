import 'dart:collection';
import 'dart:io';

import 'package:yaml/yaml.dart';

import 'error.dart';
import 'internal/yaml_conversion.dart';
import 'internal/yaml_writer.dart';
import 'io/atomic_file_writer.dart';
import 'model.dart';

/// Reads and writes `patchwork.lock`.
///
/// The store treats a missing or empty file as an empty lockfile, but rejects
/// malformed content with [PatchworkException]. All writes go through
/// [fileWriter] so callers get the same atomic-write behavior as other
/// Patchwork state files.
final class LockfileStore {
  /// Creates a store for the lockfile at [path].
  const LockfileStore({
    required this.path,
    this.fileWriter = const AtomicFileWriter(),
  });

  /// The path to `patchwork.lock`.
  final String path;

  /// The writer used to persist lockfile updates.
  final AtomicFileWriter fileWriter;

  /// Reads and validates the lockfile.
  ///
  /// Returns [Lockfile.empty] if [path] does not exist or contains only
  /// whitespace.
  Lockfile read() {
    try {
      final file = File(path);
      if (!file.existsSync()) {
        return Lockfile.empty();
      }

      final content = file.readAsStringSync();
      if (content.trim().isEmpty) {
        return Lockfile.empty();
      }

      final decoded = loadYaml(content);
      if (decoded is! YamlMap) {
        throw PatchworkException(
          'patchwork.lock must contain a YAML object.',
          code: 'lock.malformed',
          location: path,
        );
      }

      final version = decoded['version'];
      if (version != 2) {
        throw PatchworkException(
          'Unsupported patchwork.lock version "$version".',
          code: 'lock.unsupported_version',
          hint: 'Patchwork 0.2 expects patchwork.lock version 2.',
          location: path,
        );
      }

      final packages = decoded['packages'];
      if (packages == null) {
        return Lockfile.empty();
      }
      if (packages is! YamlMap) {
        throw PatchworkException(
          'patchwork.lock packages must be a YAML object.',
          code: 'lock.malformed',
          location: path,
        );
      }

      final entries = SplayTreeMap<String, LockfilePackage>();
      for (final entry in packages.entries) {
        final name = entry.key;
        final value = entry.value;
        if (name is! String || value is! YamlMap) {
          throw PatchworkException(
            'patchwork.lock package entries must be YAML objects.',
            code: 'lock.malformed',
            location: path,
          );
        }
        entries[name] = _readPackage(name, value);
      }

      return Lockfile(packages: entries);
    } on YamlException catch (error) {
      throw PatchworkException(
        'patchwork.lock is malformed.',
        code: 'lock.malformed',
        hint: error.message,
        location: path,
      );
    } on FileSystemException catch (error) {
      throw PatchworkException(
        'Could not read patchwork.lock.',
        code: 'lock.unreadable',
        hint: error.message,
        location: path,
      );
    }
  }

  /// Serializes [lockfile] as deterministic YAML.
  void write(Lockfile lockfile) {
    fileWriter.writeString(path, '${formatYamlMap(lockfile.toYaml())}\n');
  }

  LockfilePackage _readPackage(String package, YamlMap value) {
    final version = value['version'];
    final source = value['source'];
    if (version is! String || source is! YamlMap) {
      throw PatchworkException(
        'patchwork.lock package "$package" must include version and source.',
        code: 'lock.malformed',
        location: path,
      );
    }
    if (!_isPlainPackageName(package) || !_isSafePathSegment(version)) {
      throw PatchworkException(
        'patchwork.lock package "$package" must use safe package names and versions.',
        code: 'lock.malformed',
        location: path,
      );
    }

    return LockfilePackage(
      version: version,
      source: _readSource(package, source),
      applied: _readApplied(value['applied']),
    );
  }

  PackageSource _readSource(String package, YamlMap value) {
    final type = value['type'];
    final sha256 = value['sha256'];
    if (type is! String || sha256 is! String) {
      throw PatchworkException(
        'patchwork.lock source for "$package" must include type and sha256.',
        code: 'lock.malformed',
        location: path,
      );
    }

    final fields = <String, String>{};
    for (final entry in value.entries) {
      final key = entry.key;
      if (key == 'type' || key == 'sha256') {
        continue;
      }
      if (key is! String || entry.value == null) {
        throw PatchworkException(
          'patchwork.lock source fields for "$package" must be strings.',
          code: 'lock.malformed',
          location: path,
        );
      }
      fields[key] = entry.value.toString();
    }

    return PackageSource(type: type, fields: fields, sha256: sha256);
  }

  AppliedPatchRecord? _readApplied(Object? value) {
    if (value == null) {
      return null;
    }
    if (value is! YamlMap) {
      throw PatchworkException(
        'patchwork.lock applied entries must be YAML objects.',
        code: 'lock.malformed',
        location: path,
      );
    }

    final appliedPath = value['path'];
    if (appliedPath is! String) {
      throw PatchworkException(
        'patchwork.lock applied entries must include path.',
        code: 'lock.malformed',
        location: path,
      );
    }
    return AppliedPatchRecord(
      path: appliedPath,
      mirroredPubspecDependencyOverrides: _readObjectMap(
        value['mirrored-pubspec-overrides'],
        'patchwork.lock applied mirrored-pubspec-overrides must be a YAML object.',
      ),
    );
  }

  Map<String, Object?> _readObjectMap(Object? value, String message) {
    if (value == null) {
      return const {};
    }
    if (value is! YamlMap) {
      throw PatchworkException(message, code: 'lock.malformed', location: path);
    }
    try {
      return yamlMapToStringKeyedMap(value);
    } on FormatException catch (error) {
      throw PatchworkException(
        message,
        code: 'lock.malformed',
        hint: error.message,
        location: path,
      );
    }
  }
}

/// The in-memory representation of a Patchwork lockfile.
///
/// A lockfile is intentionally package-keyed so operations can update one
/// package without depending on the order in which pub reports dependencies.
final class Lockfile {
  /// Creates a lockfile with package records sorted by package name.
  Lockfile({required Map<String, LockfilePackage> packages})
    : packages = SplayTreeMap<String, LockfilePackage>.of(packages);

  /// Creates a lockfile with no package records.
  factory Lockfile.empty() {
    return Lockfile(packages: const {});
  }

  /// Package records keyed by dependency package name.
  final SplayTreeMap<String, LockfilePackage> packages;

  /// Converts this lockfile to the versioned YAML structure on disk.
  Map<String, Object?> toYaml() {
    return {
      'version': 2,
      'packages': {
        for (final entry in packages.entries) entry.key: entry.value.toYaml(),
      },
    };
  }
}

/// Lockfile state for one patched dependency package.
///
/// The record captures source or applied-output state Patchwork still needs for
/// safety. Committed patch inventory is derived from `patches/*.patch` files
/// instead of being duplicated here.
final class LockfilePackage {
  /// Creates lockfile state for one dependency package.
  const LockfilePackage({
    required this.version,
    required this.source,
    this.applied,
  });

  /// The resolved dependency version this record applies to.
  final String version;

  /// The source tree identity Patchwork verified for [version].
  final PackageSource source;

  /// The generated output Patchwork last wrote into pub overrides.
  final AppliedPatchRecord? applied;

  /// Returns a copy with selected fields replaced.
  ///
  /// Passing [clearApplied] removes [applied] even if the [applied] parameter is
  /// omitted.
  LockfilePackage copyWith({
    String? version,
    PackageSource? source,
    AppliedPatchRecord? applied,
    bool clearApplied = false,
  }) {
    return LockfilePackage(
      version: version ?? this.version,
      source: source ?? this.source,
      applied: clearApplied ? null : applied ?? this.applied,
    );
  }

  /// Converts this package record to the YAML structure stored under its key.
  Map<String, Object?> toYaml() {
    return {
      'version': version,
      'source': _sourceToYaml(source),
      if (applied != null) 'applied': applied!.toYaml(),
    };
  }
}

/// The generated output that Patchwork recorded as applied.
///
/// This record lets [Patchwork.undo] distinguish Patchwork-owned generated
/// output from user-owned overrides or arbitrary project directories.
final class AppliedPatchRecord {
  /// Creates applied-output state.
  const AppliedPatchRecord({
    required this.path,
    this.mirroredPubspecDependencyOverrides = const {},
  });

  /// The project-relative generated output path.
  final String path;

  /// Root pubspec overrides that Patchwork mirrored into `pubspec_overrides.yaml`.
  final Map<String, Object?> mirroredPubspecDependencyOverrides;

  /// Converts this record to the YAML structure stored in `applied`.
  Map<String, Object?> toYaml() {
    return {
      'path': path,
      if (mirroredPubspecDependencyOverrides.isNotEmpty)
        'mirrored-pubspec-overrides': {
          for (final entry in SplayTreeMap<String, Object?>.of(
            mirroredPubspecDependencyOverrides,
          ).entries)
            entry.key: entry.value,
        },
    };
  }
}

Map<String, Object?> _sourceToYaml(PackageSource source) {
  return {'type': source.type, ...source.fields, 'sha256': source.sha256};
}

bool _isPlainPackageName(String value) {
  return RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(value);
}

bool _isSafePathSegment(String value) {
  return value.isNotEmpty &&
      value != '.' &&
      value != '..' &&
      !value.contains('/') &&
      !value.contains(r'\');
}
