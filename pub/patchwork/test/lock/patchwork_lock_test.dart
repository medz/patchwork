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
}
