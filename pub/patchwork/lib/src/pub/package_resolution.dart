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
    final packages = _PackageIndex(
      packageConfig: _readPackageConfig(workspace),
      lockfile: _readLockfile(workspace),
    );
    final currentPackageName = packages.currentPackageName(workspace);
    final dependencies = _readCurrentPubspecDependencies(workspace);
    final graph = _readPackageGraph(
      workspace,
      currentPackageName,
      dependencies: dependencies,
      workspaceRootNames: _readWorkspaceRootNames(workspace),
    );

    return PubResolution._(
      workspace: workspace,
      packages: packages,
      graph: graph,
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

  _PackageGraph _readPackageGraph(
    PubWorkspace workspace,
    String currentPackageName, {
    required _PubspecDependencies dependencies,
    required Set<String> workspaceRootNames,
  }) {
    final packageGraph = File(workspace.packageGraphPath);
    if (!packageGraph.existsSync()) {
      return _PackageGraph(
        rootNames: workspaceRootNames,
        currentPackageName: currentPackageName,
        directMainDependencies: dependencies.main,
        directDevDependencies: dependencies.dev,
        hasCurrentPackage: true,
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

      final rootNames = {
        ..._readStringSet(workspace, decoded['roots'], fieldName: 'roots'),
        ...workspaceRootNames,
      };
      final packages = decoded['packages'];
      if (packages is! List<Object?>) {
        throw _malformedPackageGraph(
          workspace,
          'Expected package_graph.json to contain a packages list.',
        );
      }

      for (final package in packages) {
        if (package is! Map<String, Object?>) {
          throw _malformedPackageGraph(
            workspace,
            'Expected each package_graph package entry to be an object.',
          );
        }
      }

      return _PackageGraph(
        rootNames: rootNames,
        currentPackageName: currentPackageName,
        directMainDependencies: dependencies.main,
        directDevDependencies: dependencies.dev,
        hasCurrentPackage: true,
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

  _PubspecDependencies _readCurrentPubspecDependencies(PubWorkspace workspace) {
    final pubspecPath = p.join(
      workspace.currentPackageRootPath,
      'pubspec.yaml',
    );
    try {
      final decoded = loadYaml(File(pubspecPath).readAsStringSync());
      if (decoded is! YamlMap) {
        throw _malformedPubspec(pubspecPath, 'Expected a YAML object.');
      }
      return _PubspecDependencies(
        main: _readDependencyNames(pubspecPath, decoded['dependencies']),
        dev: _readDependencyNames(pubspecPath, decoded['dev_dependencies']),
      );
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

  Set<String> _readWorkspaceRootNames(PubWorkspace workspace) {
    final pubspecPath = p.join(workspace.rootPath, 'pubspec.yaml');
    try {
      final decoded = loadYaml(File(pubspecPath).readAsStringSync());
      if (decoded is! YamlMap) {
        throw _malformedPubspec(pubspecPath, 'Expected a YAML object.');
      }
      final workspaceEntries = decoded['workspace'];
      if (workspaceEntries == null) {
        return const {};
      }
      if (workspaceEntries is! YamlList) {
        throw _malformedPubspec(
          pubspecPath,
          'Expected workspace to be a YAML list.',
        );
      }

      final names = <String>{};
      for (final entry in workspaceEntries.nodes) {
        final value = entry.value;
        if (value is! String) {
          throw _malformedPubspec(
            pubspecPath,
            'Expected workspace entries to be strings.',
          );
        }
        for (final packageRoot in _workspacePackageRoots(
          workspace.rootPath,
          value,
        )) {
          names.add(_readPackageName(packageRoot));
        }
      }
      return names;
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

  List<String> _workspacePackageRoots(String workspaceRoot, String entry) {
    if (!_containsGlob(entry)) {
      return [p.join(workspaceRoot, entry)];
    }

    var candidates = [workspaceRoot];
    for (final part in p.split(entry)) {
      if (part == '.' || part.isEmpty) {
        continue;
      }
      if (part == '**') {
        candidates = [
          for (final candidate in candidates)
            ..._descendantDirectories(candidate, includeSelf: true),
        ];
        continue;
      }
      if (_containsGlob(part)) {
        final pattern = _globSegmentPattern(part);
        candidates = [
          for (final candidate in candidates)
            if (Directory(candidate).existsSync())
              for (final entity in Directory(
                candidate,
              ).listSync(followLinks: false))
                if (FileSystemEntity.typeSync(
                      entity.path,
                      followLinks: false,
                    ) ==
                    FileSystemEntityType.directory)
                  if (pattern.hasMatch(p.basename(entity.path))) entity.path,
        ];
        continue;
      }
      candidates = [
        for (final candidate in candidates) p.join(candidate, part),
      ];
    }

    return [
      for (final candidate in candidates)
        if (File(p.join(candidate, 'pubspec.yaml')).existsSync()) candidate,
    ];
  }

  Iterable<String> _descendantDirectories(
    String root, {
    required bool includeSelf,
  }) sync* {
    final directory = Directory(root);
    if (!directory.existsSync()) {
      return;
    }
    if (includeSelf) {
      yield root;
    }
    for (final entity in directory.listSync(followLinks: false)) {
      if (FileSystemEntity.typeSync(entity.path, followLinks: false) !=
          FileSystemEntityType.directory) {
        continue;
      }
      yield entity.path;
      yield* _descendantDirectories(entity.path, includeSelf: false);
    }
  }

  RegExp _globSegmentPattern(String segment) {
    final buffer = StringBuffer('^');
    for (var index = 0; index < segment.length; index += 1) {
      final character = segment[index];
      if (character == '*') {
        buffer.write('[^/]*');
      } else if (character == '?') {
        buffer.write('[^/]');
      } else {
        buffer.write(RegExp.escape(character));
      }
    }
    buffer.write(r'$');
    return RegExp(buffer.toString());
  }

  String _readPackageName(String packageRoot) {
    final pubspecPath = p.join(packageRoot, 'pubspec.yaml');
    try {
      final decoded = loadYaml(File(pubspecPath).readAsStringSync());
      if (decoded is! YamlMap) {
        throw _malformedPubspec(pubspecPath, 'Expected a YAML object.');
      }
      final name = decoded['name'];
      if (name is! String || name.isEmpty) {
        throw _malformedPubspec(
          pubspecPath,
          'Expected package name to be a non-empty string.',
        );
      }
      return name;
    } on YamlException catch (error) {
      throw _malformedPubspec(pubspecPath, error.message);
    } on FileSystemException catch (error) {
      throw PatchworkException(
        'Could not read workspace member pubspec.yaml.',
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

  PatchworkException _malformedPubspec(String path, String message) {
    return PatchworkException(
      'Malformed pubspec.yaml: $message',
      code: 'pub.malformed_pubspec',
      location: path,
    );
  }
}

bool _containsGlob(String value) {
  return value.contains('*') || value.contains('?');
}

final class PubResolution {
  const PubResolution._({
    required this.workspace,
    required this._packages,
    required this._graph,
    required this.packageTree,
  });

  final PubWorkspace workspace;
  final _PackageIndex _packages;
  final _PackageGraph _graph;
  final PackageTree packageTree;

  ResolvedPubPackage resolvePackage(String packageName) {
    final packageConfig = _packages.packageConfig[packageName];
    if (packageConfig == null) {
      throw PatchworkException(
        'Package "$packageName" is not selected by the current pub resolution.',
        code: 'pub.package_not_found',
        hint: 'Run dart pub get and check that the package is a dependency.',
      );
    }

    if (_graph.isRoot(packageName) ||
        p.equals(packageConfig.rootPath, workspace.currentPackageRootPath) ||
        p.equals(packageConfig.rootPath, workspace.rootPath)) {
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

    if (metadata.sourceKind == PubPackageSourceKind.sdk) {
      throw PatchworkException(
        'Package "$packageName" comes from an SDK source and cannot be patched.',
        code: 'pub.unsupported_source',
      );
    }

    final dependencyKind = _graph.dependencyKindFor(
      packageName,
      metadata.dependencyKind,
    );
    if (dependencyKind != PubPackageDependencyKind.directMain &&
        dependencyKind != PubPackageDependencyKind.directDev) {
      throw PatchworkException(
        'Package "$packageName" is not a direct dependency of the current project.',
        code: 'pub.package_not_direct_dependency',
        hint:
            'patchwork patch only accepts dependencies declared by the current package.',
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
      dependencyKind: dependencyKind,
      rootPath: packageConfig.rootPath,
      packageUri: packageConfig.packageUri,
      languageVersion: packageConfig.languageVersion,
      source: _sourceFor(metadata, packageConfig.rootPath, workspace),
    );
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

final class _PackageIndex {
  const _PackageIndex({required this.packageConfig, required this.lockfile});

  final Map<String, _PackageConfigPackage> packageConfig;
  final Map<String, _ResolutionMetadataPackage> lockfile;

  String currentPackageName(PubWorkspace workspace) {
    for (final entry in packageConfig.entries) {
      if (p.equals(entry.value.rootPath, workspace.currentPackageRootPath)) {
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
    required this.dependencyKind,
    required this.description,
  });

  final String version;
  final PubPackageSourceKind sourceKind;
  final PubPackageDependencyKind dependencyKind;
  final Map<String, String> description;
}

final class _PubspecDependencies {
  const _PubspecDependencies({required this.main, required this.dev});

  final Set<String> main;
  final Set<String> dev;
}

final class _PackageGraph {
  const _PackageGraph({
    required this.rootNames,
    required this.currentPackageName,
    required this.directMainDependencies,
    required this.directDevDependencies,
    required this.hasCurrentPackage,
  });

  final Set<String> rootNames;
  final String currentPackageName;
  final Set<String> directMainDependencies;
  final Set<String> directDevDependencies;
  final bool hasCurrentPackage;

  bool isRoot(String name) {
    return rootNames.contains(name) || name == currentPackageName;
  }

  PubPackageDependencyKind dependencyKindFor(
    String name,
    PubPackageDependencyKind fallback,
  ) {
    if (isRoot(name)) {
      return PubPackageDependencyKind.root;
    }
    if (directMainDependencies.contains(name)) {
      return PubPackageDependencyKind.directMain;
    }
    if (directDevDependencies.contains(name)) {
      return PubPackageDependencyKind.directDev;
    }
    if (hasCurrentPackage) {
      return PubPackageDependencyKind.transitive;
    }
    return fallback;
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
