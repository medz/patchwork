import 'dart:io';

import 'package:path/path.dart' as p;

import 'package_tree.dart';

/// Moves one package directory to another path on the same filesystem.
typedef PackageDirectoryRename =
    void Function(String sourcePath, String destinationPath);

/// Installs a transformed package copy through a temporary sibling directory.
final class PackageMaterializer {
  /// Creates a package materializer.
  const PackageMaterializer({
    required this.packageTree,
    this.renameDirectory = _renameDirectory,
  });

  /// Filesystem tree helper used for copies and cleanup.
  final PackageTree packageTree;

  /// Directory rename operation used for failure-safe swaps.
  final PackageDirectoryRename renameDirectory;

  /// Copies [sourcePath], runs [transform], and replaces [outputPath].
  void materialize({
    required String identity,
    required String sourcePath,
    required String outputPath,
    required void Function(String packagePath) transform,
  }) {
    final parentPath = p.dirname(outputPath);
    final tempPath = p.join(
      parentPath,
      '.$identity.$pid.${DateTime.now().microsecondsSinceEpoch}',
    );
    final backupPath = '$tempPath.backup';
    packageTree.deleteDirectory(tempPath);
    packageTree.deleteDirectory(backupPath);
    Directory(tempPath).createSync(recursive: true);
    var previousOutputMoved = false;
    var outputInstalled = false;
    try {
      packageTree.copy(sourcePath, tempPath);
      transform(tempPath);
      Directory(parentPath).createSync(recursive: true);
      if (Directory(outputPath).existsSync()) {
        renameDirectory(outputPath, backupPath);
        previousOutputMoved = true;
      }
      try {
        renameDirectory(tempPath, outputPath);
        outputInstalled = true;
      } catch (_) {
        if (previousOutputMoved &&
            Directory(backupPath).existsSync() &&
            !Directory(outputPath).existsSync()) {
          renameDirectory(backupPath, outputPath);
          previousOutputMoved = false;
        }
        rethrow;
      }
      if (previousOutputMoved) {
        packageTree.deleteDirectory(backupPath);
      }
    } catch (_) {
      packageTree.deleteDirectory(tempPath);
      if (!outputInstalled &&
          previousOutputMoved &&
          Directory(backupPath).existsSync() &&
          !Directory(outputPath).existsSync()) {
        renameDirectory(backupPath, outputPath);
      }
      rethrow;
    }
  }
}

void _renameDirectory(String sourcePath, String destinationPath) {
  Directory(sourcePath).renameSync(destinationPath);
}
