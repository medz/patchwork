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

final class PatchApplyResult {
  const PatchApplyResult._({this.diagnostic});

  factory PatchApplyResult.success() {
    return const PatchApplyResult._();
  }

  factory PatchApplyResult.failure(Diagnostic diagnostic) {
    return PatchApplyResult._(diagnostic: diagnostic);
  }

  final Diagnostic? diagnostic;

  bool get isSuccess => diagnostic == null;
}

typedef GitProcessRunner =
    ProcessResult Function(List<String> arguments, {String? workingDirectory});

ProcessResult _defaultGitRunner(
  List<String> arguments, {
  String? workingDirectory,
}) {
  return Process.runSync('git', arguments, workingDirectory: workingDirectory);
}

final class PatchFileBuilder {
  const PatchFileBuilder({
    GitProcessRunner? gitRunner,
    String? workingDirectory,
  }) : this._(gitRunner: gitRunner, workingDirectory: workingDirectory);

  const PatchFileBuilder._({
    GitProcessRunner? gitRunner,
    this._workingDirectory,
  }) : _gitRunner = gitRunner ?? _defaultGitRunner;

  final GitProcessRunner _gitRunner;
  final String? _workingDirectory;

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
      final diffMode = _selectGitDiffMode(
        baselinePath: diffRoots.baselinePath,
        editPath: diffRoots.editPath,
      );
      final diffResult = _gitDiffDirectories(
        baselinePath: diffRoots.baselinePath,
        editPath: diffRoots.editPath,
        mode: diffMode,
        workingDirectory: _workingDirectory ?? diffRoots.root.path,
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
    required _GitDiffMode mode,
    required String workingDirectory,
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
      if (mode == _GitDiffMode.text) '--text' else '--binary',
      '--no-index',
      _gitArgumentPath(baselinePath),
      _gitArgumentPath(editPath),
    ];
    final ProcessResult result;
    try {
      result = _gitRunner(arguments, workingDirectory: workingDirectory);
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
    final validationTempRoot = Directory.systemTemp.createTempSync(
      'patchwork_patch_validate_',
    );
    final validationRoot = Directory(p.join(validationTempRoot.path, 'root'));
    File? patchFile;

    try {
      validationRoot.createSync();
      _copyDirectoryContents(baselinePath, validationRoot.path);
      patchFile = File(p.join(validationTempRoot.path, 'patch.patch'));
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
      if (validationTempRoot.existsSync()) {
        validationTempRoot.deleteSync(recursive: true);
      }
    }
  }
}

final class PatchApplier {
  const PatchApplier();

