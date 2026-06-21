import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:patchwork/src/internal/dependency_override_state.dart';
import 'package:patchwork/src/pub/pubspec_dependency_overrides.dart';
import 'package:patchwork/src/pub/pubspec_overrides.dart';
import 'package:test/test.dart';

void main() {
  test('skips pubspec overrides when pubspec_overrides shadows them', () {
    final root = Directory.systemTemp.createTempSync(
      'patchwork_override_state_',
    );
    addTearDown(() => root.deleteSync(recursive: true));

    File(p.join(root.path, 'pubspec_overrides.yaml')).writeAsStringSync('''
dependency_overrides:
  other:
    path: vendor/other
''');
    File(
      p.join(root.path, 'pubspec.yaml'),
    ).writeAsStringSync('dependency_overrides: [');

    final state = _readState(root.path);
    final conflict = state.blockingConflict(
      package: 'foo',
      targetPath: p.join(root.path, '.dart_tool', 'patchwork', 'foo@1.0.0'),
    );

    expect(conflict, isNull);
  });

  test(
    'reports pubspec override conflicts when no override file shadows them',
    () {
      final root = Directory.systemTemp.createTempSync(
        'patchwork_override_state_',
      );
      addTearDown(() => root.deleteSync(recursive: true));

      File(p.join(root.path, 'pubspec.yaml')).writeAsStringSync('''
name: app
dependency_overrides:
  foo:
    path: ../foo
''');

      final state = _readState(root.path);
      final conflict = state.blockingConflict(
        package: 'foo',
        targetPath: p.join(root.path, '.dart_tool', 'patchwork', 'foo@1.0.0'),
      );

      expect(conflict?.fileName, 'pubspec.yaml');
      expect(conflict?.path, p.join(root.path, 'pubspec.yaml'));
    },
  );
}

DependencyOverrideState _readState(String rootPath) {
  return DependencyOverrideState.read(
    rootPath: rootPath,
    overrideRootPaths: {rootPath},
    pubspecOverrides: const PubspecOverrides(),
    pubspecDependencyOverrides: const PubspecDependencyOverrides(),
  );
}
