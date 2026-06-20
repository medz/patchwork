import 'dart:convert';

import 'package:test/test.dart';

import 'project_sandbox.dart';

void main() {
  test(
    'renders machine-readable JSON for state and action commands',
    () async {
      final project = await ProjectSandbox.standalone();
      addTearDown(project.dispose);

      await project.pubGet();
      final emptyStatus = await project.patchworkResult(['status', '--json']);
      expect(emptyStatus.stdout, isNot(contains('No patchwork packages.')));
      expect(_decodeObject(emptyStatus.stdout), {
        'packages': [],
        'needsApply': [],
        'problems': [],
      });

      final patchResult = await project.patchworkResult([
        'patch',
        'greeter',
        '--json',
      ]);
      expect(patchResult.stdout, isNot(contains('Created edit')));
      final patchJson = _decodeObject(patchResult.stdout);
      expect(patchJson['command'], 'patch');
      final editJson = _object(patchJson['edit']);
      expect(editJson['package'], 'greeter');
      expect(editJson['version'], '0.1.0');
      expect(editJson['path'], '.patchwork/greeter@0.1.0');
      expect(editJson['sourcePath'], endsWith('/packages/greeter'));
      expect(editJson['continuedFromPatchPath'], isNull);

      project.writeEdit('Hello from JSON output');
      final commitResult = await project.patchworkResult([
        'commit',
        '--json',
        'greeter',
      ]);
      expect(commitResult.stdout, isNot(contains('Wrote ')));
      final commitJson = _decodeObject(commitResult.stdout);
      expect(commitJson['command'], 'commit');
      final writeJson = _objects(commitJson['writes']).single;
      expect(writeJson['package'], 'greeter');
      expect(writeJson['version'], '0.1.0');
      expect(writeJson['status'], 'written');
      expect(writeJson['editPath'], '.patchwork/greeter@0.1.0');
      expect(writeJson['patchPath'], 'patches/greeter@0.1.0.patch');

      final needsApplyDoctor = await project.patchworkResult(
        ['doctor', '--json'],
        exitCodes: {1},
      );
      expect(needsApplyDoctor.exitCode, 1);
      expect(
        needsApplyDoctor.stdout,
        isNot(contains('action: patchwork apply')),
      );
      final needsApplyJson = _decodeObject(needsApplyDoctor.stdout);
      expect(_objects(needsApplyJson['needsApply']).single, {
        'package': 'greeter',
        'version': '0.1.0',
      });

      final applyResult = await project.patchworkResult(['apply', '--json']);
      expect(applyResult.stdout, isNot(contains('Run dart pub get.')));
      final applyJson = _decodeObject(applyResult.stdout);
      expect(applyJson['command'], 'apply');
      expect(applyJson['pubGetRan'], isTrue);
      expect(applyJson['needsPubGet'], isFalse);
      final appliedJson = _objects(applyJson['applied']).single;
      expect(appliedJson['package'], 'greeter');
      expect(appliedJson['path'], '.dart_tool/patchwork/greeter@0.1.0');
      expect(appliedJson['patchPath'], 'patches/greeter@0.1.0.patch');

      final readyDoctor = await project.patchworkResult(['doctor', '--json']);
      expect(readyDoctor.exitCode, 0);
      final readyPackage = _objects(
        _decodeObject(readyDoctor.stdout)['packages'],
      ).single;
      expect(readyPackage['appliedPath'], '.dart_tool/patchwork/greeter@0.1.0');
      expect(readyPackage['problems'], isEmpty);

      final noOpApply = await project.patchworkResult(['apply', '--json']);
      expect(noOpApply.stdout, isNot(contains('No patches need apply.')));
      final noOpApplyJson = _decodeObject(noOpApply.stdout);
      expect(noOpApplyJson['applied'], isEmpty);
      expect(noOpApplyJson['pubGetRan'], isFalse);
      expect(noOpApplyJson['needsPubGet'], isFalse);

      final undoResult = await project.patchworkResult([
        'undo',
        'greeter',
        '--json',
      ]);
      expect(undoResult.stdout, isNot(contains('Unapplied greeter.')));
      final undoJson = _decodeObject(undoResult.stdout);
      expect(undoJson['command'], 'undo');
      expect(undoJson['pubGetRan'], isTrue);
      expect(undoJson['needsPubGet'], isFalse);
      final resultJson = _object(undoJson['result']);
      expect(resultJson['package'], 'greeter');
      expect(resultJson['changed'], isTrue);
      expect(resultJson['path'], '.dart_tool/patchwork/greeter@0.1.0');
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'reports explicit pub get work in low-level JSON mode',
    () async {
      final project = await ProjectSandbox.standalone();
      addTearDown(project.dispose);

      await project.pubGet();
      await project.patchwork(['patch', 'greeter']);
      project.writeEdit('Hello from low-level JSON output');
      await project.patchwork(['commit', 'greeter']);

      final applyResult = await project.patchworkResult([
        'apply',
        '--no-pub-get',
        '--json',
      ]);
      final applyJson = _decodeObject(applyResult.stdout);
      expect(applyJson['pubGetRan'], isFalse);
      expect(applyJson['needsPubGet'], isTrue);

      final finishApply = await project.patchworkResult(['apply', '--json']);
      final finishApplyJson = _decodeObject(finishApply.stdout);
      expect(finishApplyJson['applied'], isEmpty);
      expect(finishApplyJson['pubGetRan'], isTrue);
      expect(finishApplyJson['needsPubGet'], isFalse);
      await project.runApp('Hello from low-level JSON output, Patchwork!');

      final undoResult = await project.patchworkResult([
        'undo',
        'greeter',
        '--no-pub-get',
        '--json',
      ]);
      final undoJson = _decodeObject(undoResult.stdout);
      expect(undoJson['pubGetRan'], isFalse);
      expect(undoJson['needsPubGet'], isTrue);
      expect(_object(undoJson['result'])['changed'], isTrue);

      await project.pubGet();
      await project.runApp('Hello, Patchwork!');
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'renders JSON problem details while preserving doctor exit behavior',
    () async {
      final project = await ProjectSandbox.standalone();
      addTearDown(project.dispose);

      await project.pubGet();
      await project.patchwork(['patch', 'greeter']);
      project.writeEdit('Hello from a JSON problem case');
      await project.patchwork(['commit', 'greeter']);
      project.writeManualOverride();

      final statusResult = await project.patchworkResult(['status', '--json']);
      expect(statusResult.exitCode, 0);
      expect(statusResult.stdout.trimLeft(), startsWith('{'));
      final statusJson = _decodeObject(statusResult.stdout);
      final packageJson = _objects(statusJson['packages']).single;
      expect(
        _objects(packageJson['problems']).single['code'],
        'pub.override_conflict',
      );
      expect(_objects(statusJson['problems']).single['package'], 'greeter');

      final applyResult = await project.patchworkResult(
        ['apply', 'greeter', '--json'],
        exitCodes: {1},
      );
      expect(applyResult.stdout, isNot(contains('error:')));
      final errorJson = _object(_decodeObject(applyResult.stdout)['error']);
      expect(errorJson['code'], 'pub.override_conflict');
      expect(
        errorJson['message'],
        contains('already has a dependency override'),
      );
      expect(errorJson['hint'], contains('patchwork apply greeter'));

      final doctorResult = await project.patchworkResult(
        ['doctor', '--json'],
        exitCodes: {1},
      );
      expect(doctorResult.exitCode, 1);
      final doctorJson = _decodeObject(doctorResult.stdout);
      expect(doctorJson['problems'], isNotEmpty);
      final plainProblem = _objects(doctorJson['problems']).single;
      expect(plainProblem, isNot(contains('suggestedActions')));

      final explainResult = await project.patchworkResult(
        ['doctor', '--explain', '--json'],
        exitCodes: {1},
      );
      final explainJson = _decodeObject(explainResult.stdout);
      final explainProblem = _objects(explainJson['problems']).single;
      expect(explainProblem['code'], 'pub.override_conflict');
      final actions = _objects(explainProblem['suggestedActions']);
      expect(
        actions.map((action) => action['command']),
        contains('patchwork apply greeter'),
      );
      expect(actions.map((action) => action['description']), isNotEmpty);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'explains stale patch remediation with the stale patch version',
    () async {
      final project = await ProjectSandbox.standalone();
      addTearDown(project.dispose);

      await project.pubGet();
      await project.patchwork(['patch', 'greeter']);
      project.writeEdit('Hello from a stale JSON patch');
      await project.patchwork(['commit', 'greeter']);

      project.updateGreeterPackage(
        version: '0.1.1',
        greeting: 'Hello, \$name!',
      );
      await project.pubGet();

      final result = await project.patchworkResult(
        ['doctor', '--explain', '--json'],
        exitCodes: {1},
      );
      final problem = _objects(_decodeObject(result.stdout)['problems']).single;
      expect(problem['code'], 'patch.stale');
      expect(problem['remediationVersion'], '0.1.0');

      final commands = _objects(
        problem['suggestedActions'],
      ).map((action) => action['command']);
      expect(commands, contains('patchwork patch greeter --continue 0.1.0'));
      expect(commands, contains('patchwork remove greeter 0.1.0'));
      expect(
        commands,
        isNot(contains('patchwork patch greeter --continue 0.1.1')),
      );
      expect(commands, isNot(contains('patchwork remove greeter 0.1.1')));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'explains open edit remediation with the edit directory version',
    () async {
      final project = await ProjectSandbox.standalone();
      addTearDown(project.dispose);

      await project.pubGet();
      await project.patchwork(['patch', 'greeter']);

      project.updateGreeterPackage(
        version: '0.1.1',
        greeting: 'Hello, \$name!',
      );
      await project.pubGet();

      final result = await project.patchworkResult(
        ['doctor', '--explain', '--json'],
        exitCodes: {1},
      );
      final problem = _objects(
        _decodeObject(result.stdout)['problems'],
      ).where((problem) => problem['code'] == 'commit.open_edit').single;
      expect(problem['remediationVersion'], '0.1.0');

      final commands = _objects(
        problem['suggestedActions'],
      ).map((action) => action['command']);
      expect(commands, contains('patchwork commit greeter'));
      expect(commands, contains('patchwork remove greeter 0.1.0 --force'));
      expect(
        commands,
        isNot(contains('patchwork remove greeter 0.1.1 --force')),
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'explains stale applied remediation with undo first when pub resolves output',
    () async {
      final project = await ProjectSandbox.standalone();
      addTearDown(project.dispose);

      await project.pubGet();
      await project.patchwork(['patch', 'greeter']);
      project.writeEdit('Hello from a stale applied JSON patch');
      await project.patchwork(['commit', 'greeter']);
      await project.patchwork(['apply', 'greeter']);

      final marker = project.appliedMarkerFor('0.1.0');
      final decoded =
          jsonDecode(marker.readAsStringSync()) as Map<String, Object?>;
      decoded['patchSha256'] = 'stale';
      marker.writeAsStringSync('${jsonEncode(decoded)}\n');

      final result = await project.patchworkResult(
        ['doctor', '--explain', '--json'],
        exitCodes: {1},
      );
      final problem = _objects(
        _decodeObject(result.stdout)['problems'],
      ).where((problem) => problem['code'] == 'applied.patch_stale').single;
      expect(problem['remediationRequiresUndoFirst'], isTrue);

      final commands = _objects(
        problem['suggestedActions'],
      ).map((action) => action['command']);
      expect(
        commands,
        orderedEquals([
          'patchwork undo greeter',
          'dart pub get',
          'patchwork apply greeter',
        ]),
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'explains broken edit remediation without removing committed patches',
    () async {
      final project = await ProjectSandbox.standalone();
      addTearDown(project.dispose);

      await project.pubGet();
      await project.patchwork(['patch', 'greeter']);
      project.writeEdit('Hello from a committed JSON patch');
      await project.patchwork(['commit', 'greeter']);
      await project.patchwork(['patch', 'greeter', '--continue']);
      project.editManifestFor('0.1.0').deleteSync();

      final result = await project.patchworkResult(
        ['doctor', '--explain', '--json'],
        exitCodes: {1},
      );
      final problem = _objects(_decodeObject(result.stdout)['problems'])
          .where((problem) => problem['code'] == 'commit.edit_manifest_missing')
          .single;

      final actions = _objects(problem['suggestedActions']);
      final commands = actions.map((action) => action['command']);
      expect(commands, contains('patchwork patch greeter --continue 0.1.0'));
      expect(
        commands,
        isNot(contains('patchwork remove greeter 0.1.0 --force')),
      );
      expect(
        actions.map((action) => action['description']),
        contains(
          'Delete only the broken edit directory at .patchwork/greeter@0.1.0; do not remove the committed patch file.',
        ),
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'explains marker-missing remediation with generated override cleanup',
    () async {
      final project = await ProjectSandbox.standalone();
      addTearDown(project.dispose);

      await project.pubGet();
      await project.patchwork(['patch', 'greeter']);
      project.writeEdit('Hello from a marker-missing JSON patch');
      await project.patchwork(['commit', 'greeter']);
      await project.patchwork(['apply', 'greeter']);
      project.appliedMarkerFor('0.1.0').deleteSync();

      final result = await project.patchworkResult(
        ['doctor', '--explain', '--json'],
        exitCodes: {1},
      );
      final problem = _objects(
        _decodeObject(result.stdout)['problems'],
      ).where((problem) => problem['code'] == 'applied.marker_missing').single;
      expect(problem['remediationRequiresOverrideCleanup'], isTrue);

      final actions = _objects(problem['suggestedActions']);
      expect(
        actions.map((action) => action['command']),
        orderedEquals([null, null, 'dart pub get', 'patchwork apply greeter']),
      );
      expect(
        actions.map((action) => action['description']),
        contains(
          'Remove the "greeter" entry from pubspec_overrides.yaml if it points at .dart_tool/patchwork/greeter@0.1.0.',
        ),
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'explains stale broken edit remediation by continuing the stale patch',
    () async {
      final project = await ProjectSandbox.standalone();
      addTearDown(project.dispose);

      await project.pubGet();
      await project.patchwork(['patch', 'greeter']);
      project.writeEdit('Hello from a stale broken edit JSON patch');
      await project.patchwork(['commit', 'greeter']);
      await project.patchwork(['patch', 'greeter', '--continue']);
      project.updateGreeterPackage(
        version: '0.1.1',
        greeting: 'Hello, \$name!',
      );
      await project.pubGet();
      project.editManifestFor('0.1.0').deleteSync();

      final result = await project.patchworkResult(
        ['doctor', '--explain', '--json'],
        exitCodes: {1},
      );
      final problem = _objects(_decodeObject(result.stdout)['problems'])
          .where((problem) => problem['code'] == 'commit.edit_manifest_missing')
          .single;
      expect(problem['remediationVersion'], '0.1.0');
      expect(problem['remediationCanContinuePatch'], isTrue);

      final commands = _objects(
        problem['suggestedActions'],
      ).map((action) => action['command']);
      expect(commands, contains('patchwork patch greeter --continue 0.1.0'));
      expect(commands, isNot(contains('patchwork patch greeter')));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'explains missing package remediation with applied state first',
    () async {
      final project = await ProjectSandbox.standalone();
      addTearDown(project.dispose);

      await project.pubGet();
      await project.patchwork(['patch', 'greeter']);
      project.writeEdit('Hello from a missing package JSON patch');
      await project.patchwork(['commit', 'greeter']);
      await project.patchwork(['apply', 'greeter']);
      project.overrideFile.deleteSync();
      project.replaceAppPubspecText('''
  greeter:
    path: ../packages/greeter
''', '');
      await project.pubGet();

      final result = await project.patchworkResult(
        ['doctor', '--explain', '--json'],
        exitCodes: {1},
      );
      final problem = _objects(
        _decodeObject(result.stdout)['problems'],
      ).where((problem) => problem['code'] == 'pub.package_not_found').single;

      final commands = _objects(
        problem['suggestedActions'],
      ).map((action) => action['command']);
      expect(
        commands,
        orderedEquals([
          'dart pub get',
          'patchwork undo greeter',
          'patchwork remove greeter 0.1.0',
        ]),
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

Map<String, Object?> _object(Object? value) {
  if (value is! Map) {
    fail('Expected a JSON object, got ${value.runtimeType}.');
  }
  return value.cast<String, Object?>();
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
