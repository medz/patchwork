import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../error.dart';

/// Copies and hashes dependency package trees using Patchwork's filter rules.
///
/// The hash is intended to describe the source files that matter for patching,
/// not transient pub or build output. The same filters are used for hashing and
/// copying so a generated patch is based on the same tree that was fingerprinted.
final class PackageTree {
  /// Creates a package tree helper.
  const PackageTree();

  /// Computes Patchwork's deterministic SHA-256 hash for [rootPath].
  ///
  /// The hash includes relative paths, file modes, file contents, and symlink
  /// targets. Entries such as `.dart_tool`, `build`, `.git`, `.packages`, and
  /// `pubspec.lock` are ignored because they are generated or environment local.
  String sha256Of(String rootPath) {
    final root = Directory(rootPath);
    if (!root.existsSync()) {
      throw PatchworkException(
        'Package tree does not exist.',
        code: 'fs.package_tree_missing',
        location: rootPath,
      );
    }

    final entries = _collectEntries(rootPath);
    final digestSink = _DigestSink();
    final sink = sha256.startChunkedConversion(digestSink);
    for (final entry in entries) {
      sink.add(utf8.encode('${entry.type}:${entry.relativePath}\n'));
      switch (entry.type) {
        case _TreeEntryType.file:
          _addFileToHash(sink, entry.path);
        case _TreeEntryType.link:
          sink.add(utf8.encode('${Link(entry.path).targetSync()}\n'));
      }
    }
    sink.close();
    return digestSink.digest.toString();
  }

  /// Copies a filtered package tree from [sourcePath] to [destinationPath].
  ///
  /// Existing contents of [destinationPath] are preserved unless overwritten by
  /// copied files; callers normally pass a fresh temporary directory.
  void copy(String sourcePath, String destinationPath) {
    final source = Directory(sourcePath);
    if (!source.existsSync()) {
      throw PatchworkException(
        'Source package does not exist.',
        code: 'fs.source_missing',
        location: sourcePath,
      );
    }

    final destination = Directory(destinationPath);
    if (!destination.existsSync()) {
      destination.createSync(recursive: true);
    }

    _copyDirectory(sourcePath, destinationPath, sourceRootPath: sourcePath);
  }

  /// Deletes [path] recursively when it exists.
  void deleteDirectory(String path) {
    final directory = Directory(path);
    if (directory.existsSync()) {
      directory.deleteSync(recursive: true);
    }
  }

  List<_TreeEntry> _collectEntries(String rootPath) {
    final entries = <_TreeEntry>[];

    void collect(String path) {
      for (final entity in Directory(path).listSync(followLinks: false)) {
        final relativePath = _relativePath(entity.path, rootPath);
        final type = FileSystemEntity.typeSync(entity.path, followLinks: false);
        if (!_shouldInclude(relativePath, type)) {
          continue;
        }

        switch (type) {
          case FileSystemEntityType.directory:
            collect(entity.path);
          case FileSystemEntityType.file:
            entries.add(
              _TreeEntry(
                type: _TreeEntryType.file,
                path: entity.path,
                relativePath: relativePath,
              ),
            );
          case FileSystemEntityType.link:
            entries.add(
              _TreeEntry(
                type: _TreeEntryType.link,
                path: entity.path,
                relativePath: relativePath,
              ),
            );
          case FileSystemEntityType.notFound:
          case FileSystemEntityType.pipe:
          case FileSystemEntityType.unixDomainSock:
            break;
        }
      }
    }

    collect(rootPath);
    entries.sort(
      (left, right) => left.relativePath.compareTo(right.relativePath),
    );
    return entries;
  }

  void _copyDirectory(
    String sourcePath,
    String destinationPath, {
    required String sourceRootPath,
  }) {
    for (final entity in Directory(sourcePath).listSync(followLinks: false)) {
      final relativePath = _relativePath(entity.path, sourceRootPath);
      final type = FileSystemEntity.typeSync(entity.path, followLinks: false);
      if (!_shouldInclude(relativePath, type)) {
        continue;
      }

      final targetPath = p.join(destinationPath, p.basename(entity.path));
      switch (type) {
        case FileSystemEntityType.directory:
          Directory(targetPath).createSync(recursive: true);
          _copyDirectory(
            entity.path,
            targetPath,
            sourceRootPath: sourceRootPath,
          );
        case FileSystemEntityType.file:
          File(targetPath).parent.createSync(recursive: true);
          File(entity.path).copySync(targetPath);
        case FileSystemEntityType.link:
          Link(targetPath).parent.createSync(recursive: true);
          Link(targetPath).createSync(Link(entity.path).targetSync());
        case FileSystemEntityType.notFound:
        case FileSystemEntityType.pipe:
        case FileSystemEntityType.unixDomainSock:
          break;
      }
    }
  }
}

void _addFileToHash(Sink<List<int>> sink, String path) {
  final file = File(path);
  final mode = file.statSync().mode;
  final input = file.openSync();
  try {
    sink.add(utf8.encode('$mode\n'));
    sink.add(utf8.encode('${input.lengthSync()}\n'));
    while (true) {
      final bytes = input.readSync(64 * 1024);
      if (bytes.isEmpty) {
        break;
      }
      sink.add(bytes);
    }
    sink.add(const [0x0a]);
  } finally {
    input.closeSync();
  }
}

bool _shouldInclude(String relativePath, FileSystemEntityType type) {
  if (type == FileSystemEntityType.pipe ||
      type == FileSystemEntityType.unixDomainSock ||
      type == FileSystemEntityType.notFound) {
    return false;
  }

  final parts = relativePath.split('/');
  if (parts.isEmpty) {
    return true;
  }
  final first = parts.first;
  if (first == '.dart_tool' ||
      first == '.patchwork' ||
      first == 'build' ||
      first == '.git') {
    return false;
  }
  return relativePath != '.packages' && relativePath != 'pubspec.lock';
}

String _relativePath(String path, String rootPath) {
  return p.split(p.relative(path, from: rootPath)).join('/');
}

enum _TreeEntryType { file, link }

final class _TreeEntry {
  const _TreeEntry({
    required this.type,
    required this.path,
    required this.relativePath,
  });

  final _TreeEntryType type;
  final String path;
  final String relativePath;
}

final class _DigestSink implements Sink<Digest> {
  late Digest digest;

  @override
  void add(Digest data) {
    digest = data;
  }

  @override
  void close() {}
}
