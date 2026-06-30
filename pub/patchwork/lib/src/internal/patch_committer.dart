import 'dart:convert';
import 'dart:io';

import '../edit_session.dart';
import '../error.dart';
import '../io/atomic_file_writer.dart';
import '../model.dart';
import '../patch_file.dart';
import 'artifact_inventory.dart';
import 'hashing.dart';
import 'package_tree.dart';
import 'path_layout.dart';

/// Commits edit directories into durable patch files.
final class PatchCommitter {
  /// Creates a committer for one Patchwork state root.
  const PatchCommitter({
    required this.layout,
    required this.editSessionStore,
    required this.packageTree,
    required this.patchFile,
  });

  /// Path layout for Patchwork artifacts.
  final PathLayout layout;

  /// Edit session metadata store.
  final EditSessionStore editSessionStore;

  /// Filesystem tree helper.
  final PackageTree packageTree;

  /// Patch build/validation helper.
  final PatchFile patchFile;

  /// Commits the open edit directory for [package].
  Future<PatchWrite> commit(String package) async {
    final inventory = PatchworkArtifactInventory.read(layout);
    return _commitEdit(_singleEditDirectory(package, inventory));
  }

  /// Commits every open edit directory in package-name order.
  Future<List<PatchWrite>> commitAll() async {
    final inventory = PatchworkArtifactInventory.read(layout);
    final writes = <PatchWrite>[];
    for (final package in inventory.openEditPackages) {
      writes.add(await _commitEdit(_singleEditDirectory(package, inventory)));
    }
    return writes;
  }

  PackageVersionPath _singleEditDirectory(
    String package,
    PatchworkArtifactInventory inventory,
  ) {
    final edits = inventory.editsFor(package);
    if (edits.isEmpty) {
      throw PatchworkException(
        'No edit directory exists for "$package".',
        code: 'commit.edit_missing',
        hint: 'Run patchwork patch $package first.',
      );
    }
    if (edits.length > 1) {
      throw PatchworkException(
        'More than one edit directory exists for "$package".',
        code: 'commit.ambiguous_edit',
        hint:
            'Commit or delete the extra .patchwork/$package@<version> directories.',
      );
    }
    return edits.single;
  }

  Future<PatchWrite> _commitEdit(PackageVersionPath edit) async {
    final session = editSessionStore.read(edit);
    final patchPath = layout.patchPath(edit.package, edit.version);
    final patch = _BuiltPatch(
      patchFile.build(sourcePath: session.baselinePath, editPath: edit.path),
    );
    final status = _commitPatchArtifact(
      baselinePath: session.baselinePath,
      patchPath: patchPath,
      patch: patch,
    );
    packageTree.deleteDirectory(edit.path);

    return PatchWrite(
      package: edit.package,
      version: edit.version,
      status: status,
      editPath: edit.path,
      patchPath: patchPath,
    );
  }

  PatchWriteStatus _commitPatchArtifact({
    required String baselinePath,
    required String patchPath,
    required _BuiltPatch patch,
  }) {
    final existingPatchFile = File(patchPath);
    if (patch.isEmpty) {
      if (existingPatchFile.existsSync()) {
        existingPatchFile.deleteSync();
      }
      return PatchWriteStatus.removed;
    }

    if (_existingPatchMatches(existingPatchFile, patch)) {
      return PatchWriteStatus.unchanged;
    }

    patchFile.validate(sourcePath: baselinePath, patchContent: patch.content);
    writeBytesFileAtomically(patchPath, patch.bytes);
    return PatchWriteStatus.written;
  }
}

final class _BuiltPatch {
  factory _BuiltPatch(String content) {
    final bytes = utf8.encode(content);
    return _BuiltPatch._(content, bytes, sha256Hex(bytes));
  }

  const _BuiltPatch._(this.content, this.bytes, this.sha256);

  final String content;
  final List<int> bytes;
  final String sha256;

  bool get isEmpty => content.isEmpty;
}

bool _existingPatchMatches(File existingPatchFile, _BuiltPatch patch) {
  if (!existingPatchFile.existsSync()) {
    return false;
  }
  return sha256Hex(existingPatchFile.readAsBytesSync()) == patch.sha256;
}
