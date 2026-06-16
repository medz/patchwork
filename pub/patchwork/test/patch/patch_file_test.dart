import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:patchwork/src/patch/patch_file.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('patchwork_patch_');
  });

  tearDown(() {
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  });

  test('builds, validates, and applies a unified patch', () {
    final sourcePath = p.join(root.path, 'source');
    final editPath = p.join(root.path, 'edit');
    final appliedPath = p.join(root.path, 'applied');
    Directory(p.join(sourcePath, 'lib')).createSync(recursive: true);
    Directory(p.join(editPath, 'lib')).createSync(recursive: true);
    Directory(p.join(appliedPath, 'lib')).createSync(recursive: true);
    File(p.join(sourcePath, 'lib', 'foo.dart')).writeAsStringSync('old\n');
    File(p.join(editPath, 'lib', 'foo.dart')).writeAsStringSync('new\n');
    File(p.join(appliedPath, 'lib', 'foo.dart')).writeAsStringSync('old\n');

    const patchFile = PatchFile();
    final patch = patchFile.build(sourcePath: sourcePath, editPath: editPath);

    expect(patch, contains('--- a/lib/foo.dart'));
    expect(patch, contains('+++ b/lib/foo.dart'));

    patchFile.validate(sourcePath: sourcePath, patchContent: patch);
    patchFile.apply(packagePath: appliedPath, patchContent: patch);

    expect(
      File(p.join(appliedPath, 'lib', 'foo.dart')).readAsStringSync(),
      'new\n',
    );
  });

  test('applies inside a package copy nested under a git repository', () {
    final gitRoot = p.join(root.path, 'repo');
    Directory(gitRoot).createSync();
    Process.runSync('git', ['init'], workingDirectory: gitRoot);

    final sourcePath = p.join(root.path, 'source');
    final editPath = p.join(root.path, 'edit');
    final appliedPath = p.join(gitRoot, '.dart_tool', 'patchwork', 'foo@0.1.0');
    Directory(p.join(sourcePath, 'lib')).createSync(recursive: true);
    Directory(p.join(editPath, 'lib')).createSync(recursive: true);
    Directory(p.join(appliedPath, 'lib')).createSync(recursive: true);
    File(p.join(sourcePath, 'lib', 'foo.dart')).writeAsStringSync('old\n');
    File(p.join(editPath, 'lib', 'foo.dart')).writeAsStringSync('new\n');
    File(p.join(appliedPath, 'lib', 'foo.dart')).writeAsStringSync('old\n');

    const patchFile = PatchFile();
    final patch = patchFile.build(sourcePath: sourcePath, editPath: editPath);

    patchFile.apply(packagePath: appliedPath, patchContent: patch);

    expect(
      File(p.join(appliedPath, 'lib', 'foo.dart')).readAsStringSync(),
      'new\n',
    );
  });

  test('excludes generated pub state from package patches', () {
    final sourcePath = p.join(root.path, 'source');
    final editPath = p.join(root.path, 'edit');
    Directory(p.join(sourcePath, 'lib')).createSync(recursive: true);
    Directory(p.join(editPath, 'lib')).createSync(recursive: true);
    File(p.join(sourcePath, 'lib', 'foo.dart')).writeAsStringSync('old\n');
    File(p.join(editPath, 'lib', 'foo.dart')).writeAsStringSync('new\n');
    Directory(p.join(editPath, '.dart_tool')).createSync();
    Directory(p.join(editPath, 'build')).createSync();
    File(
      p.join(editPath, '.dart_tool', 'package_config.json'),
    ).writeAsStringSync('{}');
    File(
      p.join(editPath, 'build', 'generated.txt'),
    ).writeAsStringSync('generated');
    File(p.join(editPath, '.packages')).writeAsStringSync('legacy');
    File(p.join(editPath, 'pubspec.lock')).writeAsStringSync('lock');

    final patch = const PatchFile().build(
      sourcePath: sourcePath,
      editPath: editPath,
    );

    expect(patch, contains('lib/foo.dart'));
    expect(patch, isNot(contains('.dart_tool')));
    expect(patch, isNot(contains('build/generated.txt')));
    expect(patch, isNot(contains('.packages')));
    expect(patch, isNot(contains('pubspec.lock')));
  });
}
