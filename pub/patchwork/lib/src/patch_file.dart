import 'dart:io';

import 'package:path/path.dart' as p;

import 'error.dart';
import 'internal/package_tree.dart';

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

final class PatchFile {
  const PatchFile({GitProcessRunner? gitRunner, PackageTree? packageTree})
    : _gitRunner = gitRunner ?? _defaultGitRunner,
      _packageTree = packageTree ?? const PackageTree();

  final GitProcessRunner _gitRunner;
  final PackageTree _packageTree;

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
}

String _gitArgumentPath(String path) {
  return p.absolute(path).replaceAll('\\', '/');
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
