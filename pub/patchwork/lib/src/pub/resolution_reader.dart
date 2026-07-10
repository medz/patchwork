import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../error.dart';
import '../patch/package_tree.dart';
import 'resolution.dart';
import 'workspace.dart';

/// Reads the active pub resolution for a Dart package or workspace member.
///
/// Pub spreads resolution data across generated JSON, `pubspec.lock`, and the
/// current package's `pubspec.yaml`. This reader normalizes those files into a
/// [PubResolution] that can answer whether a dependency is direct, patchable,
/// and safe to use as a baseline.
final class PubResolutionReader {
  /// Creates a resolution reader with injectable filesystem helpers.
  const PubResolutionReader({
    this.workspaceLocator = const PubWorkspaceLocator(),
    this.packageTree = const PackageTree(),
  });

  /// Locates the package or workspace that owns the active pub resolution.
  final PubWorkspaceLocator workspaceLocator;

  /// Computes content hashes for resolved package roots.
  final PackageTree packageTree;

  /// Reads and validates the pub resolution active for [currentDirectory].
  ///
  /// When [packageConfigContent] is provided, it is parsed as the active
  /// `package_config.json` contents while retaining the same project paths.
  /// This lets read-only diagnostics inspect pub's base resolution even when a
  /// generated tool has temporarily rewritten `.dart_tool/package_config.json`.
  PubResolution readFromDirectory(
    String currentDirectory, {
    String? packageConfigContent,
  }) {
    final workspace = workspaceLocator.locate(currentDirectory);
    final packages = _PackageIndex(
      packageConfig: _readPackageConfig(
        workspace,
        packageConfigContent: packageConfigContent,
      ),
      lockfile: _readLockfile(workspace),
    );
    final currentPackageName = packages.currentPackageName(workspace);
    final directDependencies = _readCurrentPubspecDependencyNames(workspace);
    final rootNames = _readRootPackageNames(workspace, currentPackageName);

    return PubResolution(
      workspace: workspace,
      packageRoots: packages.packageConfig,
      metadata: packages.lockfile,
      rootNames: rootNames,
      directDependencies: directDependencies,
      packageTree: packageTree,
    );
  }

  Map<String, String> _readPackageConfig(
    PubWorkspace workspace, {
    String? packageConfigContent,
  }) {
    final packageConfigFile = File(workspace.packageConfigPath);
    try {
      final decoded = jsonDecode(
        packageConfigContent ?? packageConfigFile.readAsStringSync(),
      );
      if (decoded is! Map<String, Object?>) {
        throw _malformedPackageConfig(
          workspace,
          'Expected package_config.json to contain a JSON object.',
        );
      }

      final packages = decoded['packages'];
      if (packages is! List<Object?>) {
        throw _malformedPackageConfig(
          workspace,
          'Expected package_config.json to contain a packages list.',
        );
      }

      final entries = <String, String>{};
      for (final package in packages) {
        if (package is! Map<String, Object?>) {
          throw _malformedPackageConfig(
            workspace,
            'Expected each package_config entry to be an object.',
          );
        }

        final name = package['name'];
        final rootUri = package['rootUri'];
        if (name is! String || rootUri is! String) {
          throw _malformedPackageConfig(
            workspace,
            'Expected package_config entries to include name and rootUri.',
          );
        }
        if (entries.containsKey(name)) {
          throw PatchworkException(
            'Package "$name" appears more than once in pub resolution.',
            code: 'pub.ambiguous_package',
            location: workspace.packageConfigPath,
          );
        }

        entries[name] = _resolvePackageRootUri(workspace, rootUri);
      }
      return entries;
    } on FormatException catch (error) {
      throw _malformedPackageConfig(workspace, error.message);
    } on FileSystemException catch (error) {
      throw PatchworkException(
        'Could not read pub package_config.json.',
        code: 'pub.package_config_not_readable',
        hint: error.message,
        location: workspace.packageConfigPath,
      );
    }
  }

