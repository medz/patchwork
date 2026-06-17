import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'project_sandbox.dart';

void main() {
  test(
    'patches, applies, continues, and forces a standalone project dependency',
    () async {
      final project = await ProjectSandbox.standalone();
      addTearDown(project.dispose);

      await project.pubGet();
      await project.patchwork(['doctor'], stdoutContains: 'No patchwork');

      await project.patchwork(['patch', 'greeter']);
      project.writeEdit('Hello from a standalone patch');
      await project.patchwork(['commit']);
      await project.patchwork(['apply']);
      await project.patchwork(
        ['patch', 'greeter'],
        exitCodes: {1},
        stderrContains: 'already has an applied Patchwork patch',
      );
      await project.patchwork(
        ['doctor'],
        exitCodes: {1},
        stdoutContains: 'pub resolution has not activated',
      );
      await project.patchwork(
        ['doctor'],
        exitCodes: {1},
        stdoutContains: 'applied: .dart_tool/patchwork/greeter@0.1.0',
      );

      await project.pubGet();
      await project.patchwork([
        'doctor',
      ], stdoutContains: 'applied: .dart_tool/patchwork/greeter@0.1.0');
      await project.patchwork([
        'status',
      ], stdoutContains: 'applied: .dart_tool/patchwork/greeter@0.1.0');
      await project.patchwork([
        'apply',
      ], stdoutContains: 'No patches need apply.');
      await project.runApp('Hello from a standalone patch, Patchwork!');

      await project.patchwork(['undo', 'greeter']);
      await project.pubGet();
      await project.patchwork(
        ['doctor'],
        exitCodes: {1},
        stdoutContains: 'action: patchwork apply greeter',
      );
      await project.runApp('Hello, Patchwork!');

      await project.patchwork(['patch', 'greeter', '--continue']);
      expect(
        project.editFile.readAsStringSync(),
        contains('Hello from a standalone patch'),
      );
      await project.patchwork(['commit', 'greeter']);

      project.writeManualOverride();
      await project.patchwork(
        ['apply', 'greeter'],
        exitCodes: {1},
        stderrContains: 'already has a dependency override',
      );
      expect(
        project.overrideFile.readAsStringSync(),
        contains('manual_greeter'),
      );
      expect(project.appliedDirectory.existsSync(), isFalse);
      await project.patchwork(
        ['doctor'],
        exitCodes: {1},
        stdoutContains: 'already has a dependency override',
      );
      await project.patchwork([
        'status',
      ], stdoutContains: 'already has a dependency override');

      project.overrideFile.deleteSync();
      await project.pubGet();
      await project.patchwork(['patch', 'greeter']);
      project.editFile.writeAsStringSync('dirty edit\n');
      await project.patchwork(['patch', 'greeter'], exitCodes: {1});
      await project.patchwork(
        ['patch', 'greeter', '--force', '--continue', '9.9.9'],
        exitCodes: {1},
        stderrContains: 'Patch file does not exist',
      );
      expect(project.editFile.readAsStringSync(), 'dirty edit\n');
      await project.patchwork(['patch', 'greeter', '--force']);
      expect(project.editFile.readAsStringSync(), contains('Hello, \$name!'));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'can continue an old version patch after the dependency version changes',
    () async {
      final project = await ProjectSandbox.standalone();
      addTearDown(project.dispose);

      await project.pubGet();
      await project.patchwork(['patch', 'greeter']);
      project.writeEdit('Hello from a carried patch');
      await project.patchwork(['commit', 'greeter']);

      project.updateGreeterPackage(
        version: '0.1.1',
        greeting: 'Hello, \$name!',
      );
      await project.pubGet();

      await project.patchwork(['patch', 'greeter', '--continue', '0.1.0']);
      expect(
        project.editFileFor('0.1.1').readAsStringSync(),
        contains('Hello from a carried patch'),
      );
      project.editDirectoryFor('0.1.1').deleteSync(recursive: true);
      await project.patchwork(
        ['doctor'],
        exitCodes: {1},
        stdoutContains: 'only historical patches',
      );

      await project.patchwork(['patch', 'greeter', '--continue', '0.1.0']);
      expect(
        project.editFileFor('0.1.1').readAsStringSync(),
        contains('Hello from a carried patch'),
      );
      project.editDirectoryFor('0.1.1').deleteSync(recursive: true);

      File(
        p.join(project.stateRoot, 'patches', 'greeter@0.1.0.patch'),
      ).writeAsStringSync('tampered\n');
      await project.patchwork(
        ['patch', 'greeter', '--continue', '0.1.0'],
        exitCodes: {1},
        stderrContains: 'sha256 does not match',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'can continue a same-version patch after the dependency source changes',
    () async {
      final project = await ProjectSandbox.standalone();
      addTearDown(project.dispose);

      await project.pubGet();
      await project.patchwork(['patch', 'greeter']);
      project.writeEdit('Hello from a same-version patch');
      await project.patchwork(['commit', 'greeter']);

      File(
        p.join(project.greeterRoot, 'lib', 'upstream.dart'),
      ).writeAsStringSync("const upstream = 'changed';\n");
      await project.pubGet();

      await project.patchwork(['patch', 'greeter']);
      expect(
        File(
          p.join(
            project.editDirectoryFor('0.1.0').path,
            'lib',
            'upstream.dart',
          ),
        ).existsSync(),
        isTrue,
      );
      project.editDirectoryFor('0.1.0').deleteSync(recursive: true);

      await project.patchwork(['patch', 'greeter', '--continue', '0.1.0']);
      expect(
        project.editFileFor('0.1.0').readAsStringSync(),
        contains('Hello from a same-version patch'),
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'commit removes an unchanged edit without leaving a package record',
    () async {
      final project = await ProjectSandbox.standalone();
      addTearDown(project.dispose);

      await project.pubGet();
      await project.patchwork(['patch', 'greeter']);
      await project.patchwork([
        'commit',
        'greeter',
      ], stdoutContains: 'has no changes');

      expect(project.editDirectoryFor('0.1.0').existsSync(), isFalse);
      await project.patchwork(['doctor'], stdoutContains: 'No patchwork');
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
