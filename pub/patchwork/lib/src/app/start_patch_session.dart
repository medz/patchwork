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

    return store.createPubEditSession(
      workspace: resolution.workspace,
      package: packageResult.package!,
    );
  }
}
