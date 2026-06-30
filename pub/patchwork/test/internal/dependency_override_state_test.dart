import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:patchwork/src/error.dart';
import 'package:patchwork/src/internal/dependency_override_guard.dart';
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

  test('normalizes root pubspec path overrides relative to the root', () {
    final root = Directory.systemTemp.createTempSync(
      'patchwork_override_state_',
    );
    addTearDown(() => root.deleteSync(recursive: true));

    final vendor = Directory(p.join(root.path, 'vendor', 'other'))
      ..createSync(recursive: true);
    File(p.join(root.path, 'pubspec.yaml')).writeAsStringSync('''
name: app
dependency_overrides:
  other:
    path: ${vendor.path}
''');

    final overrides = _readState(root.path).rootPubspecDependencyOverrides();

    expect(overrides['other'], {'path': p.posix.join('vendor', 'other')});
  });

  test('rejects blocking override conflicts with command-specific hints', () {
    final root = Directory.systemTemp.createTempSync(
      'patchwork_override_state_',
    );
    addTearDown(() => root.deleteSync(recursive: true));

    final pubspecPath = p.join(root.path, 'pubspec.yaml');
    File(pubspecPath).writeAsStringSync('''
name: app
dependency_overrides:
  foo:
    path: ../foo
''');

    expect(
      () => rejectBlockingOverride(
        overrideState: _readState(root.path),
        package: 'foo',
        command: 'apply',
        targetPath: p.join(root.path, '.dart_tool', 'patchwork', 'foo@1.0.0'),
      ),
      throwsA(
        isA<PatchworkException>()
            .having((error) => error.code, 'code', 'pub.override_conflict')
            .having(
              (error) => error.hint,
              'hint',
              contains('patchwork apply foo'),
            )
            .having((error) => error.location, 'location', pubspecPath),
      ),
    );
  });
}

DependencyOverrideState _readState(String rootPath) {
  return DependencyOverrideState.read(
    rootPath: rootPath,
    overrideRootPaths: {rootPath},
    pubspecOverrides: const PubspecOverrides(),
    pubspecDependencyOverrides: const PubspecDependencyOverrides(),
  );
}
