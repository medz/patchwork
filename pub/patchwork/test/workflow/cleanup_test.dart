@Tags(['full'])
library;

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
      await project.application(['patch', 'greeter']);
      project.writeEdit('Hello from a stale patch');
      await project.application(['commit', 'greeter']);
      final oldPatch = File(
        p.join(project.stateRoot, 'patches', 'greeter@0.1.0.patch'),
      );
      expect(oldPatch.existsSync(), isTrue);

      project.updateGreeterPackage(
        version: '0.1.1',
        greeting: 'Hello, \$name!',
      );
      await project.pubGet();
      await project.application(
        ['doctor'],
        exitCodes: {1},
        stdoutContains: 'patchwork remove greeter 0.1.0',
      );

      await project.application(
        ['remove', 'greeter', '0.1.0', '--dry-run'],
        stdoutContains: 'Would remove patch file patches/greeter@0.1.0.patch.',
      );
      expect(oldPatch.existsSync(), isTrue);

      final dryRunJson = await project.applicationResult([
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

      await project.application([
        'remove',
        'greeter',
        '0.1.0',
      ], stdoutContains: 'Removed patch file patches/greeter@0.1.0.patch.');
      expect(oldPatch.existsSync(), isFalse);
      await project.application(['doctor'], stdoutContains: 'No patchwork');
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'remove refuses open edits unless forced',
    () async {
      final project = await ProjectSandbox.standalone();
      addTearDown(project.dispose);

      await project.pubGet();
      await project.application(['patch', 'greeter']);
      project.writeEdit('Hello from an open edit');

      await project.application(
        ['remove', 'greeter'],
        exitCodes: {1},
        stderrContains: 'has an open edit directory',
      );
      expect(project.editDirectoryFor('0.1.0').existsSync(), isTrue);

      await project.application(
        ['remove', 'greeter', '--force', '--dry-run'],
        stdoutContains: 'Would remove edit directory .patchwork/greeter@0.1.0.',
      );
      expect(project.editDirectoryFor('0.1.0').existsSync(), isTrue);

      await project.application([
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
      await project.application(['patch', 'greeter']);
      project.writeEdit('Hello from a committed patch');
      await project.application(['commit', 'greeter']);
      await project.application(['patch', 'greeter']);

      final doctor = await project.applicationResult(
        ['doctor'],
        exitCodes: {1},
      );
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
      await project.application(['patch', 'greeter']);
      project.writeEdit('Hello from a removable patch');
      await project.application(['commit', 'greeter']);
      project.writeOtherOverride();
      await project.application(['apply', 'greeter']);
      final patchFile = File(
        p.join(project.stateRoot, 'patches', 'greeter@0.1.0.patch'),
      );
      expect(patchFile.existsSync(), isTrue);
      expect(project.appliedDirectory.existsSync(), isTrue);

      await project.application(
        ['remove', 'greeter'],
        exitCodes: {1},
        stderrContains: 'has applied Patchwork state',
      );
      expect(patchFile.existsSync(), isTrue);
      expect(project.appliedDirectory.existsSync(), isTrue);

      final dryRun = await project.applicationResult([
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

      await project.application(['remove', 'greeter', '--force']);
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
    'remove force refuses applied output referenced by pubspec dependency override',
    () async {
      final project = await ProjectSandbox.standalone();
      addTearDown(project.dispose);

      await project.pubGet();
      await project.application(['patch', 'greeter']);
      project.writeEdit('Hello from a forced remove guard');
      await project.application(['commit', 'greeter']);
      await project.application(['apply', 'greeter']);
      final patchFile = File(
        p.join(project.stateRoot, 'patches', 'greeter@0.1.0.patch'),
      );
      expect(patchFile.existsSync(), isTrue);
      expect(project.appliedDirectory.existsSync(), isTrue);

      project.overrideFile.deleteSync();
      final pubspec = File(p.join(project.appRoot, 'pubspec.yaml'));
      pubspec.writeAsStringSync('''
${pubspec.readAsStringSync()}
dependency_overrides:
  greeter:
    path: .dart_tool/patchwork/greeter@0.1.0
''');
      await project.pubGet();
      project.expectPackageResolvedTo('greeter', project.appliedDirectory.path);

      await project.application(
        ['remove', 'greeter', '--force'],
        exitCodes: {1},
        stderrContains: 'still referenced by pubspec.yaml',
      );
      expect(patchFile.existsSync(), isTrue);
      expect(project.appliedDirectory.existsSync(), isTrue);
      project.expectPackageResolvedTo('greeter', project.appliedDirectory.path);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'prune removes stale patch files and unreferenced generated output',
    () async {
      final staleProject = await ProjectSandbox.standalone();
      addTearDown(staleProject.dispose);

      await staleProject.pubGet();
      await staleProject.application(['patch', 'greeter']);
      staleProject.writeEdit('Hello from prune');
      await staleProject.application(['commit', 'greeter']);
      final stalePatch = File(
        p.join(staleProject.stateRoot, 'patches', 'greeter@0.1.0.patch'),
      );
      staleProject.updateGreeterPackage(
        version: '0.1.1',
        greeting: 'Hello, \$name!',
      );
      await staleProject.pubGet();

      await staleProject.application(
        ['prune', '--dry-run'],
        stdoutContains: 'Would remove patch file patches/greeter@0.1.0.patch.',
      );
      expect(stalePatch.existsSync(), isTrue);

      await staleProject.application([
        'prune',
      ], stdoutContains: 'Removed patch file patches/greeter@0.1.0.patch.');
      expect(stalePatch.existsSync(), isFalse);

      final appliedProject = await ProjectSandbox.standalone();
      addTearDown(appliedProject.dispose);

      await appliedProject.pubGet();
      await appliedProject.application(['patch', 'greeter']);
      appliedProject.writeEdit('Hello from unreferenced output');
      await appliedProject.application(['commit', 'greeter']);
      await appliedProject.application(['apply', 'greeter']);
      expect(appliedProject.appliedDirectory.existsSync(), isTrue);
      appliedProject.overrideFile.deleteSync();

      await appliedProject.application(
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

  test(
    'prune preserves generated output referenced by pubspec dependency override',
    () async {
      final project = await ProjectSandbox.standalone();
      addTearDown(project.dispose);

      await project.pubGet();
      await project.application(['patch', 'greeter']);
      project.writeEdit('Hello from pubspec override');
      await project.application(['commit', 'greeter']);
      await project.application(['apply', 'greeter']);
      expect(project.appliedDirectory.existsSync(), isTrue);

      project.overrideFile.deleteSync();
      final pubspec = File(p.join(project.appRoot, 'pubspec.yaml'));
      pubspec.writeAsStringSync('''
${pubspec.readAsStringSync()}
dependency_overrides:
  greeter:
    path: .dart_tool/patchwork/greeter@0.1.0
''');
      await project.pubGet();
      project.expectPackageResolvedTo('greeter', project.appliedDirectory.path);

      await project.application([
        'prune',
      ], stdoutContains: 'No patchwork artifacts to prune.');
      expect(project.appliedDirectory.existsSync(), isTrue);
      project.expectPackageResolvedTo('greeter', project.appliedDirectory.path);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'prune force refuses stale applied output referenced by pubspec dependency override',
    () async {
      final project = await ProjectSandbox.standalone();
      addTearDown(project.dispose);

      await project.pubGet();
      await project.application(['patch', 'greeter']);
      project.writeEdit('Hello from a forced prune guard');
      await project.application(['commit', 'greeter']);
      await project.application(['apply', 'greeter']);
      final patchFile = File(
        p.join(project.stateRoot, 'patches', 'greeter@0.1.0.patch'),
      );
      expect(patchFile.existsSync(), isTrue);
      expect(project.appliedDirectory.existsSync(), isTrue);

      project.overrideFile.deleteSync();
      final pubspec = File(p.join(project.appRoot, 'pubspec.yaml'));
      pubspec.writeAsStringSync('''
${pubspec.readAsStringSync()}
dependency_overrides:
  greeter:
    path: .dart_tool/patchwork/greeter@0.1.0
''');
      final appliedPubspec = File(
        p.join(project.appliedDirectory.path, 'pubspec.yaml'),
      );
      appliedPubspec.writeAsStringSync(
        appliedPubspec.readAsStringSync().replaceFirst(
          'version: 0.1.0',
          'version: 0.1.1',
        ),
      );
      await project.pubGet();
      project.expectPackageResolvedTo('greeter', project.appliedDirectory.path);

      await project.application(
        ['prune', '--force'],
        exitCodes: {1},
        stderrContains: 'still referenced by pubspec.yaml',
      );
      expect(patchFile.existsSync(), isTrue);
      expect(project.appliedDirectory.existsSync(), isTrue);
      project.expectPackageResolvedTo('greeter', project.appliedDirectory.path);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'prune removes stale patch files for packages that became workspace roots',
    () async {
      final project = await ProjectSandbox.workspace();
      addTearDown(project.dispose);

      await project.pubGet();
      final stalePatch = File(
        p.join(project.stateRoot, 'patches', 'member_greeter@0.1.0.patch'),
      );
      stalePatch.parent.createSync(recursive: true);
      stalePatch.writeAsStringSync('stale patch');

      await project.application(
        ['prune'],
        stdoutContains:
            'Removed patch file patches/member_greeter@0.1.0.patch.',
      );
      expect(stalePatch.existsSync(), isFalse);
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
