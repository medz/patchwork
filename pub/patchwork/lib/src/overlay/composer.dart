import 'dart:io';

import '../error.dart';
import '../patch/file.dart';
import '../patch/materializer.dart';
import '../patch/package_tree.dart';
import '../state/artifact_identity.dart';
import '../state/path_layout.dart';
import 'rules.dart';

/// One resolved package and its ordered overlay contributions.
final class OverlayComposition {
  /// Creates an overlay composition target.
  OverlayComposition({
    required this.package,
    required this.version,
    required this.sourceSha256,
    required this.sourcePath,
  });

  /// Target package name.
  final String package;

  /// Target package version.
  final String version;

  /// Hash of the unmodified source package.
  final String sourceSha256;

  /// Unmodified source package path.
  final String sourcePath;

  /// Ordered patch contributions to compose.
  final List<OverlayContribution> contributions = [];
}

/// Materializes one resolved package with all matching overlay patches.
final class OverlayComposer {
  /// Creates an overlay composer.
  const OverlayComposer({
    this.materializer = const PackageMaterializer(packageTree: PackageTree()),
    this.patchFile = const PatchFile(),
  });

  /// Atomic package-copy installer.
  final PackageMaterializer materializer;

  /// Patch application helper.
  final PatchFile patchFile;

  /// Composes [target] into Patchwork generated output.
  void compose(OverlayComposition target, {required PathLayout layout}) {
    final identity = packageVersionName(target.package, target.version);
    materializer.materialize(
      identity: identity,
      sourcePath: target.sourcePath,
      outputPath: layout.appliedPath(target.package, target.version),
      transform: (packagePath) {
        for (final contribution in target.contributions) {
          if (contribution.deduplicated) {
            continue;
          }
          final patchContent = readOverlayPatch(contribution.patchPath);
          try {
            patchFile.apply(
              packagePath: packagePath,
              patchContent: patchContent,
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
      },
    );
  }
}

/// Reads an overlay patch with a stable Patchwork filesystem diagnostic.
String readOverlayPatch(String path) {
  try {
    return File(path).readAsStringSync();
  } on FileSystemException catch (error) {
    throw PatchworkException(
      'Could not read overlay patch file.',
      code: 'overlay.patch_unreadable',
      hint: error.message,
      location: path,
    );
  }
}
