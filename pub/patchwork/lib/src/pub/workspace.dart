import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../error.dart';

/// The pub project context selected for a Patchwork command.
///
/// A command may run from a standalone package, a workspace root, or a workspace
/// member. This value records both the current package and the root that owns
/// generated pub resolution files so Patchwork can keep state in the same place
/// pub will read overrides from.
final class PubWorkspace {
  /// Creates workspace metadata discovered from pub files.
  PubWorkspace({
    required this.rootPath,
    required this.currentPackageRootPath,
    required Set<String> rootPackageRootPaths,
    required this.packageConfigPath,
    required this.lockfilePath,
    required this.packageGraphPath,
  }) : rootPackageRootPaths = Set.unmodifiable(rootPackageRootPaths);

  /// The root that owns `.dart_tool/package_config.json` and `pubspec.lock`.
  final String rootPath;

  /// The nearest package root containing the command's working directory.
  final String currentPackageRootPath;

  /// Package roots that are part of the user's project, not patch targets.
  final Set<String> rootPackageRootPaths;

  /// The active `.dart_tool/package_config.json` path.
  final String packageConfigPath;

  /// The active `pubspec.lock` path.
  final String lockfilePath;

  /// The active `.dart_tool/package_graph.json` path.
  final String packageGraphPath;
}

/// Locates the pub project context for a command directory.
///
/// The locator walks ancestors to find the nearest `pubspec.yaml`, then walks
/// again to find the pub resolution root whose `package_config.json` contains
/// that package. This mirrors pub's workspace/member behavior closely enough
/// for Patchwork to choose where state files belong.
final class PubWorkspaceLocator {
  /// Creates a workspace locator.
  const PubWorkspaceLocator();

  /// Returns workspace metadata for [currentDirectory].
  ///
  /// Throws [PatchworkException] when no package root or active pub resolution
  /// can be found.
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
      ..._pubspecWorkspaceRootPaths(resolutionRoot),
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

  Set<String> _pubspecWorkspaceRootPaths(String resolutionRoot) {
    try {
      final decoded = loadYaml(
        File(p.join(resolutionRoot, 'pubspec.yaml')).readAsStringSync(),
      );
      if (decoded is! YamlMap) {
        return const {};
      }
      final workspace = decoded['workspace'];
      if (workspace is! YamlList) {
        return const {};
      }
      return {
        for (final item in workspace.nodes)
          if (item.value is String)
            ..._expandWorkspacePath(resolutionRoot, item.value as String),
      };
    } on YamlException {
      return const {};
    } on FileSystemException {
      return const {};
    }
  }

  Set<String> _expandWorkspacePath(
    String resolutionRoot,
    String workspacePath,
  ) {
    final segments = p.split(workspacePath);
    var paths = {p.normalize(p.absolute(resolutionRoot))};
    for (final segment in segments) {
      final next = <String>{};
      for (final base in paths) {
        if (segment == '*') {
          final directory = Directory(base);
          if (!directory.existsSync()) {
            continue;
          }
          for (final entity in directory.listSync(followLinks: false)) {
            if (FileSystemEntity.typeSync(entity.path, followLinks: false) ==
                FileSystemEntityType.directory) {
              next.add(p.normalize(entity.path));
            }
          }
        } else {
          next.add(p.normalize(p.join(base, segment)));
        }
      }
      paths = next;
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
