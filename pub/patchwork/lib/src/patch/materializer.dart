import 'dart:io';

import 'package:path/path.dart' as p;

import 'package_tree.dart';

/// Installs a transformed package copy through a temporary sibling directory.
final class PackageMaterializer {
  /// Creates a package materializer.
  const PackageMaterializer({required this.packageTree});

  /// Filesystem tree helper used for copies and cleanup.
  final PackageTree packageTree;

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
    packageTree.deleteDirectory(tempPath);
    Directory(tempPath).createSync(recursive: true);
    try {
      packageTree.copy(sourcePath, tempPath);
      transform(tempPath);
      packageTree.deleteDirectory(outputPath);
      Directory(parentPath).createSync(recursive: true);
      Directory(tempPath).renameSync(outputPath);
    } catch (_) {
      packageTree.deleteDirectory(tempPath);
      rethrow;
    }
  }
}
