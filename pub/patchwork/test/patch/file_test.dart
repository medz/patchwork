import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:patchwork/src/error.dart';
import 'package:patchwork/src/patch/file.dart';
import 'package:test/test.dart';

void main() {
  test('partial apply forces C locale for Git reject diagnostics', () {
    final root = Directory.systemTemp.createTempSync('patchwork_patch_file_');
    addTearDown(() => root.deleteSync(recursive: true));

    Map<String, String>? gitEnvironment;
    final patchFile = PatchFile(
      gitRunner: (arguments, {workingDirectory, environment}) {
        gitEnvironment = environment;
        return ProcessResult(0, 0, '', '');
      },
    );

    patchFile.applyPartial(packagePath: root.path, patchContent: '');

    expect(gitEnvironment, containsPair('LC_ALL', 'C'));
    expect(gitEnvironment, containsPair('LANG', 'C'));
  });

  test('partial apply fails when a reported reject was not written', () {
    final root = Directory.systemTemp.createTempSync('patchwork_patch_file_');
    addTearDown(() => root.deleteSync(recursive: true));

    Directory(
      p.join(root.path, 'lib', 'foo.dart.rej'),
    ).createSync(recursive: true);
    final patchFile = PatchFile(
      gitRunner: (arguments, {workingDirectory, environment}) {
        return ProcessResult(
          1,
          1,
          '',
          'Applying patch lib/foo.dart with 1 reject...\n',
        );
      },
    );

    expect(
      () => patchFile.applyPartial(packagePath: root.path, patchContent: ''),
      throwsA(
        isA<PatchworkException>()
            .having((error) => error.code, 'code', 'patch.reject_missing')
            .having(
              (error) => error.location,
              'location',
              p.join(root.path, 'lib', 'foo.dart.rej'),
            ),
      ),
    );
  });

  test('partial apply fails when reject output collides with a patch file', () {
    final root = Directory.systemTemp.createTempSync('patchwork_patch_file_');
    addTearDown(() => root.deleteSync(recursive: true));

    final existingRejectFile = File(p.join(root.path, 'lib', 'foo.dart.rej'))
      ..createSync(recursive: true)
      ..writeAsStringSync('original source file\n');
    final patchFile = PatchFile(
      gitRunner: (arguments, {workingDirectory, environment}) {
        File(
          p.join(workingDirectory!, 'lib', 'foo.dart.rej'),
        ).writeAsStringSync('ambiguous reject output\n');
        return ProcessResult(
          1,
          1,
          '',
          'Applying patch lib/foo.dart with 1 reject...\n',
        );
      },
    );

    expect(
      () => patchFile.applyPartial(
        packagePath: root.path,
        patchContent: '''
diff --git a/lib/foo.dart.rej b/lib/foo.dart.rej
--- a/lib/foo.dart.rej
+++ b/lib/foo.dart.rej
@@ -1 +1 @@
-original source file
+patched source file
''',
      ),
      throwsA(
        isA<PatchworkException>()
            .having((error) => error.code, 'code', 'patch.reject_collision')
            .having(
              (error) => error.location,
              'location',
              p.join(root.path, 'lib', 'foo.dart.rej'),
            ),
      ),
    );
    expect(existingRejectFile.readAsStringSync(), 'original source file\n');
    expect(Directory(p.join(root.path, '.patchwork')).existsSync(), isFalse);
  });

  test('partial apply detects reject collisions from binary patch paths', () {
    final root = Directory.systemTemp.createTempSync('patchwork_patch_file_');
    addTearDown(() => root.deleteSync(recursive: true));

    final existingRejectFile =
        File(p.join(root.path, 'lib', 'foo bar.dart.rej'))
          ..createSync(recursive: true)
          ..writeAsStringSync('original source file\n');
    final patchFile = PatchFile(
      gitRunner: (arguments, {workingDirectory, environment}) {
        if (arguments.contains('--numstat')) {
          return ProcessResult(1, 0, '-\t-\tlib/foo bar.dart.rej\x00', '');
        }
        File(
          p.join(workingDirectory!, 'lib', 'foo bar.dart.rej'),
        ).writeAsStringSync('ambiguous reject output\n');
        return ProcessResult(
          1,
          1,
          '',
          'Applying patch lib/foo bar.dart with 1 reject...\n',
        );
      },
    );

    expect(
      () => patchFile.applyPartial(
        packagePath: root.path,
        patchContent: '''
diff --git a/lib/foo bar.dart.rej b/lib/foo bar.dart.rej
new file mode 100644
index 0000000..1234567
GIT binary patch
literal 4
LcmZQzU|;|M0N2U<
''',
      ),
      throwsA(
        isA<PatchworkException>()
            .having((error) => error.code, 'code', 'patch.reject_collision')
            .having(
              (error) => error.location,
              'location',
              p.join(root.path, 'lib', 'foo bar.dart.rej'),
            ),
      ),
    );
    expect(existingRejectFile.readAsStringSync(), 'original source file\n');
  });

  test('partial apply detects reject collisions from rename metadata', () {
    final root = Directory.systemTemp.createTempSync('patchwork_patch_file_');
    addTearDown(() => root.deleteSync(recursive: true));

    final existingRejectFile = File(p.join(root.path, 'lib', 'foo.dart.rej'))
      ..createSync(recursive: true)
      ..writeAsStringSync('original source file\n');
    final patchFile = PatchFile(
      gitRunner: (arguments, {workingDirectory, environment}) {
        if (arguments.contains('--numstat')) {
          return ProcessResult(1, 0, '0\t0\tlib/bar.dart.rej\x00', '');
        }
        File(
          p.join(workingDirectory!, 'lib', 'foo.dart.rej'),
        ).writeAsStringSync('ambiguous reject output\n');
        return ProcessResult(
          1,
          1,
          '',
          'Applying patch lib/foo.dart with 1 reject...\n',
        );
      },
    );

    expect(
      () => patchFile.applyPartial(
        packagePath: root.path,
        patchContent: '''
diff --git a/lib/foo.dart.rej b/lib/bar.dart.rej
similarity index 100%
rename from lib/foo.dart.rej
rename to lib/bar.dart.rej
''',
      ),
      throwsA(
        isA<PatchworkException>()
            .having((error) => error.code, 'code', 'patch.reject_collision')
            .having(
              (error) => error.location,
              'location',
              p.join(root.path, 'lib', 'foo.dart.rej'),
            ),
      ),
    );
    expect(existingRejectFile.readAsStringSync(), 'original source file\n');
  });
}
