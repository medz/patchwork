import 'package:path/path.dart' as p;

/// Returns [path] relative to [rootPath] when it is inside the project.
///
/// Absolute paths outside the project are returned unchanged so diagnostics and
/// CLI output do not lose information.
String relativeToProjectRoot({required String rootPath, required String path}) {
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
