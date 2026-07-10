import 'dart:io';

import 'package:yaml/yaml.dart';
import 'package:yaml_edit/yaml_edit.dart';

import '../error.dart';
import '../state/artifact_identity.dart';
import '../io/atomic_file_writer.dart';

/// Reads and writes package-provided overlay declarations.
///
/// The manifest is intentionally small and deterministic.
final class OverlayManifestStore {
  /// Creates a manifest store for [path].
  const OverlayManifestStore({
    required this.path,
    this.fileWriter = const AtomicFileWriter(),
  });

  /// The `patchwork.yaml` path.
  final String path;

  /// The writer used to persist manifest updates.
  final AtomicFileWriter fileWriter;

  /// Reads the manifest, returning an empty value when it is absent.
  OverlayManifest read() {
    final file = File(path);
    if (!file.existsSync()) {
      return OverlayManifest.empty();
    }

    try {
      final content = file.readAsStringSync();
      if (content.trim().isEmpty) {
        return OverlayManifest.empty();
      }
      final decoded = loadYaml(content);
      if (decoded is! YamlMap) {
        throw PatchworkException(
          'patchwork.yaml must contain a YAML object.',
          code: 'overlay_manifest.malformed',
          location: path,
        );
      }

      final overlays = decoded['overlays'];
      if (overlays == null) {
        return OverlayManifest.empty();
      }
      if (overlays is! YamlList) {
        throw PatchworkException(
          'patchwork.yaml overlays must be a list.',
          code: 'overlay_manifest.malformed',
          location: path,
        );
      }

      final entries = <OverlayManifestEntry>[];
      for (var index = 0; index < overlays.length; index++) {
        final item = overlays[index];
        if (item is! YamlMap) {
          throw PatchworkException(
            'patchwork.yaml overlay entries must be YAML objects.',
            code: 'overlay_manifest.malformed',
            location: path,
          );
        }
        entries.add(_readEntry(index, item));
      }
      _checkDuplicateEntries(entries);
      return OverlayManifest(overlays: entries);
    } on YamlException catch (error) {
      throw PatchworkException(
        'patchwork.yaml is malformed.',
        code: 'overlay_manifest.malformed',
        hint: error.message,
        location: path,
      );
    } on FileSystemException catch (error) {
      throw PatchworkException(
        'Could not read patchwork.yaml.',
        code: 'overlay_manifest.unreadable',
        hint: error.message,
        location: path,
      );
    }
  }

  /// Writes [manifest] to disk.
  void write(OverlayManifest manifest) {
    final editor = YamlEditor('');
    editor.update([], manifest.toYaml());
    fileWriter.writeString(path, '${editor.toString()}\n');
  }

  OverlayManifestEntry _readEntry(int index, YamlMap value) {
    final package = value['package'];
    final version = value['version'];
    final sha256 = value['sha256'];
    final patch = value['patch'];
    final reason = value['reason'];
    if (package is! String ||
        version is! String ||
        sha256 is! String ||
        patch is! String) {
      throw PatchworkException(
        'patchwork.yaml overlay #${index + 1} must include package, version, sha256, and patch.',
        code: 'overlay_manifest.malformed',
        location: path,
      );
    }
    if (reason != null && reason is! String) {
      throw PatchworkException(
        'patchwork.yaml overlay #${index + 1} reason must be a string.',
        code: 'overlay_manifest.malformed',
        location: path,
      );
    }
    if (!isPlainPackageName(package) || !isSafePathSegment(version)) {
      throw PatchworkException(
        'patchwork.yaml overlay #${index + 1} has an unsafe package or version.',
        code: 'overlay_manifest.malformed',
        location: path,
      );
    }
    return OverlayManifestEntry(
      package: package,
      version: version,
      sha256: sha256,
      patch: patch,
      reason: reason,
    );
  }

  void _checkDuplicateEntries(List<OverlayManifestEntry> entries) {
    final seen = <String>{};
    for (final entry in entries) {
      final key = '${entry.package}@${entry.version}:${entry.sha256}';
      if (!seen.add(key)) {
        throw PatchworkException(
          'patchwork.yaml contains duplicate overlays for ${entry.package}@${entry.version}.',
          code: 'overlay_manifest.duplicate_overlay',
          location: path,
        );
      }
    }
  }
}

/// In-memory `patchwork.yaml` representation.
final class OverlayManifest {
  /// Creates a manifest with [overlays].
  OverlayManifest({required List<OverlayManifestEntry> overlays})
    : overlays = List.unmodifiable(overlays);

  /// Creates an empty manifest.
  factory OverlayManifest.empty() {
    return OverlayManifest(overlays: const []);
  }

  /// Overlay entries in manifest order.
  final List<OverlayManifestEntry> overlays;

  /// Returns a copy with [entry] inserted or replacing the same target.
  OverlayManifest upsert(OverlayManifestEntry entry) {
    final entries = [...overlays];
    final existingIndex = entries.indexWhere(
      (candidate) =>
          candidate.package == entry.package &&
          candidate.version == entry.version &&
          candidate.sha256 == entry.sha256,
    );
    if (existingIndex >= 0) {
      entries[existingIndex] = entry;
    } else {
      entries.add(entry);
    }
    entries.sort((left, right) {
      final packageCompare = left.package.compareTo(right.package);
      if (packageCompare != 0) {
        return packageCompare;
      }
      final versionCompare = left.version.compareTo(right.version);
      if (versionCompare != 0) {
        return versionCompare;
      }
      return left.sha256.compareTo(right.sha256);
    });
    return OverlayManifest(overlays: entries);
  }

  /// Converts the manifest to deterministic YAML data.
  Map<String, Object?> toYaml() {
    return {
      'overlays': [for (final overlay in overlays) overlay.toYaml()],
    };
  }
}

/// A single overlay declaration from `patchwork.yaml`.
final class OverlayManifestEntry {
  /// Creates an overlay declaration.
  const OverlayManifestEntry({
    required this.package,
    required this.version,
    required this.sha256,
    required this.patch,
    this.reason,
  });

  /// The package targeted by the overlay.
  final String package;

  /// The target package version.
  final String version;

  /// The target source tree hash.
  final String sha256;

  /// The patch path relative to the declaring package root.
  final String patch;

  /// Optional human-readable reason.
  final String? reason;

  /// Converts the entry to deterministic YAML data.
  Map<String, Object?> toYaml() {
    return {
      'package': package,
      'version': version,
      'sha256': sha256,
      'patch': patch,
      if (reason != null && reason!.isNotEmpty) 'reason': reason,
    };
  }
}
