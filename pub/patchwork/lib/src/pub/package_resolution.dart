import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';
import 'package:yaml/yaml.dart';

import '../diagnostics/diagnostic.dart';
import '../target/target.dart';
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
    this.languageVersion,
  });

  final String name;
  final String version;
  final PubPackageSourceKind sourceKind;
  final PubPackageDependencyKind dependencyKind;
  final String rootPath;
  final String packageUri;
  final String? languageVersion;
}

final class PubPackageResolveResult {
  const PubPackageResolveResult._({this.package, this.diagnostic});

  factory PubPackageResolveResult.success(ResolvedPubPackage package) {
    return PubPackageResolveResult._(package: package);
  }

  factory PubPackageResolveResult.failure(Diagnostic diagnostic) {
    return PubPackageResolveResult._(diagnostic: diagnostic);
  }

  final ResolvedPubPackage? package;
  final Diagnostic? diagnostic;

  bool get isSuccess => package != null;
}

final class PubResolutionReadResult {
  const PubResolutionReadResult._({this.resolution, this.diagnostic});

  factory PubResolutionReadResult.success(PubResolution resolution) {
    return PubResolutionReadResult._(resolution: resolution);
  }

  factory PubResolutionReadResult.failure(Diagnostic diagnostic) {
    return PubResolutionReadResult._(diagnostic: diagnostic);
  }

  final PubResolution? resolution;
  final Diagnostic? diagnostic;

  bool get isSuccess => resolution != null;
}

final class PubResolutionReader {
  const PubResolutionReader({
    this.workspaceLocator = const PubWorkspaceLocator(),
  });

  final PubWorkspaceLocator workspaceLocator;

  PubResolutionReadResult readFromDirectory(String currentDirectory) {
    final workspaceResult = workspaceLocator.locate(currentDirectory);
    final workspaceDiagnostic = workspaceResult.diagnostic;
    if (workspaceDiagnostic != null) {
      return PubResolutionReadResult.failure(workspaceDiagnostic);
    }

    final workspace = workspaceResult.workspace!;
    final packageConfigResult = _readPackageConfig(workspace);
    final packageConfigDiagnostic = packageConfigResult.diagnostic;
    if (packageConfigDiagnostic != null) {
      return PubResolutionReadResult.failure(packageConfigDiagnostic);
    }

    final metadataResult = _readResolutionMetadata(workspace);
    final metadataDiagnostic = metadataResult.diagnostic;
    if (metadataDiagnostic != null) {
      return PubResolutionReadResult.failure(metadataDiagnostic);
    }

    return PubResolutionReadResult.success(
      PubResolution._(
        workspace: workspace,
        packageConfigPackages: packageConfigResult.packages,
        metadataPackages: metadataResult.packages,
      ),
    );
  }

