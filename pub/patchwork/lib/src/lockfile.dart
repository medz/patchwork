import 'dart:collection';
import 'dart:io';

import 'package:yaml/yaml.dart';

import 'error.dart';
import 'internal/yaml_writer.dart';
import 'io/atomic_file_writer.dart';
import 'model.dart';

final class LockfileStore {
  const LockfileStore({
    required this.path,
    this.fileWriter = const AtomicFileWriter(),
  });

  final String path;
  final AtomicFileWriter fileWriter;

  Lockfile read() {
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
  }

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

    return LockfilePackage(
      version: version,
      source: _readSource(package, source),
      patch: _readPatch(value['patch']),
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
    final sha256 = value['sha256'];
    if (editSha256 is! String || sha256 is! String) {
      throw PatchworkException(
        'patchwork.lock patch entries must include edit-sha256 and sha256.',
        code: 'lock.malformed',
        location: path,
      );
    }
    return CommittedPatch(editSha256: editSha256, sha256: sha256);
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

final class Lockfile {
  Lockfile({required Map<String, LockfilePackage> packages})
    : packages = SplayTreeMap<String, LockfilePackage>.of(packages);

  factory Lockfile.empty() {
    return Lockfile(packages: const {});
  }

  final SplayTreeMap<String, LockfilePackage> packages;

  Map<String, Object?> toYaml() {
    return {
      'version': 2,
      'packages': {
        for (final entry in packages.entries) entry.key: entry.value.toYaml(),
      },
    };
  }
}

final class LockfilePackage {
  const LockfilePackage({
    required this.version,
    required this.source,
    this.patch,
    this.applied,
  });

  final String version;
  final PackageSource source;
  final CommittedPatch? patch;
  final AppliedPatchRecord? applied;

  LockfilePackage copyWith({
    String? version,
    PackageSource? source,
    CommittedPatch? patch,
    AppliedPatchRecord? applied,
    bool clearPatch = false,
    bool clearApplied = false,
  }) {
    return LockfilePackage(
      version: version ?? this.version,
      source: source ?? this.source,
      patch: clearPatch ? null : patch ?? this.patch,
      applied: clearApplied ? null : applied ?? this.applied,
    );
  }

  Map<String, Object?> toYaml() {
    return {
      'version': version,
      'source': _sourceToYaml(source),
      if (patch != null) 'patch': patch!.toYaml(),
      if (applied != null) 'applied': applied!.toYaml(),
    };
  }
}

final class CommittedPatch {
  const CommittedPatch({required this.editSha256, required this.sha256});

  final String editSha256;
  final String sha256;

  Map<String, Object?> toYaml() {
    return {'edit-sha256': editSha256, 'sha256': sha256};
  }
}

final class AppliedPatchRecord {
  const AppliedPatchRecord({required this.patchSha256, required this.path});

  final String patchSha256;
  final String path;

  Map<String, Object?> toYaml() {
    return {'patch-sha256': patchSha256, 'path': path};
  }
}

Map<String, Object?> _sourceToYaml(PackageSource source) {
  return {'type': source.type, ...source.fields, 'sha256': source.sha256};
}
