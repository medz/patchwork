import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../diagnostics/diagnostic.dart';

final class PatchworkManifest {
  PatchworkManifest({required List<PatchworkManifestPatch> patches})
    : patches = List.unmodifiable(patches);

  final List<PatchworkManifestPatch> patches;
}

final class PatchworkManifestPatch {
  const PatchworkManifestPatch({
    required this.target,
    required this.path,
    required this.hash,
  });

  final String target;
  final String path;
  final String hash;
}

final class PatchworkManifestReadResult {
  const PatchworkManifestReadResult._({this.manifest, this.diagnostic});

  factory PatchworkManifestReadResult.success(PatchworkManifest manifest) {
    return PatchworkManifestReadResult._(manifest: manifest);
  }

  factory PatchworkManifestReadResult.failure(Diagnostic diagnostic) {
    return PatchworkManifestReadResult._(diagnostic: diagnostic);
  }

  final PatchworkManifest? manifest;
  final Diagnostic? diagnostic;
}

enum PatchworkManifestPatchState { current, missing, stale }

final class PatchworkManifestPatchInspection {
  const PatchworkManifestPatchInspection({
    required this.entry,
    required this.state,
    this.actualHash,
    this.diagnostic,
  });

  final PatchworkManifestPatch entry;
  final PatchworkManifestPatchState state;
  final String? actualHash;
  final Diagnostic? diagnostic;
}

final class PatchworkManifestInspectionResult {
  const PatchworkManifestInspectionResult._({
    this.patches = const [],
    this.diagnostic,
  });

  factory PatchworkManifestInspectionResult.success(
    List<PatchworkManifestPatchInspection> patches,
  ) {
    return PatchworkManifestInspectionResult._(
      patches: List.unmodifiable(patches),
    );
  }

  factory PatchworkManifestInspectionResult.failure(Diagnostic diagnostic) {
    return PatchworkManifestInspectionResult._(diagnostic: diagnostic);
  }

  final List<PatchworkManifestPatchInspection> patches;
  final Diagnostic? diagnostic;
}

final class PatchworkManifestException implements Exception {
  const PatchworkManifestException(this.diagnostic);

  final Diagnostic diagnostic;
}

final class PatchworkManifestStore {
  const PatchworkManifestStore();

  String path({required String workspaceRootPath}) {
    return p.join(workspaceRootPath, 'patchwork.lock');
  }

  PatchworkManifestReadResult read({required String workspaceRootPath}) {
    final manifestPath = path(workspaceRootPath: workspaceRootPath);
    final file = File(manifestPath);
    if (!file.existsSync()) {
      return PatchworkManifestReadResult.success(
        PatchworkManifest(patches: const []),
      );
    }

    final String content;
    final Object? root;
    try {
      content = file.readAsStringSync();
      if (content.trim().isEmpty) {
        return PatchworkManifestReadResult.success(
          PatchworkManifest(patches: const []),
        );
      }
      root = loadYaml(content);
    } on YamlException catch (error) {
      return PatchworkManifestReadResult.failure(
        _malformedManifest(manifestPath, hint: error.message),
      );
    } on FormatException catch (error) {
      return PatchworkManifestReadResult.failure(
        _malformedManifest(manifestPath, hint: error.message),
      );
    } on FileSystemException catch (error) {
      return PatchworkManifestReadResult.failure(
        Diagnostic(
          code: 'patchwork.manifest_unreadable',
          message: 'Could not read patchwork.lock.',
          hint: error.message,
          location: manifestPath,
        ),
      );
    }

    if (root == null) {
      return PatchworkManifestReadResult.success(
        PatchworkManifest(patches: const []),
      );
    }

    if (root is! YamlMap) {
      return PatchworkManifestReadResult.failure(
        _malformedManifest(manifestPath),
      );
    }

    final patchesNode = root['patches'];
    if (patchesNode == null) {
      return PatchworkManifestReadResult.success(
        PatchworkManifest(patches: const []),
      );
    }

    if (patchesNode is! YamlList) {
      return PatchworkManifestReadResult.failure(
        _malformedManifest(manifestPath),
      );
    }

    final patches = <PatchworkManifestPatch>[];
    final targets = <String>{};
    for (final item in patchesNode.nodes) {
      final value = item.value;
      if (value is! YamlMap) {
        return PatchworkManifestReadResult.failure(
          _malformedManifest(manifestPath),
        );
      }

      final target = value['target'];
      final patchPath = value['path'];
      final hash = value['hash'];
      if (target is! String || patchPath is! String || hash is! String) {
        return PatchworkManifestReadResult.failure(
          _malformedManifest(manifestPath),
        );
      }

      if (!targets.add(target)) {
        return PatchworkManifestReadResult.failure(
          Diagnostic(
            code: 'patchwork.manifest_duplicate_target',
            message: 'patchwork.lock contains duplicate patch targets.',
            hint: 'Keep one patch entry per target.',
            location: manifestPath,
          ),
        );
      }

      patches.add(
        PatchworkManifestPatch(target: target, path: patchPath, hash: hash),
      );
    }

    return PatchworkManifestReadResult.success(
      PatchworkManifest(patches: patches),
    );
  }

