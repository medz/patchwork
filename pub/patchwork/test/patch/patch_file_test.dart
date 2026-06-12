import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:patchwork/src/patch/patch_file.dart';
import 'package:test/test.dart';

void main() {
  group('PatchFileBuilder', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('patchwork patch file ');
    });

    tearDown(() {
      if (root.existsSync()) {
        root.deleteSync(recursive: true);
      }
    });

    test('builds and validates a unified patch', () {
      final baselinePath = p.join(root.path, 'baseline');
      final editPath = p.join(root.path, 'edit');
      Directory(p.join(baselinePath, 'lib')).createSync(recursive: true);
      Directory(p.join(editPath, 'lib')).createSync(recursive: true);
      File(
        p.join(baselinePath, 'lib', 'file.dart'),
      ).writeAsStringSync('String value = "old";\n');
      File(
        p.join(editPath, 'lib', 'file.dart'),
      ).writeAsStringSync('String value = "new";\n');

      final buildResult = const PatchFileBuilder().build(
        baselinePath: baselinePath,
        editPath: editPath,
      );

      expect(buildResult.diagnostic, isNull);
      expect(buildResult.hasChanges, isTrue);
      expect(buildResult.content, contains('--- a/lib/file.dart'));
      expect(buildResult.content, contains('+++ b/lib/file.dart'));

      final validationResult = const PatchValidator().validate(
        baselinePath: baselinePath,
        patchContent: buildResult.content!,
      );
      expect(validationResult.diagnostic, isNull);
    });

    test('builds a patch for paths containing spaces', () {
      final baselinePath = p.join(root.path, 'baseline');
      final editPath = p.join(root.path, 'edit');
      Directory(p.join(baselinePath, 'lib folder')).createSync(recursive: true);
      Directory(p.join(editPath, 'lib folder')).createSync(recursive: true);
      File(
        p.join(baselinePath, 'lib folder', 'file name.dart'),
      ).writeAsStringSync('old\n');
      File(
        p.join(editPath, 'lib folder', 'file name.dart'),
      ).writeAsStringSync('new\n');

      final buildResult = const PatchFileBuilder().build(
        baselinePath: baselinePath,
        editPath: editPath,
      );

      expect(buildResult.diagnostic, isNull);
      expect(
        buildResult.content,
        contains('diff --git a/lib folder/file name.dart'),
      );
      expect(
        buildResult.content,
        contains('--- a/lib folder/file name.dart\t'),
      );

      final appliedPath = _applyPatch(
        root: root,
        baselinePath: baselinePath,
        patchContent: buildResult.content!,
      );
      expect(
        File(
          p.join(appliedPath, 'lib folder', 'file name.dart'),
        ).readAsStringSync(),
        'new\n',
      );
    });

    test('preserves empty file additions', () {
      final baselinePath = p.join(root.path, 'baseline');
      final editPath = p.join(root.path, 'edit');
      Directory(baselinePath).createSync(recursive: true);
      Directory(editPath).createSync(recursive: true);
      File(p.join(editPath, 'empty.txt')).createSync();

      final buildResult = const PatchFileBuilder().build(
        baselinePath: baselinePath,
        editPath: editPath,
      );

      expect(buildResult.diagnostic, isNull);
      expect(buildResult.hasChanges, isTrue);
      expect(buildResult.content, contains('new file mode 100644'));

      final appliedPath = _applyPatch(
        root: root,
        baselinePath: baselinePath,
        patchContent: buildResult.content!,
      );
      final emptyFile = File(p.join(appliedPath, 'empty.txt'));
      expect(emptyFile.existsSync(), isTrue);
      expect(emptyFile.lengthSync(), 0);
    });

    test('preserves empty file deletions', () {
      final baselinePath = p.join(root.path, 'baseline');
      final editPath = p.join(root.path, 'edit');
      Directory(baselinePath).createSync(recursive: true);
      Directory(editPath).createSync(recursive: true);
      File(p.join(baselinePath, 'empty.txt')).createSync();

      final buildResult = const PatchFileBuilder().build(
        baselinePath: baselinePath,
        editPath: editPath,
      );

      expect(buildResult.diagnostic, isNull);
      expect(buildResult.hasChanges, isTrue);
      expect(buildResult.content, contains('deleted file mode 100644'));

      final appliedPath = _applyPatch(
        root: root,
        baselinePath: baselinePath,
        patchContent: buildResult.content!,
      );
      expect(File(p.join(appliedPath, 'empty.txt')).existsSync(), isFalse);
    });
  });

  group('PatchValidator', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('patchwork patch validate ');
    });

    tearDown(() {
      if (root.existsSync()) {
        root.deleteSync(recursive: true);
      }
    });

    test('rejects a patch that cannot apply to the baseline', () {
      File(p.join(root.path, 'file.dart')).writeAsStringSync('old\n');

      final result = const PatchValidator().validate(
        baselinePath: root.path,
        patchContent: '''
--- a/file.dart
+++ b/file.dart
@@ -1 +1 @@
-missing
+new
''',
      );

      expect(result.diagnostic?.code, 'patch.validation_failed');
    });
  });
}

String _applyPatch({
  required Directory root,
  required String baselinePath,
  required String patchContent,
}) {
  final applyPath = p.join(root.path, 'apply');
  Directory(applyPath).createSync(recursive: true);
  _copyDirectoryContents(baselinePath, applyPath);
  final patchFile = File(p.join(root.path, 'candidate.patch'))
    ..writeAsStringSync(patchContent);
  final result = Process.runSync('git', [
    'apply',
    patchFile.path,
  ], workingDirectory: applyPath);
  expect(result.exitCode, 0, reason: '${result.stderr}${result.stdout}'.trim());
  return applyPath;
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
