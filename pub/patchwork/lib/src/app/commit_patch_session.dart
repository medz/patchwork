import 'dart:io';

import 'package:path/path.dart' as p;

import '../diagnostics/diagnostic.dart';
import '../patch/patch_file.dart';
import '../pub/package_resolution.dart';
import '../store/edit_session.dart';
import '../store/patchwork_manifest.dart';
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
    this.manifestStore = const PatchworkManifestStore(),
    this.patchBuilder = const PatchFileBuilder(),
    this.patchValidator = const PatchValidator(),
  });

  final PubResolutionReader resolutionReader;
  final PatchworkStore store;
  final PatchworkManifestStore manifestStore;
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
      final workspaceRootPath = locateResult.workspaceRootPath!;
      final manifestDiagnostic = manifestStore
          .read(workspaceRootPath: workspaceRootPath)
          .diagnostic;
      if (manifestDiagnostic != null) {
        return PubPatchSessionCommitResult.failure(manifestDiagnostic);
      }

      final patchFilePath = store.pubPatchFilePath(
        workspaceRootPath: workspaceRootPath,
        session: session,
      );
      _PatchFileSnapshot? patchSnapshot;
      try {
        patchSnapshot = _PatchFileSnapshot.capture(patchFilePath);
        store.deletePubPatchFile(
          workspaceRootPath: workspaceRootPath,
          session: session,
        );
        manifestStore.removePatch(
          workspaceRootPath: workspaceRootPath,
          target: session.target.toString(),
        );
      } on FileSystemException catch (error) {
        final rollbackDiagnostic = _restorePatchFile(patchSnapshot);
        if (rollbackDiagnostic != null) {
          return PubPatchSessionCommitResult.failure(rollbackDiagnostic);
        }
        return PubPatchSessionCommitResult.failure(
          _patchCommitDiagnostic(error),
        );
      } on PatchworkManifestException catch (error) {
        final rollbackDiagnostic = _restorePatchFile(patchSnapshot);
        if (rollbackDiagnostic != null) {
          return PubPatchSessionCommitResult.failure(rollbackDiagnostic);
        }
        return PubPatchSessionCommitResult.failure(error.diagnostic);
      }
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
    final manifestDiagnostic = manifestStore
        .read(workspaceRootPath: workspaceRootPath)
        .diagnostic;
    if (manifestDiagnostic != null) {
      return PubPatchSessionCommitResult.failure(manifestDiagnostic);
    }

    final patchFilePath = store.pubPatchFilePath(
      workspaceRootPath: workspaceRootPath,
      session: session,
    );
    final relativePatchPath = p.relative(
      patchFilePath,
      from: workspaceRootPath,
    );
    final manifestPatchPath = patchworkManifestPath(relativePatchPath);
    _PatchFileSnapshot? patchSnapshot;
    try {
      patchSnapshot = _PatchFileSnapshot.capture(patchFilePath);
      store.writePubPatchFile(
        workspaceRootPath: workspaceRootPath,
        session: session,
        content: patchContent,
      );
      manifestStore.upsertPatch(
        workspaceRootPath: workspaceRootPath,
        entry: PatchworkManifestPatch(
          target: session.target.toString(),
          path: manifestPatchPath,
          hash: manifestStore.hashFile(patchFilePath),
        ),
      );
    } on FileSystemException catch (error) {
      final rollbackDiagnostic = _restorePatchFile(patchSnapshot);
      if (rollbackDiagnostic != null) {
        return PubPatchSessionCommitResult.failure(rollbackDiagnostic);
      }
      return PubPatchSessionCommitResult.failure(_patchCommitDiagnostic(error));
    } on PatchworkManifestException catch (error) {
      final rollbackDiagnostic = _restorePatchFile(patchSnapshot);
      if (rollbackDiagnostic != null) {
        return PubPatchSessionCommitResult.failure(rollbackDiagnostic);
      }
      return PubPatchSessionCommitResult.failure(error.diagnostic);
    }

    return PubPatchSessionCommitResult.success(relativePatchPath);
  }
}

final class _PatchFileSnapshot {
  const _PatchFileSnapshot._({required this.path, required this.bytes});

  final String path;
  final List<int>? bytes;

  static _PatchFileSnapshot capture(String path) {
    final file = File(path);
    return _PatchFileSnapshot._(
      path: path,
      bytes: file.existsSync() ? file.readAsBytesSync() : null,
    );
  }

  void restore() {
    final file = File(path);
    final bytes = this.bytes;
    if (bytes == null) {
      if (file.existsSync()) {
        file.deleteSync();
      }
      return;
    }

    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes, flush: true);
  }
}

Diagnostic? _restorePatchFile(_PatchFileSnapshot? snapshot) {
  if (snapshot == null) {
    return null;
  }

  try {
    snapshot.restore();
    return null;
  } on FileSystemException catch (error) {
    return Diagnostic(
      code: 'pub.patch_commit_failed',
      message: 'Could not roll back the pub patch file after commit failure.',
      hint: error.message,
      location: error.path,
    );
  }
}

Diagnostic _patchCommitDiagnostic(FileSystemException error) {
  return Diagnostic(
    code: 'pub.patch_commit_failed',
    message: 'Could not commit the pub patch file.',
    hint: error.message,
    location: error.path,
  );
}
