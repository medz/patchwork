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
    'patch refuses same-package dependency overrides from root and member pubspecs',
    () async {
      final standalone = await ProjectSandbox.standalone();
      final workspace = await ProjectSandbox.workspace();
      addTearDown(standalone.dispose);
      addTearDown(workspace.dispose);

      await standalone.pubGet();
      _writePubspecDependencyOverride(
        standalone,
        packageRoot: standalone.stateRoot,
      );
      await standalone.pubGet();
      await workspace.pubGet();
      _writePubspecDependencyOverride(
        workspace,
        packageRoot: workspace.appRoot,
      );
      await workspace.pubGet();

      await standalone.patchwork(
        ['patch', 'greeter'],
        exitCodes: {1},
        stderrContains: 'pubspec.yaml already has a dependency override',
      );
      await workspace.patchwork(
        ['patch', 'greeter'],
        exitCodes: {1},
        stderrContains: 'pubspec.yaml already has a dependency override',
      );
      expect(standalone.editDirectoryFor('0.1.0').existsSync(), isFalse);
      expect(workspace.editDirectoryFor('0.1.0').existsSync(), isFalse);
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
    'apply refuses same-package dependency overrides before writing generated overrides',
    () async {
      final standalone = await ProjectSandbox.standalone();
      final workspace = await ProjectSandbox.workspace();
      addTearDown(standalone.dispose);
      addTearDown(workspace.dispose);

      await standalone.pubGet();
      await standalone.patchwork(['patch', 'greeter']);
      standalone.writeEdit('Hello from a blocked pubspec override');
      await standalone.patchwork(['commit', 'greeter']);
      _writePubspecDependencyOverride(
        standalone,
        packageRoot: standalone.stateRoot,
      );

      await workspace.pubGet();
      await workspace.patchwork(['patch', 'greeter']);
      workspace.writeEdit('Hello from a blocked member pubspec override');
      await workspace.patchwork(['commit', 'greeter']);
      _writePubspecDependencyOverride(
        workspace,
        packageRoot: workspace.appRoot,
      );

      await standalone.patchwork(
        ['apply', 'greeter'],
        exitCodes: {1},
        stderrContains: 'pubspec.yaml already has a dependency override',
      );
      await workspace.patchwork(
        ['apply', 'greeter'],
        exitCodes: {1},
        stderrContains: 'pubspec.yaml already has a dependency override',
      );
      expect(standalone.overrideFile.existsSync(), isFalse);
      expect(standalone.appliedDirectory.existsSync(), isFalse);
      expect(workspace.overrideFile.existsSync(), isFalse);
      expect(workspace.appliedDirectory.existsSync(), isFalse);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'apply preserves unrelated dependency overrides from project pubspecs',
    () async {
      final standalone = await ProjectSandbox.standalone(
        includeOtherDependency: true,
      );
      final workspace = await ProjectSandbox.workspace(
        includeOtherDependency: true,
      );
      addTearDown(standalone.dispose);
      addTearDown(workspace.dispose);

      await standalone.pubGet();
      _writePubspecDependencyOverride(
        standalone,
        packageRoot: standalone.stateRoot,
        package: 'other_pkg',
      );
      await standalone.patchwork(['patch', 'greeter']);
      standalone.writeEdit('Hello with a root pubspec override');
      await standalone.patchwork(['commit', 'greeter']);
      await standalone.patchwork(['apply', 'greeter']);
      await standalone.pubGet();

      await workspace.pubGet();
      _writePubspecDependencyOverride(
        workspace,
        packageRoot: workspace.appRoot,
        package: 'other_pkg',
      );
      await workspace.patchwork(['patch', 'greeter']);
      workspace.writeEdit('Hello with a member pubspec override');
      await workspace.patchwork(['commit', 'greeter']);
      await workspace.patchwork(['apply', 'greeter']);
      await workspace.pubGet();

      standalone.expectPackageResolvedTo(
        'other_pkg',
        standalone.otherOverrideRoot!,
      );
      workspace.expectPackageResolvedTo(
        'other_pkg',
        workspace.otherOverrideRoot!,
      );
      expect(standalone.overrideFile.readAsStringSync(), contains('other_pkg'));
      expect(
        workspace.overrideFile.readAsStringSync(),
        isNot(contains('other_pkg')),
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'apply refreshes mirrored root pubspec dependency overrides',
    () async {
      final project = await ProjectSandbox.standalone(
        includeOtherDependency: true,
      );
      addTearDown(project.dispose);

      await project.pubGet();
      _writePubspecDependencyOverride(
        project,
        packageRoot: project.stateRoot,
        package: 'other_pkg',
      );
      await project.patchwork(['patch', 'greeter']);
      project.writeEdit('Hello with a stale mirrored override');
      await project.patchwork(['commit', 'greeter']);
      await project.patchwork(['apply', 'greeter']);
      await project.pubGet();
      project.expectPackageResolvedTo('other_pkg', project.otherOverrideRoot!);

      await project.patchwork(['undo', 'greeter']);
      await project.pubGet();
      _writePubspecDependencyOverride(
        project,
        packageRoot: project.stateRoot,
        package: 'other_pkg',
        targetRoot: project.otherRoot!,
      );
      await project.patchwork(['apply', 'greeter']);
      await project.pubGet();

      project.expectPackageResolvedTo('other_pkg', project.otherRoot!);
      expect(
        project.overrideFile.readAsStringSync(),
        contains(p.relative(project.otherRoot!, from: project.stateRoot)),
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'apply refreshes mirrored root pubspec overrides while still applied',
    () async {
      final project = await ProjectSandbox.standalone(
        includeOtherDependency: true,
      );
      addTearDown(project.dispose);
      final thirdRoot = p.join(project.root.path, 'packages', 'third_pkg');
      final manualThirdRoot = p.join(project.root.path, 'manual_third_pkg');
      _writeSimplePackage(thirdRoot, 'third_pkg');
      _writeSimplePackage(manualThirdRoot, 'third_pkg');
      _addPathDependency(project, 'third_pkg', thirdRoot);

      await project.pubGet();
      _writePubspecDependencyOverride(
        project,
        packageRoot: project.stateRoot,
        package: 'third_pkg',
        targetRoot: manualThirdRoot,
      );
      await project.patchwork(['patch', 'greeter']);
      project.writeEdit('Hello while refreshing an applied mirror');
      await project.patchwork(['commit', 'greeter']);
      await project.patchwork(['apply', 'greeter']);
      await project.pubGet();
      project.expectPackageResolvedTo('third_pkg', manualThirdRoot);

      _writePubspecDependencyOverride(
        project,
        packageRoot: project.stateRoot,
        package: 'third_pkg',
        targetRoot: thirdRoot,
      );
      await _commitOtherPackagePatch(project);
      await project.patchwork(['apply', 'other_pkg']);
      await project.pubGet();

      project.expectPackageResolvedTo('third_pkg', thirdRoot);
      final overrides = project.overrideFile.readAsStringSync();
      expect(
        overrides,
        contains(p.relative(thirdRoot, from: project.stateRoot)),
      );
      expect(overrides, isNot(contains('manual_third_pkg')));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'undo refreshes mirrored root pubspec overrides while other patches remain',
    () async {
      final project = await ProjectSandbox.standalone(
        includeOtherDependency: true,
      );
      addTearDown(project.dispose);
      final thirdRoot = p.join(project.root.path, 'packages', 'third_pkg');
      final manualThirdRoot = p.join(project.root.path, 'manual_third_pkg');
      _writeSimplePackage(thirdRoot, 'third_pkg');
      _writeSimplePackage(manualThirdRoot, 'third_pkg');
      _addPathDependency(project, 'third_pkg', thirdRoot);

      await project.pubGet();
      _writePubspecDependencyOverride(
        project,
        packageRoot: project.stateRoot,
        package: 'third_pkg',
        targetRoot: manualThirdRoot,
      );
      await project.patchwork(['patch', 'greeter']);
      project.writeEdit('Hello before undo refreshes a remaining mirror');
      await project.patchwork(['commit', 'greeter']);
      await project.patchwork(['apply', 'greeter']);
      await _commitOtherPackagePatch(project);
      await project.patchwork(['apply', 'other_pkg']);
      await project.pubGet();
      project.expectPackageResolvedTo('third_pkg', manualThirdRoot);

      _writePubspecDependencyOverride(
        project,
        packageRoot: project.stateRoot,
        package: 'third_pkg',
        targetRoot: thirdRoot,
      );
      await project.patchwork(['undo', 'greeter']);
      await project.pubGet();

      project.expectPackageResolvedTo('third_pkg', thirdRoot);
      expect(
        Directory(
          p.join(
            project.stateRoot,
            '.dart_tool',
            'patchwork',
            'other_pkg@0.1.0',
          ),
        ).existsSync(),
        isTrue,
      );
      final overrides = project.overrideFile.readAsStringSync();
      expect(overrides, contains('other_pkg:'));
      expect(
        overrides,
        contains(p.relative(thirdRoot, from: project.stateRoot)),
      );
      expect(overrides, isNot(contains('manual_third_pkg')));
      final lockfile = project.lockfile.readAsStringSync();
      expect(
        lockfile,
        contains(p.relative(thirdRoot, from: project.stateRoot)),
      );
      expect(lockfile, isNot(contains('manual_third_pkg')));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'apply keeps mirrored root pubspec overrides after user overrides are added',
    () async {
      final project = await ProjectSandbox.standalone(
        includeOtherDependency: true,
      );
      addTearDown(project.dispose);
      final thirdRoot = p.join(project.root.path, 'packages', 'third_pkg');
      final manualRoot = p.join(project.root.path, 'manual_pkg');
      _writeSimplePackage(thirdRoot, 'third_pkg');
      _writeSimplePackage(manualRoot, 'manual_pkg');
      _addPathDependency(project, 'third_pkg', thirdRoot);

      await project.pubGet();
      _writePubspecDependencyOverride(
        project,
        packageRoot: project.stateRoot,
        package: 'other_pkg',
      );
      await project.patchwork(['patch', 'greeter']);
      project.writeEdit('Hello while keeping an owned mirror');
      await project.patchwork(['commit', 'greeter']);
      await project.patchwork(['apply', 'greeter']);
      await project.pubGet();
      project.expectPackageResolvedTo('other_pkg', project.otherOverrideRoot!);

      _appendPubspecOverridesPathOverride(
        project,
        package: 'manual_pkg',
        targetRoot: manualRoot,
      );
      await project.patchwork(['patch', 'third_pkg']);
      File(
        p.join(
          project.stateRoot,
          '.patchwork',
          'third_pkg@0.1.0',
          'lib',
          'third_pkg.dart',
        ),
      ).writeAsStringSync('''
String packageName() {
  return 'patched_third_pkg';
}
''');
      await project.patchwork(['commit', 'third_pkg']);
      await project.patchwork(['apply', 'third_pkg']);
      await project.pubGet();

      project.expectPackageResolvedTo('other_pkg', project.otherOverrideRoot!);
      final overrides = project.overrideFile.readAsStringSync();
      expect(overrides, contains('other_pkg:'));
      expect(overrides, contains('manual_pkg:'));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'undo removes stale mirrored root pubspec overrides',
    () async {
      final project = await ProjectSandbox.standalone(
        includeOtherDependency: true,
      );
      addTearDown(project.dispose);

      await project.pubGet();
      _writePubspecDependencyOverride(
        project,
        packageRoot: project.stateRoot,
        package: 'other_pkg',
      );
      await project.patchwork(['patch', 'greeter']);
      project.writeEdit('Hello before removing a mirrored override');
      await project.patchwork(['commit', 'greeter']);
      await project.patchwork(['apply', 'greeter']);
      await project.pubGet();
      project.expectPackageResolvedTo('other_pkg', project.otherOverrideRoot!);

      _removePubspecDependencyOverrides(project.stateRoot);
      await project.patchwork(['undo', 'greeter']);
      await project.pubGet();

      project.expectPackageResolvedTo('other_pkg', project.otherRoot!);
      expect(project.overrideFile.existsSync(), isFalse);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'undo cleans mirrored root pubspec overrides when package override is edited',
    () async {
      final project = await ProjectSandbox.standalone(
        includeOtherDependency: true,
      );
      addTearDown(project.dispose);

      await project.pubGet();
      _writePubspecDependencyOverride(
        project,
        packageRoot: project.stateRoot,
        package: 'other_pkg',
      );
      await project.patchwork(['patch', 'greeter']);
      project.writeEdit('Hello before cleaning an edited override');
      await project.patchwork(['commit', 'greeter']);
      await project.patchwork(['apply', 'greeter']);
      await project.pubGet();
      project.expectPackageResolvedTo('other_pkg', project.otherOverrideRoot!);

      _removePubspecDependencyOverrides(project.stateRoot);
      project.overrideFile.writeAsStringSync(
        project.overrideFile.readAsStringSync().replaceFirst(
          '.dart_tool/patchwork/greeter@0.1.0',
          p.relative(project.manualOverrideRoot, from: project.stateRoot),
        ),
      );
      await project.patchwork(['undo', 'greeter']);
      await project.pubGet();

      project.expectPackageResolvedTo('greeter', project.manualOverrideRoot);
      project.expectPackageResolvedTo('other_pkg', project.otherRoot!);
      final overrides = project.overrideFile.readAsStringSync();
      expect(overrides, contains('manual_greeter'));
      expect(overrides, isNot(contains('other_pkg:')));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'undo keeps mirrored root pubspec overrides with remaining user overrides',
    () async {
      final project = await ProjectSandbox.standalone(
        includeOtherDependency: true,
      );
      addTearDown(project.dispose);
      final manualRoot = p.join(project.root.path, 'manual_pkg');
      _writeSimplePackage(manualRoot, 'manual_pkg');

      await project.pubGet();
      _writePubspecDependencyOverride(
        project,
        packageRoot: project.stateRoot,
        package: 'other_pkg',
      );
      await project.patchwork(['patch', 'greeter']);
      project.writeEdit('Hello while keeping a mirror with user overrides');
      await project.patchwork(['commit', 'greeter']);
      await project.patchwork(['apply', 'greeter']);
      await project.pubGet();
      project.expectPackageResolvedTo('other_pkg', project.otherOverrideRoot!);

      _appendPubspecOverridesPathOverride(
        project,
        package: 'manual_pkg',
        targetRoot: manualRoot,
      );
      await project.patchwork(['undo', 'greeter']);
      await project.pubGet();

      project.expectPackageResolvedTo('other_pkg', project.otherOverrideRoot!);
      final overrides = project.overrideFile.readAsStringSync();
      expect(overrides, contains('manual_pkg:'));
      expect(overrides, contains('other_pkg:'));
      expect(overrides, isNot(contains('greeter:')));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'patch and apply ignore shadowed same-package pubspec overrides',
    () async {
      final project = await ProjectSandbox.standalone(
        includeOtherDependency: true,
      );
      addTearDown(project.dispose);

      project.writeOtherOverride();
      _writePubspecDependencyOverride(project, packageRoot: project.stateRoot);
      await project.pubGet();
      project.expectPackageResolvedTo('greeter', project.greeterRoot);

      await project.patchwork(['patch', 'greeter']);
      project.writeEdit('Hello with a shadowed pubspec override');
      await project.patchwork(['commit', 'greeter']);
      await project.patchwork(['apply', 'greeter']);

      expect(project.appliedDirectory.existsSync(), isTrue);
      expect(project.overrideFile.readAsStringSync(), contains('other_pkg:'));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'apply preserves empty active pubspec_overrides as shadowing state',
    () async {
      final project = await ProjectSandbox.standalone(
        includeOtherDependency: true,
      );
      addTearDown(project.dispose);

      _writePubspecDependencyOverride(
        project,
        packageRoot: project.stateRoot,
        package: 'other_pkg',
      );
      project.overrideFile.writeAsStringSync('dependency_overrides: {}\n');
      await project.pubGet();
      project.expectPackageResolvedTo('other_pkg', project.otherRoot!);

      await project.patchwork(['patch', 'greeter']);
      project.writeEdit('Hello with an empty override shadow');
      await project.patchwork(['commit', 'greeter']);
      await project.patchwork(['apply', 'greeter']);
      await project.pubGet();

      project.expectPackageResolvedTo('other_pkg', project.otherRoot!);
      final overrides = project.overrideFile.readAsStringSync();
      expect(overrides, contains('greeter:'));
      expect(overrides, isNot(contains('other_pkg:')));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'apply preserves active pubspec_overrides entries over shadowed pubspec',
    () async {
      final project = await ProjectSandbox.standalone(
        includeOtherDependency: true,
      );
      addTearDown(project.dispose);

      project.writeOtherOverride();
      _writePubspecDependencyOverride(
        project,
        packageRoot: project.stateRoot,
        package: 'other_pkg',
        targetRoot: project.otherRoot!,
      );
      await project.pubGet();
      project.expectPackageResolvedTo('other_pkg', project.otherOverrideRoot!);

      await project.patchwork(['patch', 'greeter']);
      project.writeEdit('Hello while preserving active overrides');
      await project.patchwork(['commit', 'greeter']);
      await project.patchwork(['apply', 'greeter']);
      await project.pubGet();

      project.expectPackageResolvedTo('other_pkg', project.otherOverrideRoot!);
      final overrides = project.overrideFile.readAsStringSync();
      expect(overrides, contains('manual_other_pkg'));
      expect(
        overrides,
        isNot(
          contains(p.relative(project.otherRoot!, from: project.stateRoot)),
        ),
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'apply does not mirror through user-owned dart tool overrides',
    () async {
      final project = await ProjectSandbox.standalone(
        includeOtherDependency: true,
      );
      addTearDown(project.dispose);
      final userPackageRoot = p.join(
        project.stateRoot,
        '.dart_tool',
        'patchwork',
        'manual_pkg@0.1.0',
      );
      _writeSimplePackage(userPackageRoot, 'manual_pkg');

      _writePubspecDependencyOverride(
        project,
        packageRoot: project.stateRoot,
        package: 'other_pkg',
      );
      project.overrideFile.writeAsStringSync('''
dependency_overrides:
  manual_pkg:
    path: .dart_tool/patchwork/manual_pkg@0.1.0
''');
      await project.pubGet();
      project.expectPackageResolvedTo('other_pkg', project.otherRoot!);

      await project.patchwork(['patch', 'greeter']);
      project.writeEdit('Hello with a user-owned dart tool override');
      await project.patchwork(['commit', 'greeter']);
      await project.patchwork(['apply', 'greeter']);
      await project.pubGet();

      project.expectPackageResolvedTo('other_pkg', project.otherRoot!);
      final overrides = project.overrideFile.readAsStringSync();
      expect(overrides, contains('manual_pkg:'));
      expect(overrides, contains('greeter:'));
      expect(overrides, isNot(contains('other_pkg:')));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'undo preserves empty pubspec_overrides shadowing state',
    () async {
      final project = await ProjectSandbox.standalone(
        includeOtherDependency: true,
      );
      addTearDown(project.dispose);

      _writePubspecDependencyOverride(
        project,
        packageRoot: project.stateRoot,
        package: 'other_pkg',
      );
      project.overrideFile.writeAsStringSync('dependency_overrides: {}\n');
      await project.pubGet();
      project.expectPackageResolvedTo('other_pkg', project.otherRoot!);

      await project.patchwork(['patch', 'greeter']);
      project.writeEdit('Hello with an empty shadow before undo');
      await project.patchwork(['commit', 'greeter']);
      await project.patchwork(['apply', 'greeter']);
      project.overrideFile.writeAsStringSync('dependency_overrides: {}\n');
      await project.patchwork(['undo', 'greeter']);
      await project.pubGet();

      expect(project.overrideFile.readAsStringSync(), contains('{}'));
      project.expectPackageResolvedTo('other_pkg', project.otherRoot!);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'undo preserves active pubspec_overrides entries matching pubspec',
    () async {
      final project = await ProjectSandbox.standalone(
        includeOtherDependency: true,
      );
      addTearDown(project.dispose);

      project.writeOtherOverride();
      _writePubspecDependencyOverride(
        project,
        packageRoot: project.stateRoot,
        package: 'other_pkg',
      );
      await project.pubGet();
      project.expectPackageResolvedTo('other_pkg', project.otherOverrideRoot!);

      await project.patchwork(['patch', 'greeter']);
      project.writeEdit('Hello without deleting active overrides');
      await project.patchwork(['commit', 'greeter']);
      await project.patchwork(['apply', 'greeter']);
      await project.patchwork(['undo', 'greeter']);
      await project.pubGet();

      project.expectPackageResolvedTo('other_pkg', project.otherOverrideRoot!);
      final overrides = project.overrideFile.readAsStringSync();
      expect(overrides, contains('other_pkg:'));
      expect(overrides, isNot(contains('greeter:')));
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
    'workspace-root inspect reports member overrides after apply',
    () async {
      final project = await ProjectSandbox.workspace();
      addTearDown(project.dispose);

      await project.pubGet();
      await project.patchwork(['patch', 'greeter']);
      project.writeEdit('Hello from an applied root patch');
      await project.patchwork(['commit', 'greeter']);
      await project.patchwork(['apply', 'greeter']);
      await project.pubGet();
      _writeWorkspaceMemberOverride(project);

      final patchwork = await Patchwork.open(project.stateRoot);
      final state = await patchwork.inspect();
      expect(
        state.problems.map((problem) => problem.code),
        contains('pub.override_conflict'),
      );
      await expectLater(
        patchwork.applyAll(),
        throwsA(
          isA<PatchworkException>().having(
            (error) => error.code,
            'code',
            'pub.override_conflict',
          ),
        ),
      );
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
        stderrContains: 'Generated patch does not apply',
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
    'apply-all skips packages already applied through pub resolution',
    () async {
      final project = await ProjectSandbox.standalone();
      addTearDown(project.dispose);

      await project.pubGet();
      await project.patchwork(['patch', 'greeter']);
      project.writeEdit('Hello from a stale apply');
      await project.patchwork(['commit', 'greeter']);
      await project.patchwork(['apply', 'greeter']);
      await project.pubGet();

      await project.patchwork(['doctor'], stdoutContains: 'greeter@0.1.0');
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

Future<void> _commitOtherPackagePatch(ProjectSandbox project) async {
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
  await project.patchwork(['commit', 'other_pkg']);
}

void _appendPubspecOverridesPathOverride(
  ProjectSandbox project, {
  required String package,
  required String targetRoot,
}) {
  final existing = project.overrideFile.existsSync()
      ? project.overrideFile.readAsStringSync().trimRight()
      : 'dependency_overrides:';
  project.overrideFile.writeAsStringSync('''
$existing
  $package:
    path: ${p.relative(targetRoot, from: project.stateRoot)}
''');
}

void _writeSimplePackage(String root, String package) {
  Directory(p.join(root, 'lib')).createSync(recursive: true);
  File(p.join(root, 'pubspec.yaml')).writeAsStringSync('''
name: $package
version: 0.1.0
publish_to: none

environment:
  sdk: ^3.12.0
''');
  File(p.join(root, 'lib', '$package.dart')).writeAsStringSync('''
String packageName() {
  return '$package';
}
''');
}

void _addPathDependency(
  ProjectSandbox project,
  String package,
  String packageRoot,
) {
  final pubspec = File(p.join(project.stateRoot, 'pubspec.yaml'));
  pubspec.writeAsStringSync(
    pubspec.readAsStringSync().replaceFirst('dependencies:\n', '''
dependencies:
  $package:
    path: ${p.relative(packageRoot, from: project.stateRoot)}
'''),
  );
}

void _writePubspecDependencyOverride(
  ProjectSandbox project, {
  required String packageRoot,
  String package = 'greeter',
  String? targetRoot,
}) {
  final pubspec = File(p.join(packageRoot, 'pubspec.yaml'));
  final overrideRoot = targetRoot ?? _overrideTargetRoot(project, package);
  final pubspecContent = _withoutPubspecDependencyOverrides(
    pubspec.readAsStringSync(),
  );
  pubspec.writeAsStringSync('''
$pubspecContent

dependency_overrides:
  $package:
    path: ${p.relative(overrideRoot, from: packageRoot)}
''');
}

void _removePubspecDependencyOverrides(String packageRoot) {
  final pubspec = File(p.join(packageRoot, 'pubspec.yaml'));
  pubspec.writeAsStringSync(
    '${_withoutPubspecDependencyOverrides(pubspec.readAsStringSync())}\n',
  );
}

String _withoutPubspecDependencyOverrides(String content) {
  const marker = '\ndependency_overrides:\n';
  final index = content.lastIndexOf(marker);
  if (index < 0) {
    return content.trimRight();
  }
  return content.substring(0, index).trimRight();
}

String _overrideTargetRoot(ProjectSandbox project, String package) {
  if (package == 'greeter') {
    return project.manualOverrideRoot;
  }
  if (package == 'other_pkg') {
    final otherRoot = project.otherOverrideRoot;
    if (otherRoot != null) {
      return otherRoot;
    }
  }
  fail('No override target root is available for $package.');
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
