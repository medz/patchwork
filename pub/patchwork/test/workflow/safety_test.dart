import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'project_sandbox.dart';

void main() {
  test(
    'undo refuses an applied path outside the package version output',
    () async {
      final project = await ProjectSandbox.standalone();
      addTearDown(project.dispose);

      await project.pubGet();
      await project.patchwork(['patch', 'greeter']);
      project.writeEdit('Hello from a safe patch');
      await project.patchwork(['commit', 'greeter']);
      await project.patchwork(['apply', 'greeter']);

      final unsafePath = p.join('.dart_tool', 'patchwork', 'not-greeter@0.1.0');
      project.lockfile.writeAsStringSync(
        project.lockfile.readAsStringSync().replaceAll(
          '.dart_tool/patchwork/greeter@0.1.0',
          unsafePath,
        ),
      );
      final sentinel = File(p.join(project.stateRoot, unsafePath, 'sentinel'));
      sentinel.parent.createSync(recursive: true);
      sentinel.writeAsStringSync('do not delete');

      await project.patchwork(
        ['undo', 'greeter'],
        exitCodes: {1},
        stderrContains: 'applied path does not match',
      );
      expect(sentinel.existsSync(), isTrue);
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
      sha256: "patch"
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
        ['apply', 'greeter'],
        exitCodes: {1},
        stderrContains: 'open edit directory',
      );
      await project.patchwork([
        'apply',
      ], stdoutContains: 'No patches need apply.');
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
}
