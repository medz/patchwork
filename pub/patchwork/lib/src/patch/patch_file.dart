import 'dart:io';

import 'package:path/path.dart' as p;

import '../diagnostics/diagnostic.dart';

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

final class PatchFileBuilder {
  const PatchFileBuilder();

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

    final baselineEntries = _collectEntries(baselinePath);
    final editEntries = _collectEntries(editPath);
    final allPaths = {...baselineEntries.keys, ...editEntries.keys}.toList()
      ..sort();
    final buffer = StringBuffer();

    for (final relativePath in allPaths) {
      final baselineType = baselineEntries[relativePath];
      final editType = editEntries[relativePath];
      if (baselineType == FileSystemEntityType.link ||
          editType == FileSystemEntityType.link) {
        return PatchFileBuildResult.failure(
          Diagnostic(
            code: 'patch.unsupported_link',
            message: 'Symlink changes are not supported yet.',
            location: relativePath,
          ),
        );
      }

      if (baselineType == FileSystemEntityType.directory ||
          editType == FileSystemEntityType.directory) {
        continue;
      }

      final diffResult = _diffPath(
        relativePath: relativePath,
        baselinePath: baselinePath,
        editPath: editPath,
        baselineExists: baselineType == FileSystemEntityType.file,
        editExists: editType == FileSystemEntityType.file,
      );
      final diagnostic = diffResult.diagnostic;
      if (diagnostic != null) {
        return PatchFileBuildResult.failure(diagnostic);
      }

      final content = diffResult.content;
      if (content != null && content.isNotEmpty) {
        buffer.write(content);
        if (!content.endsWith('\n')) {
          buffer.writeln();
        }
      }
    }

    if (buffer.isEmpty) {
      return PatchFileBuildResult.noChanges();
    }

    return PatchFileBuildResult.success(buffer.toString());
  }

  Map<String, FileSystemEntityType> _collectEntries(String rootPath) {
    final entries = <String, FileSystemEntityType>{};
    for (final entity in Directory(
      rootPath,
    ).listSync(recursive: true, followLinks: false)) {
      final relativePath = _patchPath(p.relative(entity.path, from: rootPath));
      entries[relativePath] = FileSystemEntity.typeSync(
        entity.path,
        followLinks: false,
      );
    }
    return entries;
  }

  _PathDiffResult _diffPath({
    required String relativePath,
    required String baselinePath,
    required String editPath,
    required bool baselineExists,
    required bool editExists,
  }) {
    final baselineFilePath = p.joinAll([
      baselinePath,
      ...relativePath.split('/'),
    ]);
    final editFilePath = p.joinAll([editPath, ...relativePath.split('/')]);
    final arguments = <String>[
      '-u',
      '--label',
      baselineExists ? 'a/$relativePath' : '/dev/null',
      '--label',
      editExists ? 'b/$relativePath' : '/dev/null',
      baselineExists ? baselineFilePath : '/dev/null',
      editExists ? editFilePath : '/dev/null',
    ];
    final result = Process.runSync('diff', arguments);

    if (result.exitCode == 0) {
      return const _PathDiffResult();
    }

    if (result.exitCode != 1) {
      return _PathDiffResult.failure(
        Diagnostic(
          code: 'patch.diff_failed',
          message: 'Could not generate a patch diff.',
          hint: '${result.stderr}',
          location: relativePath,
        ),
      );
    }

    final output = '${result.stdout}';
    if (!output.startsWith('--- ')) {
      return _PathDiffResult.failure(
        Diagnostic(
          code: 'patch.unsupported_binary',
          message: 'Binary file changes are not supported yet.',
          location: relativePath,
        ),
      );
    }

    return _PathDiffResult(content: output);
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
      final result = Process.runSync('patch', [
        '--dry-run',
        '-p1',
        '-i',
        patchFile.path,
      ], workingDirectory: validationRoot.path);
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

  void _copyDirectoryContents(String sourcePath, String destinationPath) {
    for (final entity in Directory(sourcePath).listSync(followLinks: false)) {
      final targetPath = p.join(destinationPath, p.basename(entity.path));
      final type = FileSystemEntity.typeSync(entity.path, followLinks: false);
      switch (type) {
        case FileSystemEntityType.directory:
          Directory(targetPath).createSync(recursive: true);
          _copyDirectoryContents(entity.path, targetPath);
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
}

final class _PathDiffResult {
  const _PathDiffResult({this.content, this.diagnostic});

  factory _PathDiffResult.failure(Diagnostic diagnostic) {
    return _PathDiffResult(diagnostic: diagnostic);
  }

  final String? content;
  final Diagnostic? diagnostic;
}

String _patchPath(String relativePath) {
  return p.split(relativePath).join('/');
}
