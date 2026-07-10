import 'dart:io';

import 'package:path/path.dart' as p;

import '../error.dart';
import '../patch/file.dart';
import '../patch/package_tree.dart';
import '../pub/resolution_reader.dart';
import '../state/path_layout.dart';
import 'composer.dart';
import 'discovery.dart';
import 'model.dart';
import 'pub_resolution.dart';
import 'resolver.dart';

/// Inspects package-provided overlays without mutating pub resolution files.
final class OverlayInspector {
  /// Creates an overlay inspector for one Patchwork state root.
  const OverlayInspector({
    required this.rootPath,
    required this.layout,
    this.pubResolutionReader = const PubResolutionReader(),
    this.packageTree = const PackageTree(),
    this.patchFile = const PatchFile(),
  });

  /// The pub resolution root being inspected.
  final String rootPath;

  /// Patchwork paths for the inspected project.
  final PathLayout layout;

  /// Reads pub resolution metadata.
  final PubResolutionReader pubResolutionReader;

  /// Copies package trees for temporary composition checks.
  final PackageTree packageTree;

  /// Applies patch files inside temporary composition checks.
  final PatchFile patchFile;

  /// Returns a read-only overlay discovery and composition report.
  OverlayInspection inspect() {
    final packageConfigPath = p.join(
      rootPath,
      '.dart_tool',
      'package_config.json',
    );
    final packageConfig = _basePackageConfig(
      PackageConfigFile.read(packageConfigPath),
      packageConfigPath: packageConfigPath,
    );
    final graph = PackageGraph.read(p.join(rootPath, '.dart_tool'));
    final resolution = pubResolutionReader.readFromDirectory(
      rootPath,
      packageConfigContent: packageConfig.content,
    );
    final catalog = const OverlayManifestDiscovery().discover(
      packageConfig,
      graph,
    );
    final resolved = OverlayResolver(
      layout: layout,
    ).resolve(catalog: catalog, graph: graph, resolution: resolution);

    return OverlayInspection(
      providers: resolved.providers,
      targets: List.unmodifiable([
        for (final target in resolved.targets) _targetInspection(target),
      ]),
    );
  }

  PackageConfigFile _basePackageConfig(
    PackageConfigFile current, {
    required String packageConfigPath,
  }) {
    if (!current.hasGeneratedPatchworkRoots(layout.appliedRootPath)) {
      return current;
    }

    final baseFile = File(
      p.join(layout.appliedRootPath, 'package_config.base.json'),
    );
    if (!baseFile.existsSync()) {
      return current;
    }
    return PackageConfigFile.fromContent(
      path: packageConfigPath,
      content: baseFile.readAsStringSync(),
    );
  }

  OverlayTargetInspection _targetInspection(OverlayComposition target) {
    return OverlayTargetInspection(
      package: target.package,
      version: target.version,
      sha256: target.sourceSha256,
      sourcePath: target.sourcePath,
      contributions: List.unmodifiable([
        for (final contribution in target.contributions)
          OverlayContributionInspection(
            provider: contribution.provider,
            patchPath: contribution.patchPath,
            sha256: contribution.patchSha256,
            status: contribution.deduplicated
                ? OverlayContributionStatus.deduplicated
                : OverlayContributionStatus.active,
          ),
      ]),
      conflict: _inspectConflict(target),
    );
  }

  OverlayConflictInspection? _inspectConflict(OverlayComposition target) {
    final active = target.contributions.where(
      (contribution) => !contribution.deduplicated,
    );
    if (active.isEmpty) {
      return null;
    }

    final tempRoot = Directory.systemTemp.createTempSync(
      'patchwork_overlay_inspect_',
    );
    try {
      final packagePath = p.join(tempRoot.path, 'package');
      Directory(packagePath).createSync();
      packageTree.copy(target.sourcePath, packagePath);
      for (final contribution in active) {
        try {
          patchFile.apply(
            packagePath: packagePath,
            patchContent: File(contribution.patchPath).readAsStringSync(),
          );
        } on PatchworkException catch (error) {
          final hint = error.hint;
          return OverlayConflictInspection(
            provider: contribution.provider,
            patchPath: contribution.patchPath,
            message: hint == null || hint.isEmpty
                ? error.message
                : '${error.message}\n$hint',
          );
        }
      }
      return null;
    } finally {
      if (tempRoot.existsSync()) {
        tempRoot.deleteSync(recursive: true);
      }
    }
  }
}