  _PackageConfigReadResult _readPackageConfig(PubWorkspace workspace) {
    final packageConfigFile = File(workspace.packageConfigPath);

    try {
      final decoded = jsonDecode(packageConfigFile.readAsStringSync());
      if (decoded is! Map<String, Object?>) {
        return _PackageConfigReadResult.failure(
          _malformedPackageConfig(
            workspace,
            'Expected package_config.json to contain a JSON object.',
          ),
        );
      }

      final packages = decoded['packages'];
      if (packages is! List<Object?>) {
        return _PackageConfigReadResult.failure(
          _malformedPackageConfig(
            workspace,
            'Expected package_config.json to contain a packages list.',
          ),
        );
      }

      final entries = <String, _PackageConfigPackage>{};
      for (final package in packages) {
        if (package is! Map<String, Object?>) {
          return _PackageConfigReadResult.failure(
            _malformedPackageConfig(
              workspace,
              'Expected each package_config entry to be an object.',
            ),
          );
        }

        final name = package['name'];
        final rootUri = package['rootUri'];
        final packageUri = package['packageUri'];
        final languageVersion = package['languageVersion'];

        if (name is! String || rootUri is! String || packageUri is! String) {
          return _PackageConfigReadResult.failure(
            _malformedPackageConfig(
              workspace,
              'Expected package_config entries to include name, rootUri, and packageUri.',
            ),
          );
        }

        if (entries.containsKey(name)) {
          return _PackageConfigReadResult.failure(
            Diagnostic(
              code: 'pub.ambiguous_package',
              message:
                  'Package "$name" appears more than once in pub resolution.',
              location: workspace.packageConfigPath,
            ),
          );
        }

        final rootPath = _resolvePackageRootUri(workspace, rootUri);
        if (rootPath == null) {
          return _PackageConfigReadResult.failure(
            _malformedPackageConfig(
              workspace,
              'Could not resolve rootUri "$rootUri" for package "$name".',
            ),
          );
        }

        entries[name] = _PackageConfigPackage(
          rootPath: rootPath,
          packageUri: packageUri,
          languageVersion: languageVersion is String ? languageVersion : null,
        );
      }

      return _PackageConfigReadResult.success(entries);
    } on FormatException catch (error) {
      return _PackageConfigReadResult.failure(
        _malformedPackageConfig(workspace, error.message),
      );
    } on FileSystemException catch (error) {
      return _PackageConfigReadResult.failure(
        Diagnostic(
          code: 'pub.package_config_not_readable',
          message: 'Could not read pub package_config.json.',
          hint: error.message,
          location: workspace.packageConfigPath,
        ),
      );
    }
  }

  _ResolutionMetadataReadResult _readResolutionMetadata(
    PubWorkspace workspace,
  ) {
    final lockfile = File(workspace.lockfilePath);
    final packageGraph = File(workspace.packageGraphPath);

    if (lockfile.existsSync()) {
      final lockfileResult = _readLockfile(workspace, lockfile);
      final lockfileDiagnostic = lockfileResult.diagnostic;
      if (lockfileDiagnostic != null) {
        return _ResolutionMetadataReadResult.failure(lockfileDiagnostic);
      }

      if (!packageGraph.existsSync()) {
        return lockfileResult;
      }

      final packageGraphResult = _readPackageGraph(workspace, packageGraph);
      final packageGraphDiagnostic = packageGraphResult.diagnostic;
      if (packageGraphDiagnostic != null) {
        return _ResolutionMetadataReadResult.failure(packageGraphDiagnostic);
      }

      return _ResolutionMetadataReadResult.success({
        ...packageGraphResult.packages,
        ...lockfileResult.packages,
      });
    }

    if (packageGraph.existsSync()) {
      return _readPackageGraph(workspace, packageGraph);
    }

    return _ResolutionMetadataReadResult.failure(
      Diagnostic(
        code: 'pub.resolution_metadata_not_found',
        message:
            'Could not find pubspec.lock or .dart_tool/package_graph.json.',
        hint: 'Run dart pub get before using patchwork.',
        location: workspace.rootPath,
      ),
    );
  }

  _ResolutionMetadataReadResult _readLockfile(
    PubWorkspace workspace,
    File lockfile,
  ) {
    try {
      final decoded = loadYaml(lockfile.readAsStringSync());
      if (decoded is! YamlMap) {
        return _ResolutionMetadataReadResult.failure(
          _malformedLockfile(
            workspace,
            'Expected pubspec.lock to contain a YAML object.',
          ),
        );
      }

      final packages = decoded['packages'];
      if (packages is! YamlMap) {
        return _ResolutionMetadataReadResult.failure(
          _malformedLockfile(
            workspace,
            'Expected pubspec.lock to contain a packages map.',
          ),
        );
      }

      final entries = <String, _ResolutionMetadataPackage>{};
      for (final entry in packages.entries) {
        final name = entry.key;
        final value = entry.value;

        if (name is! String || value is! YamlMap) {
          return _ResolutionMetadataReadResult.failure(
            _malformedLockfile(
              workspace,
              'Expected each pubspec.lock package entry to be a map.',
            ),
          );
        }

        final version = value['version'];
        if (version == null) {
          return _ResolutionMetadataReadResult.failure(
            _malformedLockfile(
              workspace,
              'Expected package "$name" to include a selected version.',
            ),
          );
        }

        entries[name] = _ResolutionMetadataPackage(
          version: version.toString(),
          sourceKind: _parseSourceKind(value['source']),
          dependencyKind: _parseLockDependencyKind(value['dependency']),
        );
      }

      return _ResolutionMetadataReadResult.success(entries);
    } on YamlException catch (error) {
      return _ResolutionMetadataReadResult.failure(
        _malformedLockfile(workspace, error.message),
      );
    } on FileSystemException catch (error) {
      return _ResolutionMetadataReadResult.failure(
        Diagnostic(
          code: 'pub.lockfile_not_readable',
          message: 'Could not read pubspec.lock.',
          hint: error.message,
          location: workspace.lockfilePath,
        ),
      );
    }
  }

