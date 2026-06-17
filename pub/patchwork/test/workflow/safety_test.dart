import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:patchwork/patchwork.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

import 'project_sandbox.dart';

void main() {
  test(
    'undo refuses an applied path outside the project',
    () async {
      final project = await ProjectSandbox.standalone();
      addTearDown(project.dispose);

      await project.pubGet();
      await project.patchwork(['patch', 'greeter']);
      project.writeEdit('Hello from a safe patch');
      await project.patchwork(['commit', 'greeter']);
      await project.patchwork(['apply', 'greeter']);

      const unsafePath = '../victim';
      project.lockfile.writeAsStringSync(
        project.lockfile.readAsStringSync().replaceAll(
          '.dart_tool/patchwork/greeter@0.1.0',
          unsafePath,
        ),
      );
      final sentinel = File(p.join(project.root.path, 'victim', 'sentinel'));
      sentinel.parent.createSync(recursive: true);
      sentinel.writeAsStringSync('do not delete');

      await project.patchwork(
        ['undo', 'greeter'],
        exitCodes: {1},
        stderrContains: 'generated Patchwork output',
      );
      expect(sentinel.existsSync(), isTrue);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'apply-all refuses an applied path outside the project',
    () async {
      final project = await ProjectSandbox.standalone();
      addTearDown(project.dispose);

      await project.pubGet();
      await project.patchwork(['patch', 'greeter']);
      project.writeEdit('Hello from a safe apply-all patch');
      await project.patchwork(['commit', 'greeter']);
      await project.patchwork(['apply', 'greeter']);

      project.lockfile.writeAsStringSync(
        project.lockfile.readAsStringSync().replaceAll(
          '.dart_tool/patchwork/greeter@0.1.0',
          '../victim',
        ),
      );

      await project.patchwork(
        ['apply'],
        exitCodes: {1},
        stderrContains: 'generated Patchwork output',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'undo refuses unsafe lockfile package versions before deleting',
    () async {
      final project = await ProjectSandbox.standalone();
      addTearDown(project.dispose);

      await project.pubGet();
      final victim = File(p.join(project.stateRoot, 'victim', 'sentinel'));
      victim.parent.createSync(recursive: true);
      victim.writeAsStringSync('do not delete');
      project.lockfile.writeAsStringSync('''
version: 2
packages:
  greeter:
    version: "0.1.0/../../../victim"
    source:
      type: "path"
      sha256: "source"
    patch:
      edit-sha256: "edit"
      commit-sha256: "patch"
    applied:
      patch-sha256: "patch"
      path: ".dart_tool/patchwork/greeter@0.1.0/../../../victim"
''');

      await project.patchwork(
        ['undo', 'greeter'],
        exitCodes: {1},
        stderrContains: 'safe package names and versions',
      );
      expect(victim.existsSync(), isTrue);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'undo refuses a workspace member root recorded as applied path',
    () async {
      final project = await ProjectSandbox.workspace();
      addTearDown(project.dispose);

      await project.pubGet();
      await project.patchwork(['patch', 'greeter']);
      project.writeEdit('Hello from a safe workspace patch');
      await project.patchwork(['commit', 'greeter']);
      await project.patchwork(['apply', 'greeter']);

      _replaceAppliedPath(project, 'app');

      await project.patchwork(
        ['undo', 'greeter'],
        exitCodes: {1},
        stderrContains: 'generated Patchwork output',
      );
      expect(
        File(p.join(project.appRoot, 'bin', 'app.dart')).existsSync(),
        isTrue,
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'undo refuses a sibling workspace package root recorded as applied path',
    () async {
      final project = await ProjectSandbox.workspace();
      addTearDown(project.dispose);

      await project.pubGet();
      await project.patchwork(['patch', 'greeter']);
      project.writeEdit('Hello from a safe sibling patch');
      await project.patchwork(['commit', 'greeter']);
      await project.patchwork(['apply', 'greeter']);

      const memberPath = 'packages/member_greeter';
      _replaceAppliedPath(project, memberPath);

      await project.patchwork(
        ['undo', 'greeter'],
        exitCodes: {1},
        stderrContains: 'generated Patchwork output',
      );
      expect(
        File(
          p.join(project.stateRoot, memberPath, 'lib', 'member_greeter.dart'),
        ).existsSync(),
        isTrue,
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'undo refuses sibling workspace package roots without package graph',
    () async {
      final project = await ProjectSandbox.workspace();
      addTearDown(project.dispose);

      await project.pubGet();
      await project.patchwork(['patch', 'greeter']);
      project.writeEdit('Hello from a package-graph-safe patch');
      await project.patchwork(['commit', 'greeter']);
      await project.patchwork(['apply', 'greeter']);

      File(
        p.join(project.stateRoot, '.dart_tool', 'package_graph.json'),
      ).deleteSync();
      final pubspec = File(p.join(project.stateRoot, 'pubspec.yaml'));
      pubspec.writeAsStringSync(
        pubspec.readAsStringSync().replaceFirst(
          '  - packages/member_greeter',
          '  - packages/*',
        ),
      );
      const memberPath = 'packages/member_greeter';
      _replaceAppliedPath(project, memberPath);

      await project.patchwork(
        ['undo', 'greeter'],
        exitCodes: {1},
        stderrContains: 'generated Patchwork output',
      );
      expect(
        File(
          p.join(project.stateRoot, memberPath, 'lib', 'member_greeter.dart'),
        ).existsSync(),
        isTrue,
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'undo refuses an applied path that resolves outside through a symlink',
    () async {
      final project = await ProjectSandbox.standalone();
      addTearDown(project.dispose);

      await project.pubGet();
      await project.patchwork(['patch', 'greeter']);
      project.writeEdit('Hello from a symlink-safe patch');
      await project.patchwork(['commit', 'greeter']);
      await project.patchwork(['apply', 'greeter']);

      final outside = Directory(p.join(project.root.path, 'outside_target'));
      final victim = File(p.join(outside.path, 'victim', 'sentinel'));
      victim.parent.createSync(recursive: true);
      victim.writeAsStringSync('do not delete');
      Link(
        p.join(project.stateRoot, 'link_to_outside'),
      ).createSync(outside.path);
      _replaceAppliedPath(project, 'link_to_outside/victim');

      await project.patchwork(
        ['undo', 'greeter'],
        exitCodes: {1},
        stderrContains: 'generated Patchwork output',
      );
      expect(victim.existsSync(), isTrue);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'apply refuses a missing applied path under a symlinked parent',
    () async {
      final project = await ProjectSandbox.standalone();
      addTearDown(project.dispose);

      await project.pubGet();
      await project.patchwork(['patch', 'greeter']);
      project.writeEdit('Hello from a missing symlink leaf');
      await project.patchwork(['commit', 'greeter']);
      await (await Patchwork.open(project.commandRoot)).apply('greeter');

      final outside = Directory(p.join(project.root.path, 'outside_target'));
      outside.createSync(recursive: true);
      Link(
        p.join(project.stateRoot, 'link_to_outside'),
      ).createSync(outside.path);
      const unsafePath = 'link_to_outside/greeter@0.1.0';
      project.lockfile.writeAsStringSync(
        project.lockfile.readAsStringSync().replaceAll(
          '.dart_tool/patchwork/greeter@0.1.0',
          unsafePath,
        ),
      );

      await expectLater(
        () async =>
            (await Patchwork.open(project.commandRoot)).apply('greeter'),
        throwsA(
          isA<PatchworkException>().having(
            (error) => error.code,
            'code',
            'apply.applied_path_not_deletable',
          ),
        ),
      );
      expect(
        Directory(p.join(outside.path, 'greeter@0.1.0')).existsSync(),
        isFalse,
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'patch refuses to use a same-package user override as source',
    () async {
      final project = await ProjectSandbox.standalone();
      addTearDown(project.dispose);

      await project.pubGet();
      project.writeManualOverride();
      await project.pubGet();

      await project.patchwork(
        ['patch', 'greeter'],
        exitCodes: {1},
        stderrContains: 'already has a dependency override',
      );
      expect(project.editDirectoryFor('0.1.0').existsSync(), isFalse);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'patch refuses same-package overrides from a workspace member',
    () async {
      final project = await ProjectSandbox.workspace();
      addTearDown(project.dispose);

      await project.pubGet();
      _writeWorkspaceMemberOverride(project);
      await project.pubGet();

      await project.patchwork(
        ['patch', 'greeter'],
        exitCodes: {1},
        stderrContains: 'already has a dependency override',
      );
      expect(project.editDirectoryFor('0.1.0').existsSync(), isFalse);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'apply refuses same-package overrides from a workspace member',
    () async {
      final project = await ProjectSandbox.workspace();
      addTearDown(project.dispose);

      await project.pubGet();
      await project.patchwork(['patch', 'greeter']);
      project.writeEdit('Hello from a blocked member override');
      await project.patchwork(['commit', 'greeter']);
      _writeWorkspaceMemberOverride(project);

      await project.patchwork(
        ['apply', 'greeter'],
        exitCodes: {1},
        stderrContains: 'already has a dependency override',
      );
      expect(project.overrideFile.existsSync(), isFalse);
      expect(project.appliedDirectory.existsSync(), isFalse);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'workspace-root apply refuses same-package overrides from a workspace member',
    () async {
      final project = await ProjectSandbox.workspace();
      addTearDown(project.dispose);

      await project.pubGet();
      await project.patchwork(['patch', 'greeter']);
      project.writeEdit('Hello from a blocked root apply');
      await project.patchwork(['commit', 'greeter']);
      _writeWorkspaceMemberOverride(project);

      await project.patchwork(
        ['doctor'],
        workingDirectory: project.stateRoot,
        exitCodes: {1},
        stdoutContains: 'already has a dependency override',
      );
      await project.patchwork(
        ['apply'],
        workingDirectory: project.stateRoot,
        exitCodes: {1},
        stderrContains: 'already has a dependency override',
      );
      expect(project.appliedDirectory.existsSync(), isFalse);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'patch allows user-owned path dependencies under dart_tool patchwork',
    () async {
      final project = await ProjectSandbox.standalone();
      addTearDown(project.dispose);

      final userDependency = Directory(
        p.join(project.stateRoot, '.dart_tool', 'patchwork', 'greeter@0.1.0'),
      );
      const dependencyPath = '.dart_tool/patchwork/greeter@0.1.0';
      project.writeGreeterPackageAt(
        userDependency.path,
        'Hello from a user-owned path, \$name!',
      );
      project.replaceAppPubspecText('../packages/greeter', dependencyPath);

      await project.pubGet();
      await project.patchwork(['patch', 'greeter']);

      expect(
        project.editFile.readAsStringSync(),
        contains('Hello from a user-owned path'),
      );
      final lock = loadYaml(project.lockfile.readAsStringSync()) as YamlMap;
      final greeter = (lock['packages'] as YamlMap)['greeter'] as YamlMap;
      expect((greeter['source'] as YamlMap)['path'], dependencyPath);
      expect(greeter.containsKey('applied'), isFalse);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'doctor reports uncommitted edit directories',
    () async {
      final project = await ProjectSandbox.standalone();
      addTearDown(project.dispose);

      await project.pubGet();
      await project.patchwork(['patch', 'greeter']);

      await project.patchwork(
        ['doctor'],
        exitCodes: {1},
        stdoutContains: 'uncommitted edit directory',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'patch continue version without package reports a missing package',
    () async {
      final project = await ProjectSandbox.standalone();
      addTearDown(project.dispose);

      await project.pubGet();
      await project.patchwork(
        ['patch', '--continue', '0.1.0'],
        exitCodes: {64},
        stderrContains: 'Expected a package name',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'doctor reports ambiguous edit directories before commit fails',
    () async {
      final project = await ProjectSandbox.standalone();
      addTearDown(project.dispose);

      await project.pubGet();
      await project.patchwork(['patch', 'greeter']);
      project.editDirectoryFor('0.2.0').createSync(recursive: true);

      await project.patchwork(
        ['doctor'],
        exitCodes: {1},
        stdoutContains: 'More than one edit directory exists',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'inspect reports patchwork state when pub resolution is missing',
    () async {
      final project = await ProjectSandbox.standalone();
      addTearDown(project.dispose);

      await project.pubGet();
      await project.patchwork(['patch', 'greeter']);
      project.writeEdit('Hello from a missing pub lock');
      await project.patchwork(['commit', 'greeter']);
      File(p.join(project.stateRoot, 'pubspec.lock')).deleteSync();

      final state = await (await Patchwork.open(project.commandRoot)).inspect();
      expect(state.packages.single.package, 'greeter');
      expect(
        state.problems.map((problem) => problem.message),
        contains('Could not find pubspec.lock.'),
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'apply refuses to apply while the package has an open edit',
    () async {
      final project = await ProjectSandbox.standalone();
      addTearDown(project.dispose);

      await project.pubGet();
      await project.patchwork(['patch', 'greeter']);
      project.writeEdit('Hello from a committed patch');
      await project.patchwork(['commit', 'greeter']);
      await project.patchwork(['patch', 'greeter', '--continue']);
      project.writeEdit('Hello from an uncommitted edit');

      await project.patchwork(
        ['doctor'],
        exitCodes: {1},
        stdoutContains: 'open edit directory',
      );
      await project.patchwork([
        'status',
      ], stdoutContains: 'open edit directory');
      await project.patchwork(
        ['apply', 'greeter'],
        exitCodes: {1},
        stderrContains: 'open edit directory',
      );
      await project.patchwork(
        ['apply'],
        exitCodes: {1},
        stderrContains: 'open edit directory',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'apply-all reports same-package override conflicts',
    () async {
      final project = await ProjectSandbox.standalone();
      addTearDown(project.dispose);

      await project.pubGet();
      await project.patchwork(['patch', 'greeter']);
      project.writeEdit('Hello from a blocked apply all');
      await project.patchwork(['commit', 'greeter']);
      project.writeManualOverride();

      await project.patchwork(
        ['apply'],
        exitCodes: {1},
        stderrContains: 'already has a dependency override',
      );
      expect(project.appliedDirectory.existsSync(), isFalse);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'apply-all fails before partially applying a tampered patch',
    () async {
      final project = await ProjectSandbox.standalone(
        includeOtherDependency: true,
      );
      addTearDown(project.dispose);

      await project.pubGet();
      await project.patchwork(['patch', 'greeter']);
      project.writeEdit('Hello from a multi apply');
      await project.patchwork(['patch', 'other_pkg']);
      File(
        p.join(
          project.stateRoot,
          '.patchwork',
          'other_pkg@0.1.0',
          'lib',
          'other_pkg.dart',
        ),
      ).writeAsStringSync('''
String otherName() {
  return 'patched_other_pkg';
}
''');
      await project.patchwork(['commit']);
      File(
        p.join(project.stateRoot, 'patches', 'other_pkg@0.1.0.patch'),
      ).writeAsStringSync('tampered\n');

      await project.patchwork(
        ['apply'],
        exitCodes: {1},
        stderrContains: 'sha256 does not match',
      );
      expect(project.appliedDirectory.existsSync(), isFalse);
      expect(
        Directory(
          p.join(
            project.stateRoot,
            '.dart_tool',
            'patchwork',
            'other_pkg@0.1.0',
          ),
        ).existsSync(),
        isFalse,
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'apply-all skips stale applied records until pub resolves the source',
    () async {
      final project = await ProjectSandbox.standalone();
      addTearDown(project.dispose);

      await project.pubGet();
      await project.patchwork(['patch', 'greeter']);
      project.writeEdit('Hello from a stale apply');
      await project.patchwork(['commit', 'greeter']);
      await project.patchwork(['apply', 'greeter']);
      await project.pubGet();
      project.lockfile.writeAsStringSync(
        project.lockfile.readAsStringSync().replaceFirst(
          RegExp(r'patch-sha256: "[0-9a-f]+"'),
          'patch-sha256: "stale"',
        ),
      );

      await project.patchwork(
        ['doctor'],
        exitCodes: {1},
        stdoutContains:
            'Applied patch sha256 differs from the committed patch.',
      );
      await project.patchwork(
        ['doctor'],
        exitCodes: {1},
        stdoutContains:
            'Run patchwork undo greeter, dart pub get, then patchwork apply greeter.',
      );
      await project.patchwork([
        'apply',
      ], stdoutContains: 'No patches need apply.');
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'apply and undo preserve user-owned dependency overrides',
    () async {
      final project = await ProjectSandbox.standalone(
        includeOtherDependency: true,
      );
      addTearDown(project.dispose);

      await project.pubGet();
      await project.patchwork(['patch', 'greeter']);
      project.writeEdit('Hello from an override-safe patch');
      await project.patchwork(['commit', 'greeter']);

      project.writeOtherOverride();
      await project.patchwork(['apply', 'greeter']);
      await project.pubGet();
      project.expectPackageResolvedTo('other_pkg', project.otherOverrideRoot!);
      expect(project.overrideFile.readAsStringSync(), contains('other_pkg:'));
      expect(project.overrideFile.readAsStringSync(), contains('greeter:'));

      await project.patchwork(['undo', 'greeter']);
      await project.pubGet();
      project.expectPackageResolvedTo('other_pkg', project.otherOverrideRoot!);
      final afterUndo = project.overrideFile.readAsStringSync();
      expect(afterUndo, contains('other_pkg:'));
      expect(afterUndo, isNot(contains('greeter:')));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'apply refuses to replace unowned applied output or override paths',
    () async {
      final project = await ProjectSandbox.standalone();
      addTearDown(project.dispose);

      await project.pubGet();
      await project.patchwork(['patch', 'greeter']);
      project.writeEdit('Hello from an owned patch');
      await project.patchwork(['commit', 'greeter']);

      final sentinel = File(p.join(project.appliedDirectory.path, 'SENTINEL'));
      sentinel.parent.createSync(recursive: true);
      sentinel.writeAsStringSync('user data');
      await project.patchwork(
        ['apply', 'greeter'],
        exitCodes: {1},
        stderrContains: 'Applied output path already exists',
      );
      expect(sentinel.readAsStringSync(), 'user data');

      project.appliedDirectory.deleteSync(recursive: true);
      project.overrideFile.writeAsStringSync('''
dependency_overrides:
  greeter:
    path: .dart_tool/patchwork/greeter@0.1.0
''');
      await project.patchwork(
        ['apply', 'greeter'],
        exitCodes: {1},
        stderrContains: 'already has a dependency override',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'undo leaves a same-package user override in place',
    () async {
      final project = await ProjectSandbox.standalone(
        includeOtherDependency: true,
      );
      addTearDown(project.dispose);

      await project.pubGet();
      await project.patchwork(['patch', 'greeter']);
      project.writeEdit('Hello from a replaceable patch');
      await project.patchwork(['commit', 'greeter']);
      await project.patchwork(['apply', 'greeter']);

      project.writeManualAndOtherOverrides();
      await project.patchwork(['undo', 'greeter']);
      await project.pubGet();
      project.expectPackageResolvedTo('greeter', project.manualOverrideRoot);
      project.expectPackageResolvedTo('other_pkg', project.otherOverrideRoot!);

      final overrides = project.overrideFile.readAsStringSync();
      expect(overrides, contains('manual_greeter'));
      expect(overrides, contains('other_pkg:'));
      expect(project.appliedDirectory.existsSync(), isFalse);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'undo refuses a user project directory recorded as applied path in standalone projects',
    () async {
      final project = await ProjectSandbox.standalone();
      addTearDown(project.dispose);

      await _expectUndoRefusesUserDirectory(project);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'undo refuses a user project directory recorded as applied path in workspace members',
    () async {
      final project = await ProjectSandbox.workspace();
      addTearDown(project.dispose);

      await _expectUndoRefusesUserDirectory(project);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'apply refuses a user project directory recorded as applied path in standalone projects',
    () async {
      final project = await ProjectSandbox.standalone();
      addTearDown(project.dispose);

      await _expectApplyRefusesUserDirectory(project);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'apply refuses a user project directory recorded as applied path in workspace members',
    () async {
      final project = await ProjectSandbox.workspace();
      addTearDown(project.dispose);

      await _expectApplyRefusesUserDirectory(project);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

void _writeWorkspaceMemberOverride(ProjectSandbox project) {
  File(p.join(project.appRoot, 'pubspec_overrides.yaml')).writeAsStringSync('''
dependency_overrides:
  greeter:
    path: ${p.relative(project.manualOverrideRoot, from: project.appRoot)}
''');
}

void _replaceAppliedPath(ProjectSandbox project, String path) {
  const originalPath = '.dart_tool/patchwork/greeter@0.1.0';
  project.lockfile.writeAsStringSync(
    project.lockfile.readAsStringSync().replaceAll(originalPath, path),
  );
}

Future<void> _expectUndoRefusesUserDirectory(ProjectSandbox project) async {
  await project.pubGet();
  await project.patchwork(['patch', 'greeter']);
  project.writeEdit('Hello from a safe patch');
  await project.patchwork(['commit', 'greeter']);
  await project.patchwork(['apply', 'greeter']);

  const userPath = 'user_owned_output';
  final sentinel = File(p.join(project.stateRoot, userPath, 'sentinel'));
  sentinel.parent.createSync(recursive: true);
  sentinel.writeAsStringSync('do not delete');
  _replaceAppliedPath(project, userPath);

  await project.patchwork(
    ['undo', 'greeter'],
    exitCodes: {1},
    stderrContains: 'generated Patchwork output',
  );

  expect(sentinel.existsSync(), isTrue);
  expect(project.appliedDirectory.existsSync(), isTrue);
}

Future<void> _expectApplyRefusesUserDirectory(ProjectSandbox project) async {
  await project.pubGet();
  await project.patchwork(['patch', 'greeter']);
  project.writeEdit('Hello from a safe apply');
  await project.patchwork(['commit', 'greeter']);
  await (await Patchwork.open(project.commandRoot)).apply('greeter');

  const userPath = 'user_owned_output';
  final sentinel = File(p.join(project.stateRoot, userPath, 'sentinel'));
  sentinel.parent.createSync(recursive: true);
  sentinel.writeAsStringSync('do not replace');
  _replaceAppliedPath(project, userPath);

  await project.patchwork(
    ['apply', 'greeter'],
    exitCodes: {1},
    stderrContains: 'generated Patchwork output',
  );

  expect(sentinel.existsSync(), isTrue);
  expect(project.appliedDirectory.existsSync(), isTrue);
}
