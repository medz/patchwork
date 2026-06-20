import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'project_sandbox.dart';

void main() {
  test(
    'doctor setup reports repository configuration warnings as JSON',
    () async {
      final project = await ProjectSandbox.standalone();
      addTearDown(project.dispose);
      await project.pubGet();

      final missingIgnore = await project.patchworkResult(
        ['doctor', '--setup', '--json'],
        exitCodes: {1},
      );
      final missingJson = _decodeObject(missingIgnore.stdout);
      expect(missingJson['hasWarnings'], isTrue);
      expect(
        _warningCodes(missingJson),
        containsAll([
          'setup.ignore_edit_state',
          'setup.ignore_applied_output',
          'setup.ignore_pubspec_overrides',
        ]),
      );

      File(p.join(project.stateRoot, '.gitignore')).writeAsStringSync('''
.patchwork/
.dart_tool/
pubspec_overrides.yaml
''');
      final ready = await project.patchworkResult([
        'doctor',
        '--setup',
        '--json',
      ]);
      final readyJson = _decodeObject(ready.stdout);
      expect(readyJson['hasWarnings'], isFalse);
      expect(_warningCodes(readyJson), isEmpty);
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

Set<String> _warningCodes(Map<String, Object?> json) {
  final checks = json['setupChecks'];
  if (checks is! List) {
    fail('Expected setupChecks to be a list.');
  }
  return {
    for (final check in checks)
      if (check is Map && check['level'] == 'warning') check['code'] as String,
  };
}
