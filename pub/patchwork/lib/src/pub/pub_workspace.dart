import 'dart:io';

import 'package:path/path.dart' as p;

import '../error.dart';

final class PubWorkspace {
  const PubWorkspace({
    required this.rootPath,
    required this.currentPackageRootPath,
    required this.packageConfigPath,
    required this.lockfilePath,
    required this.packageGraphPath,
  });

  final String rootPath;
  final String currentPackageRootPath;
  final String packageConfigPath;
  final String lockfilePath;
  final String packageGraphPath;
}

final class PubWorkspaceLocator {
  const PubWorkspaceLocator();

  PubWorkspace locate(String currentDirectory) {
    final startPath = p.normalize(p.absolute(currentDirectory));
    final resolutionRoot = _findResolutionRoot(startPath);
    if (resolutionRoot == null) {
      throw PatchworkException(
        'Could not find a pub resolution for "$startPath".',
        code: 'pub.resolution_not_found',
        hint: 'Run dart pub get before using patchwork.',
      );
    }

    return PubWorkspace(
      rootPath: resolutionRoot,
      currentPackageRootPath: _findCurrentPackageRoot(
        startPath,
        resolutionRoot,
      ),
      packageConfigPath: p.join(
        resolutionRoot,
        '.dart_tool',
        'package_config.json',
      ),
      lockfilePath: p.join(resolutionRoot, 'pubspec.lock'),
      packageGraphPath: p.join(
        resolutionRoot,
        '.dart_tool',
        'package_graph.json',
      ),
    );
  }

  String? _findResolutionRoot(String startPath) {
    for (final candidate in _ancestorDirectories(startPath)) {
      if (File(
        p.join(candidate, '.dart_tool', 'package_config.json'),
      ).existsSync()) {
        return candidate;
      }
    }
    return null;
  }

  String _findCurrentPackageRoot(String startPath, String resolutionRoot) {
    for (final candidate in _ancestorDirectories(startPath)) {
      if (!p.isWithin(resolutionRoot, candidate) &&
          candidate != resolutionRoot) {
        break;
      }
      if (File(p.join(candidate, 'pubspec.yaml')).existsSync()) {
        return candidate;
      }
    }
    return resolutionRoot;
  }

  Iterable<String> _ancestorDirectories(String startPath) sync* {
    var current = FileSystemEntity.isDirectorySync(startPath)
        ? startPath
        : p.dirname(startPath);

    while (true) {
      yield current;

      final parent = p.dirname(current);
      if (parent == current) {
        break;
      }
      current = parent;
    }
  }
}
