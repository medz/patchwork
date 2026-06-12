import 'dart:io';

import 'package:path/path.dart' as p;

import '../diagnostics/diagnostic.dart';
import '../session/session_file_filter.dart';

final class PatchFileBuildResult {
  const PatchFileBuildResult._({this.content, this.diagnostic});

  factory PatchFileBuildResult.success(String content) {
    return PatchFileBuildResult._(content: content);
  }

  factory PatchFileBuildResult.noChanges() {
    return const PatchFileBuildResult._(content: '');
  }

  factory PatchFileBuildResult.failure(Diagnostic diagnostic) {
    return PatchFileBuildResult._(diagnostic: diagnostic);
  }

  final String? content;
  final Diagnostic? diagnostic;

  bool get isSuccess => diagnostic == null;

  bool get hasChanges => content != null && content!.isNotEmpty;
}

final class PatchValidationResult {
  const PatchValidationResult._({this.diagnostic});

  factory PatchValidationResult.success() {
    return const PatchValidationResult._();
  }

  factory PatchValidationResult.failure(Diagnostic diagnostic) {
    return PatchValidationResult._(diagnostic: diagnostic);
  }

  final Diagnostic? diagnostic;

  bool get isSuccess => diagnostic == null;
}

typedef GitProcessRunner = ProcessResult Function(List<String> arguments);

ProcessResult _defaultGitRunner(List<String> arguments) {
  return Process.runSync('git', arguments);
}

final class PatchFileBuilder {
  const PatchFileBuilder({GitProcessRunner? gitRunner})
    : _gitRunner = gitRunner ?? _defaultGitRunner;

  final GitProcessRunner _gitRunner;

  PatchFileBuildResult build({
    required String baselinePath,
    required String editPath,
  }) {
    final baselineRoot = Directory(baselinePath);
    final editRoot = Directory(editPath);
    if (!baselineRoot.existsSync() || !editRoot.existsSync()) {
      return PatchFileBuildResult.failure(
        const Diagnostic(
          code: 'patch.session_missing',
          message: 'Patch session baseline or edit directory is missing.',
        ),
      );
    }

    _DiffRoots? diffRoots;
    try {
      diffRoots = _DiffRoots.create(
        baselinePath: baselinePath,
        editPath: editPath,
      );
      final diffResult = _gitDiffDirectories(
        baselinePath: diffRoots.baselinePath,
        editPath: diffRoots.editPath,
      );
      final diffDiagnostic = diffResult.diagnostic;
      if (diffDiagnostic != null) {
        return PatchFileBuildResult.failure(diffDiagnostic);
      }

      final content = diffResult.content;
      if (content == null || content.isEmpty) {
        return PatchFileBuildResult.noChanges();
      }

      return PatchFileBuildResult.success(content);
    } on FileSystemException catch (error) {
      return PatchFileBuildResult.failure(
        Diagnostic(
          code: 'patch.diff_failed',
          message: 'Could not prepare a patch diff.',
          hint: error.message,
          location: error.path,
        ),
      );
    } finally {
      diffRoots?.deleteSync();
    }
  }

  _GitDiffResult _gitDiffDirectories({
    required String baselinePath,
    required String editPath,
  }) {
    final arguments = <String>[
      '-c',
      'core.safecrlf=false',
      'diff',
      '--no-ext-diff',
      '--no-color',
      '--no-textconv',
      '--src-prefix=a/',
      '--dst-prefix=b/',
      '--full-index',
      '--no-index',
      _gitArgumentPath(baselinePath),
      _gitArgumentPath(editPath),
    ];
    final ProcessResult result;
    try {
      result = _gitRunner(arguments);
    } on ProcessException catch (error) {
      return _GitDiffResult.failure(
        Diagnostic(
          code: 'patch.git_missing',
          message: 'Git is required to generate patch files.',
          hint: error.message,
        ),
      );
    }

    final stderr = '${result.stderr}'.trim();
    if (result.exitCode != 0 && result.exitCode != 1) {
      return _GitDiffResult.failure(
        Diagnostic(
          code: 'patch.diff_failed',
          message: 'Could not generate a patch diff.',
          hint: stderr,
        ),
      );
    }

    final output = '${result.stdout}';
    if (output.isEmpty) {
      if (stderr.isNotEmpty && result.exitCode != 0) {
        return _GitDiffResult.failure(
          Diagnostic(
            code: 'patch.diff_failed',
            message: 'Could not generate a patch diff.',
            hint: stderr,
          ),
        );
      }
      return const _GitDiffResult();
    }

    if (_containsBinaryDiff(output)) {
      return _GitDiffResult.failure(
        const Diagnostic(
          code: 'patch.unsupported_binary',
          message: 'Binary file changes are not supported yet.',
        ),
      );
    }

    final content = _postProcessGitDiff(
      output: output,
      baselinePath: baselinePath,
      editPath: editPath,
    );
    return _GitDiffResult(content: content);
  }
}

