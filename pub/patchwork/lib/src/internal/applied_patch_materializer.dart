import 'dart:io';

import 'package:path/path.dart' as p;

import '../patch_file.dart';
import 'package_tree.dart';
import 'path_layout.dart';

/// Materializes a committed patch into generated applied output.
final class AppliedPatchMaterializer {
  /// Creates a materializer for one Patchwork state root.
  const AppliedPatchMaterializer({
    required this.layout,
    required this.packageTree,
    required this.patchFile,
  });

  /// Path layout for generated applied output.
  final PathLayout layout;

  /// Filesystem tree helper.
  final PackageTree packageTree;

  /// Patch apply helper.
  final PatchFile patchFile;

  /// Copies [sourcePath], applies [patchContent], and atomically installs it.
  void materialize({
    required String package,
    required String version,
    required String sourcePath,
    required String appliedPath,
    required String patchContent,
  }) {
    final tempPath = p.join(
      layout.appliedRootPath,
      '.$package@$version.$pid.${DateTime.now().microsecondsSinceEpoch}',
    );
    packageTree.deleteDirectory(tempPath);
    Directory(tempPath).createSync(recursive: true);
    try {
      packageTree.copy(sourcePath, tempPath);
      patchFile.apply(packagePath: tempPath, patchContent: patchContent);
      packageTree.deleteDirectory(appliedPath);
      Directory(p.dirname(appliedPath)).createSync(recursive: true);
      Directory(tempPath).renameSync(appliedPath);
    } catch (_) {
      packageTree.deleteDirectory(tempPath);
      rethrow;
    }
  }
}
