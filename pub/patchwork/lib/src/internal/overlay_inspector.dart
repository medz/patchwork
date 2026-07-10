import 'dart:collection';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../error.dart';
import '../model.dart';
import '../overlay_manifest.dart';
import '../patch_file.dart';
import '../pub/package_resolution.dart';
import 'overlay_rules.dart';
import 'package_tree.dart';
import 'path_layout.dart';
import 'pub_resolution_files.dart';

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
  Future<OverlayInspection> inspect() async {
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

    final groups = SplayTreeMap<String, _OverlayTargetPlan>();
    final providers = <OverlayProviderInspection>[];
    for (final package in packageConfig.packages) {
      if (package.name == 'patchwork' ||
          !graph.hasIncomingDependency(package.name)) {
        continue;
      }

      final manifestPath = p.join(package.rootPath, 'patchwork.yaml');
      final manifestFile = File(manifestPath);
      if (!manifestFile.existsSync()) {
        continue;
      }

      final provider = graph.packages[package.name];
      final manifest = OverlayManifestStore(path: manifestPath).read();
      final entries = [
        for (final entry in manifest.overlays)
          _inspectEntry(
            package: package,
            provider: provider,
            manifestPath: manifestPath,
            entry: entry,
            resolution: resolution,
            groups: groups,
          ),
      ];
      providers.add(
        OverlayProviderInspection(
          package: package.name,
          rootPath: package.rootPath,
          manifestPath: manifestPath,
          entries: List.unmodifiable(entries),
        ),
      );
    }

    _normalizeProviderContributions(groups.values);
    _appendRootPatchContributions(groups.values);

    return OverlayInspection(
      providers: List.unmodifiable(providers),
      targets: List.unmodifiable([
        for (final group in groups.values) _targetInspection(group),
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

    final basePath = p.join(layout.appliedRootPath, 'package_config.base.json');
    final baseFile = File(basePath);
    if (!baseFile.existsSync()) {
      return current;
    }
    return PackageConfigFile.fromContent(
      path: packageConfigPath,
      content: baseFile.readAsStringSync(),
    );
  }

  OverlayEntryInspection _inspectEntry({
    required PackageConfigPackage package,
    required GraphPackage? provider,
    required String manifestPath,
    required OverlayManifestEntry entry,
    required PubResolution resolution,
    required SplayTreeMap<String, _OverlayTargetPlan> groups,
  }) {
    if (!providerDependsOnOverlayTarget(provider, entry.package)) {
      return _skippedEntry(
        entry,
        patchPath: entry.patch,
        skipReason: 'overlay.provider_not_dependency',
        status: OverlayEntryStatus.failed,
      );
    }

    final resolved = tryResolveOverlayTarget(resolution, entry.package);
    if (resolved == null) {
      return _skippedEntry(
        entry,
        patchPath: entry.patch,
        skipReason: 'pub.package_not_found',
      );
    }

    if (resolved.version != entry.version) {
      return _skippedEntry(
        entry,
        patchPath: entry.patch,
        skipReason: 'overlay.version_mismatch',
        resolved: resolved,
      );
    }
    if (resolved.source.sha256 != entry.sha256) {
      return _skippedEntry(
        entry,
        patchPath: entry.patch,
        skipReason: 'overlay.source_mismatch',
        resolved: resolved,
      );
    }

    final patchPath = resolveOverlayPatchPath(
      packageRootPath: package.rootPath,
      manifestPath: manifestPath,
      patchPath: entry.patch,
    );
    if (!File(patchPath).existsSync()) {
      return _skippedEntry(
        entry,
        patchPath: patchPath,
        skipReason: 'overlay.patch_file_missing',
        resolved: resolved,
        status: OverlayEntryStatus.failed,
      );
    }

    final group = groups.putIfAbsent(
      entry.package,
      () => _OverlayTargetPlan(
        package: entry.package,
        version: resolved.version,
        sha256: resolved.source.sha256,
        sourcePath: resolved.rootPath,
      ),
    );
    group.contributions.add(
      OverlayContribution(provider: package.name, patchPath: patchPath),
    );

    return OverlayEntryInspection(
      package: entry.package,
      version: entry.version,
      sha256: entry.sha256,
      patchPath: patchPath,
      reason: entry.reason,
      status: OverlayEntryStatus.matched,
      resolvedVersion: resolved.version,
      resolvedSha256: resolved.source.sha256,
    );
  }

  OverlayEntryInspection _skippedEntry(
    OverlayManifestEntry entry, {
    required String patchPath,
    required String skipReason,
    ResolvedPubPackage? resolved,
    OverlayEntryStatus status = OverlayEntryStatus.skipped,
  }) {
    return OverlayEntryInspection(
      package: entry.package,
      version: entry.version,
      sha256: entry.sha256,
      patchPath: patchPath,
      reason: entry.reason,
      status: status,
      skipReason: skipReason,
      resolvedVersion: resolved?.version,
      resolvedSha256: resolved?.source.sha256,
    );
  }

  void _normalizeProviderContributions(Iterable<_OverlayTargetPlan> groups) {
    for (final group in groups) {
      final normalized = normalizeProviderOverlayContributions(
        group.contributions,
      );
      group.contributions
        ..clear()
        ..addAll(normalized);
    }
  }

  void _appendRootPatchContributions(Iterable<_OverlayTargetPlan> groups) {
    for (final group in groups) {
      final patchPath = layout.patchPath(group.package, group.version);
      final contribution = rootOverlayContribution(
        patchPath,
        group.contributions,
      );
      if (contribution == null) {
        continue;
      }
      group.contributions.add(contribution);
    }
  }

  OverlayTargetInspection _targetInspection(_OverlayTargetPlan group) {
    return OverlayTargetInspection(
      package: group.package,
      version: group.version,
      sha256: group.sha256,
      sourcePath: group.sourcePath,
      contributions: List.unmodifiable([
        for (final contribution in group.contributions)
          OverlayContributionInspection(
            provider: contribution.provider,
            patchPath: contribution.patchPath,
            sha256: contribution.patchSha256,
            status: contribution.deduplicated
                ? OverlayContributionStatus.deduplicated
                : OverlayContributionStatus.active,
          ),
      ]),
      conflict: _inspectConflict(group),
    );
  }

  OverlayConflictInspection? _inspectConflict(_OverlayTargetPlan group) {
    final active = group.contributions.where(
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
      packageTree.copy(group.sourcePath, packagePath);
      for (final contribution in active) {
        try {
          patchFile.apply(
            packagePath: packagePath,
            patchContent: File(contribution.patchPath).readAsStringSync(),
          );
        } on PatchworkException catch (error) {
          return OverlayConflictInspection(
            provider: contribution.provider,
            patchPath: contribution.patchPath,
            message: _formatConflictMessage(error),
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

  String _formatConflictMessage(PatchworkException error) {
    final hint = error.hint;
    if (hint == null || hint.isEmpty) {
      return error.message;
    }
    return '${error.message}\n$hint';
  }
}

final class _OverlayTargetPlan {
  _OverlayTargetPlan({
    required this.package,
    required this.version,
    required this.sha256,
    required this.sourcePath,
  });

  final String package;
  final String version;
  final String sha256;
  final String sourcePath;
  final List<OverlayContribution> contributions = [];
}
