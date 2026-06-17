import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../error.dart';

final class PubWorkspace {
  const PubWorkspace({
    required this.rootPath,
    required this.currentPackageRootPath,
    required this.rootPackageRootPaths,
    required this.packageConfigPath,
    required this.lockfilePath,
    required this.packageGraphPath,
  });

  final String rootPath;
  final String currentPackageRootPath;
  final Set<String> rootPackageRootPaths;
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

    final packageConfigPath = p.join(
      resolutionRoot,
      '.dart_tool',
      'package_config.json',
    );
    final packageGraphPath = p.join(
      resolutionRoot,
      '.dart_tool',
      'package_graph.json',
    );

    return PubWorkspace(
      rootPath: resolutionRoot,
      currentPackageRootPath: currentPackageRoot,
      rootPackageRootPaths: _rootPackageRootPaths(
        resolutionRoot: resolutionRoot,
        currentPackageRoot: currentPackageRoot,
        packageConfigPath: packageConfigPath,
        packageGraphPath: packageGraphPath,
      ),
      packageConfigPath: packageConfigPath,
      lockfilePath: p.join(resolutionRoot, 'pubspec.lock'),
      packageGraphPath: packageGraphPath,
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
    final expectedRoot = p.normalize(p.absolute(packageRoot));
    return _packageConfigRootPaths(
      packageConfigPath,
    ).values.any((root) => p.equals(root, expectedRoot));
  }

  Set<String> _rootPackageRootPaths({
    required String resolutionRoot,
    required String currentPackageRoot,
    required String packageConfigPath,
    required String packageGraphPath,
  }) {
    final paths = <String>{
      p.normalize(p.absolute(resolutionRoot)),
      p.normalize(p.absolute(currentPackageRoot)),
    };

    final packageRoots = _packageConfigRootPaths(packageConfigPath);
    for (final name in _packageGraphRootNames(packageGraphPath)) {
      final rootPath = packageRoots[name];
      if (rootPath != null) {
        paths.add(rootPath);
      }
    }
    return paths;
  }

  Map<String, String> _packageConfigRootPaths(String packageConfigPath) {
    try {
      final decoded = jsonDecode(File(packageConfigPath).readAsStringSync());
      if (decoded is! Map<String, Object?>) {
        return const {};
      }

      final packages = decoded['packages'];
      if (packages is! List<Object?>) {
        return const {};
      }

      final baseUri = Directory(p.dirname(packageConfigPath)).uri;
      final entries = <String, String>{};
      for (final package in packages) {
        if (package is! Map<String, Object?>) {
          continue;
        }
        final name = package['name'];
        final rootUri = package['rootUri'];
        if (name is! String || rootUri is! String) {
          continue;
        }
        entries[name] = p.normalize(
          baseUri.resolveUri(Uri.parse(rootUri)).toFilePath(),
        );
      }
      return entries;
    } on FormatException {
      return const {};
    } on FileSystemException {
      return const {};
    } on UnsupportedError {
      return const {};
    }
  }

  Set<String> _packageGraphRootNames(String packageGraphPath) {
    final packageGraph = File(packageGraphPath);
    if (!packageGraph.existsSync()) {
      return const {};
    }

    try {
      final decoded = jsonDecode(packageGraph.readAsStringSync());
      if (decoded is! Map<String, Object?>) {
        return const {};
      }
      final roots = decoded['roots'];
      if (roots is! List<Object?>) {
        return const {};
      }
      return {
        for (final root in roots)
          if (root is String) root,
      };
    } on FormatException {
      return const {};
    } on FileSystemException {
      return const {};
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
