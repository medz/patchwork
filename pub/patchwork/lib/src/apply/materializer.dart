import '../patch/file.dart';
import '../patch/materializer.dart';
import '../state/artifact_identity.dart';

/// Materializes a committed patch into generated applied output.
final class AppliedPatchMaterializer {
  /// Creates a materializer for one Patchwork state root.
  const AppliedPatchMaterializer({
    required this.packageMaterializer,
    required this.patchFile,
  });

  /// Atomic package-copy installer.
  final PackageMaterializer packageMaterializer;

  /// Patch apply helper.
  final PatchFile patchFile;

  /// Copies [sourcePath], applies [patchContent], and atomically installs it.
  void materialize({
    required String package,
    required String version,
    required String sourcePath,
    required String appliedPath,
    required String patchContent,
  }) {
    packageMaterializer.materialize(
      identity: packageVersionName(package, version),
      sourcePath: sourcePath,
      outputPath: appliedPath,
      transform: (packagePath) {
        patchFile.apply(packagePath: packagePath, patchContent: patchContent);
      },
    );
  }
}
