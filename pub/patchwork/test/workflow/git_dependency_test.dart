import 'package:test/test.dart';

import 'project_sandbox.dart';

void main() {
  test(
    'patches a dependency resolved from a real local git repository',
    () async {
      final project = await ProjectSandbox.gitDependency();
      addTearDown(project.dispose);

      await project.pubGet();
      await project.patchwork(['patch', 'greeter']);
      project.writeEdit('Hello from a git patch');
      await project.patchwork(['commit', 'greeter']);

      expect(project.lockfile.readAsStringSync(), isNot(contains('git')));

      await project.patchwork(['apply', 'greeter']);
      final lockfile = project.lockfile.readAsStringSync();
      expect(lockfile, contains('type: "git"'));
      expect(lockfile, contains('branch: "main"'));
      expect(lockfile, contains('commit:'));

      await project.pubGet();
      await project.runApp('Hello from a git patch, Patchwork!');
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
