import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'project_sandbox.dart';

void main() {
  test(
    'remove dry-runs and deletes an explicit stale patch file',
    () async {
      final project = await ProjectSandbox.standalone();
      addTearDown(project.dispose);

      await project.pubGet();
      await project.patchwork(['patch', 'greeter']);
      project.writeEdit('Hello from a stale patch');
      await project.patchwork(['commit', 'greeter']);
      final oldPatch = File(
        p.join(project.stateRoot, 'patches', 'greeter@0.1.0.patch'),
      );
      expect(oldPatch.existsSync(), isTrue);

      project.updateGreeterPackage(
        version: '0.1.1',
        greeting: 'Hello, \$name!',
      );
      await project.pubGet();
      await project.patchwork(
        ['doctor'],
        exitCodes: {1},
        stdoutContains: 'patchwork remove greeter 0.1.0',
      );

      await project.patchwork(
        ['remove', 'greeter', '0.1.0', '--dry-run'],
        stdoutContains: 'Would remove patch file patches/greeter@0.1.0.patch.',
      );
      expect(oldPatch.existsSync(), isTrue);

      final dryRunJson = await project.patchworkResult([
        'remove',
        'greeter',
        '0.1.0',
        '--dry-run',
        '--json',
      ]);
      expect(_decodeObject(dryRunJson.stdout), {
        'command': 'remove',
        'dryRun': true,
        'force': false,
        'changes': [
          {
            'kind': 'patchFile',
            'package': 'greeter',
            'version': '0.1.0',
            'path': 'patches/greeter@0.1.0.patch',
          },
        ],
        'pubGetRan': false,
        'needsPubGet': false,
      });
      expect(oldPatch.existsSync(), isTrue);

      await project.patchwork([
        'remove',
        'greeter',
        '0.1.0',
      ], stdoutContains: 'Removed patch file patches/greeter@0.1.0.patch.');
      expect(oldPatch.existsSync(), isFalse);
      await project.patchwork(['doctor'], stdoutContains: 'No patchwork');
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'remove refuses open edits unless forced',
    () async {
      final project = await ProjectSandbox.standalone();
      addTearDown(project.dispose);

      await project.pubGet();
      await project.patchwork(['patch', 'greeter']);
      project.writeEdit('Hello from an open edit');

      await project.patchwork(
        ['remove', 'greeter'],
        exitCodes: {1},
        stderrContains: 'has an open edit directory',
      );
      expect(project.editDirectoryFor('0.1.0').existsSync(), isTrue);

      await project.patchwork(
        ['remove', 'greeter', '--force', '--dry-run'],
        stdoutContains: 'Would remove edit directory .patchwork/greeter@0.1.0.',
      );
      expect(project.editDirectoryFor('0.1.0').existsSync(), isTrue);

      await project.patchwork([
        'remove',
        'greeter',
        '--force',
      ], stdoutContains: 'Removed edit directory .patchwork/greeter@0.1.0.');
      expect(project.editDirectoryFor('0.1.0').existsSync(), isFalse);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'doctor does not suggest remove force for open edits with committed patches',
    () async {
      final project = await ProjectSandbox.standalone();
      addTearDown(project.dispose);

      await project.pubGet();
      await project.patchwork(['patch', 'greeter']);
      project.writeEdit('Hello from a committed patch');
      await project.patchwork(['commit', 'greeter']);
      await project.patchwork(['patch', 'greeter']);

      final doctor = await project.patchworkResult(['doctor'], exitCodes: {1});
      expect(
        doctor.stdout,
        contains('Run patchwork commit greeter before applying this patch.'),
      );
      expect(
        doctor.stdout,
        isNot(contains('patchwork remove greeter 0.1.0 --force')),
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'remove refuses applied state unless forced and preserves user overrides',
    () async {
      final project = await ProjectSandbox.standalone(
        includeOtherDependency: true,
      );
      addTearDown(project.dispose);

      await project.pubGet();
      await project.patchwork(['patch', 'greeter']);
      project.writeEdit('Hello from a removable patch');
      await project.patchwork(['commit', 'greeter']);
      project.writeOtherOverride();
      await project.patchwork(['apply', 'greeter']);
      final patchFile = File(
        p.join(project.stateRoot, 'patches', 'greeter@0.1.0.patch'),
      );
      expect(patchFile.existsSync(), isTrue);
      expect(project.appliedDirectory.existsSync(), isTrue);

      await project.patchwork(
        ['remove', 'greeter'],
        exitCodes: {1},
        stderrContains: 'has applied Patchwork state',
      );
      expect(patchFile.existsSync(), isTrue);
      expect(project.appliedDirectory.existsSync(), isTrue);

      final dryRun = await project.patchworkResult([
        'remove',
        'greeter',
        '--force',
        '--dry-run',
        '--json',
      ]);
      final dryRunChanges = _objects(_decodeObject(dryRun.stdout)['changes']);
      expect(
        dryRunChanges.map((change) => change['kind']),
        containsAll(['patchFile', 'appliedDirectory', 'pubspecOverride']),
      );
      expect(patchFile.existsSync(), isTrue);
      expect(project.appliedDirectory.existsSync(), isTrue);

      await project.patchwork(['remove', 'greeter', '--force']);
      expect(patchFile.existsSync(), isFalse);
      expect(project.appliedDirectory.existsSync(), isFalse);
      expect(project.overrideFile.readAsStringSync(), contains('other_pkg:'));
      expect(
        project.overrideFile.readAsStringSync(),
        isNot(contains('greeter:')),
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'prune removes stale patch files and unreferenced generated output',
    () async {
      final staleProject = await ProjectSandbox.standalone();
      addTearDown(staleProject.dispose);

      await staleProject.pubGet();
      await staleProject.patchwork(['patch', 'greeter']);
      staleProject.writeEdit('Hello from prune');
      await staleProject.patchwork(['commit', 'greeter']);
      final stalePatch = File(
        p.join(staleProject.stateRoot, 'patches', 'greeter@0.1.0.patch'),
      );
      staleProject.updateGreeterPackage(
        version: '0.1.1',
        greeting: 'Hello, \$name!',
      );
      await staleProject.pubGet();

      await staleProject.patchwork(
        ['prune', '--dry-run'],
        stdoutContains: 'Would remove patch file patches/greeter@0.1.0.patch.',
      );
      expect(stalePatch.existsSync(), isTrue);

      await staleProject.patchwork([
        'prune',
      ], stdoutContains: 'Removed patch file patches/greeter@0.1.0.patch.');
      expect(stalePatch.existsSync(), isFalse);

      final appliedProject = await ProjectSandbox.standalone();
      addTearDown(appliedProject.dispose);

      await appliedProject.pubGet();
      await appliedProject.patchwork(['patch', 'greeter']);
      appliedProject.writeEdit('Hello from unreferenced output');
      await appliedProject.patchwork(['commit', 'greeter']);
      await appliedProject.patchwork(['apply', 'greeter']);
      expect(appliedProject.appliedDirectory.existsSync(), isTrue);
      appliedProject.overrideFile.deleteSync();

      await appliedProject.patchwork(
        ['prune'],
        stdoutContains:
            'Removed applied directory .dart_tool/patchwork/greeter@0.1.0.',
      );
      expect(appliedProject.appliedDirectory.existsSync(), isFalse);
      appliedProject.expectPackageResolvedTo(
        'greeter',
        appliedProject.greeterRoot,
      );
      expect(
        File(
          p.join(appliedProject.stateRoot, 'patches', 'greeter@0.1.0.patch'),
        ).existsSync(),
        isTrue,
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

Map<String, Object?> _decodeObject(String source) {
  final decoded = jsonDecode(source);
  if (decoded is! Map) {
    fail('Expected a JSON object, got ${decoded.runtimeType}.');
  }
  return decoded.cast<String, Object?>();
}

List<Map<String, Object?>> _objects(Object? value) {
  if (value is! List) {
    fail('Expected a JSON array, got ${value.runtimeType}.');
  }
  return [
    for (final item in value)
      if (item is Map)
        item.cast<String, Object?>()
      else
        fail('Expected a JSON object item, got ${item.runtimeType}.'),
  ];
}
