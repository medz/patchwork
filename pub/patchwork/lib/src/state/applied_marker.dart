import 'dart:convert';
import 'dart:io';

import '../error.dart';
import 'path_layout.dart';
import '../io/atomic_file_writer.dart';
import '../pub/source.dart';

/// Reads and writes ownership metadata colocated with generated applied output.
///
/// The marker proves Patchwork ownership for cleanup and refresh decisions. It
/// is disposable generated state and never defines which patches exist.
final class AppliedMarkerStore {
  /// Creates a marker store rooted at [layout].
  const AppliedMarkerStore({
    required this.layout,
    this.fileWriter = const AtomicFileWriter(),
  });

  /// Patchwork path layout for the current project.
  final PathLayout layout;

  /// The writer used to persist marker files.
  final AtomicFileWriter fileWriter;

  /// Reads the marker for [package] and [version], if one exists.
  AppliedMarker? read(String package, String version) {
    final path = layout.appliedMarkerPath(package, version);
    final file = File(path);
    if (!file.existsSync()) {
      return null;
    }

    final decoded = _readJsonObject(
      file,
      code: 'applied.marker_invalid',
      message: 'Applied output marker is malformed.',
    );
    if (decoded['schemaVersion'] != 1 ||
        decoded['kind'] != 'patchwork.applied' ||
        decoded['package'] != package ||
        decoded['version'] != version) {
      throw PatchworkException(
        'Applied output marker does not match "$package@$version".',
        code: 'applied.marker_invalid',
        location: path,
      );
    }

    final patchSha256 = decoded['patchSha256'];
    final pathValue = decoded['path'];
    if (patchSha256 is! String || pathValue is! String) {
      throw PatchworkException(
        'Applied output marker is missing required fields.',
        code: 'applied.marker_invalid',
        location: path,
      );
    }

    return AppliedMarker(
      package: package,
      version: version,
      patchSha256: patchSha256,
      path: pathValue,
      source: _sourceFromJson(decoded['source']),
      mirroredPubspecDependencyOverrides: _objectMap(
        decoded['mirroredPubspecDependencyOverrides'],
      ),
    );
  }

  /// Reads all valid marker locations under `.dart_tool/patchwork/`.
  List<AppliedMarker> readAll() {
    final markers = <AppliedMarker>[];
    for (final applied in layout.appliedDirectories()) {
      final marker = read(applied.package, applied.version);
      if (marker != null) {
        markers.add(marker);
      }
    }
    markers.sort((left, right) {
      final packageCompare = left.package.compareTo(right.package);
      if (packageCompare != 0) {
        return packageCompare;
      }
      return left.version.compareTo(right.version);
    });
    return markers;
  }

  /// Writes [marker] to its colocated marker path.
  void write(AppliedMarker marker) {
    final manifest = {
      'schemaVersion': 1,
      'kind': 'patchwork.applied',
      'package': marker.package,
      'version': marker.version,
      'patchSha256': marker.patchSha256,
      'path': marker.path,
      if (marker.source != null) 'source': _sourceToJson(marker.source!),
      if (marker.mirroredPubspecDependencyOverrides.isNotEmpty)
        'mirroredPubspecDependencyOverrides':
            marker.mirroredPubspecDependencyOverrides,
    };
    fileWriter.writeString(
      layout.appliedMarkerPath(marker.package, marker.version),
      '${jsonEncode(manifest)}\n',
    );
  }
}

/// Ownership metadata for generated applied output.
final class AppliedMarker {
  /// Creates an applied marker.
  AppliedMarker({
    required this.package,
    required this.version,
    required this.patchSha256,
    required this.path,
    required this.source,
    Map<String, Object?> mirroredPubspecDependencyOverrides = const {},
  }) : mirroredPubspecDependencyOverrides = Map.unmodifiable(
         mirroredPubspecDependencyOverrides,
       );

  /// The dependency package.
  final String package;

  /// The dependency version.
  final String version;

  /// The committed patch file hash used to generate [path].
  final String patchSha256;

  /// The project-relative generated output path.
  final String path;

  /// The source fingerprint used to generate output, if recorded.
  final PackageSource? source;

  /// Root pubspec overrides mirrored into `pubspec_overrides.yaml`.
  final Map<String, Object?> mirroredPubspecDependencyOverrides;

  /// Returns a copy with selected fields replaced.
  AppliedMarker copyWith({
    String? patchSha256,
    String? path,
    PackageSource? source,
    Map<String, Object?>? mirroredPubspecDependencyOverrides,
  }) {
    return AppliedMarker(
      package: package,
      version: version,
      patchSha256: patchSha256 ?? this.patchSha256,
      path: path ?? this.path,
      source: source ?? this.source,
      mirroredPubspecDependencyOverrides:
          mirroredPubspecDependencyOverrides ??
          this.mirroredPubspecDependencyOverrides,
    );
  }
}

/// Patchwork-owned mirrors recorded across [markers].
Map<String, Object?> mirroredPubspecDependencyOverrides(
  Iterable<AppliedMarker> markers,
) {
  final dependencyOverrides = <String, Object?>{};
  for (final marker in markers) {
    dependencyOverrides.addAll(marker.mirroredPubspecDependencyOverrides);
  }
  return dependencyOverrides;
}

/// Patchwork-owned package paths and mirrors represented by [markers].
Map<String, Object?> ownedPubspecDependencyOverrides(
  Iterable<AppliedMarker> markers,
) {
  final dependencyOverrides = <String, Object?>{};
  for (final marker in markers) {
    dependencyOverrides.addAll(marker.mirroredPubspecDependencyOverrides);
    dependencyOverrides[marker.package] = {'path': marker.path};
  }
  return dependencyOverrides;
}

Map<String, Object?> _sourceToJson(PackageSource source) {
  return {
    'sourceType': source.type,
    'sha256': source.sha256,
    if (source.fields.isNotEmpty) 'fields': source.fields,
  };
}

PackageSource? _sourceFromJson(Object? value) {
  if (value is! Map<String, Object?>) {
    return null;
  }
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

Map<String, Object?> _objectMap(Object? value) {
  if (value is! Map<String, Object?>) {
    return const {};
  }
  return Map<String, Object?>.of(value);
}

Map<String, Object?> _readJsonObject(
  File file, {
  required String code,
  required String message,
}) {
  try {
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! Map<String, Object?>) {
      throw PatchworkException(message, code: code, location: file.path);
    }
    return decoded;
  } on FormatException catch (error) {
    throw PatchworkException(
      message,
      code: code,
      hint: error.message,
      location: file.path,
    );
  } on FileSystemException catch (error) {
    throw PatchworkException(
      'Could not read applied output marker.',
      code: code,
      hint: error.message,
      location: file.path,
    );
  }
}
