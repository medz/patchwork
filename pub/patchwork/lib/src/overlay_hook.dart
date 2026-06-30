import 'dart:convert';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';

import 'package:hooks/hooks.dart';
import 'package:path/path.dart' as p;

import 'error.dart';
import 'internal/artifact_identity.dart';
import 'internal/hashing.dart';
import 'internal/package_tree.dart';
import 'internal/path_layout.dart';
import 'internal/pub_resolution_files.dart';
import 'io/atomic_file_writer.dart';
import 'overlay_manifest.dart';
import 'patch_file.dart';
import 'pub/package_resolution.dart';

/// Applies package-provided overlays from Patchwork's own build hook.
Future<void> applyPackageOverlays(
  BuildInput _,
  BuildOutputBuilder output,
) async {
  final packageConfigUri = await Isolate.packageConfig;
  if (packageConfigUri == null || !packageConfigUri.isScheme('file')) {
    return;
  }

  await applyPackageOverlaysFromPackageConfig(
    packageConfigUri.toFilePath(),
    output,
  );
}

/// Applies package-provided overlays for an explicit pub package config file.
///
/// This is the same implementation used by [applyPackageOverlays], with the
/// package config lookup supplied by callers that already know the state root.
Future<void> applyPackageOverlaysFromPackageConfig(
  String packageConfigPath,
  BuildOutputBuilder output,
) {
  return _wrapPatchworkErrors(
    () => _applyPackageOverlaysFromPackageConfig(packageConfigPath, output),
  );
}

Future<void> _applyPackageOverlaysFromPackageConfig(
  String packageConfigPath,
  BuildOutputBuilder output,
) async {
  final rootPath = p.dirname(p.dirname(packageConfigPath));
  final layout = PathLayout(rootPath);
  final graph = PackageGraph.read(p.join(rootPath, '.dart_tool'));
  final currentPackageConfig = PackageConfigFile.read(packageConfigPath);
  _declareBaseDependencies(output, rootPath: rootPath, layout: layout);

  final manifests = _readOverlayManifests(
    currentPackageConfig,
    graph: graph,
    output: output,
  );
  if (!manifests.any((manifest) => manifest.manifest.overlays.isNotEmpty)) {
    if (currentPackageConfig.hasGeneratedPatchworkRoots(
          layout.appliedRootPath,
        ) &&
        _hasBasePackageConfig(layout)) {
      _restoreBasePackageConfig(
        currentPackageConfig,
        packageConfigPath: packageConfigPath,
        layout: layout,
      );
    }
    return;
  }

  final basePackageConfig = _restoreBasePackageConfig(
    currentPackageConfig,
    packageConfigPath: packageConfigPath,
    layout: layout,
  );
  final resolution = const PubResolutionReader().readFromDirectory(rootPath);
  final groups = _collectOverlayGroups(
    manifests,
    graph: graph,
    resolution: resolution,
    output: output,
  );
  _appendRootPatches(
    groups,
    layout: layout,
    resolution: resolution,
    output: output,
  );

  if (groups.isEmpty) {
    return;
  }
  _rejectOpenEdits(groups.values, layout);

  for (final group in groups.values) {
    _composeOverlayGroup(group, layout: layout);
  }
  _writeOverlayPackageConfig(
    basePackageConfig,
    packageConfigPath: packageConfigPath,
    groups: groups.values,
  );
}

List<_PackageManifest> _readOverlayManifests(
  PackageConfigFile packageConfig, {
  required PackageGraph graph,
  required BuildOutputBuilder output,
}) {
  final manifests = <_PackageManifest>[];
  for (final package in packageConfig.packages) {
    if (package.name == 'patchwork' ||
        !graph.hasIncomingDependency(package.name)) {
      continue;
    }
    final manifestPath = p.join(package.rootPath, 'patchwork.yaml');
    final manifestFile = File(manifestPath);
    _declareOverlayManifestDependency(
      output,
      manifestFile: manifestFile,
      packageRootPath: package.rootPath,
    );
    if (!manifestFile.existsSync()) {
      continue;
    }
    manifests.add(
      _PackageManifest(
        packageName: package.name,
        packageRootPath: package.rootPath,
        manifestPath: manifestPath,
        manifest: OverlayManifestStore(path: manifestPath).read(),
      ),
    );
  }
  manifests.sort(
    (left, right) => left.packageName.compareTo(right.packageName),
  );
  return manifests;
}

