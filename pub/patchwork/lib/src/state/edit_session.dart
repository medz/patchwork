import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../error.dart';
import 'path_layout.dart';
import '../io/atomic_file_writer.dart';
import '../pub/source.dart';

/// Reads and writes hidden metadata for an open `.patchwork/<pkg>@<version>`
/// edit directory.
///
/// This metadata belongs to the edit session lifecycle. It is not committed
/// project truth and does not define which patches exist.
final class EditSessionStore {
  /// Creates a store rooted at [layout].
  const EditSessionStore({
    required this.layout,
    this.fileWriter = const AtomicFileWriter(),
  });

  /// Patchwork path layout for the current project.
  final PathLayout layout;

  /// The writer used to persist session manifests.
  final AtomicFileWriter fileWriter;

  /// Writes an edit-session manifest for [package] and [version].
  void write({
    required String package,
    required String version,
    required PackageSource source,
    String? editPath,
  }) {
    final path = editPath == null
        ? layout.editManifestPath(package, version)
        : p.join(editPath, '.patchwork', 'edit.json');
    final manifest = {
      'schemaVersion': 1,
      'kind': 'patchwork.edit',
      'package': package,
      'version': version,
      'createdFrom': _sourceToJson(source),
      'baseline': '.patchwork/source',
    };
    fileWriter.writeString(path, '${jsonEncode(manifest)}\n');
  }

  /// Reads and validates the edit session for [edit].
  EditSession read(PackageVersionPath edit) {
    final manifestPath = layout.editManifestPath(edit.package, edit.version);
    final file = File(manifestPath);
    if (!file.existsSync()) {
      throw PatchworkException(
        'Edit session metadata is missing for "${edit.package}".',
        code: 'commit.edit_manifest_missing',
        hint:
            'Recreate the edit directory with patchwork patch ${edit.package}.',
        location: manifestPath,
      );
    }

    final decoded = _readJsonObject(file, code: 'commit.edit_manifest_invalid');
    if (decoded['schemaVersion'] != 1 ||
        decoded['kind'] != 'patchwork.edit' ||
        decoded['package'] != edit.package ||
        decoded['version'] != edit.version) {
      throw PatchworkException(
        'Edit session metadata does not match "${edit.package}@${edit.version}".',
        code: 'commit.edit_manifest_invalid',
        location: manifestPath,
      );
    }

    final baseline = decoded['baseline'];
    if (baseline is! String || p.isAbsolute(baseline)) {
      throw PatchworkException(
        'Edit session baseline path is invalid.',
        code: 'commit.edit_manifest_invalid',
        location: manifestPath,
      );
    }
    final baselinePath = p.normalize(p.join(edit.path, baseline));
    if (!p.equals(
      p.normalize(layout.editBaselinePath(edit.package, edit.version)),
      baselinePath,
    )) {
      throw PatchworkException(
        'Edit session baseline path is invalid.',
        code: 'commit.edit_manifest_invalid',
        location: manifestPath,
      );
    }
    if (!Directory(baselinePath).existsSync()) {
      throw PatchworkException(
        'Edit session baseline is missing for "${edit.package}".',
        code: 'commit.edit_baseline_missing',
        hint:
            'Recreate the edit directory with patchwork patch ${edit.package}.',
        location: baselinePath,
      );
    }

    final createdFrom = decoded['createdFrom'];
    return EditSession(
      package: edit.package,
      version: edit.version,
      baselinePath: baselinePath,
      createdFrom: createdFrom is Map<String, Object?>
          ? _sourceFromJson(createdFrom)
          : null,
    );
  }
}

/// Validated edit-session metadata.
final class EditSession {
  /// Creates edit-session metadata.
  const EditSession({
    required this.package,
    required this.version,
    required this.baselinePath,
    required this.createdFrom,
  });

  /// The dependency package being edited.
  final String package;

  /// The dependency version being edited.
  final String version;

  /// The hidden baseline snapshot used by `patchwork commit`.
  final String baselinePath;

  /// The source fingerprint captured when the edit was opened, if readable.
  final PackageSource? createdFrom;
}

Map<String, Object?> _sourceToJson(PackageSource source) {
  return {
    'sourceType': source.type,
    'sha256': source.sha256,
    if (source.fields.isNotEmpty) 'fields': source.fields,
  };
}

PackageSource? _sourceFromJson(Map<String, Object?> value) {
  final type = value['sourceType'];
  final sha256 = value['sha256'];
  if (type is! String || sha256 is! String) {
    return null;
  }
  final rawFields = value['fields'];
  final fields = <String, String>{};
  if (rawFields is Map<String, Object?>) {
    for (final entry in rawFields.entries) {
      final fieldValue = entry.value;
      if (fieldValue != null) {
        fields[entry.key] = fieldValue.toString();
      }
    }
  }
  return PackageSource(type: type, sha256: sha256, fields: fields);
}

Map<String, Object?> _readJsonObject(File file, {required String code}) {
  try {
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! Map<String, Object?>) {
      throw PatchworkException(
        'Edit session metadata must be a JSON object.',
        code: code,
        location: file.path,
      );
    }
    return decoded;
  } on FormatException catch (error) {
    throw PatchworkException(
      'Edit session metadata is malformed.',
      code: code,
      hint: error.message,
      location: file.path,
    );
  } on FileSystemException catch (error) {
    throw PatchworkException(
      'Could not read edit session metadata.',
      code: code,
      hint: error.message,
      location: file.path,
    );
  }
}
