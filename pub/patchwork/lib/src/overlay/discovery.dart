import 'dart:io';

import 'package:path/path.dart' as p;

import 'manifest.dart';
import 'pub_resolution.dart';

/// One package that contains a `patchwork.yaml` overlay manifest.
final class OverlayProviderManifest {
  /// Creates a discovered provider manifest.
  const OverlayProviderManifest({
    required this.packageName,
    required this.packageRootPath,
    required this.manifestPath,
    required this.manifest,
  });

  /// Provider package name.
  final String packageName;

  /// Provider package root.
  final String packageRootPath;

  /// Absolute manifest path.
  final String manifestPath;

  /// Parsed overlay manifest.
  final OverlayManifest manifest;
}

/// Discovered provider manifests for one pub package config.
final class OverlayManifestCatalog {
  /// Creates a manifest catalog.
  OverlayManifestCatalog(List<OverlayProviderManifest> providers)
    : providers = List.unmodifiable(providers);

  /// Providers with an existing `patchwork.yaml` file.
  final List<OverlayProviderManifest> providers;

  /// Whether any provider declares at least one overlay.
  bool get hasDeclarations {
    return providers.any((provider) => provider.manifest.overlays.isNotEmpty);
  }
}

/// Finds overlay manifests from packages that participate in the pub graph.
final class OverlayManifestDiscovery {
  /// Creates an overlay manifest discovery helper.
  const OverlayManifestDiscovery();

  /// Reads provider manifests and reports every candidate to [onCandidate].
  OverlayManifestCatalog discover(
    PackageConfigFile packageConfig,
    PackageGraph graph, {
    void Function(File manifestFile, String packageRootPath)? onCandidate,
  }) {
    final providers = <OverlayProviderManifest>[];
    for (final package in packageConfig.packages) {
      if (package.name == 'patchwork' ||
          !graph.hasIncomingDependency(package.name)) {
        continue;
      }
      final manifestPath = p.join(package.rootPath, 'patchwork.yaml');
      final manifestFile = File(manifestPath);
      onCandidate?.call(manifestFile, package.rootPath);
      if (!manifestFile.existsSync()) {
        continue;
      }
      providers.add(
        OverlayProviderManifest(
          packageName: package.name,
          packageRootPath: package.rootPath,
          manifestPath: manifestPath,
          manifest: OverlayManifestStore(path: manifestPath).read(),
        ),
      );
    }
    providers.sort(
      (left, right) => left.packageName.compareTo(right.packageName),
    );
    return OverlayManifestCatalog(providers);
  }
}
