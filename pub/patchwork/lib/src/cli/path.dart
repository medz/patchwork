import '../patchwork.dart';
import '../state/project_paths.dart';

/// CLI-only path rendering for Patchwork results.
extension CliPath on Patchwork {
  /// Returns [path] relative to the Patchwork state root when possible.
  String displayPath(String path) {
    return relativeToProjectRoot(rootPath: rootPath, path: path);
  }
}
