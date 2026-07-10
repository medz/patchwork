import 'dart:io';

import 'package:path/path.dart' as p;

import 'error.dart';
import 'internal/git_patch.dart';
import 'internal/package_tree.dart';
import 'internal/reject_files.dart';

/// Runs the `git` subprocess used for patch operations.
///
/// The abstraction keeps [PatchFile] testable while preserving the exact
/// arguments Patchwork sends to `git diff` and `git apply`.
typedef GitProcessRunner =
    ProcessResult Function(
      List<String> arguments, {
      String? workingDirectory,
      Map<String, String>? environment,
    });

ProcessResult _defaultGitRunner(
  List<String> arguments, {
  String? workingDirectory,
  Map<String, String>? environment,
}) {
  return Process.runSync(
    'git',
    arguments,
    workingDirectory: workingDirectory,
    environment: environment,
  );
}

/// Builds, validates, and applies Patchwork patch files.
///
/// Patchwork delegates diff and apply semantics to Git so text, mode changes,
/// renames, and binary files use the same patch format developers already
/// review. Temporary copies are used when building or validating so the real
/// source and edit directories are not modified by Git.
final class PatchFile {
  /// Creates a patch helper with injectable git and tree operations.
  const PatchFile({GitProcessRunner? gitRunner, PackageTree? packageTree})
    : _gitRunner = gitRunner ?? _defaultGitRunner,
      _packageTree = packageTree ?? const PackageTree();

  final GitProcessRunner _gitRunner;
  final PackageTree _packageTree;

  /// Builds a patch from [sourcePath] to [editPath].
  ///
  /// The returned content is a Git binary patch with stable `a/` and `b/`
  /// prefixes. An empty string means the edit tree has no differences from the
  /// source tree after Patchwork's package-tree filters are applied.
  String build({required String sourcePath, required String editPath}) {
    final sourceRoot = Directory(sourcePath);
    final editRoot = Directory(editPath);
    if (!sourceRoot.existsSync() || !editRoot.existsSync()) {
      throw PatchworkException(
        'Source or edit directory is missing.',
        code: 'patch.input_missing',
      );
    }

    final tempRoot = Directory.systemTemp.createTempSync('patchwork_diff_');
    try {
      final sourceSnapshotPath = p.join(tempRoot.path, 'source');
      final editSnapshotPath = p.join(tempRoot.path, 'edit');
      Directory(sourceSnapshotPath).createSync();
      Directory(editSnapshotPath).createSync();
      _packageTree.copy(sourcePath, sourceSnapshotPath);
      _packageTree.copy(editPath, editSnapshotPath);

      final result = _runGit(
        [
          '-c',
          'core.safecrlf=false',
          'diff',
          '--no-ext-diff',
          '--no-color',
          '--no-textconv',
          '--src-prefix=a/',
          '--dst-prefix=b/',
          '--full-index',
          '--binary',
          '--no-index',
          gitArgumentPath(sourceSnapshotPath),
          gitArgumentPath(editSnapshotPath),
        ],
        workingDirectory: tempRoot.path,
        failureCode: 'patch.diff_failed',
        failureMessage: 'Could not generate a patch diff.',
        allowDifferenceExitCode: true,
      );

      final output = '${result.stdout}';
      if (output.isEmpty) {
        return '';
      }
      return postProcessGitDiff(
        output: output,
        sourcePath: sourceSnapshotPath,
        editPath: editSnapshotPath,
      );
    } finally {
      if (tempRoot.existsSync()) {
        tempRoot.deleteSync(recursive: true);
      }
    }
  }

  /// Verifies that [patchContent] applies cleanly to [sourcePath].
  ///
  /// Validation runs against a fresh copy of the source tree and uses
  /// `git apply --check`, so callers can fail before writing a patch file that
  /// cannot be applied later.
  void validate({required String sourcePath, required String patchContent}) {
    final tempRoot = Directory.systemTemp.createTempSync('patchwork_validate_');
    try {
      final rootPath = p.join(tempRoot.path, 'root');
      Directory(rootPath).createSync();
      _packageTree.copy(sourcePath, rootPath);
      final patchPath = p.join(tempRoot.path, 'patch.patch');
      File(patchPath).writeAsStringSync(patchContent);
      _runGit(
        ['apply', '--check', '--binary', '--whitespace=nowarn', patchPath],
        workingDirectory: rootPath,
        failureCode: 'patch.validation_failed',
        failureMessage:
            'Generated patch does not apply to a fresh source copy.',
      );
    } finally {
      if (tempRoot.existsSync()) {
        tempRoot.deleteSync(recursive: true);
      }
    }
  }

  /// Applies [patchContent] to the package copy at [packagePath].
  ///
  /// The patch is written to a temporary file because `git apply` expects a
  /// patch path. The operation is anchored to [packagePath] so an outer Git
  /// repository cannot affect path resolution.
  void apply({required String packagePath, required String patchContent}) {
    final packageRoot = Directory(packagePath);
    if (!packageRoot.existsSync()) {
      throw PatchworkException(
        'Could not apply patch to a missing package copy.',
        code: 'patch.apply_missing_package',
        location: packagePath,
      );
    }

    final patchFile = File(
      p.join(
        Directory.systemTemp.path,
        'patchwork_apply_$pid'
        '_${DateTime.now().microsecondsSinceEpoch}.patch',
      ),
    );

    try {
      patchFile.writeAsStringSync(patchContent, flush: true);
      _runGit(
        ['apply', '--binary', '--whitespace=nowarn', patchFile.path],
        workingDirectory: packagePath,
        failureCode: 'patch.apply_failed',
        failureMessage: 'Could not apply patch to the package copy.',
        anchorToWorkingDirectory: true,
      );
    } finally {
      if (patchFile.existsSync()) {
        patchFile.deleteSync();
      }
    }
  }