  void upsertPatch({
    required String workspaceRootPath,
    required PatchworkManifestPatch entry,
  }) {
    final manifest = _readForWrite(workspaceRootPath);
    final patches = manifest.patches.toList();
    final index = patches.indexWhere((patch) => patch.target == entry.target);
    if (index == -1) {
      patches.add(entry);
    } else {
      patches[index] = entry;
    }
    _write(workspaceRootPath, PatchworkManifest(patches: patches));
  }

  void removePatch({
    required String workspaceRootPath,
    required String target,
  }) {
    final manifestPath = path(workspaceRootPath: workspaceRootPath);
    if (!File(manifestPath).existsSync()) {
      return;
    }

    final manifest = _readForWrite(workspaceRootPath);
    final patches = manifest.patches
        .where((patch) => patch.target != target)
        .toList(growable: false);
    _write(workspaceRootPath, PatchworkManifest(patches: patches));
  }

  PatchworkManifestInspectionResult inspectPatchFiles({
    required String workspaceRootPath,
  }) {
    final readResult = read(workspaceRootPath: workspaceRootPath);
    final diagnostic = readResult.diagnostic;
    if (diagnostic != null) {
      return PatchworkManifestInspectionResult.failure(diagnostic);
    }

    final inspections = <PatchworkManifestPatchInspection>[];
    for (final entry in readResult.manifest!.patches) {
      final absolutePatchPath = _resolveManifestPath(
        workspaceRootPath: workspaceRootPath,
        relativePath: entry.path,
      );
      final file = File(absolutePatchPath);
      if (!file.existsSync()) {
        inspections.add(
          PatchworkManifestPatchInspection(
            entry: entry,
            state: PatchworkManifestPatchState.missing,
            diagnostic: Diagnostic(
              code: 'patchwork.patch_missing',
              message: 'Patch file listed in patchwork.lock is missing.',
              hint: 'Recreate the patch or remove its manifest entry.',
              location: absolutePatchPath,
            ),
          ),
        );
        continue;
      }

      final actualHash = patchworkPatchFileHash(absolutePatchPath);
      if (actualHash != entry.hash) {
        inspections.add(
          PatchworkManifestPatchInspection(
            entry: entry,
            state: PatchworkManifestPatchState.stale,
            actualHash: actualHash,
            diagnostic: Diagnostic(
              code: 'patchwork.patch_hash_mismatch',
              message: 'Patch file hash does not match patchwork.lock.',
              hint: 'Re-run patchwork patch --commit for this target.',
              location: absolutePatchPath,
            ),
          ),
        );
        continue;
      }

      inspections.add(
        PatchworkManifestPatchInspection(
          entry: entry,
          state: PatchworkManifestPatchState.current,
          actualHash: actualHash,
        ),
      );
    }

    return PatchworkManifestInspectionResult.success(inspections);
  }

  PatchworkManifest _readForWrite(String workspaceRootPath) {
    final readResult = read(workspaceRootPath: workspaceRootPath);
    final diagnostic = readResult.diagnostic;
    if (diagnostic != null) {
      throw PatchworkManifestException(diagnostic);
    }
    return readResult.manifest!;
  }

  void _write(String workspaceRootPath, PatchworkManifest manifest) {
    final file = File(path(workspaceRootPath: workspaceRootPath));
    file.writeAsStringSync(_formatManifest(manifest));
  }
}

String patchworkPatchFileHash(String path) {
  return sha256.convert(File(path).readAsBytesSync()).toString();
}

String patchworkManifestPath(String path) {
  return path.replaceAll('\\', '/');
}

String _resolveManifestPath({
  required String workspaceRootPath,
  required String relativePath,
}) {
  return p.joinAll([workspaceRootPath, ...relativePath.split('/')]);
}

String _formatManifest(PatchworkManifest manifest) {
  if (manifest.patches.isEmpty) {
    return 'patches: []\n';
  }

  final buffer = StringBuffer()..writeln('patches:');
  for (final patch in manifest.patches) {
    buffer.writeln('  - target: ${_formatYamlScalar(patch.target)}');
    buffer.writeln('    path: ${_formatYamlScalar(patch.path)}');
    buffer.writeln('    hash: ${_formatYamlScalar(patch.hash)}');
  }
  return buffer.toString();
}

String _formatYamlScalar(String value) {
  if (RegExp(r'^[A-Za-z0-9._/@:%+-]+$').hasMatch(value)) {
    return value;
  }
  return jsonEncode(value);
}

Diagnostic _malformedManifest(String manifestPath, {String? hint}) {
  return Diagnostic(
    code: 'patchwork.manifest_malformed',
    message: 'patchwork.lock is malformed.',
    hint: hint,
    location: manifestPath,
  );
}