SplayTreeMap<String, _OverlayGroup> _collectOverlayGroups(
  List<_PackageManifest> manifests, {
  required PackageGraph graph,
  required PubResolution resolution,
  required BuildOutputBuilder output,
}) {
  final groups = SplayTreeMap<String, _OverlayGroup>();
  for (final manifest in manifests) {
    final provider = graph.packages[manifest.packageName];
    if (provider == null) {
      continue;
    }
    for (final entry in manifest.manifest.overlays) {
      if (!provider.dependencies.contains(entry.package)) {
        throw PatchworkException(
          'Package "${manifest.packageName}" declares an overlay for "${entry.package}" but does not depend on it.',
          code: 'overlay.provider_not_dependency',
          location: manifest.manifestPath,
        );
      }

      final resolved = _resolveOverlayTarget(resolution, entry.package);
      if (resolved == null ||
          resolved.version != entry.version ||
          resolved.source.sha256 != entry.sha256) {
        continue;
      }

      final patchPath = _resolveManifestPatchPath(manifest, entry.patch);
      output.dependencies.add(File(patchPath).absolute.uri);
      final group = groups.putIfAbsent(
        entry.package,
        () => _OverlayGroup(
          package: entry.package,
          version: resolved.version,
          sourceSha256: resolved.source.sha256,
          sourcePath: resolved.rootPath,
        ),
      );
      group.contributions.add(
        _OverlayContribution(
          provider: manifest.packageName,
          patchPath: patchPath,
        ),
      );
    }
  }

  for (final group in groups.values) {
    group.contributions.sort((left, right) {
      final providerCompare = left.provider.compareTo(right.provider);
      if (providerCompare != 0) {
        return providerCompare;
      }
      return left.patchPath.compareTo(right.patchPath);
    });
    _deduplicateOverlayGroupContributions(group);
  }
  return groups;
}

void _deduplicateOverlayGroupContributions(_OverlayGroup group) {
  final seen = <String>{};
  group.contributions.removeWhere((contribution) {
    final file = File(contribution.patchPath);
    return !seen.add(sha256Hex(file.readAsBytesSync()));
  });
}

ResolvedPubPackage? _resolveOverlayTarget(
  PubResolution resolution,
  String package,
) {
  try {
    return resolution.resolvePackage(package, requireDirectDependency: false);
  } on PatchworkException catch (error) {
    if (error.code == 'pub.package_not_found') {
      return null;
    }
    rethrow;
  }
}

String _resolveManifestPatchPath(_PackageManifest manifest, String patchPath) {
  if (p.isAbsolute(patchPath)) {
    throw PatchworkException(
      'Overlay patch paths must be relative to the declaring package.',
      code: 'overlay.absolute_patch_path',
      location: manifest.manifestPath,
    );
  }
  final absolutePath = p.normalize(p.join(manifest.packageRootPath, patchPath));
  final rootPath = p.normalize(p.absolute(manifest.packageRootPath));
  if (!p.isWithin(rootPath, absolutePath)) {
    throw PatchworkException(
      'Overlay patch paths must stay inside the declaring package.',
      code: 'overlay.patch_path_escapes_package',
      location: manifest.manifestPath,
    );
  }
  if (!File(absolutePath).existsSync()) {
    throw PatchworkException(
      'Overlay patch file does not exist.',
      code: 'overlay.patch_file_missing',
      location: absolutePath,
    );
  }
  return absolutePath;
}