  _ResolutionMetadataReadResult _readPackageGraph(
    PubWorkspace workspace,
    File packageGraph,
  ) {
    try {
      final decoded = jsonDecode(packageGraph.readAsStringSync());
      if (decoded is! Map<String, Object?>) {
        return _ResolutionMetadataReadResult.failure(
          _malformedPackageGraph(
            workspace,
            'Expected package_graph.json to contain a JSON object.',
          ),
        );
      }

      final roots = decoded['roots'];
      final packages = decoded['packages'];
      if (roots is! List<Object?> || packages is! List<Object?>) {
        return _ResolutionMetadataReadResult.failure(
          _malformedPackageGraph(
            workspace,
            'Expected package_graph.json to contain roots and packages lists.',
          ),
        );
      }

      final rootNames = roots.whereType<String>().toSet();
      final rootMainDependencies = <String>{};
      final rootDevDependencies = <String>{};
      final packageObjects = <Map<String, Object?>>[];

      for (final package in packages) {
        if (package is! Map<String, Object?>) {
          return _ResolutionMetadataReadResult.failure(
            _malformedPackageGraph(
              workspace,
              'Expected each package_graph package entry to be an object.',
            ),
          );
        }

        packageObjects.add(package);

        final name = package['name'];
        if (name is String && rootNames.contains(name)) {
          rootMainDependencies.addAll(_stringList(package['dependencies']));
          rootDevDependencies.addAll(_stringList(package['devDependencies']));
        }
      }

      final entries = <String, _ResolutionMetadataPackage>{};
      for (final package in packageObjects) {
        final name = package['name'];
        final version = package['version'];

        if (name is! String || version == null) {
          return _ResolutionMetadataReadResult.failure(
            _malformedPackageGraph(
              workspace,
              'Expected package_graph packages to include name and version.',
            ),
          );
        }

        entries[name] = _ResolutionMetadataPackage(
          version: version.toString(),
          sourceKind: rootNames.contains(name)
              ? PubPackageSourceKind.root
              : PubPackageSourceKind.unknown,
          dependencyKind: _parseGraphDependencyKind(
            name,
            rootNames,
            rootMainDependencies,
            rootDevDependencies,
          ),
        );
      }

      return _ResolutionMetadataReadResult.success(entries);
    } on FormatException catch (error) {
      return _ResolutionMetadataReadResult.failure(
        _malformedPackageGraph(workspace, error.message),
      );
    } on FileSystemException catch (error) {
      return _ResolutionMetadataReadResult.failure(
        Diagnostic(
          code: 'pub.package_graph_not_readable',
          message: 'Could not read .dart_tool/package_graph.json.',
          hint: error.message,
          location: workspace.packageGraphPath,
        ),
      );
    }
  }

  Diagnostic _malformedPackageConfig(PubWorkspace workspace, String message) {
    return Diagnostic(
      code: 'pub.malformed_package_config',
      message: 'Malformed pub package_config.json: $message',
      location: workspace.packageConfigPath,
    );
  }

  Diagnostic _malformedLockfile(PubWorkspace workspace, String message) {
    return Diagnostic(
      code: 'pub.malformed_lockfile',
      message: 'Malformed pubspec.lock: $message',
      location: workspace.lockfilePath,
    );
  }

