import 'dart:io';

import 'package:path/path.dart' as p;

import 'error.dart';
import 'internal/package_tree.dart';

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
          _gitArgumentPath(sourceSnapshotPath),
          _gitArgumentPath(editSnapshotPath),
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
      return _postProcessGitDiff(
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

    final existingRejects = _rejectRelativePaths(packagePath).toSet();
    final patchFile = File(
      p.join(
        Directory.systemTemp.path,
        'patchwork_partial_apply_$pid'
        '_${DateTime.now().microsecondsSinceEpoch}.patch',
      ),
    );

    try {
      patchFile.writeAsStringSync(patchContent, flush: true);
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
      final rejectPaths = _moveNewRejectFiles(
        packagePath: packagePath,
        existingRejects: existingRejects,
        rejectPaths: _gitRejectRelativePaths(gitOutput),
      );
      return PartialPatchApply(
        exitCode: result.exitCode,
        output: _normalizedGitOutput(
          gitOutput,
          workingDirectory: packagePath,
          patchPath: patchFile.path,
        ),
        rejectPaths: rejectPaths,
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
            ? {
                'GIT_CEILING_DIRECTORIES': p.dirname(
                  p.normalize(p.absolute(workingDirectory)),
                ),
              }
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
        environment: {
          'GIT_CEILING_DIRECTORIES': p.dirname(
            p.normalize(p.absolute(workingDirectory)),
          ),
        },
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

String _gitArgumentPath(String path) {
  return p.absolute(path).replaceAll('\\', '/');
}

String _normalizedGitOutput(
  String output, {
  required String workingDirectory,
  required String patchPath,
}) {
  return output
      .replaceAll(_gitArgumentPath(patchPath), '<patch>')
      .replaceAll(patchPath, '<patch>')
      .replaceAll(_gitArgumentPath(workingDirectory), '.')
      .replaceAll(workingDirectory, '.')
      .trim();
}

List<String> _rejectRelativePaths(String packagePath) {
  final root = Directory(packagePath);
  if (!root.existsSync()) {
    return const [];
  }
  final paths = <String>[];
  void collect(Directory directory) {
    for (final entity in directory.listSync(followLinks: false)) {
      final relativePath = p.split(p.relative(entity.path, from: packagePath));
      if (relativePath.isNotEmpty && relativePath.first == '.patchwork') {
        continue;
      }
      final type = FileSystemEntity.typeSync(entity.path, followLinks: false);
      if (type == FileSystemEntityType.directory) {
        collect(Directory(entity.path));
      } else if (type == FileSystemEntityType.file &&
          entity.path.endsWith('.rej')) {
        paths.add(relativePath.join('/'));
      }
    }
  }

  collect(root);
  paths.sort();
  return paths;
}

Set<String> _gitRejectRelativePaths(String output) {
  final paths = <String>{};
  final rejectLine = RegExp(
    r'^Applying patch (.+) with [0-9]+ rejects?\.\.\.$',
  );
  for (final line in output.split('\n')) {
    final match = rejectLine.firstMatch(line.trimRight());
    if (match == null) {
      continue;
    }
    paths.add('${match.group(1)!}.rej');
  }
  return paths;
}

List<String> _moveNewRejectFiles({
  required String packagePath,
  required Set<String> existingRejects,
  required Set<String> rejectPaths,
}) {
  final movedPaths = <String>[];
  for (final relativePath in rejectPaths) {
    if (existingRejects.contains(relativePath)) {
      continue;
    }
    final source = File(p.joinAll([packagePath, ...relativePath.split('/')]));
    if (!source.existsSync()) {
      continue;
    }
    final movedRelativePath = p
        .joinAll(['.patchwork', 'rejects', ...relativePath.split('/')])
        .replaceAll('\\', '/');
    final destination = File(
      p.joinAll([packagePath, ...movedRelativePath.split('/')]),
    );
    destination.parent.createSync(recursive: true);
    if (destination.existsSync()) {
      destination.deleteSync();
    }
    source.renameSync(destination.path);
    movedPaths.add(movedRelativePath);
  }
  movedPaths.sort();
  return movedPaths;
}

String _gitDiffPathPrefix(String path) {
  final normalized = _gitArgumentPath(path);
  if (normalized.startsWith('/')) {
    return normalized.substring(1);
  }
  return normalized;
}

String _postProcessGitDiff({
  required String output,
  required String sourcePath,
  required String editPath,
}) {
  final oldPrefix = _gitDiffPathPrefix(sourcePath);
  final newPrefix = _gitDiffPathPrefix(editPath);
  final hasTrailingNewline = output.endsWith('\n');
  final lines = output.split('\n');
  if (hasTrailingNewline) {
    lines.removeLast();
  }

  final buffer = StringBuffer();
  for (final line in lines) {
    final processed = _shouldRewriteGitDiffLine(line)
        ? _stripGitDiffRootPrefixes(line, oldPrefix, newPrefix)
        : line;
    buffer
      ..write(processed)
      ..write('\n');
  }

  if (!hasTrailingNewline && buffer.length > 0) {
    final content = buffer.toString();
    return content.substring(0, content.length - 1);
  }
  return buffer.toString();
}

bool _shouldRewriteGitDiffLine(String line) {
  if (line.isEmpty) {
    return false;
  }

  final first = line.codeUnitAt(0);
  if (first == 0x20) {
    return false;
  }
  if (first == 0x2d && !line.startsWith('--- ')) {
    return false;
  }
  if (first == 0x2b && !line.startsWith('+++ ')) {
    return false;
  }
  return true;
}

String _stripGitDiffRootPrefixes(
  String line,
  String oldPrefix,
  String newPrefix,
) {
  var result = line;
  for (final side in const ['a', 'b']) {
    result = result.replaceAll('$side/$oldPrefix/', '$side/');
    result = result.replaceAll('$side/$newPrefix/', '$side/');
  }
  result = result.replaceAll('$oldPrefix/', '');
  result = result.replaceAll('$newPrefix/', '');
  return _stripMetadataLeadingSlash(result);
}

String _stripMetadataLeadingSlash(String line) {
  const prefixes = ['rename from ', 'rename to ', 'copy from ', 'copy to '];
  for (final prefix in prefixes) {
    if (line.startsWith('$prefix/')) {
      return '$prefix${line.substring(prefix.length + 1)}';
    }
    if (line.startsWith('$prefix"/')) {
      return '$prefix"${line.substring(prefix.length + 2)}';
    }
  }
  return line;
}
