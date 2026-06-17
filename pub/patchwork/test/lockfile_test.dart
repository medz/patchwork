import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:patchwork/src/error.dart';
import 'package:patchwork/src/lockfile.dart';
import 'package:patchwork/src/model.dart';
import 'package:test/test.dart';

void main() {
  test('round-trips source, patch, and applied records', () {
    final root = Directory.systemTemp.createTempSync('patchwork_lockfile_');
    addTearDown(() => root.deleteSync(recursive: true));

    final store = LockfileStore(path: p.join(root.path, 'patchwork.lock'));
    store.write(
      Lockfile(
        packages: {
          'foo': const LockfilePackage(
            version: '0.1.0',
            source: PackageSource(
              type: 'hosted',
              sha256: 'source-sha',
              fields: {'url': 'https://pub.dev'},
            ),
            patch: CommittedPatch(editSha256: 'edit-sha', sha256: 'patch-sha'),
            patchHistory: {'0.0.9': HistoricalPatch(sha256: 'old-patch-sha')},
            applied: AppliedPatchRecord(
              patchSha256: 'patch-sha',
              path: '.dart_tool/patchwork/foo@0.1.0',
            ),
          ),
        },
      ),
    );

    final lockfile = store.read();
    final foo = lockfile.packages['foo']!;

    expect(foo.version, '0.1.0');
    expect(foo.source.type, 'hosted');
    expect(foo.source.fields, {'url': 'https://pub.dev'});
    expect(foo.source.sha256, 'source-sha');
    expect(foo.patch!.editSha256, 'edit-sha');
    expect(foo.patch!.sha256, 'patch-sha');
    expect(foo.patchHistory['0.0.9']!.sha256, 'old-patch-sha');
    expect(foo.applied!.patchSha256, 'patch-sha');
    expect(foo.applied!.path, '.dart_tool/patchwork/foo@0.1.0');
  });

  test('rejects unsupported versions', () {
    final root = Directory.systemTemp.createTempSync('patchwork_lockfile_');
    addTearDown(() => root.deleteSync(recursive: true));

    final path = p.join(root.path, 'patchwork.lock');
    File(path).writeAsStringSync('version: 1\npackages: {}\n');

    expect(
      () => LockfileStore(path: path).read(),
      throwsA(
        isA<PatchworkException>().having(
          (error) => error.code,
          'code',
          'lock.unsupported_version',
        ),
      ),
    );
  });

  test('quotes package versions that YAML could parse as numbers', () {
    final root = Directory.systemTemp.createTempSync('patchwork_lockfile_');
    addTearDown(() => root.deleteSync(recursive: true));

    final path = p.join(root.path, 'patchwork.lock');
    final store = LockfileStore(path: path);
    store.write(
      Lockfile(
        packages: {
          'foo': const LockfilePackage(
            version: '1.0',
            source: PackageSource(type: 'hosted', sha256: 'source-sha'),
          ),
        },
      ),
    );

    expect(File(path).readAsStringSync(), contains('version: "1.0"'));
    expect(store.read().packages['foo']!.version, '1.0');
  });
}
