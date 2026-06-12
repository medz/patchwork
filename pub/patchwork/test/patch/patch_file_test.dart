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

    test('preserves non-empty file deletions', () {
      final baselinePath = p.join(root.path, 'baseline');
      final editPath = p.join(root.path, 'edit');
      Directory(baselinePath).createSync(recursive: true);
      Directory(editPath).createSync(recursive: true);
      File(p.join(baselinePath, 'dead.txt')).writeAsStringSync('remove me\n');

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
      expect(File(p.join(appliedPath, 'dead.txt')).existsSync(), isFalse);
    });

    test('excludes generated session state from the patch', () {
      final baselinePath = p.join(root.path, 'baseline');
      final editPath = p.join(root.path, 'edit');
      Directory(p.join(baselinePath, 'lib')).createSync(recursive: true);
      Directory(p.join(editPath, 'lib')).createSync(recursive: true);
      File(p.join(baselinePath, 'lib', 'file.dart')).writeAsStringSync('old\n');
      File(p.join(editPath, 'lib', 'file.dart')).writeAsStringSync('new\n');
      Directory(p.join(editPath, '.dart_tool')).createSync();
      Directory(p.join(editPath, 'build')).createSync();
      File(
        p.join(editPath, '.dart_tool', 'package_config.json'),
      ).writeAsStringSync('{}\n');
      File(
        p.join(editPath, 'build', 'generated.txt'),
      ).writeAsStringSync('gen\n');
      File(p.join(editPath, '.packages')).writeAsStringSync('legacy\n');
      File(p.join(editPath, 'pubspec.lock')).writeAsStringSync('lock\n');

      final buildResult = const PatchFileBuilder().build(
        baselinePath: baselinePath,
        editPath: editPath,
      );

      expect(buildResult.diagnostic, isNull);
      expect(buildResult.hasChanges, isTrue);
      expect(buildResult.content, contains('diff --git a/lib/file.dart'));
      expect(buildResult.content, isNot(contains('.dart_tool')));
      expect(buildResult.content, isNot(contains('build/generated.txt')));
      expect(buildResult.content, isNot(contains('.packages')));
      expect(buildResult.content, isNot(contains('pubspec.lock')));
    });

    test('preserves CRLF-only line ending changes', () {
      final roots = _PatchRootPair(root);
      File(
        p.join(roots.baselinePath, 'file.txt'),
      ).writeAsBytesSync([0x6c, 0x69, 0x6e, 0x65, 0x0a]);
      File(
        p.join(roots.editPath, 'file.txt'),
      ).writeAsBytesSync([0x6c, 0x69, 0x6e, 0x65, 0x0d, 0x0a]);

      final buildResult = roots.build();

      expect(buildResult.diagnostic, isNull);
      expect(buildResult.hasChanges, isTrue);

      final appliedPath = roots.apply(root: root, buildResult: buildResult);
      expect(File(p.join(appliedPath, 'file.txt')).readAsBytesSync(), [
        0x6c,
        0x69,
        0x6e,
        0x65,
        0x0d,
        0x0a,
      ]);
    });

    test('preserves file renames', () {
      final roots = _PatchRootPair(root);
      File(p.join(roots.baselinePath, 'old.txt')).writeAsStringSync('same\n');
      File(p.join(roots.editPath, 'new.txt')).writeAsStringSync('same\n');

      final buildResult = roots.build();

      expect(buildResult.diagnostic, isNull);
      expect(buildResult.hasChanges, isTrue);
      expect(buildResult.content, contains('rename from old.txt'));
      expect(buildResult.content, contains('rename to new.txt'));

      final appliedPath = roots.apply(root: root, buildResult: buildResult);
      expect(File(p.join(appliedPath, 'old.txt')).existsSync(), isFalse);
      expect(File(p.join(appliedPath, 'new.txt')).readAsStringSync(), 'same\n');
    });

    test('preserves quoted file renames', () {
      final roots = _PatchRootPair(root);
      File(
        p.join(roots.baselinePath, 'old\tname.txt'),
      ).writeAsStringSync('same\n');
      File(p.join(roots.editPath, 'new\tname.txt')).writeAsStringSync('same\n');

      final buildResult = roots.build();

      expect(buildResult.diagnostic, isNull);
      expect(buildResult.hasChanges, isTrue);
      expect(buildResult.content, contains(r'rename from "old\tname.txt"'));
      expect(buildResult.content, contains(r'rename to "new\tname.txt"'));

      final appliedPath = roots.apply(root: root, buildResult: buildResult);
      expect(File(p.join(appliedPath, 'old\tname.txt')).existsSync(), isFalse);
      expect(
        File(p.join(appliedPath, 'new\tname.txt')).readAsStringSync(),
        'same\n',
      );
    });

    test('ignores configured external diff drivers', () {
      final roots = _PatchRootPair(root);
      File(p.join(roots.baselinePath, 'file.txt')).writeAsStringSync('old\n');
      File(p.join(roots.editPath, 'file.txt')).writeAsStringSync('new\n');

      _withLocalGitConfig(root, {'diff.external': 'echo EXTERNAL'}, () {
        final buildResult = roots.build();

        expect(buildResult.diagnostic, isNull);
        expect(buildResult.content, contains('diff --git a/file.txt'));
        expect(buildResult.content, isNot(contains('EXTERNAL')));
      });
    });

    test('disables configured colored diff output', () {
      final roots = _PatchRootPair(root);
      File(p.join(roots.baselinePath, 'file.txt')).writeAsStringSync('old\n');
      File(p.join(roots.editPath, 'file.txt')).writeAsStringSync('new\n');

      _withLocalGitConfig(root, {'color.ui': 'always'}, () {
        final buildResult = roots.build();

        expect(buildResult.diagnostic, isNull);
        expect(buildResult.content, contains('diff --git a/file.txt'));
        expect(buildResult.content, isNot(contains('\x1B[')));
      });
    });

    test(
      'disables configured textconv filters',
      () {
        final roots = _PatchRootPair(root);
        File(p.join(roots.baselinePath, 'file.txt')).writeAsStringSync('old\n');
        File(p.join(roots.editPath, 'file.txt')).writeAsStringSync('new\n');
        final textconvRoot = Directory.systemTemp.createTempSync(
          'patchwork_textconv_',
        );
        addTearDown(() {
          if (textconvRoot.existsSync()) {
            textconvRoot.deleteSync(recursive: true);
          }
        });
        final textconvPath = p.join(textconvRoot.path, 'upcase.sh');
        File(
          textconvPath,
        ).writeAsStringSync('#!/bin/sh\ntr "[:lower:]" "[:upper:]" < "\$1"\n');
        final chmodResult = Process.runSync('chmod', ['+x', textconvPath]);
        expect(
          chmodResult.exitCode,
          0,
          reason: '${chmodResult.stderr}${chmodResult.stdout}'.trim(),
        );
        final attributesPath = p.join(textconvRoot.path, 'attributes');
        File(attributesPath).writeAsStringSync('*.txt diff=upper\n');

        _withLocalGitConfig(
          root,
          {
            'core.attributesFile': attributesPath,
            'diff.upper.textconv': textconvPath,
          },
          () {
            final buildResult = roots.build();

            expect(buildResult.diagnostic, isNull);
            expect(buildResult.content, contains('-old'));
            expect(buildResult.content, contains('+new'));
            expect(buildResult.content, isNot(contains('-OLD')));
            expect(buildResult.content, isNot(contains('+NEW')));
          },
        );
      },
      skip: Platform.isWindows
          ? 'Textconv fixture uses a POSIX shell script.'
          : false,
    );

    test('treats text files as text despite binary diff attributes', () {
      final roots = _PatchRootPair(root);
      File(p.join(roots.baselinePath, 'file.txt')).writeAsStringSync('old\n');
      File(p.join(roots.editPath, 'file.txt')).writeAsStringSync('new\n');
      final attributesPath = p.join(root.path, 'attributes');
      File(attributesPath).writeAsStringSync('*.txt binary\n');

      _withLocalGitConfig(root, {'core.attributesFile': attributesPath}, () {
        final buildResult = roots.build();

        expect(buildResult.diagnostic, isNull);
        expect(buildResult.content, contains('diff --git a/file.txt'));
        expect(buildResult.content, contains('-old'));
        expect(buildResult.content, contains('+new'));
        expect(buildResult.content, isNot(contains('Binary files')));
      });
    });

    test('preserves binary file changes with git binary patches', () {
      final roots = _PatchRootPair(root);
      File(
        p.join(roots.baselinePath, 'asset.bin'),
      ).writeAsBytesSync([0x00, 0x01, 0x02]);
      File(
        p.join(roots.editPath, 'asset.bin'),
      ).writeAsBytesSync([0x00, 0x09, 0x02]);

      final buildResult = roots.build();

      expect(buildResult.diagnostic, isNull);
      expect(buildResult.content, contains('GIT binary patch'));

      final appliedPath = roots.apply(root: root, buildResult: buildResult);
      expect(File(p.join(appliedPath, 'asset.bin')).readAsBytesSync(), [
        0x00,
        0x09,
        0x02,
      ]);
    });

    test('preserves mixed text and binary file changes', () {
      final roots = _PatchRootPair(root);
      File(
        p.join(roots.baselinePath, 'asset.bin'),
      ).writeAsBytesSync([0x00, 0x01, 0x02]);
      File(
        p.join(roots.editPath, 'asset.bin'),
      ).writeAsBytesSync([0x00, 0x09, 0x02]);
      File(p.join(roots.baselinePath, 'file.txt')).writeAsStringSync('old\n');
      File(p.join(roots.editPath, 'file.txt')).writeAsStringSync('new\n');

      final buildResult = roots.build();

      expect(buildResult.diagnostic, isNull);
      expect(buildResult.content, contains('GIT binary patch'));
      expect(buildResult.content, contains('diff --git a/file.txt'));
      expect(buildResult.content, contains('-old'));
      expect(buildResult.content, contains('+new'));

      final appliedPath = roots.apply(root: root, buildResult: buildResult);
      expect(File(p.join(appliedPath, 'asset.bin')).readAsBytesSync(), [
        0x00,
        0x09,
        0x02,
      ]);
      expect(File(p.join(appliedPath, 'file.txt')).readAsStringSync(), 'new\n');
    });

    test('preserves binary file additions and deletions', () {
      final roots = _PatchRootPair(root);
      File(
        p.join(roots.baselinePath, 'deleted.bin'),
      ).writeAsBytesSync([0x00, 0x01, 0x02]);
      File(
        p.join(roots.editPath, 'added.bin'),
      ).writeAsBytesSync([0x00, 0x09, 0x02]);

      final buildResult = roots.build();

      expect(buildResult.diagnostic, isNull);
      expect(buildResult.content, contains('GIT binary patch'));
      expect(buildResult.content, contains('deleted file mode 100644'));
      expect(buildResult.content, contains('new file mode 100644'));

      final appliedPath = roots.apply(root: root, buildResult: buildResult);
      expect(File(p.join(appliedPath, 'deleted.bin')).existsSync(), isFalse);
      expect(File(p.join(appliedPath, 'added.bin')).readAsBytesSync(), [
        0x00,
        0x09,
        0x02,
      ]);
    });

    test('allows unchanged binary files while building text patches', () {
      final roots = _PatchRootPair(root);
      File(
        p.join(roots.baselinePath, 'asset.bin'),
      ).writeAsBytesSync([0x00, 0x01, 0x02]);
      File(
        p.join(roots.editPath, 'asset.bin'),
      ).writeAsBytesSync([0x00, 0x01, 0x02]);
      File(p.join(roots.baselinePath, 'file.txt')).writeAsStringSync('old\n');
      File(p.join(roots.editPath, 'file.txt')).writeAsStringSync('new\n');

      final buildResult = roots.build();

      expect(buildResult.diagnostic, isNull);
      expect(buildResult.content, contains('diff --git a/file.txt'));

      final appliedPath = roots.apply(root: root, buildResult: buildResult);
      expect(File(p.join(appliedPath, 'asset.bin')).readAsBytesSync(), [
        0x00,
        0x01,
        0x02,
      ]);
      expect(File(p.join(appliedPath, 'file.txt')).readAsStringSync(), 'new\n');
    });

    test('allows git warnings when diff output is valid', () {
      final roots = _PatchRootPair(root);
      File(p.join(roots.baselinePath, 'file.txt')).writeAsStringSync('old\n');
      File(p.join(roots.editPath, 'file.txt')).writeAsStringSync('new\n');

      final buildResult = PatchFileBuilder(
        gitRunner: (arguments) {
          expect(arguments, contains('--no-ext-diff'));
          final oldPrefix = _gitDiffFixturePathPrefix(
            arguments[arguments.length - 2],
          );
          final newPrefix = _gitDiffFixturePathPrefix(arguments.last);
          return ProcessResult(0, 1, '''
diff --git a/$oldPrefix/file.txt b/$newPrefix/file.txt
index 3367afdbbf91e638efe983616377c60477cc6612..3e757656cf36eca53338e520d134963a44f793f8 100644
--- a/$oldPrefix/file.txt
+++ b/$newPrefix/file.txt
@@ -1 +1 @@
-old
+new
''', 'warning: LF will be replaced by CRLF\n');
        },
      ).build(baselinePath: roots.baselinePath, editPath: roots.editPath);

      expect(buildResult.diagnostic, isNull);
      expect(buildResult.content, contains('diff --git a/file.txt'));
      expect(buildResult.content, contains('+new'));
    });

    test(
      'ignores unchanged symlinks while building a patch',
      () {
        final roots = _PatchRootPair(root);
        Link(p.join(roots.baselinePath, 'link')).createSync('target.txt');
        Link(p.join(roots.editPath, 'link')).createSync('target.txt');
        File(p.join(roots.baselinePath, 'file.txt')).writeAsStringSync('old\n');
        File(p.join(roots.editPath, 'file.txt')).writeAsStringSync('new\n');

        final buildResult = roots.build();

        expect(buildResult.diagnostic, isNull);
        expect(buildResult.hasChanges, isTrue);
        expect(buildResult.content, contains('diff --git a/file.txt'));
        expect(buildResult.content, isNot(contains('link')));
      },
      skip: Platform.isWindows
          ? 'Symlink creation requires privileges.'
          : false,
    );

    test(
      'preserves symlink target changes',
      () {
        final roots = _PatchRootPair(root);
        Link(p.join(roots.baselinePath, 'link')).createSync('old-target.txt');
        Link(p.join(roots.editPath, 'link')).createSync('new-target.txt');

        final buildResult = roots.build();

        expect(buildResult.diagnostic, isNull);
        expect(buildResult.hasChanges, isTrue);
        expect(buildResult.content, contains('index '));
        expect(buildResult.content, contains(' 120000'));

        final appliedPath = roots.apply(root: root, buildResult: buildResult);
        _expectLinkTarget(p.join(appliedPath, 'link'), 'new-target.txt');
      },
      skip: Platform.isWindows
          ? 'Symlink creation requires privileges.'
          : false,
    );

    test(
      'preserves symlink additions',
      () {
        final roots = _PatchRootPair(root);
        Link(p.join(roots.editPath, 'link')).createSync('target.txt');

        final buildResult = roots.build();

        expect(buildResult.diagnostic, isNull);
        expect(buildResult.hasChanges, isTrue);
        expect(buildResult.content, contains('new file mode 120000'));

        final appliedPath = roots.apply(root: root, buildResult: buildResult);
        _expectLinkTarget(p.join(appliedPath, 'link'), 'target.txt');
      },
      skip: Platform.isWindows
          ? 'Symlink creation requires privileges.'
          : false,
    );

    test(
      'preserves symlink deletions',
      () {
        final roots = _PatchRootPair(root);
        Link(p.join(roots.baselinePath, 'link')).createSync('target.txt');

        final buildResult = roots.build();

        expect(buildResult.diagnostic, isNull);
        expect(buildResult.hasChanges, isTrue);
        expect(buildResult.content, contains('deleted file mode 120000'));

        final appliedPath = roots.apply(root: root, buildResult: buildResult);
        expect(
          FileSystemEntity.typeSync(
            p.join(appliedPath, 'link'),
            followLinks: false,
          ),
          FileSystemEntityType.notFound,
        );
      },
      skip: Platform.isWindows
          ? 'Symlink creation requires privileges.'
          : false,
    );

    test(
      'preserves file to symlink conversions',
      () {
        final roots = _PatchRootPair(root);
        File(
          p.join(roots.baselinePath, 'entry'),
        ).writeAsStringSync('old file\n');
        Link(p.join(roots.editPath, 'entry')).createSync('target.txt');

        final buildResult = roots.build();

        expect(buildResult.diagnostic, isNull);
        expect(buildResult.hasChanges, isTrue);
        expect(buildResult.content, contains('deleted file mode 100644'));
        expect(buildResult.content, contains('new file mode 120000'));

        final appliedPath = roots.apply(root: root, buildResult: buildResult);
        _expectLinkTarget(p.join(appliedPath, 'entry'), 'target.txt');
      },
      skip: Platform.isWindows
          ? 'Symlink creation requires privileges.'
          : false,
    );

    test(
      'preserves symlink to file conversions',
      () {
        final roots = _PatchRootPair(root);
        Link(p.join(roots.baselinePath, 'entry')).createSync('target.txt');
        File(p.join(roots.editPath, 'entry')).writeAsStringSync('new file\n');

        final buildResult = roots.build();

        expect(buildResult.diagnostic, isNull);
        expect(buildResult.hasChanges, isTrue);
        expect(buildResult.content, contains('deleted file mode 120000'));
        expect(buildResult.content, contains('new file mode 100644'));

        final appliedPath = roots.apply(root: root, buildResult: buildResult);
        final entry = File(p.join(appliedPath, 'entry'));
        expect(entry.readAsStringSync(), 'new file\n');
      },
      skip: Platform.isWindows
          ? 'Symlink creation requires privileges.'
          : false,
    );
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

    test('ignores user whitespace policy while checking patches', () {
      File(p.join(root.path, 'file.txt')).writeAsStringSync('old\n');
      final initResult = Process.runSync('git', [
        'init',
        '-q',
      ], workingDirectory: root.path);
      expect(
        initResult.exitCode,
        0,
        reason: '${initResult.stderr}${initResult.stdout}'.trim(),
      );
      final configResult = Process.runSync('git', [
        'config',
        '--local',
        'apply.whitespace',
        'error',
      ], workingDirectory: root.path);
      expect(
        configResult.exitCode,
        0,
        reason: '${configResult.stderr}${configResult.stdout}'.trim(),
      );

      final result = const PatchValidator().validate(
        baselinePath: root.path,
        patchContent: [
          'diff --git a/file.txt b/file.txt',
          '--- a/file.txt',
          '+++ b/file.txt',
          '@@ -1 +1 @@',
          '-old',
          '+new   ',
          '',
        ].join('\n'),
      );

      expect(result.diagnostic, isNull);
    });

    test('keeps the temporary patch outside the validated tree', () {
      File(p.join(root.path, '.patchwork.patch')).writeAsStringSync('old\n');

      final result = const PatchValidator().validate(
        baselinePath: root.path,
        patchContent: [
          'diff --git a/.patchwork.patch b/.patchwork.patch',
          '--- a/.patchwork.patch',
          '+++ b/.patchwork.patch',
          '@@ -1 +1 @@',
          '-old',
          '+new',
          '',
        ].join('\n'),
      );

      expect(result.diagnostic, isNull);
    });

    test('deletes temporary patch files after validation', () {
      File(p.join(root.path, 'file.txt')).writeAsStringSync('old\n');
      final before = _validationPatchFiles();
      addTearDown(() {
        for (final path in _validationPatchFiles().difference(before)) {
          final file = File(path);
          if (file.existsSync()) {
            file.deleteSync();
          }
        }
      });

      final result = const PatchValidator().validate(
        baselinePath: root.path,
        patchContent: [
          'diff --git a/file.txt b/file.txt',
          '--- a/file.txt',
          '+++ b/file.txt',
          '@@ -1 +1 @@',
          '-old',
          '+new',
          '',
        ].join('\n'),
      );

      expect(result.diagnostic, isNull);
      expect(_validationPatchFiles(), before);
    });
  });
}

