import 'dart:io';

import '../diagnostics/diagnostic.dart';
import '../pub/package_resolution.dart';
import '../pub/pub_workspace.dart';
import '../store/patchwork_store.dart';

enum PubDoctorCheckState { ok, error }

final class PubDoctorResult {
  const PubDoctorResult({required this.checks});

  final List<PubDoctorCheck> checks;

  bool get hasErrors {
    return checks.any((check) => check.state == PubDoctorCheckState.error);
  }
}

final class PubDoctorCheck {
  const PubDoctorCheck({
    required this.name,
    required this.state,
    required this.message,
    this.hint,
    this.location,
  });

  final String name;
  final PubDoctorCheckState state;
  final String message;
  final String? hint;
  final String? location;
}

typedef PubDoctorProcessRunner =
    ProcessResult Function(String executable, List<String> arguments);

ProcessResult _defaultProcessRunner(String executable, List<String> arguments) {
  return Process.runSync(executable, arguments);
}

final class PubDoctor {
  const PubDoctor({
    this.workspaceLocator = const PubWorkspaceLocator(),
    this.resolutionReader = const PubResolutionReader(),
    this.store = const PatchworkStore(),
    this.processRunner = _defaultProcessRunner,
  });

  final PubWorkspaceLocator workspaceLocator;
  final PubResolutionReader resolutionReader;
  final PatchworkStore store;
  final PubDoctorProcessRunner processRunner;

  PubDoctorResult check({required String currentDirectory}) {
    final checks = <PubDoctorCheck>[_checkDartExecutable()];

    final workspaceResult = workspaceLocator.locate(currentDirectory);
    final workspaceDiagnostic = workspaceResult.diagnostic;
    if (workspaceDiagnostic != null) {
      checks.add(_errorFromDiagnostic('workspace', workspaceDiagnostic));
      return PubDoctorResult(checks: checks);
    }

    final workspace = workspaceResult.workspace!;
    checks.add(
      PubDoctorCheck(
        name: 'workspace',
        state: PubDoctorCheckState.ok,
        message: 'Found pub workspace.',
        location: workspace.rootPath,
      ),
    );
    checks.add(_checkFile('package config', workspace.packageConfigPath));
    checks.add(_checkResolutionMetadata(currentDirectory, workspace));
    checks.add(_checkWriteAccess(workspace));

    return PubDoctorResult(checks: checks);
  }

  PubDoctorCheck _checkDartExecutable() {
    try {
      final result = processRunner('dart', ['--version']);
      if (result.exitCode == 0) {
        final version = '${result.stderr}${result.stdout}'.trim();
        return PubDoctorCheck(
          name: 'dart executable',
          state: PubDoctorCheckState.ok,
          message: version.isEmpty ? 'Found dart executable.' : version,
        );
      }

      return PubDoctorCheck(
        name: 'dart executable',
        state: PubDoctorCheckState.error,
        message: 'Could not run dart --version.',
        hint: '${result.stderr}${result.stdout}'.trim(),
      );
    } on ProcessException catch (error) {
      return PubDoctorCheck(
        name: 'dart executable',
        state: PubDoctorCheckState.error,
        message: 'Dart executable was not found.',
        hint: error.message,
      );
    }
  }

  PubDoctorCheck _checkFile(String name, String path) {
    final file = File(path);
    if (file.existsSync()) {
      return PubDoctorCheck(
        name: name,
        state: PubDoctorCheckState.ok,
        message: 'Found $name.',
        location: path,
      );
    }

    return PubDoctorCheck(
      name: name,
      state: PubDoctorCheckState.error,
      message: 'Missing $name.',
      hint: 'Run dart pub get before using patchwork.',
      location: path,
    );
  }

  PubDoctorCheck _checkResolutionMetadata(
    String currentDirectory,
    PubWorkspace workspace,
  ) {
    final result = resolutionReader.readFromDirectory(currentDirectory);
    final diagnostic = result.diagnostic;
    if (diagnostic != null) {
      return _errorFromDiagnostic('pub resolution metadata', diagnostic);
    }

    return PubDoctorCheck(
      name: 'pub resolution metadata',
      state: PubDoctorCheckState.ok,
      message: 'Pub resolution metadata is readable.',
      location: workspace.rootPath,
    );
  }

  PubDoctorCheck _checkWriteAccess(PubWorkspace workspace) {
    String? tempPath;
    try {
      tempPath = store.createPatchworkTempDirectory(
        workspaceRootPath: workspace.rootPath,
        prefix: 'doctor_',
      );
      return PubDoctorCheck(
        name: 'write access',
        state: PubDoctorCheckState.ok,
        message: 'Can write generated Patchwork state.',
        location: workspace.rootPath,
      );
    } on FileSystemException catch (error) {
      return PubDoctorCheck(
        name: 'write access',
        state: PubDoctorCheckState.error,
        message: 'Could not write generated Patchwork state.',
        hint: error.message,
        location: error.path,
      );
    } finally {
      if (tempPath != null) {
        store.deleteDirectory(tempPath);
      }
    }
  }

  PubDoctorCheck _errorFromDiagnostic(String name, Diagnostic diagnostic) {
    return PubDoctorCheck(
      name: name,
      state: PubDoctorCheckState.error,
      message: diagnostic.message,
      hint: diagnostic.hint,
      location: diagnostic.location,
    );
  }
}