  Map<String, PubPackageMetadata> _readLockfile(PubWorkspace workspace) {
    final lockfile = File(workspace.lockfilePath);
    if (!lockfile.existsSync()) {
      throw PatchworkException(
        'Could not find pubspec.lock.',
        code: 'pub.lockfile_not_found',
        hint: 'Run dart pub get before using patchwork.',
        location: workspace.lockfilePath,
      );
    }

    try {
      final decoded = loadYaml(lockfile.readAsStringSync());
      if (decoded is! YamlMap) {
        throw _malformedLockfile(
          workspace,
          'Expected pubspec.lock to contain a YAML object.',
        );
      }
      final packages = decoded['packages'];
      if (packages is! YamlMap) {
        throw _malformedLockfile(
          workspace,
          'Expected pubspec.lock to contain a packages map.',
        );
      }

      final entries = <String, PubPackageMetadata>{};
      for (final entry in packages.entries) {
        final name = entry.key;
        final value = entry.value;
        if (name is! String || value is! YamlMap) {
          throw _malformedLockfile(
            workspace,
            'Expected each pubspec.lock package entry to be a map.',
          );
        }

        final version = value['version'];
        if (version == null) {
          throw _malformedLockfile(
            workspace,
            'Expected package "$name" to include a selected version.',
          );
        }

        entries[name] = PubPackageMetadata(
          version: version.toString(),
          sourceKind: _parseSourceKind(value['source']),
          description: _yamlMapToStringMap(value['description']),
        );
      }
      return entries;
    } on YamlException catch (error) {
      throw _malformedLockfile(workspace, error.message);
    } on FileSystemException catch (error) {
      throw PatchworkException(
        'Could not read pubspec.lock.',
        code: 'pub.lockfile_not_readable',
        hint: error.message,
        location: workspace.lockfilePath,
      );
    }
  }

  Set<String> _readRootPackageNames(
    PubWorkspace workspace,
    String currentPackageName,
  ) {
    final packageGraph = File(workspace.packageGraphPath);
    if (!packageGraph.existsSync()) {
      return {currentPackageName};
    }

    try {
      final decoded = jsonDecode(packageGraph.readAsStringSync());
      if (decoded is! Map<String, Object?>) {
        throw _malformedPackageGraph(
          workspace,
          'Expected package_graph.json to contain a JSON object.',
        );
      }

      final rootNames = {
        ..._readStringSet(workspace, decoded['roots'], fieldName: 'roots'),
        currentPackageName,
      };

      return rootNames;
    } on FormatException catch (error) {
      throw _malformedPackageGraph(workspace, error.message);
    } on FileSystemException catch (error) {
      throw PatchworkException(
        'Could not read .dart_tool/package_graph.json.',
        code: 'pub.package_graph_not_readable',
        hint: error.message,
        location: workspace.packageGraphPath,
      );
    }
  }

  Set<String> _readCurrentPubspecDependencyNames(PubWorkspace workspace) {
    final pubspecPath = p.join(
      workspace.currentPackageRootPath,
      'pubspec.yaml',
    );
    try {
      final decoded = loadYaml(File(pubspecPath).readAsStringSync());
      if (decoded is! YamlMap) {
        throw _malformedPubspec(pubspecPath, 'Expected a YAML object.');
      }
      return {
        ..._readDependencyNames(pubspecPath, decoded['dependencies']),
        ..._readDependencyNames(pubspecPath, decoded['dev_dependencies']),
      };
    } on YamlException catch (error) {
      throw _malformedPubspec(pubspecPath, error.message);
    } on FileSystemException catch (error) {
      throw PatchworkException(
        'Could not read pubspec.yaml.',
        code: 'pub.pubspec_not_readable',
        hint: error.message,
        location: pubspecPath,
      );
    }
  }

