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
        ['doctor'],
        exitCodes: {1},
        stdoutContains: 'pub resolution has not activated',
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
      await project.patchwork([
        'doctor',
      ], stdoutContains: 'action: patchwork apply greeter');
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

      await project.patchwork(['patch', 'greeter', '--continue', '0.1.0']);
      expect(
        project.editFileFor('0.1.1').readAsStringSync(),
        contains('Hello from a carried patch'),
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