  /// Applies as much of [patchContent] as Git can apply to [packagePath].
  ///
  /// Unlike [apply], this method keeps Git's `--reject` output as repair
  /// material instead of treating rejected hunks as an exception. Newly written
  /// `.rej` files are moved under `.patchwork/rejects/` so they stay out of
  /// future committed patch diffs.
  PartialPatchApply applyPartial({
    required String packagePath,
    required String patchContent,
  }) {
    final packageRoot = Directory(packagePath);
    if (!packageRoot.existsSync()) {
      throw PatchworkException(
        'Could not apply patch to a missing package copy.',
        code: 'patch.apply_missing_package',
        location: packagePath,
      );
    }

    final rejectFiles = RejectFileTransaction.capture(packagePath);
    final patchFile = File(
      p.join(
        Directory.systemTemp.path,
        'patchwork_partial_apply_$pid'
        '_${DateTime.now().microsecondsSinceEpoch}.patch',
      ),
    );

    try {
      patchFile.writeAsStringSync(patchContent, flush: true);
      final patchTouchedPaths = patchTouchedRelativePaths(patchContent)
        ..addAll(
          gitNumstatRelativePaths(
            _runGitAllowingRejects([
              'apply',
              '--numstat',
              '-z',
              patchFile.path,
            ], workingDirectory: packagePath),
          ),
        );
      final result = _runGitAllowingRejects([
        'apply',
        '--reject',
        '--binary',
        '--whitespace=nowarn',
        patchFile.path,
      ], workingDirectory: packagePath);
      final gitOutput = '${result.stderr}${result.stdout}'.replaceAll(
        '\r\n',
        '\n',
      );
      final normalizedOutput = normalizedGitOutput(
        gitOutput,
        workingDirectory: packagePath,
        patchPath: patchFile.path,
      );
      if (result.exitCode > 1) {
        throw PatchworkException(
          'Could not apply patch to the package copy.',
          code: 'patch.apply_failed',
          hint: normalizedOutput,
        );
      }
      final rejectPaths = gitRejectRelativePaths(gitOutput);
      final movedRejectPaths = rejectFiles.moveReported(
        rejectPaths: rejectPaths,
        patchTouchedPaths: patchTouchedPaths,
        failureHint: normalizedOutput,
      );
      return PartialPatchApply(
        exitCode: result.exitCode,
        output: normalizedOutput,
        rejectPaths: movedRejectPaths,
      );
    } finally {
      if (patchFile.existsSync()) {
        patchFile.deleteSync();
      }
    }
  }

  ProcessResult _runGit(
    List<String> arguments, {
    required String workingDirectory,
    required String failureCode,
    required String failureMessage,
    bool allowDifferenceExitCode = false,
    bool anchorToWorkingDirectory = false,
  }) {
    final ProcessResult result;
    try {
      result = _gitRunner(
        arguments,
        workingDirectory: workingDirectory,
        environment: anchorToWorkingDirectory
            ? _gitEnvironment(workingDirectory)
            : null,
      );
    } on ProcessException catch (error) {
      throw PatchworkException(
        'Git is required for patch operations.',
        code: 'patch.git_missing',
        hint: error.message,
      );
    }

    final acceptedExitCodes = allowDifferenceExitCode
        ? const {0, 1}
        : const {0};
    if (!acceptedExitCodes.contains(result.exitCode)) {
      throw PatchworkException(
        failureMessage,
        code: failureCode,
        hint: '${result.stderr}${result.stdout}'.trim(),
      );
    }
    return result;
  }

  ProcessResult _runGitAllowingRejects(
    List<String> arguments, {
    required String workingDirectory,
  }) {
    try {
      return _gitRunner(
        arguments,
        workingDirectory: workingDirectory,
        environment: _gitEnvironment(workingDirectory, forceCLocale: true),
      );
    } on ProcessException catch (error) {
      throw PatchworkException(
        'Git is required for patch operations.',
        code: 'patch.git_missing',
        hint: error.message,
      );
    }
  }
}

Map<String, String> _gitEnvironment(
  String workingDirectory, {
  bool forceCLocale = false,
}) {
  return {
    'GIT_CEILING_DIRECTORIES': p.dirname(
      p.normalize(p.absolute(workingDirectory)),
    ),
    if (forceCLocale) ...{'LC_ALL': 'C', 'LANG': 'C'},
  };
}

/// Result from a best-effort partial patch application.
final class PartialPatchApply {
  /// Creates a partial apply result.
  const PartialPatchApply({
    required this.exitCode,
    required this.output,
    required this.rejectPaths,
  });

  /// Exit code returned by `git apply --reject`.
  final int exitCode;

  /// Combined Git output with process-local paths removed.
  final String output;

  /// Reject files moved under `.patchwork/rejects/`, relative to the edit root.
  final List<String> rejectPaths;

  /// Whether Git applied the patch without rejected or failed hunks.
  bool get appliedCleanly => exitCode == 0 && rejectPaths.isEmpty;
}