  PatchApplyResult apply({
    required String packagePath,
    required String patchContent,
  }) {
    final packageRoot = Directory(packagePath);
    if (!packageRoot.existsSync()) {
      return PatchApplyResult.failure(
        Diagnostic(
          code: 'patch.apply_failed',
          message: 'Could not apply patch to a missing package copy.',
          location: packagePath,
        ),
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
      final ProcessResult result;
      try {
        result = Process.runSync('git', [
          'apply',
          '--binary',
          '--whitespace=nowarn',
          patchFile.path,
        ], workingDirectory: packagePath);
      } on ProcessException catch (error) {
        return PatchApplyResult.failure(
          Diagnostic(
            code: 'patch.git_missing',
            message: 'Git is required to apply patch files.',
            hint: error.message,
          ),
        );
      }

      if (result.exitCode == 0) {
        return PatchApplyResult.success();
      }

      return PatchApplyResult.failure(
        Diagnostic(
          code: 'patch.apply_failed',
          message: 'Could not apply patch to the generated package copy.',
          hint: '${result.stderr}${result.stdout}'.trim(),
          location: packagePath,
        ),
      );
    } on FileSystemException catch (error) {
      return PatchApplyResult.failure(
        Diagnostic(
          code: 'patch.apply_failed',
          message: 'Could not prepare a patch apply operation.',
          hint: error.message,
          location: error.path,
        ),
      );
    } finally {
      if (patchFile.existsSync()) {
        patchFile.deleteSync();
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

enum _GitDiffMode { text, binary }

_GitDiffMode _selectGitDiffMode({
  required String baselinePath,
  required String editPath,
}) {
  if (_hasChangedBinaryFile(baselinePath: baselinePath, editPath: editPath)) {
    return _GitDiffMode.binary;
  }
  return _GitDiffMode.text;
}

bool _hasChangedBinaryFile({
  required String baselinePath,
  required String editPath,
}) {
  final baselineEntries = _collectPatchEntries(baselinePath);
  final editEntries = _collectPatchEntries(editPath);
  final paths = {...baselineEntries.keys, ...editEntries.keys}.toList()..sort();

  for (final relativePath in paths) {
    final baselineType =
        baselineEntries[relativePath] ?? FileSystemEntityType.notFound;
    final editType = editEntries[relativePath] ?? FileSystemEntityType.notFound;
    if (!_entryChanged(
      relativePath: relativePath,
      baselinePath: baselinePath,
      baselineType: baselineType,
      editPath: editPath,
      editType: editType,
    )) {
      continue;
    }

    if (baselineType == FileSystemEntityType.file &&
        _looksBinaryFile(_joinPatchPath(baselinePath, relativePath))) {
      return true;
    }
    if (editType == FileSystemEntityType.file &&
        _looksBinaryFile(_joinPatchPath(editPath, relativePath))) {
      return true;
    }
  }

  return false;
}

Map<String, FileSystemEntityType> _collectPatchEntries(String rootPath) {
  final entries = <String, FileSystemEntityType>{};

  void collect(String path) {
    for (final entity in Directory(path).listSync(followLinks: false)) {
      final relativePath = _patchPath(p.relative(entity.path, from: rootPath));
      final type = FileSystemEntity.typeSync(entity.path, followLinks: false);
      entries[relativePath] = type;
      if (type == FileSystemEntityType.directory) {
        collect(entity.path);
      }
    }
  }

  collect(rootPath);
  return entries;
}

bool _entryChanged({
  required String relativePath,
  required String baselinePath,
  required FileSystemEntityType baselineType,
  required String editPath,
  required FileSystemEntityType editType,
}) {
  if (baselineType != editType) {
    return true;
  }

  switch (baselineType) {
    case FileSystemEntityType.file:
      return !_filesHaveSameBytes(
        _joinPatchPath(baselinePath, relativePath),
        _joinPatchPath(editPath, relativePath),
      );
    case FileSystemEntityType.link:
      return Link(_joinPatchPath(baselinePath, relativePath)).targetSync() !=
          Link(_joinPatchPath(editPath, relativePath)).targetSync();
    case FileSystemEntityType.directory:
    case FileSystemEntityType.notFound:
    case FileSystemEntityType.pipe:
    case FileSystemEntityType.unixDomainSock:
      return false;
  }

  return false;
}

String _joinPatchPath(String rootPath, String relativePath) {
  return p.joinAll([rootPath, ...relativePath.split('/')]);
}

bool _looksBinaryFile(String path) {
  const probeByteCount = 8000;
  final file = File(path).openSync();
  try {
    final length = file.lengthSync();
    final count = length < probeByteCount ? length : probeByteCount;
    return file.readSync(count).contains(0);
  } finally {
    file.closeSync();
  }
}

bool _filesHaveSameBytes(String leftPath, String rightPath) {
  const chunkSize = 8192;
  final leftFile = File(leftPath);
  final rightFile = File(rightPath);
  if (leftFile.lengthSync() != rightFile.lengthSync()) {
    return false;
  }

  final left = leftFile.openSync();
  final right = rightFile.openSync();
  try {
    while (true) {
      final leftChunk = left.readSync(chunkSize);
      final rightChunk = right.readSync(chunkSize);
      if (leftChunk.length != rightChunk.length) {
        return false;
      }
      for (var i = 0; i < leftChunk.length; i += 1) {
        if (leftChunk[i] != rightChunk[i]) {
          return false;
        }
      }
      if (leftChunk.length < chunkSize) {
        return true;
      }
    }
  } finally {
    left.closeSync();
    right.closeSync();
  }
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
  result = _stripMetadataLeadingSlash(result);
  return result;
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

bool _containsBinaryDiff(String output) {
  return output
      .split('\n')
      .any(
        (line) => line.startsWith('Binary files ') && line.endsWith(' differ'),
      );
}
