import 'dart:io';

import 'package:path/path.dart' as p;

import '../error.dart';
import '../overlay_manifest.dart';
import '../pub/package_resolution.dart';
import 'hashing.dart';
import 'pub_resolution_files.dart';

/// Whether [provider] is allowed to contribute an overlay for [package].
bool providerDependsOnOverlayTarget(GraphPackage? provider, String package) {
  return provider != null && provider.dependencies.contains(package);
}

/// Resolves an overlay target, returning `null` when pub did not select it.
ResolvedPubPackage? tryResolveOverlayTarget(
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

/// Whether [entry] targets the exact package source selected by pub.
bool overlayEntryMatchesResolution(
  OverlayManifestEntry entry,
  ResolvedPubPackage resolved,
) {
  return resolved.version == entry.version &&
      resolved.source.sha256 == entry.sha256;
}

/// Resolves a provider patch path and rejects paths outside the provider.
String resolveOverlayPatchPath({
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

/// One ordered overlay patch contribution with a cached content hash.
final class OverlayContribution {
  /// Reads one patch contribution and caches its content hash.
  factory OverlayContribution({
    required String provider,
    required String patchPath,
  }) {
    return OverlayContribution._(
      provider: provider,
      patchPath: patchPath,
      patchSha256: sha256Hex(File(patchPath).readAsBytesSync()),
      deduplicated: false,
    );
  }

  const OverlayContribution._({
    required this.provider,
    required this.patchPath,
    required this.patchSha256,
    required this.deduplicated,
  });

  /// Package providing the patch, or `<root>` for a project patch.
  final String provider;

  /// Absolute patch file path.
  final String patchPath;

  /// SHA-256 of the patch bytes, computed once when the contribution is read.
  final String patchSha256;

  /// Whether an earlier contribution already provides identical patch bytes.
  final bool deduplicated;

  /// Returns this contribution marked as a duplicate.
  OverlayContribution asDeduplicated() {
    if (deduplicated) {
      return this;
    }
    return OverlayContribution._(
      provider: provider,
      patchPath: patchPath,
      patchSha256: patchSha256,
      deduplicated: true,
    );
  }
}

/// Sorts provider contributions and marks later identical patches as duplicates.
List<OverlayContribution> normalizeProviderOverlayContributions(
  Iterable<OverlayContribution> contributions,
) {
  final sorted = contributions.toList()
    ..sort((left, right) {
      final providerCompare = left.provider.compareTo(right.provider);
      if (providerCompare != 0) {
        return providerCompare;
      }
      return left.patchPath.compareTo(right.patchPath);
    });
  final seen = <String>{};
  return [
    for (final contribution in sorted)
      if (seen.add(contribution.patchSha256))
        contribution
      else
        contribution.asDeduplicated(),
  ];
}

/// Reads a root patch contribution and marks it duplicate when appropriate.
OverlayContribution? rootOverlayContribution(
  String patchPath,
  Iterable<OverlayContribution> existing,
) {
  if (!File(patchPath).existsSync()) {
    return null;
  }
  final contribution = OverlayContribution(
    provider: '<root>',
    patchPath: patchPath,
  );
  if (existing.any(
    (candidate) => candidate.patchSha256 == contribution.patchSha256,
  )) {
    return contribution.asDeduplicated();
  }
  return contribution;
}
