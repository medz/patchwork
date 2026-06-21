import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../edit_session.dart';
import '../error.dart';
import '../model.dart';
import '../patch_file.dart';
import '../pub/package_resolution.dart';
import 'package_tree.dart';
import 'path_layout.dart';

/// Materializes editable package copies under `.patchwork/`.
///
/// Command code decides which package/version may be edited. This service owns
/// the filesystem transaction for creating the edit tree, applying an optional
/// seed patch, and recording repair metadata when carry can partially proceed.
final class EditPreparer {
  /// Creates an edit tree preparer for one Patchwork state root.
  const EditPreparer({
    required this.rootPath,
    required this.layout,
    required this.packageTree,
    required this.patchFile,
    required this.editSessionStore,
  });

  /// Patchwork state root.
  final String rootPath;

  /// Path layout for Patchwork artifacts.
  final PathLayout layout;

  /// Filesystem tree helper.
  final PackageTree packageTree;

  /// Patch apply/build helper.
  final PatchFile patchFile;

  /// Edit session metadata store.
  final EditSessionStore editSessionStore;

  /// Creates or replaces the editable tree for [resolved].
  Future<PreparedEdit> prepare({
    required String package,
    required ResolvedPubPackage resolved,
    required String? continuedFromPatchPath,
    required String? continuedFromPatchContent,
    required bool replaceExisting,
    required bool preserveFailedPatchApply,
    required bool partialPatchApply,
  }) async {
    final editPath = layout.editPath(package, resolved.version);
    final editExists = Directory(editPath).existsSync();
    if (editExists) {
      if (!replaceExisting &&
          !canReplaceEditDirectory(
            package: package,
            editPath: editPath,
            version: resolved.version,
          )) {
        throw PatchworkException(
          'Edit directory has uncommitted changes for "$package".',
          code: 'patch.edit_exists',
          hint:
              'Run patchwork commit $package, delete $editPath, or pass --force.',
          location: editPath,
        );
      }
    }

    final tempEditPath = p.join(
      layout.editRootPath,
      '.$package@${resolved.version}.$pid.${DateTime.now().microsecondsSinceEpoch}',
    );
    packageTree.deleteDirectory(tempEditPath);
    var preservedFailedEdit = false;
    var wrotePartialRepairLog = false;
    var partialRejectPaths = const <String>[];
    try {
      packageTree.copy(resolved.rootPath, tempEditPath);
      packageTree.copy(
        resolved.rootPath,
        p.join(tempEditPath, '.patchwork', 'source'),
      );
      editSessionStore.write(
        package: package,
        version: resolved.version,
        source: resolved.source,
        editPath: tempEditPath,
      );
      if (continuedFromPatchContent != null) {
        if (partialPatchApply) {
          final partialApply = patchFile.applyPartial(
            packagePath: tempEditPath,
            patchContent: continuedFromPatchContent,
          );
          if (!partialApply.appliedCleanly) {
            wrotePartialRepairLog = true;
            partialRejectPaths = partialApply.rejectPaths;
            _writePartialRepairLog(
              editPath: tempEditPath,
              package: package,
              version: resolved.version,
              patchPath: continuedFromPatchPath!,
              partialApply: partialApply,
            );
          }
        } else {
          try {
            patchFile.apply(
              packagePath: tempEditPath,
              patchContent: continuedFromPatchContent,
            );
          } on PatchworkException catch (error) {
            if (!preserveFailedPatchApply) {
              rethrow;
            }
            if (editExists) {
              packageTree.deleteDirectory(editPath);
            }
            Directory(tempEditPath).renameSync(editPath);
            preservedFailedEdit = true;
            throw PatchworkException(
              error.message,
              code: error.code,
              hint: _failedCarryHint(
                package: package,
                editPath: editPath,
                originalHint: error.hint,
              ),
              location: editPath,
            );
          }
        }
      }
      if (editExists) {
        packageTree.deleteDirectory(editPath);
      }
      Directory(tempEditPath).renameSync(editPath);
    } catch (_) {
      if (!preservedFailedEdit) {
        packageTree.deleteDirectory(tempEditPath);
      }
      rethrow;
    }

    return PreparedEdit(
      package: package,
      version: resolved.version,
      path: editPath,
      sourcePath: resolved.rootPath,
      continuedFromPatchPath: continuedFromPatchPath,
      partialRepairLogPath: wrotePartialRepairLog
          ? p.join(editPath, '.patchwork', 'partial-repair.log')
          : null,
      partialRejectPaths: partialRejectPaths,
    );
  }

  /// Whether [editPath] can be safely replaced by a fresh edit tree.
  bool canReplaceEditDirectory({
    required String package,
    required String editPath,
    required String version,
  }) {
    final session = _tryReadEditSession(
      PackageVersionPath(package: package, version: version, path: editPath),
    );
    if (session == null) {
      return false;
    }

    final patch = File(layout.patchPath(package, version));
    final content = patchFile.build(
      sourcePath: session.baselinePath,
      editPath: editPath,
    );
    if (content.isEmpty) {
      return true;
    }
    return patch.existsSync() &&
        _sha256(utf8.encode(content)) == _sha256(patch.readAsBytesSync());
  }

  String _failedCarryHint({
    required String package,
    required String editPath,
    required String? originalHint,
  }) {
    final repairHint =
        'Created ${_relativePath(editPath)} with the current source and baseline. '
        'Fix the edit manually, then run patchwork commit $package.';
    if (originalHint == null || originalHint.isEmpty) {
      return repairHint;
    }
    return '$originalHint\n$repairHint';
  }

  void _writePartialRepairLog({
    required String editPath,
    required String package,
    required String version,
    required String patchPath,
    required PartialPatchApply partialApply,
  }) {
    final metadataPath = p.join(editPath, '.patchwork');
    Directory(metadataPath).createSync(recursive: true);
    final log = StringBuffer()
      ..writeln('Patchwork partial repair')
      ..writeln('package: $package')
      ..writeln('version: $version')
      ..writeln('patch: ${_relativePath(patchPath)}')
      ..writeln('gitExitCode: ${partialApply.exitCode}');

    if (partialApply.rejectPaths.isEmpty) {
      log.writeln('rejects: none');
    } else {
      log.writeln('rejects:');
      for (final rejectPath in partialApply.rejectPaths) {
        log.writeln('- $rejectPath');
      }
    }

    if (partialApply.output.isNotEmpty) {
      log
        ..writeln()
        ..writeln('git apply --reject output:')
        ..writeln(partialApply.output);
    }

    File(
      p.join(metadataPath, 'partial-repair.log'),
    ).writeAsStringSync(log.toString(), flush: true);
  }

  EditSession? _tryReadEditSession(PackageVersionPath edit) {
    try {
      return editSessionStore.read(edit);
    } on PatchworkException {
      return null;
    }
  }

  String _relativePath(String path) {
    final absolute = p.normalize(p.absolute(path));
    final root = p.normalize(p.absolute(rootPath));
    if (p.equals(root, absolute)) {
      return '.';
    }
    if (p.isWithin(root, absolute)) {
      return p.posix.joinAll(p.split(p.relative(absolute, from: root)));
    }
    return path;
  }
}

String _sha256(List<int> bytes) {
  return sha256.convert(bytes).toString();
}
