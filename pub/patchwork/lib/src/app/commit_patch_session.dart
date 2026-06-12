import 'package:path/path.dart' as p;

import '../diagnostics/diagnostic.dart';
import '../patch/patch_file.dart';
import '../pub/package_resolution.dart';
import '../store/edit_session.dart';
import '../store/patchwork_store.dart';
import '../target/target.dart';

final class PubPatchSessionCommitResult {
  const PubPatchSessionCommitResult._({
    this.patchPath,
    this.noChanges = false,
    this.diagnostic,
  });

  factory PubPatchSessionCommitResult.success(String patchPath) {
    return PubPatchSessionCommitResult._(patchPath: patchPath);
  }

  factory PubPatchSessionCommitResult.noChanges() {
    return const PubPatchSessionCommitResult._(noChanges: true);
  }

  factory PubPatchSessionCommitResult.failure(Diagnostic diagnostic) {
    return PubPatchSessionCommitResult._(diagnostic: diagnostic);
  }

  final String? patchPath;
  final bool noChanges;
  final Diagnostic? diagnostic;

  bool get isSuccess => diagnostic == null;
}

final class CommitPatchSession {
  const CommitPatchSession({
    this.resolutionReader = const PubResolutionReader(),
    this.store = const PatchworkStore(),
    this.patchBuilder = const PatchFileBuilder(),
    this.patchValidator = const PatchValidator(),
  });

  final PubResolutionReader resolutionReader;
  final PatchworkStore store;
  final PatchFileBuilder patchBuilder;
  final PatchValidator patchValidator;

  PubPatchSessionCommitResult commitTarget(
    PubTarget target, {
    required String currentDirectory,
  }) {
    final resolutionResult = resolutionReader.readFromDirectory(
      currentDirectory,
    );
    final resolutionDiagnostic = resolutionResult.diagnostic;
    if (resolutionDiagnostic != null) {
      return PubPatchSessionCommitResult.failure(resolutionDiagnostic);
    }

    final resolution = resolutionResult.resolution!;
    final packageResult = resolution.resolve(target);
    final packageDiagnostic = packageResult.diagnostic;
    if (packageDiagnostic != null) {
      return PubPatchSessionCommitResult.failure(packageDiagnostic);
    }

    final locateResult = store.locatePubEditSessionForPackage(
      workspace: resolution.workspace,
      package: packageResult.package!,
    );
    return _commitLocatedSession(locateResult);
  }

  PubPatchSessionCommitResult commitEditDirectory(
    String editPath, {
    required String currentDirectory,
  }) {
    final locateResult = store.locatePubEditSessionForEditPath(
      editPath: editPath,
      currentDirectory: currentDirectory,
    );
    return _commitLocatedSession(locateResult);
  }

  PubPatchSessionCommitResult _commitLocatedSession(
    PubPatchSessionLocateResult locateResult,
  ) {
    final locateDiagnostic = locateResult.diagnostic;
    if (locateDiagnostic != null) {
      return PubPatchSessionCommitResult.failure(locateDiagnostic);
    }

    final session = locateResult.session!;
    final buildResult = patchBuilder.build(
      baselinePath: session.baselinePath,
      editPath: session.editPath,
    );
    final buildDiagnostic = buildResult.diagnostic;
    if (buildDiagnostic != null) {
      return PubPatchSessionCommitResult.failure(buildDiagnostic);
    }

    if (!buildResult.hasChanges) {
      return PubPatchSessionCommitResult.noChanges();
    }

    final patchContent = buildResult.content!;
    final validationResult = patchValidator.validate(
      baselinePath: session.baselinePath,
      patchContent: patchContent,
    );
    final validationDiagnostic = validationResult.diagnostic;
    if (validationDiagnostic != null) {
      return PubPatchSessionCommitResult.failure(validationDiagnostic);
    }

    final workspaceRootPath = locateResult.workspaceRootPath!;
    store.writePubPatchFile(
      workspaceRootPath: workspaceRootPath,
      session: session,
      content: patchContent,
    );

    return PubPatchSessionCommitResult.success(
      p.relative(
        store.pubPatchFilePath(
          workspaceRootPath: workspaceRootPath,
          session: session,
        ),
        from: workspaceRootPath,
      ),
    );
  }
}