  Set<String> _readDependencyNames(String pubspecPath, Object? value) {
    if (value == null) {
      return const {};
    }
    if (value is! YamlMap) {
      throw _malformedPubspec(
        pubspecPath,
        'Expected dependencies to be a YAML object.',
      );
    }

    return {
      for (final entry in value.entries)
        if (entry.key is String)
          entry.key as String
        else
          throw _malformedPubspec(
            pubspecPath,
            'Expected dependency names to be strings.',
          ),
    };
  }

  Set<String> _readStringSet(
    PubWorkspace workspace,
    Object? value, {
    required String fieldName,
  }) {
    if (value is! List<Object?>) {
      throw _malformedPackageGraph(
        workspace,
        'Expected package_graph $fieldName to be a list of strings.',
      );
    }
    return {
      for (final item in value)
        if (item is String)
          item
        else
          throw _malformedPackageGraph(
            workspace,
            'Expected package_graph $fieldName to contain only strings.',
          ),
    };
  }

  String _resolvePackageRootUri(PubWorkspace workspace, String rootUri) {
    try {
      final uri = Uri.parse(rootUri);
      if (uri.scheme == 'file') {
        return p.normalize(uri.toFilePath());
      }
      if (uri.hasScheme) {
        throw const FormatException('Unsupported package root URI scheme.');
      }

      final baseUri = Directory(p.dirname(workspace.packageConfigPath)).uri;
      return p.normalize(baseUri.resolveUri(uri).toFilePath());
    } on FormatException catch (error) {
      throw _malformedPackageConfig(
        workspace,
        'Could not resolve rootUri "$rootUri": ${error.message}',
      );
    } on UnsupportedError {
      throw _malformedPackageConfig(
        workspace,
        'Could not resolve rootUri "$rootUri".',
      );
    }
  }

  PubPackageSourceKind _parseSourceKind(Object? source) {
    return switch (source) {
      'hosted' => PubPackageSourceKind.hosted,
      'path' => PubPackageSourceKind.path,
      'git' => PubPackageSourceKind.git,
      'sdk' => PubPackageSourceKind.sdk,
      _ => PubPackageSourceKind.unknown,
    };
  }

  PatchworkException _malformedPackageConfig(
    PubWorkspace workspace,
    String message,
  ) {
    return PatchworkException(
      'Malformed pub package_config.json: $message',
      code: 'pub.malformed_package_config',
      location: workspace.packageConfigPath,
    );
  }

  PatchworkException _malformedLockfile(
    PubWorkspace workspace,
    String message,
  ) {
    return PatchworkException(
      'Malformed pubspec.lock: $message',
      code: 'pub.malformed_lockfile',
      location: workspace.lockfilePath,
    );
  }

  PatchworkException _malformedPackageGraph(
    PubWorkspace workspace,
    String message,
  ) {
    return PatchworkException(
      'Malformed .dart_tool/package_graph.json: $message',
      code: 'pub.malformed_package_graph',
      location: workspace.packageGraphPath,
    );
  }

  PatchworkException _malformedPubspec(String path, String message) {
    return PatchworkException(
      'Malformed pubspec.yaml: $message',
      code: 'pub.malformed_pubspec',
      location: path,
    );
  }
}

final class _PackageIndex {
  const _PackageIndex({required this.packageConfig, required this.lockfile});

  final Map<String, String> packageConfig;
  final Map<String, PubPackageMetadata> lockfile;

  String currentPackageName(PubWorkspace workspace) {
    for (final entry in packageConfig.entries) {
      if (p.equals(entry.value, workspace.currentPackageRootPath)) {
        return entry.key;
      }
    }
    throw PatchworkException(
      'Current package is not part of the active pub resolution.',
      code: 'pub.current_package_not_found',
      hint: 'Run dart pub get from the current package or workspace.',
      location: workspace.packageConfigPath,
    );
  }
}

Map<String, String> _yamlMapToStringMap(Object? value) {
  if (value is! YamlMap) {
    return const {};
  }

  return {
    for (final entry in value.entries)
      if (entry.key is String && entry.value != null)
        entry.key as String: entry.value.toString(),
  };
}
