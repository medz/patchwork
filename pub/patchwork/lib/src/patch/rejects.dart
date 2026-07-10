import 'dart:io';

import 'package:path/path.dart' as p;

import '../error.dart';

/// Preserves pre-existing `.rej` files while moving new rejects to metadata.
final class RejectFileTransaction {
  RejectFileTransaction._(this.packagePath, this._backups);

  /// Captures every pre-existing reject file below [packagePath].
  factory RejectFileTransaction.capture(String packagePath) {
    return RejectFileTransaction._(packagePath, {
      for (final relativePath in _rejectRelativePaths(packagePath))
        relativePath: _RejectEntryBackup.read(
          p.joinAll([packagePath, ...relativePath.split('/')]),
        ),
    });
  }

  /// Root of the package edit tree.
  final String packagePath;

  final Map<String, _RejectEntryBackup> _backups;

  /// Moves reported rejects under `.patchwork/rejects/` without data loss.
  List<String> moveReported({
    required Set<String> rejectPaths,
    required Set<String> patchTouchedPaths,
    required String failureHint,
  }) {
    _validateReportedRejectFiles(
      packagePath: packagePath,
      rejectPaths: rejectPaths,
      failureHint: failureHint,
    );
    _validateNoRejectPathCollisions(
      packagePath: packagePath,
      existingRejectBackups: _backups,
      rejectPaths: rejectPaths,
      patchTouchedPaths: patchTouchedPaths,
      failureHint: failureHint,
    );

    final movedPaths = <String>[];
    for (final relativePath in rejectPaths) {
      final source = File(p.joinAll([packagePath, ...relativePath.split('/')]));
      final rejectBytes = source.readAsBytesSync();
      final movedRelativePath = p
          .joinAll(['.patchwork', 'rejects', ...relativePath.split('/')])
          .replaceAll('\\', '/');
      final destination = File(
        p.joinAll([packagePath, ...movedRelativePath.split('/')]),
      );
      destination.parent.createSync(recursive: true);
      _deleteExistingPath(destination.path);
      destination.writeAsBytesSync(rejectBytes, flush: true);
      final backup = _backups[relativePath];
      if (backup == null) {
        _deleteExistingPath(source.path);
      } else {
        backup.restore(source.path);
      }
      movedPaths.add(movedRelativePath);
    }
    movedPaths.sort();
    return movedPaths;
  }
}

List<String> _rejectRelativePaths(String packagePath) {
  final root = Directory(packagePath);
  if (!root.existsSync()) {
    return const [];
  }
  final paths = <String>[];
  void collect(Directory directory) {
    for (final entity in directory.listSync(followLinks: false)) {
      final relativePath = p.split(p.relative(entity.path, from: packagePath));
      if (relativePath.isNotEmpty && relativePath.first == '.patchwork') {
        continue;
      }
      final type = FileSystemEntity.typeSync(entity.path, followLinks: false);
      if (type == FileSystemEntityType.directory) {
        collect(Directory(entity.path));
      } else if ((type == FileSystemEntityType.file ||
              type == FileSystemEntityType.link) &&
          entity.path.endsWith('.rej')) {
        paths.add(relativePath.join('/'));
      }
    }
  }

  collect(root);
  paths.sort();
  return paths;
}

final class _RejectEntryBackup {
  const _RejectEntryBackup.file(this.bytes, this.mode) : linkTarget = null;

  const _RejectEntryBackup.link(this.linkTarget) : bytes = null, mode = null;

  factory _RejectEntryBackup.read(String path) {
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type == FileSystemEntityType.link) {
      return _RejectEntryBackup.link(Link(path).targetSync());
    }
    final file = File(path);
    return _RejectEntryBackup.file(
      file.readAsBytesSync(),
      file.statSync().mode,
    );
  }

  final List<int>? bytes;
  final int? mode;
  final String? linkTarget;

  void restore(String path) {
    _deleteExistingPath(path);
    final target = linkTarget;
    if (target != null) {
      Link(path).createSync(target);
      return;
    }
    File(path).writeAsBytesSync(bytes!, flush: true);
    _restoreFileMode(path, mode!);
  }
}

void _restoreFileMode(String path, int mode) {
  if (Platform.isWindows) {
    return;
  }

  final permissions = (mode & 0x0fff).toRadixString(8);
  final ProcessResult result;
  try {
    result = Process.runSync('chmod', [permissions, path]);
  } on ProcessException catch (error) {
    throw PatchworkException(
      'Could not restore reject file mode.',
      code: 'patch.reject_mode_restore_failed',
      hint: error.message,
      location: path,
    );
  }
  if (result.exitCode != 0) {
    throw PatchworkException(
      'Could not restore reject file mode.',
      code: 'patch.reject_mode_restore_failed',
      hint: '${result.stderr}${result.stdout}'.trim(),
      location: path,
    );
  }
}

void _validateNoRejectPathCollisions({
  required String packagePath,
  required Map<String, _RejectEntryBackup> existingRejectBackups,
  required Set<String> rejectPaths,
  required Set<String> patchTouchedPaths,
  required String failureHint,
}) {
  final collisions = rejectPaths.where(patchTouchedPaths.contains).toList()
    ..sort();
  if (collisions.isEmpty) {
    return;
  }

  for (final relativePath in collisions) {
    final path = p.joinAll([packagePath, ...relativePath.split('/')]);
    final backup = existingRejectBackups[relativePath];
    if (backup == null) {
      _deleteExistingPath(path);
    } else {
      backup.restore(path);
    }
  }

  final relativePath = collisions.first;
  throw PatchworkException(
    'Could not safely create partial repair because a rejected hunk '
    'collides with a patched .rej file.',
    code: 'patch.reject_collision',
    hint: failureHint,
    location: p.joinAll([packagePath, ...relativePath.split('/')]),
  );
}

void _validateReportedRejectFiles({
  required String packagePath,
  required Set<String> rejectPaths,
  required String failureHint,
}) {
  for (final relativePath in rejectPaths) {
    final path = p.joinAll([packagePath, ...relativePath.split('/')]);
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type == FileSystemEntityType.file ||
        type == FileSystemEntityType.link) {
      continue;
    }
    throw PatchworkException(
      'Git reported a rejected hunk but did not write the reject file.',
      code: 'patch.reject_missing',
      hint: failureHint,
      location: path,
    );
  }
}

void _deleteExistingPath(String path) {
  final type = FileSystemEntity.typeSync(path, followLinks: false);
  switch (type) {
    case FileSystemEntityType.directory:
      Directory(path).deleteSync(recursive: true);
    case FileSystemEntityType.file:
      File(path).deleteSync();
    case FileSystemEntityType.link:
      Link(path).deleteSync();
    case FileSystemEntityType.notFound:
    case FileSystemEntityType.pipe:
    case FileSystemEntityType.unixDomainSock:
      break;
  }
}
