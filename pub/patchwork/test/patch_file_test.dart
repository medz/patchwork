import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:patchwork/src/error.dart';
import 'package:patchwork/src/patch_file.dart';
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
}