  Diagnostic _malformedPackageGraph(PubWorkspace workspace, String message) {
    return Diagnostic(
      code: 'pub.malformed_package_graph',
      message: 'Malformed .dart_tool/package_graph.json: $message',
      location: workspace.packageGraphPath,
    );
  }

  String? _resolvePackageRootUri(PubWorkspace workspace, String rootUri) {
    try {
      final uri = Uri.parse(rootUri);
      if (uri.scheme == 'file') {
        return p.normalize(uri.toFilePath());
      }

      if (uri.hasScheme) {
        return null;
      }

      final baseUri = Directory(p.dirname(workspace.packageConfigPath)).uri;
      return p.normalize(baseUri.resolveUri(uri).toFilePath());
    } on FormatException {
      return null;
    } on UnsupportedError {
      return null;
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

  PubPackageDependencyKind _parseGraphDependencyKind(
    String name,
    Set<String> rootNames,
    Set<String> rootMainDependencies,
    Set<String> rootDevDependencies,
  ) {
    if (rootNames.contains(name)) {
      return PubPackageDependencyKind.root;
    }

    if (rootMainDependencies.contains(name)) {
      return PubPackageDependencyKind.directMain;
    }

    if (rootDevDependencies.contains(name)) {
      return PubPackageDependencyKind.directDev;
    }

    return PubPackageDependencyKind.transitive;
  }

  Iterable<String> _stringList(Object? value) {
    if (value is! List<Object?>) {
      return const [];
    }

    return value.whereType<String>();
  }
}

final class PubResolution {
  const PubResolution._({
    required this.workspace,
    required Map<String, _PackageConfigPackage> packageConfigPackages,
    required Map<String, _ResolutionMetadataPackage> metadataPackages,
  }) : _packageConfigPackages = packageConfigPackages,
       _metadataPackages = metadataPackages;

  final PubWorkspace workspace;
  final Map<String, _PackageConfigPackage> _packageConfigPackages;
  final Map<String, _ResolutionMetadataPackage> _metadataPackages;

  PubPackageResolveResult resolve(PubTarget target) {
    final packageConfig = _packageConfigPackages[target.name];
    if (packageConfig == null) {
      return PubPackageResolveResult.failure(
        Diagnostic(
          code: 'pub.package_not_found',
          message:
              'Package "${target.name}" is not selected by the current pub resolution.',
          hint: 'Run dart pub get and check that the package is a dependency.',
        ),
      );
    }

    final metadata = _metadataPackages[target.name];
    if (metadata == null) {
      return PubPackageResolveResult.failure(
        Diagnostic(
          code: 'pub.package_version_not_found',
          message: 'Package "${target.name}" has no selected version metadata.',
          hint: 'Run dart pub get to refresh pub resolution metadata.',
        ),
      );
    }

    final requestedVersion = target.versionConstraint;
    if (requestedVersion != null) {
      final selectedVersionResult = _parseSelectedVersion(metadata.version);
      final selectedVersionDiagnostic = selectedVersionResult.diagnostic;
      if (selectedVersionDiagnostic != null) {
        return PubPackageResolveResult.failure(selectedVersionDiagnostic);
      }

      final requestedConstraintResult = _parseRequestedVersionConstraint(
        target.name,
        requestedVersion,
      );
      final requestedConstraintDiagnostic =
          requestedConstraintResult.diagnostic;
      if (requestedConstraintDiagnostic != null) {
        return PubPackageResolveResult.failure(requestedConstraintDiagnostic);
      }

      if (!requestedConstraintResult.constraint!.allows(
        selectedVersionResult.version!,
      )) {
        return PubPackageResolveResult.failure(
          Diagnostic(
            code: 'pub.version_not_selected',
            message:
                'Package "${target.name}" is selected at ${metadata.version}, which does not satisfy $requestedVersion.',
            hint:
                'Use ${target.name}@${metadata.version} or update pub resolution.',
          ),
        );
      }
    }

    if (!Directory(packageConfig.rootPath).existsSync()) {
      return PubPackageResolveResult.failure(
        Diagnostic(
          code: 'pub.package_root_missing',
          message: 'Resolved package root does not exist for "${target.name}".',
          hint: 'Run dart pub get to refresh pub resolution metadata.',
          location: packageConfig.rootPath,
        ),
      );
    }

    return PubPackageResolveResult.success(
      ResolvedPubPackage(
        name: target.name,
        version: metadata.version,
        sourceKind: metadata.sourceKind,
        dependencyKind: metadata.dependencyKind,
        rootPath: packageConfig.rootPath,
        packageUri: packageConfig.packageUri,
        languageVersion: packageConfig.languageVersion,
      ),
    );
  }

  _SelectedVersionParseResult _parseSelectedVersion(String selectedVersion) {
    try {
      return _SelectedVersionParseResult.success(
        Version.parse(selectedVersion),
      );
    } on FormatException catch (error) {
      return _SelectedVersionParseResult.failure(
        Diagnostic(
          code: 'pub.invalid_selected_version',
          message: 'Selected package version "$selectedVersion" is invalid.',
          hint: error.message,
        ),
      );
    }
  }

  _VersionConstraintParseResult _parseRequestedVersionConstraint(
    String packageName,
    String requestedVersion,
  ) {
    try {
      return _VersionConstraintParseResult.success(
        VersionConstraint.parse(requestedVersion),
      );
    } on FormatException catch (error) {
      return _VersionConstraintParseResult.failure(
        Diagnostic(
          code: 'pub.invalid_version_constraint',
          message:
              'Requested version constraint "$requestedVersion" for "$packageName" is invalid.',
          hint: error.message,
        ),
      );
    }
  }
}

final class _SelectedVersionParseResult {
  const _SelectedVersionParseResult._({this.version, this.diagnostic});

  factory _SelectedVersionParseResult.success(Version version) {
    return _SelectedVersionParseResult._(version: version);
  }

  factory _SelectedVersionParseResult.failure(Diagnostic diagnostic) {
    return _SelectedVersionParseResult._(diagnostic: diagnostic);
  }

  final Version? version;
  final Diagnostic? diagnostic;
}

final class _VersionConstraintParseResult {
  const _VersionConstraintParseResult._({this.constraint, this.diagnostic});

  factory _VersionConstraintParseResult.success(VersionConstraint constraint) {
    return _VersionConstraintParseResult._(constraint: constraint);
  }

  factory _VersionConstraintParseResult.failure(Diagnostic diagnostic) {
    return _VersionConstraintParseResult._(diagnostic: diagnostic);
  }

  final VersionConstraint? constraint;
  final Diagnostic? diagnostic;
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
  });

