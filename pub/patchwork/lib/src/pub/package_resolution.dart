import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../error.dart';
import '../internal/package_tree.dart';
import '../model.dart';
import 'pub_workspace.dart';

enum PubPackageSourceKind { hosted, path, git, sdk, root, unknown }

enum PubPackageDependencyKind {
  root,
  directMain,
  directDev,
  transitive,
  unknown,
}

final class ResolvedPubPackage {
  const ResolvedPubPackage({
    required this.name,
    required this.version,
    required this.sourceKind,
    required this.dependencyKind,
    required this.rootPath,
    required this.packageUri,
    required this.source,
    this.languageVersion,
  });

  final String name;
  final String version;
  final PubPackageSourceKind sourceKind;
  final PubPackageDependencyKind dependencyKind;
  final String rootPath;
  final String packageUri;
  final PackageSource source;
  final String? languageVersion;
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
    final packageConfigPackages = _readPackageConfig(workspace);
    final metadataPackages = _readLockfile(workspace);
    final graph = _readPackageGraph(workspace);

    return PubResolution._(
      workspace: workspace,
      packageConfigPackages: packageConfigPackages,
      metadataPackages: metadataPackages,
      rootPackageNames: graph.rootNames,
      rootMainDependencies: graph.rootMainDependencies,
      rootDevDependencies: graph.rootDevDependencies,
      packageTree: packageTree,
    );
  }

  Map<String, _PackageConfigPackage> _readPackageConfig(
    PubWorkspace workspace,
  ) {
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

      final entries = <String, _PackageConfigPackage>{};
      for (final package in packages) {
        if (package is! Map<String, Object?>) {
          throw _malformedPackageConfig(
            workspace,
            'Expected each package_config entry to be an object.',
          );
        }

        final name = package['name'];
        final rootUri = package['rootUri'];
        final packageUri = package['packageUri'];
        final languageVersion = package['languageVersion'];
        if (name is! String || rootUri is! String || packageUri is! String) {
          throw _malformedPackageConfig(
            workspace,
            'Expected package_config entries to include name, rootUri, and packageUri.',
          );
        }
        if (entries.containsKey(name)) {
          throw PatchworkException(
            'Package "$name" appears more than once in pub resolution.',
            code: 'pub.ambiguous_package',
            location: workspace.packageConfigPath,
          );
        }

        entries[name] = _PackageConfigPackage(
          rootPath: _resolvePackageRootUri(workspace, rootUri),
          packageUri: packageUri,
          languageVersion: languageVersion is String ? languageVersion : null,
        );
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
          dependencyKind: _parseLockDependencyKind(value['dependency']),
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

  _PackageGraph _readPackageGraph(PubWorkspace workspace) {
    final packageGraph = File(workspace.packageGraphPath);
    if (!packageGraph.existsSync()) {
      return const _PackageGraph(
        rootNames: <String>{},
        rootMainDependencies: <String>{},
        rootDevDependencies: <String>{},
      );
    }

    try {
      final decoded = jsonDecode(packageGraph.readAsStringSync());
      if (decoded is! Map<String, Object?>) {
        throw _malformedPackageGraph(
          workspace,
          'Expected package_graph.json to contain a JSON object.',
        );
      }

      final rootNames = _readStringSet(
        workspace,
        decoded['roots'],
        fieldName: 'roots',
      );
      final packages = decoded['packages'];
      if (packages is! List<Object?>) {
        throw _malformedPackageGraph(
          workspace,
          'Expected package_graph.json to contain a packages list.',
        );
      }

      final rootMainDependencies = <String>{};
      final rootDevDependencies = <String>{};
      for (final package in packages) {
        if (package is! Map<String, Object?>) {
          throw _malformedPackageGraph(
            workspace,
            'Expected each package_graph package entry to be an object.',
          );
        }
        final name = package['name'];
        if (name is String && rootNames.contains(name)) {
          rootMainDependencies.addAll(
            _readStringSet(
              workspace,
              package['dependencies'],
              fieldName: 'package dependencies',
              allowMissing: true,
            ),
          );
          rootDevDependencies.addAll(
            _readStringSet(
              workspace,
              package['devDependencies'],
              fieldName: 'package devDependencies',
              allowMissing: true,
            ),
          );
        }
      }

      return _PackageGraph(
        rootNames: rootNames,
        rootMainDependencies: rootMainDependencies,
        rootDevDependencies: rootDevDependencies,
      );
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

  Set<String> _readStringSet(
    PubWorkspace workspace,
    Object? value, {
    required String fieldName,
    bool allowMissing = false,
  }) {
    if (value == null && allowMissing) {
      return {};
    }
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

  PubPackageDependencyKind _parseLockDependencyKind(Object? dependency) {
    return switch (dependency) {
      'direct main' => PubPackageDependencyKind.directMain,
      'direct dev' => PubPackageDependencyKind.directDev,
      'transitive' => PubPackageDependencyKind.transitive,
      _ => PubPackageDependencyKind.unknown,
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
}

final class PubResolution {
  const PubResolution._({
    required this.workspace,
    required this._packageConfigPackages,
    required this._metadataPackages,
    required this.rootPackageNames,
    required this.rootMainDependencies,
    required this.rootDevDependencies,
    required this.packageTree,
  });

  final PubWorkspace workspace;
  final Map<String, _PackageConfigPackage> _packageConfigPackages;
  final Map<String, _ResolutionMetadataPackage> _metadataPackages;
  final Set<String> rootPackageNames;
  final Set<String> rootMainDependencies;
  final Set<String> rootDevDependencies;
  final PackageTree packageTree;

  ResolvedPubPackage resolvePackage(String packageName) {
    final packageConfig = _packageConfigPackages[packageName];
    if (packageConfig == null) {
      throw PatchworkException(
        'Package "$packageName" is not selected by the current pub resolution.',
        code: 'pub.package_not_found',
        hint: 'Run dart pub get and check that the package is a dependency.',
      );
    }

    if (rootPackageNames.contains(packageName) ||
        p.equals(packageConfig.rootPath, workspace.currentPackageRootPath) ||
        p.equals(packageConfig.rootPath, workspace.rootPath)) {
      throw PatchworkException(
        'Package "$packageName" is a workspace/root package and cannot be patched.',
        code: 'pub.package_is_project',
        hint:
            'patchwork patch only accepts dependencies of the current project.',
      );
    }

    final metadata = _metadataPackages[packageName];
    if (metadata == null) {
      throw PatchworkException(
        'Package "$packageName" has no selected version metadata.',
        code: 'pub.package_version_not_found',
        hint: 'Run dart pub get to refresh pub resolution metadata.',
      );
    }

    if (metadata.sourceKind == PubPackageSourceKind.sdk) {
      throw PatchworkException(
        'Package "$packageName" comes from an SDK source and cannot be patched.',
        code: 'pub.unsupported_source',
      );
    }

    if (!Directory(packageConfig.rootPath).existsSync()) {
      throw PatchworkException(
        'Resolved package root does not exist for "$packageName".',
        code: 'pub.package_root_missing',
        hint: 'Run dart pub get to refresh pub resolution metadata.',
        location: packageConfig.rootPath,
      );
    }

    return ResolvedPubPackage(
      name: packageName,
      version: metadata.version,
      sourceKind: metadata.sourceKind,
      dependencyKind: _dependencyKindFor(packageName, metadata.dependencyKind),
      rootPath: packageConfig.rootPath,
      packageUri: packageConfig.packageUri,
      languageVersion: packageConfig.languageVersion,
      source: _sourceFor(metadata, packageConfig.rootPath, workspace),
    );
  }

  PubPackageDependencyKind _dependencyKindFor(
    String name,
    PubPackageDependencyKind fallback,
  ) {
    if (rootPackageNames.contains(name)) {
      return PubPackageDependencyKind.root;
    }
    if (rootMainDependencies.contains(name)) {
      return PubPackageDependencyKind.directMain;
    }
    if (rootDevDependencies.contains(name)) {
      return PubPackageDependencyKind.directDev;
    }
    return fallback;
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
      case PubPackageSourceKind.root:
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

final class _PackageConfigPackage {
  const _PackageConfigPackage({
    required this.rootPath,
    required this.packageUri,
    required this.languageVersion,
  });

  final String rootPath;
  final String packageUri;
  final String? languageVersion;
}

final class _ResolutionMetadataPackage {
  const _ResolutionMetadataPackage({
    required this.version,
    required this.sourceKind,
    required this.dependencyKind,
    required this.description,
  });

  final String version;
  final PubPackageSourceKind sourceKind;
  final PubPackageDependencyKind dependencyKind;
  final Map<String, String> description;
}

final class _PackageGraph {
  const _PackageGraph({
    required this.rootNames,
    required this.rootMainDependencies,
    required this.rootDevDependencies,
  });

  final Set<String> rootNames;
  final Set<String> rootMainDependencies;
  final Set<String> rootDevDependencies;
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
