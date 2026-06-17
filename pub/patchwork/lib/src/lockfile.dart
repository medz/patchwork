import 'dart:collection';
import 'dart:io';

import 'package:yaml/yaml.dart';

import 'error.dart';
import 'internal/yaml_writer.dart';
import 'io/atomic_file_writer.dart';
import 'model.dart';

/// Reads and writes a Patchwork lockfile.
final class LockfileStore {
  /// Creates a lockfile store for [path].
  const LockfileStore({
    required this.path,
    this.fileWriter = const AtomicFileWriter(),
  });

  /// The lockfile path.
  final String path;

  /// The writer used to persist lockfile updates.
  final AtomicFileWriter fileWriter;

  /// Reads the lockfile, returning an empty model when the file is absent.
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

  /// Writes [lockfile] to disk.
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
    return AppliedPatchRecord(patchSha256: patchSha256, path: appliedPath);
  }
}

/// The in-memory representation of `patchwork.lock`.
final class Lockfile {
  /// Creates a lockfile with package records sorted by package name.
  Lockfile({required Map<String, LockfilePackage> packages})
    : packages = SplayTreeMap<String, LockfilePackage>.of(packages);

  /// Creates an empty lockfile.
  factory Lockfile.empty() {
    return Lockfile(packages: const {});
  }

  /// Package records keyed by package name.
  final SplayTreeMap<String, LockfilePackage> packages;

  /// Converts this lockfile to a YAML-compatible map.
  Map<String, Object?> toYaml() {
    return {
      'version': 2,
      'packages': {
        for (final entry in packages.entries) entry.key: entry.value.toYaml(),
      },
    };
  }
}

/// A Patchwork lockfile record for one package.
final class LockfilePackage {
  /// Creates a package lock record.
  const LockfilePackage({
    required this.version,
    required this.source,
    this.patch,
    this.patchHistory = const {},
    this.applied,
  });

  /// The package version this record applies to.
  final String version;

  /// The source tree metadata for this package version.
  final PackageSource source;

  /// The committed patch metadata, when a patch is recorded.
  final CommittedPatch? patch;

  /// Patch hashes for older versions used by continuation flows.
  final Map<String, String> patchHistory;

  /// The generated output recorded as currently applied.
  final AppliedPatchRecord? applied;

  /// Returns a copy with selected fields replaced.
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

  /// Converts this package record to a YAML-compatible map.
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

/// Metadata for a committed patch file.
final class CommittedPatch {
  /// Creates committed patch metadata.
  const CommittedPatch({required this.editSha256, required this.commitSha256});

  /// The hash of the edit tree that produced the patch.
  final String editSha256;

  /// The hash of the committed patch file contents.
  final String commitSha256;

  /// Converts this record to a YAML-compatible map.
  Map<String, Object?> toYaml() {
    return {'edit-sha256': editSha256, 'commit-sha256': commitSha256};
  }
}

/// Metadata for generated output currently applied to pub overrides.
final class AppliedPatchRecord {
  /// Creates applied patch metadata.
  const AppliedPatchRecord({required this.patchSha256, required this.path});

  /// The committed patch hash that generated the output.
  final String patchSha256;

  /// The project-relative generated output path.
  final String path;

  /// Converts this record to a YAML-compatible map.
  Map<String, Object?> toYaml() {
    return {'patch-sha256': patchSha256, 'path': path};
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
