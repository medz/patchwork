import '../diagnostics/diagnostic.dart';
import '../pub/package_resolution.dart';
import '../store/edit_session.dart';
import '../store/patchwork_store.dart';
import '../target/target.dart';

final class StartPatchSession {
  const StartPatchSession({
    this.resolutionReader = const PubResolutionReader(),
    this.store = const PatchworkStore(),
  });

  final PubResolutionReader resolutionReader;
  final PatchworkStore store;

  PubPatchSessionCreateResult call(
    PubTarget target, {
    required String currentDirectory,
  }) {
    final resolutionResult = resolutionReader.readFromDirectory(
      currentDirectory,
    );
    final resolutionDiagnostic = resolutionResult.diagnostic;
    if (resolutionDiagnostic != null) {
      return PubPatchSessionCreateResult.failure(resolutionDiagnostic);
    }

    final resolution = resolutionResult.resolution!;
    final packageResult = resolution.resolve(target);
    final packageDiagnostic = packageResult.diagnostic;
    if (packageDiagnostic != null) {
      return PubPatchSessionCreateResult.failure(packageDiagnostic);
    }

    final package = packageResult.package!;
    if (store.isPubPatchStorePath(
      workspaceRootPath: resolution.workspace.rootPath,
      path: package.rootPath,
    )) {
      return PubPatchSessionCreateResult.failure(
        Diagnostic(
          code: 'pub.patch_source_generated',
          message:
              'Could not start a pub patch session from a generated Patchwork store copy.',
          hint:
              'Refresh pub resolution without Patchwork overrides before starting a new patch session.',
          location: package.rootPath,
        ),
      );
    }

    return store.createPubEditSession(
      workspace: resolution.workspace,
      package: package,
    );
  }
}
