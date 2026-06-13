import '../diagnostics/diagnostic.dart';
import '../pub/package_resolution.dart';
import '../store/edit_session.dart';
import '../store/patchwork_store.dart';
import '../target/target.dart';
import 'pub_patch_target_resolution.dart';

final class StartPatchSession {
  const StartPatchSession({
    this.resolutionReader = const PubResolutionReader(),
    this.store = const PatchworkStore(),
    this.targetResolver = const PubPatchTargetResolver(),
  });

  final PubResolutionReader resolutionReader;
  final PatchworkStore store;
  final PubPatchTargetResolver targetResolver;

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
    final targetResult = targetResolver.resolve(resolution, target);
    final targetDiagnostic = targetResult.diagnostic;
    if (targetDiagnostic != null) {
      return PubPatchSessionCreateResult.failure(targetDiagnostic);
    }

    final package = targetResult.target!.package;

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
