import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../error.dart';

final class PackageTree {
  const PackageTree();

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
          final mode = File(entry.path).statSync().mode;
          final bytes = File(entry.path).readAsBytesSync();
          sink.add(utf8.encode('$mode\n'));
          sink.add(utf8.encode('${bytes.length}\n'));
          sink.add(bytes);
          sink.add(const [0x0a]);
        case _TreeEntryType.link:
          sink.add(utf8.encode('${Link(entry.path).targetSync()}\n'));
      }
    }
    sink.close();
    return digestSink.digest.toString();
  }

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
  if (first == '.dart_tool' || first == 'build' || first == '.git') {
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