  final String version;
  final PubPackageSourceKind sourceKind;
  final PubPackageDependencyKind dependencyKind;
}

final class _PackageConfigReadResult {
  const _PackageConfigReadResult._({required this.packages, this.diagnostic});

  factory _PackageConfigReadResult.success(
    Map<String, _PackageConfigPackage> packages,
  ) {
    return _PackageConfigReadResult._(packages: packages);
  }

  factory _PackageConfigReadResult.failure(Diagnostic diagnostic) {
    return _PackageConfigReadResult._(
      packages: const {},
      diagnostic: diagnostic,
    );
  }

  final Map<String, _PackageConfigPackage> packages;
  final Diagnostic? diagnostic;
}

final class _ResolutionMetadataReadResult {
  const _ResolutionMetadataReadResult._({
    required this.packages,
    this.diagnostic,
  });

  factory _ResolutionMetadataReadResult.success(
    Map<String, _ResolutionMetadataPackage> packages,
  ) {
    return _ResolutionMetadataReadResult._(packages: packages);
  }

  factory _ResolutionMetadataReadResult.failure(Diagnostic diagnostic) {
    return _ResolutionMetadataReadResult._(
      packages: const {},
      diagnostic: diagnostic,
    );
  }

  final Map<String, _ResolutionMetadataPackage> packages;
  final Diagnostic? diagnostic;
}
