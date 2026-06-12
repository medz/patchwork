import 'dart:io';

import 'package:path/path.dart' as p;

const _excludedDirectoryNames = {'.dart_tool', '.git', 'build'};
const _excludedFileNames = {'.packages', 'pubspec.lock'};

bool shouldExcludePatchSessionPath(
  String relativePath,
  FileSystemEntityType type,
) {
  final normalizedPath = relativePath.replaceAll(r'\', '/');
  if (p.posix.split(normalizedPath).length != 1) {
    return false;
  }

  if (type == FileSystemEntityType.directory) {
    return _excludedDirectoryNames.contains(normalizedPath);
  }

  return _excludedFileNames.contains(normalizedPath);
}
