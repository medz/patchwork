import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../error.dart';
import '../internal/package_tree.dart';
import '../model.dart';
import 'pub_workspace.dart';

enum PubPackageSourceKind { hosted, path, git, sdk, unknown }

final class ResolvedPubPackage {
  const ResolvedPubPackage({
    required this.version,
    required this.rootPath,
    required this.source,
  });

  final String version;
  final String rootPath;
  final PackageSource source;
}

final class PubResolutionReader {
  const PubResolutionReader({
    this.workspaceLocator = const PubWorkspaceLocator(),
    this.packageTree = const PackageTree(),
  });

  final PubWorkspaceLocator workspaceLocator;
  final PackageTree packageTree;

  PubResolution readFromDirectory(String currentDirectory) {
    final workspace = workspaceLocator.locate(currentDirectory);
    final packages = _PackageIndex(
      packageConfig: _readPackageConfig(workspace),
      lockfile: _readLockfile(workspace),
    );
    final currentPackageName = packages.currentPackageName(workspace);
    final directDependencies = _readCurrentPubspecDependencyNames(workspace);
    final rootNames = _readRootPackageNames(workspace, currentPackageName);

    return PubResolution._(
      workspace: workspace,
      packages: packages,
      rootNames: rootNames,
      directDependencies: directDependencies,
      packageTree: packageTree,
    );
  }

  Map<String, String> _readPackageConfig(PubWorkspace workspace) {
    final packageConfigFile = File(workspace.packageConfigPath);
    try {
      final decoded = jsonDecode(packageConfigFile.readAsStringSync());
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

  Map<String, _ResolutionMetadataPackage> _readLockfile(
    PubWorkspace workspace,
  ) {
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

      final entries = <String, _ResolutionMetadataPackage>{};
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

        entries[name] = _ResolutionMetadataPackage(
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

final class PubResolution {
  const PubResolution._({
    required this.workspace,
    required this._packages,
    required this._rootNames,
    required this._directDependencies,
    required this.packageTree,
  });

  final PubWorkspace workspace;
  final _PackageIndex _packages;
  final Set<String> _rootNames;
  final Set<String> _directDependencies;
  final PackageTree packageTree;

  ResolvedPubPackage resolvePackage(
    String packageName, {
    bool requireDirectDependency = true,
  }) {
    final packageConfig = _packages.packageConfig[packageName];
    if (packageConfig == null) {
      throw PatchworkException(
        'Package "$packageName" is not selected by the current pub resolution.',
        code: 'pub.package_not_found',
        hint: 'Run dart pub get and check that the package is a dependency.',
      );
    }

    if (_rootNames.contains(packageName) ||
        _isWorkspaceRootPath(packageConfig)) {
      throw PatchworkException(
        'Package "$packageName" is a workspace/root package and cannot be patched.',
        code: 'pub.package_is_project',
        hint:
            'patchwork patch only accepts dependencies of the current project.',
      );
    }

    final metadata = _packages.lockfile[packageName];
    if (metadata == null) {
      throw PatchworkException(
        'Package "$packageName" has no selected version metadata.',
        code: 'pub.package_version_not_found',
        hint: 'Run dart pub get to refresh pub resolution metadata.',
      );
    }

    if (metadata.sourceKind == PubPackageSourceKind.sdk ||
        metadata.sourceKind == PubPackageSourceKind.unknown) {
      throw PatchworkException(
        'Package "$packageName" comes from an unsupported pub source and cannot be patched.',
        code: 'pub.unsupported_source',
      );
    }

    if (requireDirectDependency && !_directDependencies.contains(packageName)) {
      throw PatchworkException(
        'Package "$packageName" is not a direct dependency of the current project.',
        code: 'pub.package_not_direct_dependency',
        hint:
            'patchwork patch only accepts dependencies declared by the current package.',
      );
    }

    if (!Directory(packageConfig).existsSync()) {
      throw PatchworkException(
        'Resolved package root does not exist for "$packageName".',
        code: 'pub.package_root_missing',
        hint: 'Run dart pub get to refresh pub resolution metadata.',
        location: packageConfig,
      );
    }

    return ResolvedPubPackage(
      version: metadata.version,
      rootPath: packageConfig,
      source: _sourceFor(metadata, packageConfig, workspace),
    );
  }

  bool _isWorkspaceRootPath(String packagePath) {
    return workspace.rootPackageRootPaths.any((rootPath) {
      return p.equals(rootPath, packagePath);
    });
  }

  PackageSource _sourceFor(
    _ResolutionMetadataPackage metadata,
    String rootPath,
    PubWorkspace workspace,
  ) {
    final fields = <String, String>{};
    switch (metadata.sourceKind) {
      case PubPackageSourceKind.hosted:
        fields['url'] = metadata.description['url'] ?? 'https://pub.dev';
      case PubPackageSourceKind.path:
        fields['path'] =
            metadata.description['path'] ??
            p.relative(rootPath, from: workspace.rootPath);
      case PubPackageSourceKind.git:
        final url = metadata.description['url'];
        final ref = metadata.description['ref'];
        final commit =
            metadata.description['resolved-ref'] ??
            metadata.description['resolvedRef'];
        final path = metadata.description['path'];
        if (url != null) {
          fields['url'] = url;
        }
        if (ref != null) {
          fields['branch'] = ref;
        }
        if (commit != null) {
          fields['commit'] = commit;
        }
        if (path != null && path != '.') {
          fields['path'] = path;
        }
      case PubPackageSourceKind.sdk:
      case PubPackageSourceKind.unknown:
        break;
    }

    return PackageSource(
      type: metadata.sourceKind.name,
      fields: fields,
      sha256: packageTree.sha256Of(rootPath),
    );
  }
}

final class _PackageIndex {
  const _PackageIndex({required this.packageConfig, required this.lockfile});

  final Map<String, String> packageConfig;
  final Map<String, _ResolutionMetadataPackage> lockfile;

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

final class _ResolutionMetadataPackage {
  const _ResolutionMetadataPackage({
    required this.version,
    required this.sourceKind,
    required this.description,
  });

  final String version;
  final PubPackageSourceKind sourceKind;
  final Map<String, String> description;
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
