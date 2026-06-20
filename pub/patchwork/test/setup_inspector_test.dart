import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:patchwork/src/model.dart';
import 'package:patchwork/src/setup_inspector.dart';
import 'package:test/test.dart';

void main() {
  test(
    'reports missing generated-state ignore rules without mutating files',
    () {
      final root = Directory.systemTemp.createTempSync('patchwork_setup_');
      addTearDown(() => root.deleteSync(recursive: true));
      _writePubspec(root.path);

      final report = _inspect(root.path);

      expect(_warningCodes(report), {
        'setup.ignore_edit_state',
        'setup.ignore_applied_output',
        'setup.ignore_pubspec_overrides',
      });
      expect(_level(report, 'setup.commit_patch_files'), SetupCheckLevel.ok);
      expect(_level(report, 'setup.hook_optional'), SetupCheckLevel.info);
      expect(_level(report, 'setup.ci_optional'), SetupCheckLevel.info);
      expect(File(p.join(root.path, '.patchwork')).existsSync(), isFalse);
    },
  );

  test('accepts ignored generated state, configured hooks, and CI checks', () {
    final root = Directory.systemTemp.createTempSync('patchwork_setup_');
    addTearDown(() => root.deleteSync(recursive: true));
    _writePubspec(root.path, devDependencies: const ['hooks', 'patchwork']);
    File(p.join(root.path, '.gitignore')).writeAsStringSync('''
.patchwork/
.dart_tool/
pubspec_overrides.yaml
''');
    _writeHook(root.path, includeImports: true);
    _writeWorkflow(root.path, 'dart run patchwork apply');

    final report = _inspect(root.path);

    expect(report.hasWarnings, isFalse);
    expect(_level(report, 'setup.ignore_edit_state'), SetupCheckLevel.ok);
    expect(_level(report, 'setup.ignore_applied_output'), SetupCheckLevel.ok);
    expect(
      _level(report, 'setup.ignore_pubspec_overrides'),
      SetupCheckLevel.ok,
    );
    expect(_level(report, 'setup.commit_patch_files'), SetupCheckLevel.ok);
    expect(_level(report, 'setup.hook_config'), SetupCheckLevel.ok);
    expect(_level(report, 'setup.ci_patchwork_check'), SetupCheckLevel.ok);
  });

  test('accepts Patchwork package-provided overlay hook setup', () {
    final root = Directory.systemTemp.createTempSync('patchwork_setup_');
    addTearDown(() => root.deleteSync(recursive: true));
    _writePubspec(root.path, name: 'patchwork', dependencies: const ['hooks']);
    File(p.join(root.path, '.gitignore')).writeAsStringSync('''
.patchwork/
.dart_tool/
pubspec_overrides.yaml
''');
    _writePackageHook(root.path);

    final report = _inspect(root.path);

    expect(_level(report, 'setup.hook_config'), SetupCheckLevel.ok);
  });

  test(
    'warns about ignored patch files, incomplete hooks, and CI no-pub-get',
    () {
      final root = Directory.systemTemp.createTempSync('patchwork_setup_');
      addTearDown(() => root.deleteSync(recursive: true));
      _writePubspec(root.path);
      File(p.join(root.path, '.gitignore')).writeAsStringSync('''
.patchwork/
.dart_tool/
pubspec_overrides.yaml
patches/
''');
      _writeHook(root.path, includeImports: false);
      _writeWorkflow(root.path, 'dart run patchwork apply --no-pub-get');

      final report = _inspect(root.path);

      expect(_warningCodes(report), {
        'setup.commit_patch_files',
        'setup.hook_config',
        'setup.ci_apply_pub_get',
      });
    },
  );
}

SetupReport _inspect(String rootPath) {
  return SetupInspector(
    rootPath: rootPath,
    currentPackageRootPath: rootPath,
  ).inspect();
}

Set<String> _warningCodes(SetupReport report) {
  return report.warnings.map((check) => check.code).toSet();
}

SetupCheckLevel _level(SetupReport report, String code) {
  return report.checks.singleWhere((check) => check.code == code).level;
}

void _writePubspec(
  String rootPath, {
  String name = 'setup_fixture',
  List<String> dependencies = const [],
  List<String> devDependencies = const [],
}) {
  final dependencyText = dependencies
      .map((dependency) => '  $dependency: any')
      .join('\n');
  final devDependencyText = devDependencies
      .map((dependency) => '  $dependency: any')
      .join('\n');
  File(p.join(rootPath, 'pubspec.yaml')).writeAsStringSync(
    '''
name: $name
environment:
  sdk: ^3.9.0
${dependencyText.isEmpty ? '' : 'dependencies:\n$dependencyText\n'}${devDependencyText.isEmpty ? '' : 'dev_dependencies:\n$devDependencyText\n'}''',
  );
}

void _writeHook(String rootPath, {required bool includeImports}) {
  final hookDirectory = Directory(p.join(rootPath, 'hook'))
    ..createSync(recursive: true);
  File(p.join(hookDirectory.path, 'build.dart')).writeAsStringSync(
    includeImports
        ? '''
import 'package:hooks/hooks.dart';
import 'package:patchwork/hooks.dart' as patchwork;

void build(List<String> args, dynamic output) {}
'''
        : 'void build(List<String> args, dynamic output) {}\n',
  );
}

void _writePackageHook(String rootPath) {
  final hookDirectory = Directory(p.join(rootPath, 'hook'))
    ..createSync(recursive: true);
  File(p.join(hookDirectory.path, 'build.dart')).writeAsStringSync('''
import 'package:hooks/hooks.dart';
import 'package:patchwork/src/overlay_hook.dart' as patchwork;

Future<void> main(List<String> args) async {
  await build(args, patchwork.applyPackageOverlays);
}
''');
}

void _writeWorkflow(String rootPath, String command) {
  final workflowDirectory = Directory(p.join(rootPath, '.github', 'workflows'))
    ..createSync(recursive: true);
  File(p.join(workflowDirectory.path, 'ci.yml')).writeAsStringSync('''
name: CI
on: [push]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - run: $command
''');
}
