import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:patchwork/src/pub/pubspec_overrides.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late PubspecOverrides overrides;

  setUp(() {
    root = Directory.systemTemp.createTempSync('patchwork_overrides_');
    overrides = const PubspecOverrides();
  });

  tearDown(() {
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  });

  test('upserts patchwork override while preserving unrelated overrides', () {
    File(p.join(root.path, 'pubspec_overrides.yaml')).writeAsStringSync('''
dependency_overrides:
  other:
    path: ../other
''');

    overrides.upsertPathOverride(
      workspaceRootPath: root.path,
      package: 'foo',
      path: '.dart_tool/patchwork/foo@0.1.0',
    );

    expect(overrides.readPathOverrides(root.path), {
      'other': '../other',
      'foo': '.dart_tool/patchwork/foo@0.1.0',
    });
  });

  test('undo removes only the matching applied path', () {
    overrides.upsertPathOverride(
      workspaceRootPath: root.path,
      package: 'foo',
      path: '.dart_tool/patchwork/foo@0.1.0',
    );

    expect(
      overrides.removePathOverrideIfMatches(
        workspaceRootPath: root.path,
        package: 'foo',
        path: '.dart_tool/patchwork/foo@0.1.1',
      ),
      isFalse,
    );
    expect(overrides.readPathOverrides(root.path), {
      'foo': '.dart_tool/patchwork/foo@0.1.0',
    });

    expect(
      overrides.removePathOverrideIfMatches(
        workspaceRootPath: root.path,
        package: 'foo',
        path: '.dart_tool/patchwork/foo@0.1.0',
      ),
      isTrue,
    );
    expect(
      File(p.join(root.path, 'pubspec_overrides.yaml')).existsSync(),
      isFalse,
    );
  });
}
