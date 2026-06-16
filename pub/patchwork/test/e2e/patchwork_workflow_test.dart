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
    'continue can carry an older patch onto the current dependency version',
    () async {
      final edit = await patchwork.prepareEdit('foo');
      File(
        p.join(edit.path, 'lib', 'foo.dart'),
      ).writeAsStringSync("String foo() => 'patched';\n");
      await patchwork.writePatch('foo');

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
}