void _appendRootPatches(
  SplayTreeMap<String, _OverlayGroup> groups, {
  required PathLayout layout,
  required PubResolution resolution,
  required BuildOutputBuilder output,
}) {
  for (final group in groups.values) {
    final resolved = _resolveOverlayTarget(resolution, group.package);
    if (resolved == null ||
        resolved.version != group.version ||
        resolved.source.sha256 != group.sourceSha256) {
      continue;
    }

    final patchPath = layout.patchPath(group.package, group.version);
    final patchFile = File(patchPath);
    if (!patchFile.existsSync()) {
      continue;
    }
    final patchSha256 = sha256Hex(patchFile.readAsBytesSync());
    output.dependencies.add(patchFile.absolute.uri);
    if (_hasContributionPatchSha(group, patchSha256)) {
      continue;
    }
    group.contributions.add(
      _OverlayContribution(provider: '<root>', patchPath: patchPath),
    );
  }
}

bool _hasContributionPatchSha(_OverlayGroup group, String sha256) {
  for (final contribution in group.contributions) {
    final file = File(contribution.patchPath);
    if (file.existsSync() && sha256Hex(file.readAsBytesSync()) == sha256) {
      return true;
    }
  }
  return false;
}

void _rejectOpenEdits(Iterable<_OverlayGroup> groups, PathLayout layout) {
  final targets = {for (final group in groups) group.package};
  for (final edit in layout.editDirectories()) {
    if (!targets.contains(edit.package)) {
      continue;
    }
    throw PatchworkException(
      'Package "${edit.package}" has an open edit directory.',
      code: 'overlay.open_edit',
      hint: 'Run patchwork commit ${edit.package} before composing overlays.',
      location: edit.path,
    );
  }
}

void _composeOverlayGroup(_OverlayGroup group, {required PathLayout layout}) {
  final outputPath = layout.appliedPath(group.package, group.version);
  final identity = packageVersionName(group.package, group.version);
  final tempPath = p.join(
    layout.appliedRootPath,
    '.$identity.$pid.${DateTime.now().microsecondsSinceEpoch}',
  );
  const packageTree = PackageTree();
  const patchFile = PatchFile();
  packageTree.deleteDirectory(tempPath);
  Directory(tempPath).createSync(recursive: true);
  try {
    packageTree.copy(group.sourcePath, tempPath);
    for (final contribution in group.contributions) {
      try {
        patchFile.apply(
          packagePath: tempPath,
          patchContent: File(contribution.patchPath).readAsStringSync(),
        );
      } on PatchworkException catch (error) {
        throw PatchworkException(
          'Could not compose overlays for "$identity".',
          code: 'overlay.apply_failed',
          hint:
              'Failed patch from ${contribution.provider}: ${contribution.patchPath}\n${error.message}',
          location: contribution.patchPath,
        );
      }
    }
    packageTree.deleteDirectory(outputPath);
    Directory(p.dirname(outputPath)).createSync(recursive: true);
    Directory(tempPath).renameSync(outputPath);
  } catch (_) {
    packageTree.deleteDirectory(tempPath);
    rethrow;
  }
}

void _writeOverlayPackageConfig(
  PackageConfigFile basePackageConfig, {
  required String packageConfigPath,
  required Iterable<_OverlayGroup> groups,
}) {
  final outputByPackage = {
    for (final group in groups)
      group.package: p.posix.join(
        'patchwork',
        packageVersionName(group.package, group.version),
      ),
  };
  final json = basePackageConfig.deepCopyJson();
  final packages = json['packages'];
  if (packages is! List<Object?>) {
    throw PatchworkException(
      'Malformed pub package_config.json: Expected packages to be a list.',
      code: 'pub.malformed_package_config',
      location: packageConfigPath,
    );
  }
  for (final package in packages) {
    if (package is! Map<String, Object?>) {
      continue;
    }
    final name = package['name'];
    if (name is String && outputByPackage.containsKey(name)) {
      package['rootUri'] = outputByPackage[name];
    }
  }
  writeStringFileAtomically(packageConfigPath, '${jsonEncode(json)}\n');
}

