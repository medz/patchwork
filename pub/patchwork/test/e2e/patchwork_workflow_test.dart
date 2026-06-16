import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:patchwork/patchwork.dart';
import 'package:patchwork/src/lock/patchwork_lock.dart';
import 'package:test/test.dart';

import '../pub/pub_resolution_fixture.dart';

void main() {
  late PubResolutionFixture fixture;
  late Patchwork patchwork;

  setUp(() async {
    fixture = PubResolutionFixture.create();
    patchwork = await Patchwork.open(fixture.appPath);
  });

  tearDown(() {
    fixture.dispose();
  });

  test(
    'patch, commit, apply, and undo use the v0.2 paths and lock records',
    () async {
      final edit = await patchwork.prepareEdit('foo');
      expect(edit.path, p.join(fixture.rootPath, '.patchwork', 'foo@0.1.0'));
      File(
        p.join(edit.path, 'lib', 'foo.dart'),
      ).writeAsStringSync("String foo() => 'patched';\n");

      final write = await patchwork.writePatch('foo');
      expect(write.status, PatchWriteStatus.written);
      expect(
        File(
          p.join(fixture.rootPath, 'patches', 'foo@0.1.0.patch'),
        ).existsSync(),
        isTrue,
      );
      expect(Directory(edit.path).existsSync(), isFalse);

      var lock = PatchworkLockStore(
        path: p.join(fixture.rootPath, 'patchwork.lock'),
      ).read();
      expect(lock.packages['foo']!.source.type, 'hosted');
      expect(lock.packages['foo']!.patch!.sha256, write.patchSha256);
      expect(lock.packages['foo']!.applied, isNull);

      final applied = await patchwork.applyPatch('foo');
      expect(
        applied.path,
        p.join(fixture.rootPath, '.dart_tool', 'patchwork', 'foo@0.1.0'),
      );
      expect(
        File(p.join(applied.path, 'lib', 'foo.dart')).readAsStringSync(),
        "String foo() => 'patched';\n",
      );
      expect(
        File(
          p.join(fixture.rootPath, 'pubspec_overrides.yaml'),
        ).readAsStringSync(),
        contains('foo'),
      );

      lock = PatchworkLockStore(
        path: p.join(fixture.rootPath, 'patchwork.lock'),
      ).read();
      expect(
        lock.packages['foo']!.applied!.path,
        '.dart_tool/patchwork/foo@0.1.0',
      );

      final undo = await patchwork.unapplyPatch('foo');
      expect(undo.changed, isTrue);
      expect(Directory(applied.path).existsSync(), isFalse);
      expect(
        File(p.join(fixture.rootPath, 'pubspec_overrides.yaml')).existsSync(),
        isFalse,
      );
      lock = PatchworkLockStore(
        path: p.join(fixture.rootPath, 'patchwork.lock'),
      ).read();
      expect(lock.packages['foo']!.patch, isNotNull);
      expect(lock.packages['foo']!.applied, isNull);
    },
  );

  test(
    'patch workflow supports path, git, and custom hosted sources',
    () async {
      await _expectPackageWorkflow(
        patchwork: patchwork,
        fixture: fixture,
        package: 'bar',
        version: '1.0.0',
        filePath: 'lib/bar.dart',
        patchedContent: "String bar() => 'patched bar';\n",
        expectedSourceFields: {'path': '../../deps/bar'},
      );
      await _expectPackageWorkflow(
        patchwork: patchwork,
        fixture: fixture,
        package: 'baz',
        version: '2.0.0',
        filePath: 'lib/baz.dart',
        patchedContent: "String baz() => 'patched baz';\n",
        expectedSourceFields: {
          'url': 'https://example.com/baz.git',
          'branch': 'main',
          'commit': 'abc123',
        },
      );
      await _expectPackageWorkflow(
        patchwork: patchwork,
        fixture: fixture,
        package: 'qux',
        version: '3.0.0',
        filePath: 'lib/qux.dart',
        patchedContent: "String qux() => 'patched qux';\n",
        expectedSourceFields: {'url': 'https://pub.example.test'},
      );
    },
  );

  test('patch refuses existing edits unless force is used', () async {
    final edit = await patchwork.prepareEdit('foo');
    File(p.join(edit.path, 'lib', 'foo.dart')).writeAsStringSync('dirty\n');

    expect(
      () => patchwork.prepareEdit('foo'),
      throwsA(
        isA<PatchworkException>().having(
          (error) => error.code,
          'code',
          'patch.edit_exists',
        ),
      ),
    );

    final replaced = await patchwork.prepareEdit('foo', replaceExisting: true);
    expect(
      File(p.join(replaced.path, 'lib', 'foo.dart')).readAsStringSync(),
      "String foo() => 'old';\n",
    );
  });

  test(
    'commit removes an unchanged edit without rewriting the patch',
    () async {
      var edit = await patchwork.prepareEdit('foo');
      File(
        p.join(edit.path, 'lib', 'foo.dart'),
      ).writeAsStringSync("String foo() => 'patched';\n");
      final firstWrite = await patchwork.writePatch('foo');

      edit = await patchwork.prepareEdit(
        'foo',
        fromPatch: const PatchRef.current(),
      );
      final secondWrite = await patchwork.writePatch('foo');

      expect(secondWrite.status, PatchWriteStatus.unchanged);
      expect(secondWrite.patchSha256, firstWrite.patchSha256);
      expect(Directory(edit.path).existsSync(), isFalse);
    },
  );

  test(
    'commit removes empty patches and clears the lock patch record',
    () async {
      final edit = await patchwork.prepareEdit('foo');

      final write = await patchwork.writePatch('foo');

      expect(write.status, PatchWriteStatus.removed);
      expect(
        File(
          p.join(fixture.rootPath, 'patches', 'foo@0.1.0.patch'),
        ).existsSync(),
        isFalse,
      );
      expect(Directory(edit.path).existsSync(), isFalse);
      final lock = PatchworkLockStore(
        path: p.join(fixture.rootPath, 'patchwork.lock'),
      ).read();
      expect(lock.packages['foo']!.patch, isNull);
    },
  );

  test(
    'continue can carry an older patch onto the current dependency version',
    () async {
      final edit = await patchwork.prepareEdit('foo');
      File(
        p.join(edit.path, 'lib', 'foo.dart'),
      ).writeAsStringSync("String foo() => 'patched';\n");
      await patchwork.writePatch('foo');
      await patchwork.applyPatch('foo');
      fixture.pointFooAtAppliedPath('.dart_tool/patchwork/foo@0.1.0');

      expect(
        () => patchwork.prepareEdit('foo'),
        throwsA(
          isA<PatchworkException>().having(
            (error) => error.code,
            'code',
            'pub.package_resolves_to_applied',
          ),
        ),
      );

      await patchwork.unapplyPatch('foo');
      fixture.upgradeFooTo011();
      patchwork = await Patchwork.open(fixture.appPath);

      final continued = await patchwork.prepareEdit(
        'foo',
        fromPatch: const PatchRef.version('0.1.0'),
      );
      expect(continued.version, '0.1.1');
      expect(continued.continuedFromVersion, '0.1.0');
      expect(
        File(p.join(continued.path, 'lib', 'foo.dart')).readAsStringSync(),
        "String foo() => 'patched';\n",
      );

      final write = await patchwork.writePatch('foo');
      expect(
        write.patchPath,
        p.join(fixture.rootPath, 'patches', 'foo@0.1.1.patch'),
      );
      expect(
        File(
          p.join(fixture.rootPath, 'patches', 'foo@0.1.0.patch'),
        ).existsSync(),
        isTrue,
      );
    },
  );

  test('patch refuses sources masked by an applied override', () async {
    final edit = await patchwork.prepareEdit('foo');
    File(
      p.join(edit.path, 'lib', 'foo.dart'),
    ).writeAsStringSync("String foo() => 'patched';\n");
    await patchwork.writePatch('foo');
    await patchwork.applyPatch('foo');
    fixture.pointFooAtAppliedPath('.dart_tool/patchwork/foo@0.1.0');

    expect(
      () => patchwork.prepareEdit('foo', replaceExisting: true),
      throwsA(
        isA<PatchworkException>().having(
          (error) => error.code,
          'code',
          'pub.package_resolves_to_applied',
        ),
      ),
    );
  });

  test(
    'apply refuses to overwrite a user override for the same package',
    () async {
      final edit = await patchwork.prepareEdit('foo');
      File(
        p.join(edit.path, 'lib', 'foo.dart'),
      ).writeAsStringSync("String foo() => 'patched';\n");
      await patchwork.writePatch('foo');
      File(
        p.join(fixture.rootPath, 'pubspec_overrides.yaml'),
      ).writeAsStringSync('''
dependency_overrides:
  foo:
    path: ../local-foo
''');

      expect(
        () => patchwork.applyPatch('foo'),
        throwsA(
          isA<PatchworkException>().having(
            (error) => error.code,
            'code',
            'pub.override_conflict',
          ),
        ),
      );
      expect(
        File(
          p.join(fixture.rootPath, 'pubspec_overrides.yaml'),
        ).readAsStringSync(),
        contains('../local-foo'),
      );
      expect(
        Directory(
          p.join(fixture.rootPath, '.dart_tool', 'patchwork', 'foo@0.1.0'),
        ).existsSync(),
        isFalse,
      );
      final lock = PatchworkLockStore(
        path: p.join(fixture.rootPath, 'patchwork.lock'),
      ).read();
      expect(lock.packages['foo']!.applied, isNull);
    },
  );

  test(
    'continue rejects patch files that do not match the lock hash',
    () async {
      final edit = await patchwork.prepareEdit('foo');
      File(
        p.join(edit.path, 'lib', 'foo.dart'),
      ).writeAsStringSync("String foo() => 'patched';\n");
      await patchwork.writePatch('foo');

      File(
        p.join(fixture.rootPath, 'patches', 'foo@0.1.0.patch'),
      ).writeAsStringSync('''
diff --git a/lib/foo.dart b/lib/foo.dart
index 7f5c17ebfe2e1c63d2d3d90a0b4d1fd9231be0d8..0687f67a386acb09c490df385580358343e343e3 100644
--- a/lib/foo.dart
+++ b/lib/foo.dart
@@ -1 +1 @@
-String foo() => 'old';
+String foo() => 'tampered';
''');

      expect(
        () => patchwork.prepareEdit('foo', fromPatch: const PatchRef.current()),
        throwsA(
          isA<PatchworkException>().having(
            (error) => error.code,
            'code',
            'patch.continue_patch_sha_mismatch',
          ),
        ),
      );
      expect(
        Directory(
          p.join(fixture.rootPath, '.patchwork', 'foo@0.1.0'),
        ).existsSync(),
        isFalse,
      );
    },
  );

  test(
    'undo refuses applied paths outside generated patchwork state',
    () async {
      final edit = await patchwork.prepareEdit('foo');
      File(
        p.join(edit.path, 'lib', 'foo.dart'),
      ).writeAsStringSync("String foo() => 'patched';\n");
      await patchwork.writePatch('foo');
      await patchwork.applyPatch('foo');

      final victim = Directory(p.join(fixture.rootPath, '..', 'victim'));
      victim.createSync(recursive: true);
      addTearDown(() {
        if (victim.existsSync()) {
          victim.deleteSync(recursive: true);
        }
      });
      final store = PatchworkLockStore(
        path: p.join(fixture.rootPath, 'patchwork.lock'),
      );
      final lock = store.read();
      final record = lock.packages['foo']!;
      lock.packages['foo'] = record.copyWith(
        applied: LockApplied(
          patchSha256: record.applied!.patchSha256,
          path: '../victim',
        ),
      );
      store.write(lock);

      expect(
        () => patchwork.unapplyPatch('foo'),
        throwsA(
          isA<PatchworkException>().having(
            (error) => error.code,
            'code',
            'undo.unsafe_applied_path',
          ),
        ),
      );
      expect(victim.existsSync(), isTrue);
    },
  );

  test('undo refuses applied paths for a different package', () async {
    final edit = await patchwork.prepareEdit('foo');
    File(
      p.join(edit.path, 'lib', 'foo.dart'),
    ).writeAsStringSync("String foo() => 'patched';\n");
    await patchwork.writePatch('foo');
    await patchwork.applyPatch('foo');

    final otherApplied = Directory(
      p.join(fixture.rootPath, '.dart_tool', 'patchwork', 'bar@1.0.0'),
    );
    otherApplied.createSync(recursive: true);
    final store = PatchworkLockStore(
      path: p.join(fixture.rootPath, 'patchwork.lock'),
    );
    final lock = store.read();
    final record = lock.packages['foo']!;
    lock.packages['foo'] = record.copyWith(
      applied: LockApplied(
        patchSha256: record.applied!.patchSha256,
        path: '.dart_tool/patchwork/bar@1.0.0',
      ),
    );
    store.write(lock);
    File(p.join(fixture.rootPath, 'pubspec_overrides.yaml')).writeAsStringSync(
      '''
dependency_overrides:
  foo:
    path: .dart_tool/patchwork/bar@1.0.0
''',
    );
    fixture.pointFooAtAppliedPath('.dart_tool/patchwork/bar@1.0.0');

    final state = await patchwork.inspect();
    final foo = state.packages.singleWhere((status) => status.package == 'foo');
    expect(foo.isApplied, isFalse);
    expect(
      foo.problems.map((problem) => problem.code),
      contains('undo.unsafe_applied_path'),
    );

    expect(
      () => patchwork.unapplyPatch('foo'),
      throwsA(
        isA<PatchworkException>().having(
          (error) => error.code,
          'code',
          'undo.unsafe_applied_path',
        ),
      ),
    );
    expect(otherApplied.existsSync(), isTrue);
  });

  test('status reports stale applied patches after a new commit', () async {
    var edit = await patchwork.prepareEdit('foo');
    File(
      p.join(edit.path, 'lib', 'foo.dart'),
    ).writeAsStringSync("String foo() => 'one';\n");
    await patchwork.writePatch('foo');
    await patchwork.applyPatch('foo');

    edit = await patchwork.prepareEdit('foo', replaceExisting: true);
    File(
      p.join(edit.path, 'lib', 'foo.dart'),
    ).writeAsStringSync("String foo() => 'two';\n");
    await patchwork.writePatch('foo');

    final state = await patchwork.inspect();
    final foo = state.packages.singleWhere((status) => status.package == 'foo');
    expect(foo.needsApply, isTrue);
    expect(
      foo.problems.map((problem) => problem.code),
      contains('applied.patch_stale'),
    );
  });

  test('status reports missing and modified patch files', () async {
    var edit = await patchwork.prepareEdit('foo');
    File(
      p.join(edit.path, 'lib', 'foo.dart'),
    ).writeAsStringSync("String foo() => 'patched';\n");
    await patchwork.writePatch('foo');
    final patchPath = p.join(fixture.rootPath, 'patches', 'foo@0.1.0.patch');
    final patchContent = File(patchPath).readAsStringSync();

    File(patchPath).deleteSync();
    var state = await patchwork.inspect();
    var foo = state.packages.singleWhere((status) => status.package == 'foo');
    expect(
      foo.problems.map((problem) => problem.code),
      contains('patch.file_missing'),
    );

    File(patchPath).writeAsStringSync('$patchContent\n');
    state = await patchwork.inspect();
    foo = state.packages.singleWhere((status) => status.package == 'foo');
    expect(
      foo.problems.map((problem) => problem.code),
      contains('patch.sha_mismatch'),
    );
  });

  test('status reports missing generated output and override drift', () async {
    final edit = await patchwork.prepareEdit('foo');
    File(
      p.join(edit.path, 'lib', 'foo.dart'),
    ).writeAsStringSync("String foo() => 'patched';\n");
    await patchwork.writePatch('foo');
    final applied = await patchwork.applyPatch('foo');

    Directory(applied.path).deleteSync(recursive: true);
    var state = await patchwork.inspect();
    var foo = state.packages.singleWhere((status) => status.package == 'foo');
    expect(
      foo.problems.map((problem) => problem.code),
      contains('applied.output_missing'),
    );

    await patchwork.applyPatch('foo');
    File(p.join(fixture.rootPath, 'pubspec_overrides.yaml')).deleteSync();
    state = await patchwork.inspect();
    foo = state.packages.singleWhere((status) => status.package == 'foo');
    expect(
      foo.problems.map((problem) => problem.code),
      contains('applied.override_missing'),
    );
  });

  test('status reports source drift', () async {
    final edit = await patchwork.prepareEdit('foo');
    File(
      p.join(edit.path, 'lib', 'foo.dart'),
    ).writeAsStringSync("String foo() => 'patched';\n");
    await patchwork.writePatch('foo');
    fixture.writeFooSource("String foo() => 'changed source';\n");

    final state = await patchwork.inspect();
    final foo = state.packages.singleWhere((status) => status.package == 'foo');
    expect(
      foo.problems.map((problem) => problem.code),
      contains('pub.source_changed'),
    );
  });

  test(
    'status reports when dart pub get has not activated an applied patch',
    () async {
      final edit = await patchwork.prepareEdit('foo');
      File(
        p.join(edit.path, 'lib', 'foo.dart'),
      ).writeAsStringSync("String foo() => 'patched';\n");
      await patchwork.writePatch('foo');
      await patchwork.applyPatch('foo');

      final state = await patchwork.inspect();
      final foo = state.packages.singleWhere(
        (status) => status.package == 'foo',
      );
      expect(foo.isApplied, isFalse);
      expect(
        foo.problems.map((problem) => problem.code),
        contains('applied.pub_get_required'),
      );
    },
  );

  test(
    'status reports applied output when the committed patch is removed',
    () async {
      var edit = await patchwork.prepareEdit('foo');
      File(
        p.join(edit.path, 'lib', 'foo.dart'),
      ).writeAsStringSync("String foo() => 'patched';\n");
      await patchwork.writePatch('foo');
      await patchwork.applyPatch('foo');

      edit = await patchwork.prepareEdit('foo', replaceExisting: true);
      await patchwork.writePatch('foo');

      final state = await patchwork.inspect();
      final foo = state.packages.singleWhere(
        (status) => status.package == 'foo',
      );
      expect(
        foo.problems.map((problem) => problem.code),
        contains('applied.patch_missing'),
      );
    },
  );
}

Future<void> _expectPackageWorkflow({
  required Patchwork patchwork,
  required PubResolutionFixture fixture,
  required String package,
  required String version,
  required String filePath,
  required String patchedContent,
  required Map<String, String> expectedSourceFields,
}) async {
  final edit = await patchwork.prepareEdit(package);
  File(
    p.joinAll([edit.path, ...p.split(filePath)]),
  ).writeAsStringSync(patchedContent);
  final write = await patchwork.writePatch(package);
  expect(write.status, PatchWriteStatus.written);

  final store = PatchworkLockStore(
    path: p.join(fixture.rootPath, 'patchwork.lock'),
  );
  var lock = store.read();
  expect(lock.packages[package]!.version, version);
  expect(lock.packages[package]!.source.fields, expectedSourceFields);

  final applied = await patchwork.applyPatch(package);
  expect(
    File(p.joinAll([applied.path, ...p.split(filePath)])).readAsStringSync(),
    patchedContent,
  );

  final undo = await patchwork.unapplyPatch(package);
  expect(undo.changed, isTrue);
  lock = store.read();
  expect(lock.packages[package]!.patch, isNotNull);
  expect(lock.packages[package]!.applied, isNull);
}
