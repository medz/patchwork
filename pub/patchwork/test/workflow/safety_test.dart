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
}
