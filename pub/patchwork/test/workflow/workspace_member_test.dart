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
        ['patch', 'patchwork'],
        exitCodes: {1},
        stderrContains: 'not a direct dependency',
      );

      await project.patchwork(['patch', 'greeter']);
      project.writeEdit('Hello from a workspace patch');
      await project.patchwork(['commit', 'greeter']);
      await project.patchwork(['apply']);
      await project.pubGet();
      await project.patchwork([
        'status',
      ], stdoutContains: 'applied: .dart_tool/patchwork/greeter@0.1.0');
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
        stderrContains: 'source does not match patchwork.lock',
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
      await project.patchwork(['patch', 'greeter', '--force']);
      expect(project.editFile.readAsStringSync(), contains('Hello, \$name!'));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
