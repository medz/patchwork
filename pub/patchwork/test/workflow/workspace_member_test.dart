import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'project_sandbox.dart';

void main() {
  test(
    'patches a workspace member direct dependency without patching members',
    () async {
      final project = await ProjectSandbox.workspace();
      addTearDown(project.dispose);

      await project.pubGet();
      await project.patchwork(['doctor'], stdoutContains: 'No patchwork');
      await project.patchwork(
        ['patch', 'member_greeter'],
        exitCodes: {1},
        stderrContains: 'workspace/root package',
      );
      await project.patchwork(
        ['patch', 'patchwork_test_app'],
        exitCodes: {1},
        stderrContains: 'workspace/root package',
      );
      await project.patchwork(
        ['patch', 'patchwork'],
        exitCodes: {1},
        stderrContains: 'not a direct dependency',
      );

      await project.patchwork(['patch', 'greeter']);
      project.writeEdit('Hello from a workspace patch');
      await project.patchwork(['commit']);
      await project.patchwork(['apply', 'greeter']);
      await project.pubGet();
      await project.patchwork([
        'doctor',
      ], stdoutContains: 'applied: .dart_tool/patchwork/greeter@0.1.0');
      await project.patchwork([
        'status',
      ], stdoutContains: 'applied: .dart_tool/patchwork/greeter@0.1.0');
      await project.runApp('Hello from a workspace patch, Patchwork!');

      await project.patchwork(['undo', 'greeter']);
      await project.pubGet();
      await project.patchwork(
        ['doctor'],
        exitCodes: {1},
        stdoutContains: 'action: patchwork apply greeter',
      );
      await project.runApp('Hello, Patchwork!');

      await project.patchwork(['apply']);
      await project.pubGet();
      await project.runApp('Hello from a workspace patch, Patchwork!');
      await project.patchwork(['undo', 'greeter']);
      await project.pubGet();
      await project.runApp('Hello, Patchwork!');

      await project.patchwork(['patch', 'greeter', '--continue']);
      expect(
        project.editFile.readAsStringSync(),
        contains('Hello from a workspace patch'),
      );
      await project.patchwork(['commit', 'greeter']);

      project.writeManualOverride();
      await project.pubGet();
      await project.patchwork(
        ['apply', 'greeter'],
        exitCodes: {1},
        stderrContains: 'already has a dependency override',
      );
      await project.patchwork(
        ['doctor'],
        exitCodes: {1},
        stdoutContains: 'already has a dependency override',
      );
      await project.patchwork([
        'status',
      ], stdoutContains: 'already has a dependency override');
      expect(
        project.overrideFile.readAsStringSync(),
        contains('manual_greeter'),
      );
      expect(project.appliedDirectory.existsSync(), isFalse);

      project.overrideFile.deleteSync();
      await project.pubGet();
      await project.patchwork(['patch', 'greeter']);
      project.editFile.writeAsStringSync('dirty edit\n');
      await project.patchwork(['patch', 'greeter'], exitCodes: {1});
      await project.patchwork(['patch', 'greeter', '--force']);
      expect(project.editFile.readAsStringSync(), contains('Hello, \$name!'));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'can continue an old version patch after a workspace dependency changes',
    () async {
      final project = await ProjectSandbox.workspace();
      addTearDown(project.dispose);

      await project.pubGet();
      await project.patchwork(['patch', 'greeter']);
      project.writeEdit('Hello from a carried workspace patch');
      await project.patchwork(['commit', 'greeter']);

      project.updateGreeterPackage(
        version: '0.1.1',
        greeting: 'Hello, \$name!',
      );
      await project.pubGet();

      await project.patchwork(['patch', 'greeter', '--continue', '0.1.0']);
      expect(
        project.editFileFor('0.1.1').readAsStringSync(),
        contains('Hello from a carried workspace patch'),
      );
      project.editDirectoryFor('0.1.1').deleteSync(recursive: true);

      await project.patchwork(['patch', 'greeter', '--continue', '0.1.0']);
      expect(
        project.editFileFor('0.1.1').readAsStringSync(),
        contains('Hello from a carried workspace patch'),
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'can continue a same-version patch after a workspace dependency source changes',
    () async {
      final project = await ProjectSandbox.workspace();
      addTearDown(project.dispose);

      await project.pubGet();
      await project.patchwork(['patch', 'greeter']);
      project.writeEdit('Hello from a same-version workspace patch');
      await project.patchwork(['commit', 'greeter']);

      File(
        p.join(project.greeterRoot, 'lib', 'workspace_upstream.dart'),
      ).writeAsStringSync("const upstream = 'changed';\n");
      await project.pubGet();

      await project.patchwork(['patch', 'greeter']);
      expect(
        File(
          p.join(
            project.editDirectoryFor('0.1.0').path,
            'lib',
            'workspace_upstream.dart',
          ),
        ).existsSync(),
        isTrue,
      );
      project.editDirectoryFor('0.1.0').deleteSync(recursive: true);

      await project.patchwork(['patch', 'greeter', '--continue', '0.1.0']);
      expect(
        project.editFileFor('0.1.0').readAsStringSync(),
        contains('Hello from a same-version workspace patch'),
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'applies and reports member patch state from the workspace root',
    () async {
      final project = await ProjectSandbox.workspace();
      addTearDown(project.dispose);

      await project.pubGet();
      await project.patchwork(['patch', 'greeter']);
      project.writeEdit('Hello from a workspace-root apply');
      await project.patchwork(['commit', 'greeter']);

      await project.patchwork(
        ['doctor'],
        workingDirectory: project.stateRoot,
        exitCodes: {1},
        stdoutContains: 'action: patchwork apply greeter',
      );
      await project.patchwork(
        ['status'],
        workingDirectory: project.stateRoot,
        stdoutContains: 'action: patchwork apply greeter',
      );
      await project.patchwork(['apply'], workingDirectory: project.stateRoot);
      await project.pubGet();
      await project.patchwork(
        ['status'],
        workingDirectory: project.stateRoot,
        stdoutContains: 'applied: .dart_tool/patchwork/greeter@0.1.0',
      );
      await project.runApp('Hello from a workspace-root apply, Patchwork!');
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'preserves user-owned workspace dependency overrides',
    () async {
      final project = await ProjectSandbox.workspace(
        includeOtherDependency: true,
      );
      addTearDown(project.dispose);

      await project.pubGet();
      await project.patchwork(['patch', 'greeter']);
      project.writeEdit('Hello from a workspace override patch');
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
}
