import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:patchwork/src/lock/patchwork_lock.dart';
import 'package:patchwork/src/model.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late PatchworkLockStore store;

  setUp(() {
    root = Directory.systemTemp.createTempSync('patchwork_lock_');
    store = PatchworkLockStore(path: p.join(root.path, 'patchwork.lock'));
  });

  tearDown(() {
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  });

  test('writes and reads version 2 lockfile records', () {
    final lock = PatchworkLock.empty();
    lock.packages['foo'] = const LockPackage(
      version: '0.1.0',
      source: PackageSource(
        type: 'hosted',
        fields: {'url': 'https://pub.dev'},
        sha256: 'source-sha',
      ),
      patch: LockPatch(editSha256: 'edit-sha', sha256: 'patch-sha'),
      applied: LockApplied(
        patchSha256: 'patch-sha',
        path: '.dart_tool/patchwork/foo@0.1.0',
      ),
    );

    store.write(lock);

    expect(File(store.path).readAsStringSync(), '''
version: 2
packages:
  foo:
    version: 0.1.0
    source:
      type: hosted
      url: https://pub.dev
      sha256: source-sha
    patch:
      edit-sha256: edit-sha
      sha256: patch-sha
    applied:
      patch-sha256: patch-sha
      path: .dart_tool/patchwork/foo@0.1.0

''');

    final read = store.read();
    expect(read.packages['foo']!.source.fields, {'url': 'https://pub.dev'});
    expect(read.packages['foo']!.patch!.editSha256, 'edit-sha');
    expect(
      read.packages['foo']!.applied!.path,
      '.dart_tool/patchwork/foo@0.1.0',
    );
  });

  test('round trips path and git source records', () {
    final lock = PatchworkLock.empty();
    lock.packages['bar'] = const LockPackage(
      version: '1.0.0',
      source: PackageSource(
        type: 'path',
        fields: {'path': '../bar'},
        sha256: 'bar-source',
      ),
    );
    lock.packages['baz'] = const LockPackage(
      version: '2.0.0',
      source: PackageSource(
        type: 'git',
        fields: {
          'url': 'https://example.com/baz.git',
          'branch': 'main',
          'commit': 'abc123',
          'path': 'packages/baz',
        },
        sha256: 'baz-source',
      ),
    );

    store.write(lock);
    final read = store.read();

    expect(read.packages['bar']!.source.fields, {'path': '../bar'});
    expect(read.packages['baz']!.source.fields, {
      'url': 'https://example.com/baz.git',
      'branch': 'main',
      'commit': 'abc123',
      'path': 'packages/baz',
    });
  });

  test('rejects unsupported lockfile versions', () {
    File(store.path).writeAsStringSync('''
version: 1
packages: {}
''');

    expect(() => store.read(), throwsA(isA<Exception>()));
  });

  test('rejects malformed patch records', () {
    File(store.path).writeAsStringSync('''
version: 2
packages:
  foo:
    version: 0.1.0
    source:
      type: hosted
      url: https://pub.dev
      sha256: source-sha
    patch:
      sha256: patch-sha
''');

    expect(() => store.read(), throwsA(isA<Exception>()));
  });
}
