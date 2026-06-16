import 'dart:convert';
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
    final currentPackageRoot = _findNearestPackageRoot(startPath);
    if (currentPackageRoot == null) {
      throw PatchworkException(
        'Could not find a pub project for "$startPath".',
        code: 'pub.project_not_found',
        hint: 'Run patchwork from inside a Dart package or workspace member.',
      );
    }

    final resolutionRoot = _findResolutionRoot(currentPackageRoot);
    if (resolutionRoot == null) {
      throw PatchworkException(
        'Could not find a pub resolution for "$startPath".',
        code: 'pub.resolution_not_found',
        hint: 'Run dart pub get before using patchwork.',
      );
    }

    return PubWorkspace(
      rootPath: resolutionRoot,
      currentPackageRootPath: currentPackageRoot,
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

  String? _findResolutionRoot(String currentPackageRoot) {
    for (final candidate in _ancestorDirectories(currentPackageRoot)) {
      final packageConfigPath = p.join(
        candidate,
        '.dart_tool',
        'package_config.json',
      );
      if (!File(packageConfigPath).existsSync()) {
        continue;
      }
      if (p.equals(candidate, currentPackageRoot) ||
          _packageConfigContainsRoot(packageConfigPath, currentPackageRoot)) {
        return candidate;
      }
    }
    return null;
  }

  String? _findNearestPackageRoot(String startPath) {
    for (final candidate in _ancestorDirectories(startPath)) {
      if (File(p.join(candidate, 'pubspec.yaml')).existsSync()) {
        return candidate;
      }
    }
    return null;
  }

  bool _packageConfigContainsRoot(
    String packageConfigPath,
    String packageRoot,
  ) {
    try {
      final decoded = jsonDecode(File(packageConfigPath).readAsStringSync());
      if (decoded is! Map<String, Object?>) {
        return false;
      }

      final packages = decoded['packages'];
      if (packages is! List<Object?>) {
        return false;
      }

      final baseUri = Directory(p.dirname(packageConfigPath)).uri;
      final expectedRoot = p.normalize(p.absolute(packageRoot));
      for (final package in packages) {
        if (package is! Map<String, Object?>) {
          continue;
        }
        final rootUri = package['rootUri'];
        if (rootUri is! String) {
          continue;
        }
        final resolvedRoot = p.normalize(
          baseUri.resolveUri(Uri.parse(rootUri)).toFilePath(),
        );
        if (p.equals(resolvedRoot, expectedRoot)) {
          return true;
        }
      }
      return false;
    } on FormatException {
      return false;
    } on FileSystemException {
      return false;
    } on UnsupportedError {
      return false;
    }
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
