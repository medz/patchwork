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
      expect(emptyStatus.stderr, isEmpty);
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
      expect(applyJson['needsPubGet'], isTrue);
      final appliedJson = _objects(applyJson['applied']).single;
      expect(appliedJson['package'], 'greeter');
      expect(appliedJson['path'], '.dart_tool/patchwork/greeter@0.1.0');
      expect(appliedJson['patchPath'], 'patches/greeter@0.1.0.patch');

      await project.pubGet();
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
      expect(noOpApplyJson['needsPubGet'], isFalse);

      final undoResult = await project.patchworkResult([
        'undo',
        'greeter',
        '--json',
      ]);
      expect(undoResult.stdout, isNot(contains('Unapplied greeter.')));
      final undoJson = _decodeObject(undoResult.stdout);
      expect(undoJson['command'], 'undo');
      expect(undoJson['needsPubGet'], isTrue);
      final resultJson = _object(undoJson['result']);
      expect(resultJson['package'], 'greeter');
      expect(resultJson['changed'], isTrue);
      expect(resultJson['path'], '.dart_tool/patchwork/greeter@0.1.0');
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
      expect(applyResult.stderr, isEmpty);
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
      expect(_decodeObject(doctorResult.stdout)['problems'], isNotEmpty);
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
