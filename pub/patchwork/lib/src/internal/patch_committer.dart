import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../edit_session.dart';
import '../error.dart';
import '../io/atomic_file_writer.dart';
import '../model.dart';
import '../patch_file.dart';
import 'artifact_inventory.dart';
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
    final existingPatchFile = File(patchPath);
    final content = patchFile.build(
      sourcePath: session.baselinePath,
      editPath: edit.path,
    );
    if (content.isEmpty) {
      if (existingPatchFile.existsSync()) {
        existingPatchFile.deleteSync();
      }
      packageTree.deleteDirectory(edit.path);
      return PatchWrite(
        package: edit.package,
        version: edit.version,
        status: PatchWriteStatus.removed,
        editPath: edit.path,
        patchPath: patchPath,
      );
    }

    final patchBytes = utf8.encode(content);
    if (existingPatchFile.existsSync() &&
        _sha256(existingPatchFile.readAsBytesSync()) == _sha256(patchBytes)) {
      packageTree.deleteDirectory(edit.path);
      return PatchWrite(
        package: edit.package,
        version: edit.version,
        status: PatchWriteStatus.unchanged,
        editPath: edit.path,
        patchPath: patchPath,
      );
    }

    patchFile.validate(sourcePath: session.baselinePath, patchContent: content);
    writeBytesFileAtomically(patchPath, patchBytes);
    packageTree.deleteDirectory(edit.path);

    return PatchWrite(
      package: edit.package,
      version: edit.version,
      status: PatchWriteStatus.written,
      editPath: edit.path,
      patchPath: patchPath,
    );
  }
}

String _sha256(List<int> bytes) {
  return sha256.convert(bytes).toString();
}
