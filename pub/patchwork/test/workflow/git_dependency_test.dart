import 'dart:convert';

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
      final manifest =
          jsonDecode(project.editManifestFor('0.1.0').readAsStringSync())
              as Map<String, Object?>;
      final createdFrom = manifest['createdFrom'] as Map<String, Object?>;
      final fields = createdFrom['fields'] as Map<String, Object?>;
      expect(createdFrom['sourceType'], 'git');
      expect(fields['branch'], 'main');
      expect(fields, contains('commit'));

      project.writeEdit('Hello from a git patch');
      await project.patchwork(['commit', 'greeter']);

      await project.patchwork(['apply', 'greeter']);

      await project.pubGet();
      await project.runApp('Hello from a git patch, Patchwork!');
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
