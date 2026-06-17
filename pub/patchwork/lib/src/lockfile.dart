import 'dart:collection';
import 'dart:io';

import 'package:yaml/yaml.dart';

import 'error.dart';
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
      patch: _readPatch(value['patch']),
      patchHistory: _readPatchHistory(package, value['patch-history']),
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

  CommittedPatch? _readPatch(Object? value) {
    if (value == null) {
      return null;
    }
    if (value is! YamlMap) {
      throw PatchworkException(
        'patchwork.lock patch entries must be YAML objects.',
        code: 'lock.malformed',
        location: path,
      );
    }

    final editSha256 = value['edit-sha256'];
    final commitSha256 = value['commit-sha256'];
    if (editSha256 is! String || commitSha256 is! String) {
      throw PatchworkException(
        'patchwork.lock patch entries must include edit-sha256 and commit-sha256.',
        code: 'lock.malformed',
        location: path,
      );
    }
    return CommittedPatch(editSha256: editSha256, commitSha256: commitSha256);
  }

  SplayTreeMap<String, String> _readPatchHistory(
    String package,
    Object? value,
  ) {
    if (value == null) {
      return SplayTreeMap<String, String>();
    }
    if (value is! YamlMap) {
      throw PatchworkException(
        'patchwork.lock patch-history entries must be YAML objects.',
        code: 'lock.malformed',
        location: path,
      );
    }

    final history = SplayTreeMap<String, String>();
    for (final entry in value.entries) {
      final version = entry.key;
      final patch = entry.value;
      if (version is! String || !_isSafePathSegment(version)) {
        throw PatchworkException(
          'patchwork.lock patch-history for "$package" must use safe versions.',
          code: 'lock.malformed',
          location: path,
        );
      }
      if (patch is! YamlMap) {
        throw PatchworkException(
          'patchwork.lock patch-history entries must be YAML objects.',
          code: 'lock.malformed',
          location: path,
        );
      }
      final commitSha256 = patch['commit-sha256'];
      if (commitSha256 is! String) {
        throw PatchworkException(
          'patchwork.lock patch-history entries must include commit-sha256.',
          code: 'lock.malformed',
          location: path,
        );
      }
      history[version] = commitSha256;
    }
    return history;
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

    final patchSha256 = value['patch-sha256'];
    final appliedPath = value['path'];
    if (patchSha256 is! String || appliedPath is! String) {
      throw PatchworkException(
        'patchwork.lock applied entries must include patch-sha256 and path.',
        code: 'lock.malformed',
        location: path,
      );
    }
    return AppliedPatchRecord(
      patchSha256: patchSha256,
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
      return _toStringKeyedMap(value);
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
/// The record captures the source fingerprint Patchwork last accepted, the
/// committed patch hash currently tied to that source, optional older patch
/// hashes for continuation workflows, and the generated output path that may be
/// safely undone.
final class LockfilePackage {
  /// Creates lockfile state for one dependency package.
  const LockfilePackage({
    required this.version,
    required this.source,
    this.patch,
    this.patchHistory = const {},
    this.applied,
  });

  /// The resolved dependency version this record applies to.
  final String version;

  /// The source tree identity Patchwork verified for [version].
  final PackageSource source;

  /// The committed patch tied to [source], when one exists.
  final CommittedPatch? patch;

  /// Patch file hashes for older package versions kept for `--continue`.
  final Map<String, String> patchHistory;

  /// The generated output Patchwork last wrote into pub overrides.
  final AppliedPatchRecord? applied;

  /// Returns a copy with selected fields replaced.
  ///
  /// Passing [clearApplied] removes [applied] even if the [applied] parameter is
  /// omitted.
  LockfilePackage copyWith({
    String? version,
    PackageSource? source,
    CommittedPatch? patch,
    Map<String, String>? patchHistory,
    AppliedPatchRecord? applied,
    bool clearApplied = false,
  }) {
    return LockfilePackage(
      version: version ?? this.version,
      source: source ?? this.source,
      patch: patch ?? this.patch,
      patchHistory: patchHistory ?? this.patchHistory,
      applied: clearApplied ? null : applied ?? this.applied,
    );
  }

  /// Converts this package record to the YAML structure stored under its key.
  Map<String, Object?> toYaml() {
    return {
      'version': version,
      'source': _sourceToYaml(source),
      if (patch != null) 'patch': patch!.toYaml(),
      if (patchHistory.isNotEmpty)
        'patch-history': {
          for (final entry in SplayTreeMap<String, String>.of(
            patchHistory,
          ).entries)
            entry.key: {'commit-sha256': entry.value},
        },
      if (applied != null) 'applied': applied!.toYaml(),
    };
  }
}

/// Hashes that bind a committed patch file to the edit that produced it.
final class CommittedPatch {
  /// Creates committed patch hashes.
  const CommittedPatch({required this.editSha256, required this.commitSha256});

  /// The hash of the edit tree that produced the patch.
  final String editSha256;

  /// The hash of the committed patch file contents.
  final String commitSha256;

  /// Converts this record to the YAML structure stored in `patch`.
  Map<String, Object?> toYaml() {
    return {'edit-sha256': editSha256, 'commit-sha256': commitSha256};
  }
}

/// The generated output that Patchwork recorded as applied.
///
/// This record lets [Patchwork.undo] distinguish Patchwork-owned generated
/// output from user-owned overrides or arbitrary project directories.
final class AppliedPatchRecord {
  /// Creates applied-output state.
  const AppliedPatchRecord({
    required this.patchSha256,
    required this.path,
    this.mirroredPubspecDependencyOverrides = const {},
  });

  /// The committed patch hash used to generate [path].
  final String patchSha256;

  /// The project-relative generated output path.
  final String path;

  /// Root pubspec overrides that Patchwork mirrored into `pubspec_overrides.yaml`.
  final Map<String, Object?> mirroredPubspecDependencyOverrides;

  /// Converts this record to the YAML structure stored in `applied`.
  Map<String, Object?> toYaml() {
    return {
      'patch-sha256': patchSha256,
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

Map<String, Object?> _toStringKeyedMap(YamlMap map) {
  final result = <String, Object?>{};
  for (final entry in map.entries) {
    final key = entry.key;
    if (key is! String) {
      throw const FormatException('YAML map contains a non-string key.');
    }
    result[key] = _convertYamlValue(entry.value);
  }
  return result;
}

Object? _convertYamlValue(Object? value) {
  if (value is YamlMap) {
    return _toStringKeyedMap(value);
  }
  if (value is YamlList) {
    return [for (final item in value.nodes) _convertYamlValue(item.value)];
  }
  if (value == null || value is String || value is num || value is bool) {
    return value;
  }
  return value.toString();
}