final class PatchValidator {
  const PatchValidator();

  PatchValidationResult validate({
    required String baselinePath,
    required String patchContent,
  }) {
    final validationRoot = Directory.systemTemp.createTempSync(
      'patchwork_patch_validate_',
    );

    try {
      _copyDirectoryContents(baselinePath, validationRoot.path);
      final patchFile = File(p.join(validationRoot.path, '.patchwork.patch'));
      patchFile.writeAsStringSync(patchContent);
      final ProcessResult result;
      try {
        result = Process.runSync('git', [
          'apply',
          '--check',
          '--whitespace=nowarn',
          patchFile.path,
        ], workingDirectory: validationRoot.path);
      } on ProcessException catch (error) {
        return PatchValidationResult.failure(
          Diagnostic(
            code: 'patch.git_missing',
            message: 'Git is required to validate patch files.',
            hint: error.message,
          ),
        );
      }
      if (result.exitCode == 0) {
        return PatchValidationResult.success();
      }

      return PatchValidationResult.failure(
        Diagnostic(
          code: 'patch.validation_failed',
          message: 'Generated patch did not apply to a fresh baseline.',
          hint: '${result.stderr}${result.stdout}'.trim(),
        ),
      );
    } on FileSystemException catch (error) {
      return PatchValidationResult.failure(
        Diagnostic(
          code: 'patch.validation_failed',
          message: 'Generated patch could not be validated.',
          hint: error.message,
          location: error.path,
        ),
      );
    } finally {
      if (validationRoot.existsSync()) {
        validationRoot.deleteSync(recursive: true);
      }
    }
  }
}

final class _DiffRoots {
  _DiffRoots._({
    required this.root,
    required this.baselinePath,
    required this.editPath,
  });

  factory _DiffRoots.create({
    required String baselinePath,
    required String editPath,
  }) {
    final root = Directory.systemTemp.createTempSync('patchwork_patch_diff_');
    final baselineSnapshotPath = p.join(root.path, 'baseline');
    final editSnapshotPath = p.join(root.path, 'edit');
    Directory(baselineSnapshotPath).createSync();
    Directory(editSnapshotPath).createSync();
    _copyDirectoryContents(
      baselinePath,
      baselineSnapshotPath,
      excludePatchSessionState: true,
    );
    _copyDirectoryContents(
      editPath,
      editSnapshotPath,
      excludePatchSessionState: true,
    );
    return _DiffRoots._(
      root: root,
      baselinePath: baselineSnapshotPath,
      editPath: editSnapshotPath,
    );
  }

  final Directory root;
  final String baselinePath;
  final String editPath;

  void deleteSync() {
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  }
}

final class _GitDiffResult {
  const _GitDiffResult({this.content, this.diagnostic});

  factory _GitDiffResult.failure(Diagnostic diagnostic) {
    return _GitDiffResult(diagnostic: diagnostic);
  }

  final String? content;
  final Diagnostic? diagnostic;
}

void _copyDirectoryContents(
  String sourcePath,
  String destinationPath, {
  String? sourceRootPath,
  bool excludePatchSessionState = false,
}) {
  final rootPath = sourceRootPath ?? sourcePath;
  for (final entity in Directory(sourcePath).listSync(followLinks: false)) {
    final targetPath = p.join(destinationPath, p.basename(entity.path));
    final type = FileSystemEntity.typeSync(entity.path, followLinks: false);
    final relativePath = _patchPath(p.relative(entity.path, from: rootPath));
    if (excludePatchSessionState &&
        shouldExcludePatchSessionPath(relativePath, type)) {
      continue;
    }

    switch (type) {
      case FileSystemEntityType.directory:
        Directory(targetPath).createSync(recursive: true);
        _copyDirectoryContents(
          entity.path,
          targetPath,
          sourceRootPath: rootPath,
          excludePatchSessionState: excludePatchSessionState,
        );
      case FileSystemEntityType.file:
        File(entity.path).copySync(targetPath);
      case FileSystemEntityType.link:
        Link(targetPath).createSync(Link(entity.path).targetSync());
      case FileSystemEntityType.notFound:
      case FileSystemEntityType.pipe:
      case FileSystemEntityType.unixDomainSock:
        break;
    }
  }
}

String _patchPath(String relativePath) {
  return p.split(relativePath).join('/');
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
  required String baselinePath,
  required String editPath,
}) {
  final oldPrefix = _gitDiffPathPrefix(baselinePath);
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
    buffer.write(processed);
    buffer.write('\n');
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
  return result;
}

bool _containsBinaryDiff(String output) {
  return output
      .split('\n')
      .any(
        (line) => line.startsWith('Binary files ') && line.endsWith(' differ'),
      );
}
