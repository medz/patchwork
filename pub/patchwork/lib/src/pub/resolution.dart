import 'dart:io';

import 'package:path/path.dart' as p;

import '../error.dart';
import '../patch/package_tree.dart';
import 'source.dart';
import 'workspace.dart';

/// Source kinds read from pub's `pubspec.lock`.
enum PubPackageSourceKind {
  /// A hosted pub package.
  hosted,

  /// A local path dependency.
  path,

  /// A Git dependency.
  git,

  /// A Dart or Flutter SDK package.
  sdk,

  /// A source kind Patchwork does not understand.
  unknown,
}

/// A dependency selected by the current pub resolution.
final class ResolvedPubPackage {
  /// Creates resolved dependency metadata.
  ResolvedPubPackage({
    required this.version,
    required this.rootPath,
    required PackageSource Function() source,
  }) : _readSource = source;

  /// The concrete package version selected by pub.
  final String version;

  /// The package root path selected by pub.
  final String rootPath;

  final PackageSource Function() _readSource;
  PackageSource? _source;

  /// The source identity and content hash Patchwork will lock against.
  ///
  /// The package tree is fingerprinted only when a caller needs source identity.
  PackageSource get source => _source ??= _readSource();
}

/// Version and source fields read from one lockfile entry.
final class PubPackageMetadata {
  /// Creates package metadata from a parsed lockfile entry.
  PubPackageMetadata({
    required this.version,
    required this.sourceKind,
    required Map<String, String> description,
  }) : description = Map.unmodifiable(description);

  /// The selected package version.
  final String version;

  /// The package source kind.
  final PubPackageSourceKind sourceKind;

  /// Source-specific lockfile fields.
  final Map<String, String> description;
}

/// Provides patch-oriented lookup over an active pub resolution.
final class PubResolution {
  /// Creates a resolution from already parsed pub metadata.
  PubResolution({
    required this.workspace,
    required Map<String, String> packageRoots,
    required Map<String, PubPackageMetadata> metadata,
    required Set<String> rootNames,
    required Set<String> directDependencies,
    required this.packageTree,
  }) : _packageRoots = Map.unmodifiable(packageRoots),
       _metadata = Map.unmodifiable(metadata),
       _rootNames = Set.unmodifiable(rootNames),
       _directDependencies = Set.unmodifiable(directDependencies);

  /// The package or workspace that owns the active pub resolution files.
  final PubWorkspace workspace;

  final Map<String, String> _packageRoots;
  final Map<String, PubPackageMetadata> _metadata;
  final Set<String> _rootNames;
  final Set<String> _directDependencies;
  final Map<String, ResolvedPubPackage> _resolvedPackages = {};

  /// Computes content hashes used in returned [PackageSource] values.
  final PackageTree packageTree;

  /// Resolves [packageName] to a patchable dependency source.
  ResolvedPubPackage resolvePackage(
    String packageName, {
    bool requireDirectDependency = true,
  }) {
    final packageRoot = _packageRoots[packageName];
    if (packageRoot == null) {
      throw PatchworkException(
        'Package "$packageName" is not selected by the current pub resolution.',
        code: 'pub.package_not_found',
        hint: 'Run dart pub get and check that the package is a dependency.',
      );
    }

    if (_rootNames.contains(packageName) || _isWorkspaceRootPath(packageRoot)) {
      throw PatchworkException(
        'Package "$packageName" is a workspace/root package and cannot be patched.',
        code: 'pub.package_is_project',
        hint:
            'patchwork patch only accepts dependencies of the current project.',
      );
    }

    final metadata = _metadata[packageName];
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

    if (!Directory(packageRoot).existsSync()) {
      throw PatchworkException(
        'Resolved package root does not exist for "$packageName".',
        code: 'pub.package_root_missing',
        hint: 'Run dart pub get to refresh pub resolution metadata.',
        location: packageRoot,
      );
    }

    return _resolvedPackages.putIfAbsent(
      packageName,
      () => ResolvedPubPackage(
        version: metadata.version,
        rootPath: packageRoot,
        source: () => _sourceFor(metadata, packageRoot),
      ),
    );
  }

  bool _isWorkspaceRootPath(String packagePath) {
    return workspace.rootPackageRootPaths.any(
      (rootPath) => p.equals(rootPath, packagePath),
    );
  }

  PackageSource _sourceFor(PubPackageMetadata metadata, String rootPath) {
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
        if (url != null) fields['url'] = url;
        if (ref != null) fields['branch'] = ref;
        if (commit != null) fields['commit'] = commit;
        if (path != null && path != '.') fields['path'] = path;
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
