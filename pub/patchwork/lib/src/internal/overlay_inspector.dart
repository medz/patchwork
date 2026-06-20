import 'dart:collection';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../error.dart';
import '../model.dart';
import '../overlay_manifest.dart';
import '../patch_file.dart';
import '../pub/package_resolution.dart';
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

    _sortProviderContributions(groups.values);
    _deduplicateContributions(groups.values);
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
    if (provider == null || !provider.dependencies.contains(entry.package)) {
      return _skippedEntry(
        entry,
        patchPath: entry.patch,
        skipReason: 'overlay.provider_not_dependency',
      );
    }

    final resolved = _tryResolveOverlayTarget(resolution, entry.package);
    if (resolved == null) {
      return _skippedEntry(
        entry,
        patchPath: entry.patch,
        skipReason: 'pub.package_not_found',
      );
    }

    final patchPath = _resolveManifestPatchPath(
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
    if (resolved.version != entry.version) {
      return _skippedEntry(
        entry,
        patchPath: patchPath,
        skipReason: 'overlay.version_mismatch',
        resolved: resolved,
      );
    }
    if (resolved.source.sha256 != entry.sha256) {
      return _skippedEntry(
        entry,
        patchPath: patchPath,
        skipReason: 'overlay.source_mismatch',
        resolved: resolved,
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
      _OverlayContributionPlan.active(
        provider: package.name,
        patchPath: patchPath,
      ),
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

  ResolvedPubPackage? _tryResolveOverlayTarget(
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

  String _resolveManifestPatchPath({
    required String packageRootPath,
    required String manifestPath,
    required String patchPath,
  }) {
    if (p.isAbsolute(patchPath)) {
      throw PatchworkException(
        'Overlay patch paths must be relative to the declaring package.',
        code: 'overlay.absolute_patch_path',
        location: manifestPath,
      );
    }
    final absolutePath = p.normalize(p.join(packageRootPath, patchPath));
    final rootPath = p.normalize(p.absolute(packageRootPath));
    if (!p.isWithin(rootPath, absolutePath)) {
      throw PatchworkException(
        'Overlay patch paths must stay inside the declaring package.',
        code: 'overlay.patch_path_escapes_package',
        location: manifestPath,
      );
    }
    return absolutePath;
  }

  void _sortProviderContributions(Iterable<_OverlayTargetPlan> groups) {
    for (final group in groups) {
      group.contributions.sort((left, right) {
        final providerCompare = left.provider.compareTo(right.provider);
        if (providerCompare != 0) {
          return providerCompare;
        }
        return left.patchPath.compareTo(right.patchPath);
      });
    }
  }

  void _deduplicateContributions(Iterable<_OverlayTargetPlan> groups) {
    for (final group in groups) {
      final seen = <String>{};
      for (var index = 0; index < group.contributions.length; index++) {
        final contribution = group.contributions[index];
        if (seen.add(contribution.patchSha256)) {
          continue;
        }
        group.contributions[index] = _OverlayContributionPlan.deduplicated(
          provider: contribution.provider,
          patchPath: contribution.patchPath,
        );
      }
    }
  }

  void _appendRootPatchContributions(Iterable<_OverlayTargetPlan> groups) {
    for (final group in groups) {
      final patchPath = layout.patchPath(group.package, group.version);
      final patchFile = File(patchPath);
      if (!patchFile.existsSync()) {
        continue;
      }

      final patchSha256 = _sha256(patchFile.readAsBytesSync());
      final duplicate = group.contributions.any((contribution) {
        return contribution.patchSha256 == patchSha256;
      });
      group.contributions.add(
        duplicate
            ? _OverlayContributionPlan.deduplicated(
                provider: '<root>',
                patchPath: patchPath,
              )
            : _OverlayContributionPlan.active(
                provider: '<root>',
                patchPath: patchPath,
              ),
      );
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
            status: contribution.status,
          ),
      ]),
      conflict: _inspectConflict(group),
    );
  }

  OverlayConflictInspection? _inspectConflict(_OverlayTargetPlan group) {
    final active = group.contributions.where(
      (contribution) => contribution.status == OverlayContributionStatus.active,
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
  final List<_OverlayContributionPlan> contributions = [];
}

final class _OverlayContributionPlan {
  _OverlayContributionPlan._({
    required this.provider,
    required this.patchPath,
    required this.status,
  }) : patchSha256 = _sha256(File(patchPath).readAsBytesSync());

  factory _OverlayContributionPlan.active({
    required String provider,
    required String patchPath,
  }) {
    return _OverlayContributionPlan._(
      provider: provider,
      patchPath: patchPath,
      status: OverlayContributionStatus.active,
    );
  }

  factory _OverlayContributionPlan.deduplicated({
    required String provider,
    required String patchPath,
  }) {
    return _OverlayContributionPlan._(
      provider: provider,
      patchPath: patchPath,
      status: OverlayContributionStatus.deduplicated,
    );
  }

  final String provider;
  final String patchPath;
  final String patchSha256;
  final OverlayContributionStatus status;
}

String _sha256(List<int> bytes) {
  return sha256.convert(bytes).toString();
}
