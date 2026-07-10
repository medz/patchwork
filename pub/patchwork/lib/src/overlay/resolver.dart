import 'dart:collection';
import 'dart:io';

import '../pub/resolution.dart';
import '../state/path_layout.dart';
import 'composer.dart';
import 'discovery.dart';
import 'manifest.dart';
import 'model.dart';
import 'pub_resolution.dart';
import 'rules.dart';

/// Resolved overlay diagnostics and composition targets.
final class ResolvedOverlays {
  /// Creates resolved overlay state.
  ResolvedOverlays({
    required List<OverlayProviderInspection> providers,
    required List<OverlayComposition> targets,
  }) : providers = List.unmodifiable(providers),
       targets = List.unmodifiable(targets);

  /// Provider entry diagnostics.
  final List<OverlayProviderInspection> providers;

  /// Ordered package composition targets.
  final List<OverlayComposition> targets;
}

/// Resolves provider manifests against one pub resolution.
final class OverlayResolver {
  /// Creates an overlay resolver.
  const OverlayResolver({required this.layout});

  /// Patchwork paths used to discover root-owned patch contributions.
  final PathLayout layout;

  /// Resolves [catalog] entries and normalizes contribution order.
  ResolvedOverlays resolve({
    required OverlayManifestCatalog catalog,
    required PackageGraph graph,
    required PubResolution resolution,
  }) {
    final targets = SplayTreeMap<String, OverlayComposition>();
    final providers = <OverlayProviderInspection>[];
    for (final providerManifest in catalog.providers) {
      final provider = graph.packages[providerManifest.packageName];
      final entries = [
        for (final entry in providerManifest.manifest.overlays)
          _resolveEntry(
            providerManifest: providerManifest,
            provider: provider,
            entry: entry,
            resolution: resolution,
            targets: targets,
          ),
      ];
      providers.add(
        OverlayProviderInspection(
          package: providerManifest.packageName,
          rootPath: providerManifest.packageRootPath,
          manifestPath: providerManifest.manifestPath,
          entries: List.unmodifiable(entries),
        ),
      );
    }

    for (final target in targets.values) {
      final normalized = normalizeProviderOverlayContributions(
        target.contributions,
      );
      target.contributions
        ..clear()
        ..addAll(normalized);
      final rootContribution = rootOverlayContribution(
        layout.patchPath(target.package, target.version),
        target.contributions,
      );
      if (rootContribution != null) {
        target.contributions.add(rootContribution);
      }
    }

    return ResolvedOverlays(
      providers: providers,
      targets: targets.values.toList(),
    );
  }

  OverlayEntryInspection _resolveEntry({
    required OverlayProviderManifest providerManifest,
    required GraphPackage? provider,
    required OverlayManifestEntry entry,
    required PubResolution resolution,
    required SplayTreeMap<String, OverlayComposition> targets,
  }) {
    if (!providerDependsOnOverlayTarget(provider, entry.package)) {
      return _skippedEntry(
        entry,
        skipReason: 'overlay.provider_not_dependency',
        status: OverlayEntryStatus.failed,
      );
    }

    final resolved = tryResolveOverlayTarget(resolution, entry.package);
    if (resolved == null) {
      return _skippedEntry(entry, skipReason: 'pub.package_not_found');
    }
    if (resolved.version != entry.version) {
      return _skippedEntry(
        entry,
        skipReason: 'overlay.version_mismatch',
        resolved: resolved,
      );
    }
    if (resolved.source.sha256 != entry.sha256) {
      return _skippedEntry(
        entry,
        skipReason: 'overlay.source_mismatch',
        resolved: resolved,
      );
    }

    final patchPath = resolveOverlayPatchPath(
      packageRootPath: providerManifest.packageRootPath,
      manifestPath: providerManifest.manifestPath,
      patchPath: entry.patch,
    );
    if (!File(patchPath).existsSync()) {
      return _skippedEntry(
        entry,
        skipReason: 'overlay.patch_file_missing',
        resolved: resolved,
        status: OverlayEntryStatus.failed,
      );
    }

    final target = targets.putIfAbsent(
      entry.package,
      () => OverlayComposition(
        package: entry.package,
        version: resolved.version,
        sourceSha256: resolved.source.sha256,
        sourcePath: resolved.rootPath,
      ),
    );
    target.contributions.add(
      OverlayContribution(
        provider: providerManifest.packageName,
        patchPath: patchPath,
      ),
    );

    return OverlayEntryInspection(
      package: entry.package,
      version: entry.version,
      sha256: entry.sha256,
      patchPath: entry.patch,
      reason: entry.reason,
      status: OverlayEntryStatus.matched,
      resolvedVersion: resolved.version,
      resolvedSha256: resolved.source.sha256,
    );
  }

  OverlayEntryInspection _skippedEntry(
    OverlayManifestEntry entry, {
    required String skipReason,
    ResolvedPubPackage? resolved,
    OverlayEntryStatus status = OverlayEntryStatus.skipped,
  }) {
    return OverlayEntryInspection(
      package: entry.package,
      version: entry.version,
      sha256: entry.sha256,
      patchPath: entry.patch,
      reason: entry.reason,
      status: status,
      skipReason: skipReason,
      resolvedVersion: resolved?.version,
      resolvedSha256: resolved?.source.sha256,
    );
  }
}
