import 'dart:io';

import 'package:path/path.dart' as p;

import '../diagnostics/diagnostic.dart';

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

final class PubWorkspaceLocateResult {
  const PubWorkspaceLocateResult._({this.workspace, this.diagnostic});

  factory PubWorkspaceLocateResult.success(PubWorkspace workspace) {
    return PubWorkspaceLocateResult._(workspace: workspace);
  }

  factory PubWorkspaceLocateResult.failure(Diagnostic diagnostic) {
    return PubWorkspaceLocateResult._(diagnostic: diagnostic);
  }

  final PubWorkspace? workspace;
  final Diagnostic? diagnostic;

  bool get isSuccess => workspace != null;
}

final class PubWorkspaceLocator {
  const PubWorkspaceLocator();

  PubWorkspaceLocateResult locate(String currentDirectory) {
    final startPath = p.normalize(p.absolute(currentDirectory));
    final resolutionRoot = _findResolutionRoot(startPath);

    if (resolutionRoot == null) {
      return PubWorkspaceLocateResult.failure(
        Diagnostic(
          code: 'pub.resolution_not_found',
          message: 'Could not find a pub resolution for "$startPath".',
          hint: 'Run dart pub get before using patchwork.',
        ),
      );
    }

    return PubWorkspaceLocateResult.success(
      PubWorkspace(
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
      ),
    );
  }

  String? _findResolutionRoot(String startPath) {
    for (final candidate in _ancestorDirectories(startPath)) {
      final packageConfigPath = p.join(
        candidate,
        '.dart_tool',
        'package_config.json',
      );
      if (File(packageConfigPath).existsSync()) {
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