Set<String> _validationPatchFiles() {
  if (!Directory.systemTemp.existsSync()) {
    return const {};
  }

  return Directory.systemTemp
      .listSync(followLinks: false)
      .whereType<File>()
      .map((file) => file.path)
      .where((path) {
        final name = p.basename(path);
        return name.startsWith('patchwork_patch_validate_') &&
            name.endsWith('.patch');
      })
      .toSet();
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

void _expectLinkTarget(String path, String target) {
  expect(
    FileSystemEntity.typeSync(path, followLinks: false),
    FileSystemEntityType.link,
  );
  expect(Link(path).targetSync(), target);
}

final class _PatchRootPair {
  _PatchRootPair(Directory root)
    : baselinePath = p.join(root.path, 'baseline'),
      editPath = p.join(root.path, 'edit') {
    Directory(baselinePath).createSync(recursive: true);
    Directory(editPath).createSync(recursive: true);
  }

  final String baselinePath;
  final String editPath;

  PatchFileBuildResult build() {
    return const PatchFileBuilder().build(
      baselinePath: baselinePath,
      editPath: editPath,
    );
  }

  String apply({
    required Directory root,
    required PatchFileBuildResult buildResult,
  }) {
    return _applyPatch(
      root: root,
      baselinePath: baselinePath,
      patchContent: buildResult.content!,
    );
  }
}

void _withLocalGitConfig(
  Directory root,
  Map<String, String> entries,
  void Function() body,
) {
  final previousCurrentDirectory = Directory.current;
  final configRoot = Directory(p.join(root.path, 'git-config'));
  configRoot.createSync(recursive: true);
  final initResult = Process.runSync('git', [
    'init',
    '-q',
  ], workingDirectory: configRoot.path);
  expect(
    initResult.exitCode,
    0,
    reason: '${initResult.stderr}${initResult.stdout}'.trim(),
  );

  for (final entry in entries.entries) {
    final configResult = Process.runSync('git', [
      'config',
      '--local',
      entry.key,
      entry.value,
    ], workingDirectory: configRoot.path);
    expect(
      configResult.exitCode,
      0,
      reason: '${configResult.stderr}${configResult.stdout}'.trim(),
    );
  }

  Directory.current = configRoot.path;
  try {
    body();
  } finally {
    Directory.current = previousCurrentDirectory;
  }
}

String _gitDiffFixturePathPrefix(String path) {
  final normalized = path.replaceAll('\\', '/');
  if (normalized.startsWith('/')) {
    return normalized.substring(1);
  }
  return normalized;
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
