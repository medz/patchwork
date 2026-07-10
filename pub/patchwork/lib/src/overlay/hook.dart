import 'dart:io';
import 'dart:isolate';

import 'package:hooks/hooks.dart';
import 'package:path/path.dart' as p;

import '../error.dart';
import '../hooks/errors.dart';
import 'composer.dart';
import 'discovery.dart';
import 'model.dart';
import '../state/path_layout.dart';
import 'pub_resolution.dart';
import 'package_config_activation.dart';
import '../pub/resolution_reader.dart';
import 'resolver.dart';

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
  return wrapPatchworkHookErrors(
    () => _applyPackageOverlaysFromPackageConfig(packageConfigPath, output),
  );
}

void _applyPackageOverlaysFromPackageConfig(
  String packageConfigPath,
  BuildOutputBuilder output,
) {
  final rootPath = p.dirname(p.dirname(packageConfigPath));
  final layout = PathLayout(rootPath);
  final graph = PackageGraph.read(p.join(rootPath, '.dart_tool'));
  final currentPackageConfig = PackageConfigFile.read(packageConfigPath);
  final packageConfigActivation = OverlayPackageConfigActivation(
    packageConfigPath: packageConfigPath,
    layout: layout,
  );
  _declareBaseDependencies(
    output,
    rootPath: rootPath,
    basePackageConfigPath: packageConfigActivation.basePath,
  );

  final catalog = const OverlayManifestDiscovery().discover(
    currentPackageConfig,
    graph,
    onCandidate: (manifestFile, packageRootPath) {
      _declareOverlayManifestDependency(
        output,
        manifestFile: manifestFile,
        packageRootPath: packageRootPath,
      );
    },
  );
  if (!catalog.hasDeclarations) {
    if (currentPackageConfig.hasGeneratedPatchworkRoots(
          layout.appliedRootPath,
        ) &&
        packageConfigActivation.hasBase) {
      packageConfigActivation.restore(currentPackageConfig);
    }
    return;
  }

  final basePackageConfig = packageConfigActivation.restore(
    currentPackageConfig,
  );
  final resolution = const PubResolutionReader().readFromDirectory(rootPath);
  final resolved = OverlayResolver(
    layout: layout,
  ).resolve(catalog: catalog, graph: graph, resolution: resolution);
  _rejectFailedEntries(resolved);
  output.dependencies.addAll({
    for (final target in resolved.targets)
      for (final contribution in target.contributions)
        File(contribution.patchPath).absolute.uri,
  });

  if (resolved.targets.isEmpty) {
    return;
  }
  _rejectOpenEdits(resolved.targets, layout);

  for (final target in resolved.targets) {
    const OverlayComposer().compose(target, layout: layout);
  }
  packageConfigActivation.activate(basePackageConfig, resolved.targets);
}

void _rejectFailedEntries(ResolvedOverlays resolved) {
  for (final provider in resolved.providers) {
    for (final entry in provider.entries) {
      if (entry.status != OverlayEntryStatus.failed) {
        continue;
      }
      switch (entry.skipReason) {
        case 'overlay.provider_not_dependency':
          throw PatchworkException(
            'Package "${provider.package}" declares an overlay for "${entry.package}" but does not depend on it.',
            code: 'overlay.provider_not_dependency',
            location: provider.manifestPath,
          );
        case 'overlay.patch_file_missing':
          throw PatchworkException(
            'Overlay patch file does not exist.',
            code: 'overlay.patch_file_missing',
            location: entry.patchPath,
          );
        default:
          throw PatchworkException(
            'Could not resolve package-provided overlay.',
            code: entry.skipReason ?? 'overlay.invalid',
            location: provider.manifestPath,
          );
      }
    }
  }
}

void _rejectOpenEdits(Iterable<OverlayComposition> groups, PathLayout layout) {
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

void _declareBaseDependencies(
  BuildOutputBuilder output, {
  required String rootPath,
  required String basePackageConfigPath,
}) {
  final files = {
    p.join(rootPath, '.dart_tool', 'package_graph.json'),
    p.join(rootPath, 'pubspec.lock'),
    p.join(rootPath, 'pubspec.yaml'),
  };
  output.dependencies.addAll(files.map((path) => File(path).absolute.uri));
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
