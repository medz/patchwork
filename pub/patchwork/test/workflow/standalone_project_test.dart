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
      await project.patchwork(['commit', 'greeter']);
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
      await project.runApp('Hello from a standalone patch, Patchwork!');

      await project.patchwork(['undo', 'greeter']);
      await project.pubGet();
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
      await project.patchwork(['patch', 'greeter', '--force']);
      expect(project.editFile.readAsStringSync(), contains('Hello, \$name!'));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