PackageConfigFile _restoreBasePackageConfig(
  PackageConfigFile currentPackageConfig, {
  required String packageConfigPath,
  required PathLayout layout,
}) {
  final sidecarPath = _basePackageConfigPath(layout);
  final sidecar = File(sidecarPath);
  if (currentPackageConfig.hasGeneratedPatchworkRoots(layout.appliedRootPath)) {
    if (!sidecar.existsSync()) {
      return currentPackageConfig;
    }
    final content = sidecar.readAsStringSync();
    final base = PackageConfigFile.fromContent(
      path: packageConfigPath,
      content: content,
    );
    writeStringFileAtomically(packageConfigPath, content);
    return base;
  }

  Directory(p.dirname(sidecarPath)).createSync(recursive: true);
  writeStringFileAtomically(sidecarPath, currentPackageConfig.content);
  return currentPackageConfig;
}

bool _hasBasePackageConfig(PathLayout layout) {
  return File(_basePackageConfigPath(layout)).existsSync();
}

String _basePackageConfigPath(PathLayout layout) {
  return p.join(layout.appliedRootPath, 'package_config.base.json');
}

void _declareBaseDependencies(
  BuildOutputBuilder output, {
  required String rootPath,
  required PathLayout layout,
}) {
  final files = {
    p.join(rootPath, '.dart_tool', 'package_graph.json'),
    p.join(rootPath, 'pubspec.lock'),
    p.join(rootPath, 'pubspec.yaml'),
  };
  output.dependencies.addAll(files.map((path) => File(path).absolute.uri));
  final basePackageConfigPath = _basePackageConfigPath(layout);
  _declareExistingFileDependency(output, basePackageConfigPath);
}

void _declareOverlayManifestDependency(
  BuildOutputBuilder output, {
  required File manifestFile,
  required String packageRootPath,
}) {
  if (manifestFile.existsSync()) {
    output.dependencies.add(manifestFile.absolute.uri);
    return;
  }

  // Missing file dependencies make the hooks runner rerun immediately. Watch the
  // package root instead so a newly-created patchwork.yaml still invalidates.
  output.dependencies.add(Directory(packageRootPath).absolute.uri);
}

void _declareExistingFileDependency(BuildOutputBuilder output, String path) {
  final file = File(path);
  if (file.existsSync()) {
    output.dependencies.add(file.absolute.uri);
  }
}

Future<T> _wrapPatchworkErrors<T>(Future<T> Function() run) async {
  try {
    return await run();
  } on HookError {
    rethrow;
  } on PatchworkException catch (error, stackTrace) {
    throw BuildError(
      message: _formatPatchworkException(error),
      wrappedException: error,
      wrappedTrace: stackTrace,
    );
  }
}

String _formatPatchworkException(PatchworkException error) {
  final lines = [
    '${error.code}: ${error.message}',
    if (error.hint != null && error.hint!.isNotEmpty) error.hint!,
    if (error.location != null && error.location!.isNotEmpty) error.location!,
  ];
  return lines.join('\n');
}

final class _PackageManifest {
  const _PackageManifest({
    required this.packageName,
    required this.packageRootPath,
    required this.manifestPath,
    required this.manifest,
  });

  final String packageName;
  final String packageRootPath;
  final String manifestPath;
  final OverlayManifest manifest;
}

final class _OverlayGroup {
  _OverlayGroup({
    required this.package,
    required this.version,
    required this.sourceSha256,
    required this.sourcePath,
  });

  final String package;
  final String version;
  final String sourceSha256;
  final String sourcePath;
  final List<_OverlayContribution> contributions = [];
}

final class _OverlayContribution {
  const _OverlayContribution({required this.provider, required this.patchPath});

  final String provider;
  final String patchPath;
}
