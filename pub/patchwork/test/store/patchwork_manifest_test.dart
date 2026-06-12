import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:patchwork/src/store/patchwork_manifest.dart';
import 'package:test/test.dart';

void main() {
  group('PatchworkManifestStore', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('patchwork manifest ');
    });

    tearDown(() {
      if (root.existsSync()) {
        root.deleteSync(recursive: true);
      }
    });

    test('reads a missing or empty manifest as empty', () {
      final store = const PatchworkManifestStore();

      final missingResult = store.read(workspaceRootPath: root.path);

      expect(missingResult.diagnostic, isNull);
      expect(missingResult.manifest!.patches, isEmpty);

      File(p.join(root.path, 'patchwork.lock')).writeAsStringSync('');

      final emptyResult = store.read(workspaceRootPath: root.path);

      expect(emptyResult.diagnostic, isNull);
      expect(emptyResult.manifest!.patches, isEmpty);
    });

    test('reads valid manifest entries', () {
      File(p.join(root.path, 'patchwork.lock')).writeAsStringSync('''
patches:
  - target: pub:analyzer@7.4.0
    path: patches/pub/analyzer@7.4.0.patch
    hash: 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
''');

      final result = const PatchworkManifestStore().read(
        workspaceRootPath: root.path,
      );

      expect(result.diagnostic, isNull);
      expect(result.manifest!.patches, hasLength(1));
      final entry = result.manifest!.patches.single;
      expect(entry.target, 'pub:analyzer@7.4.0');
      expect(entry.path, 'patches/pub/analyzer@7.4.0.patch');
      expect(
        entry.hash,
        '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
      );
    });

    test('rejects duplicate manifest targets', () {
      File(p.join(root.path, 'patchwork.lock')).writeAsStringSync('''
patches:
  - target: pub:analyzer@7.4.0
    path: patches/pub/analyzer@7.4.0.patch
    hash: 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
  - target: pub:analyzer@7.4.0
    path: patches/pub/analyzer-copy.patch
    hash: ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
''');

      final result = const PatchworkManifestStore().read(
        workspaceRootPath: root.path,
      );

      expect(result.manifest, isNull);
      expect(result.diagnostic?.code, 'patchwork.manifest_duplicate_target');
      expect(result.diagnostic?.location, p.join(root.path, 'patchwork.lock'));
    });

    test('rejects malformed manifest entries', () {
      File(p.join(root.path, 'patchwork.lock')).writeAsStringSync('''
patches:
  - target: pub:analyzer@7.4.0
    hash: 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
''');

      final result = const PatchworkManifestStore().read(
        workspaceRootPath: root.path,
      );

      expect(result.manifest, isNull);
      expect(result.diagnostic?.code, 'patchwork.manifest_malformed');
      expect(result.diagnostic?.location, p.join(root.path, 'patchwork.lock'));
    });

    test('rejects an explicit null patches list as malformed', () {
      File(p.join(root.path, 'patchwork.lock')).writeAsStringSync('patches:\n');

      final result = const PatchworkManifestStore().read(
        workspaceRootPath: root.path,
      );

      expect(result.manifest, isNull);
      expect(result.diagnostic?.code, 'patchwork.manifest_malformed');
      expect(result.diagnostic?.location, p.join(root.path, 'patchwork.lock'));
    });

    test('rejects explicit top-level null lockfiles as malformed', () {
      for (final content in ['null\n', '~\n']) {
        File(p.join(root.path, 'patchwork.lock')).writeAsStringSync(content);

        final result = const PatchworkManifestStore().read(
          workspaceRootPath: root.path,
        );

        expect(result.manifest, isNull);
        expect(result.diagnostic?.code, 'patchwork.manifest_malformed');
        expect(
          result.diagnostic?.location,
          p.join(root.path, 'patchwork.lock'),
        );
      }
    });

    test('rejects patch paths that escape the workspace patch directory', () {
      File(p.join(root.path, 'patchwork.lock')).writeAsStringSync('''
patches:
  - target: pub:analyzer@7.4.0
    path: ../outside.patch
    hash: 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
''');

      final result = const PatchworkManifestStore().read(
        workspaceRootPath: root.path,
      );

      expect(result.manifest, isNull);
      expect(result.diagnostic?.code, 'patchwork.manifest_invalid_path');
      expect(result.diagnostic?.location, p.join(root.path, 'patchwork.lock'));
    });

    test('rejects invalid patch paths before writing entries', () {
      final store = const PatchworkManifestStore();

      expect(
        () => store.upsertPatch(
          workspaceRootPath: root.path,
          entry: const PatchworkManifestPatch(
            target: 'pub:analyzer@7.4.0',
            path: '../outside.patch',
            hash:
                '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
          ),
        ),
        throwsA(
          isA<PatchworkManifestException>().having(
            (error) => error.diagnostic.code,
            'diagnostic code',
            'patchwork.manifest_invalid_path',
          ),
        ),
      );
      expect(File(p.join(root.path, 'patchwork.lock')).existsSync(), isFalse);
    });

    test('writes entries with stable formatting and updates by target', () {
      final store = const PatchworkManifestStore();

      store.upsertPatch(
        workspaceRootPath: root.path,
        entry: const PatchworkManifestPatch(
          target: 'pub:analyzer@7.4.0',
          path: 'patches/pub/analyzer@7.4.0.patch',
          hash:
              '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        ),
      );
      store.upsertPatch(
        workspaceRootPath: root.path,
        entry: const PatchworkManifestPatch(
          target: 'pub:analyzer@7.4.0',
          path: 'patches/pub/analyzer@7.4.0.patch',
          hash:
              'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff',
        ),
      );

      expect(File(p.join(root.path, 'patchwork.lock')).readAsStringSync(), '''
patches:
  - target: pub:analyzer@7.4.0
    path: patches/pub/analyzer@7.4.0.patch
    hash: ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
''');
      final result = store.read(workspaceRootPath: root.path);
      expect(result.diagnostic, isNull);
      expect(result.manifest!.patches, hasLength(1));
    });

    test('writes entries in stable target order', () {
      final store = const PatchworkManifestStore();
      final otherRoot = Directory.systemTemp.createTempSync(
        'patchwork manifest other ',
      );
      addTearDown(() {
        if (otherRoot.existsSync()) {
          otherRoot.deleteSync(recursive: true);
        }
      });
      final entries = [
        const PatchworkManifestPatch(
          target: 'pub:collection@1.19.1',
          path: 'patches/pub/collection@1.19.1.patch',
          hash:
              'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff',
        ),
        const PatchworkManifestPatch(
          target: 'pub:analyzer@7.4.0',
          path: 'patches/pub/analyzer@7.4.0.patch',
          hash:
              '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        ),
      ];

      for (final entry in entries) {
        store.upsertPatch(workspaceRootPath: root.path, entry: entry);
      }
      for (final entry in entries.reversed) {
        store.upsertPatch(workspaceRootPath: otherRoot.path, entry: entry);
      }

      expect(
        File(p.join(root.path, 'patchwork.lock')).readAsStringSync(),
        File(p.join(otherRoot.path, 'patchwork.lock')).readAsStringSync(),
      );
      expect(File(p.join(root.path, 'patchwork.lock')).readAsStringSync(), '''
patches:
  - target: pub:analyzer@7.4.0
    path: patches/pub/analyzer@7.4.0.patch
    hash: 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
  - target: pub:collection@1.19.1
    path: patches/pub/collection@1.19.1.patch
    hash: ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
''');
    });

    test('keeps entries sorted when removing a target', () {
      File(p.join(root.path, 'patchwork.lock')).writeAsStringSync('''
patches:
  - target: pub:zeta@1.0.0
    path: patches/pub/zeta@1.0.0.patch
    hash: ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
  - target: pub:collection@1.19.1
    path: patches/pub/collection@1.19.1.patch
    hash: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  - target: pub:analyzer@7.4.0
    path: patches/pub/analyzer@7.4.0.patch
    hash: 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
''');

      const PatchworkManifestStore().removePatch(
        workspaceRootPath: root.path,
        target: 'pub:collection@1.19.1',
      );

      expect(File(p.join(root.path, 'patchwork.lock')).readAsStringSync(), '''
patches:
  - target: pub:analyzer@7.4.0
    path: patches/pub/analyzer@7.4.0.patch
    hash: 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
  - target: pub:zeta@1.0.0
    path: patches/pub/zeta@1.0.0.patch
    hash: ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
''');
    });

    test('detects missing and stale patch files', () {
      const patchPath = 'patches/pub/analyzer@7.4.0.patch';
      final patchFile = File(p.join(root.path, patchPath));
      patchFile.parent.createSync(recursive: true);
      patchFile.writeAsStringSync('current patch\n');
      final currentHash = patchworkPatchFileHash(patchFile.path);
      File(p.join(root.path, 'patchwork.lock')).writeAsStringSync('''
patches:
  - target: pub:analyzer@7.4.0
    path: $patchPath
    hash: $currentHash
  - target: pub:collection@1.19.1
    path: patches/pub/collection@1.19.1.patch
    hash: 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
''');
      patchFile.writeAsStringSync('changed patch\n');

      final result = const PatchworkManifestStore().inspectPatchFiles(
        workspaceRootPath: root.path,
      );

      expect(result.diagnostic, isNull);
      expect(result.patches, hasLength(2));
      expect(result.patches[0].state, PatchworkManifestPatchState.stale);
      expect(
        result.patches[0].diagnostic?.code,
        'patchwork.patch_hash_mismatch',
      );
      expect(result.patches[1].state, PatchworkManifestPatchState.missing);
      expect(result.patches[1].diagnostic?.code, 'patchwork.patch_missing');
    });

    test('returns diagnostics for unreadable patch files', () {
      const patchPath = 'patches/pub/analyzer@7.4.0.patch';
      final patchFile = File(p.join(root.path, patchPath));
      patchFile.parent.createSync(recursive: true);
      patchFile.writeAsStringSync('current patch\n');
      File(p.join(root.path, 'patchwork.lock')).writeAsStringSync('''
patches:
  - target: pub:analyzer@7.4.0
    path: $patchPath
    hash: 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
''');

      final result = PatchworkManifestStore(
        hashFile: (_) =>
            throw FileSystemException('Permission denied', patchFile.path),
      ).inspectPatchFiles(workspaceRootPath: root.path);

      expect(result.diagnostic, isNull);
      expect(result.patches, hasLength(1));
      expect(
        result.patches.single.state,
        PatchworkManifestPatchState.unreadable,
      );
      expect(
        result.patches.single.diagnostic?.code,
        'patchwork.patch_unreadable',
      );
      expect(result.patches.single.diagnostic?.location, patchFile.path);
    });

    test('rejects symlinked patch files before hashing', () {
      if (Platform.isWindows) {
        markTestSkipped('Symlink creation requires privileges on Windows.');
      }

      const patchPath = 'patches/pub/analyzer@7.4.0.patch';
      final outsideDir = Directory.systemTemp.createTempSync(
        'patchwork manifest outside ',
      );
      addTearDown(() {
        if (outsideDir.existsSync()) {
          outsideDir.deleteSync(recursive: true);
        }
      });
      final outsidePatch = File(p.join(outsideDir.path, 'target.patch'));
      outsidePatch.writeAsStringSync('outside patch\n');
      final patchLink = Link(p.join(root.path, patchPath));
      patchLink.parent.createSync(recursive: true);
      patchLink.createSync(outsidePatch.path);
      File(p.join(root.path, 'patchwork.lock')).writeAsStringSync('''
patches:
  - target: pub:analyzer@7.4.0
    path: $patchPath
    hash: 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
''');

      final result = PatchworkManifestStore(
        hashFile: (_) => throw StateError(
          'hashFile should not be called for symlinked patches',
        ),
      ).inspectPatchFiles(workspaceRootPath: root.path);

      expect(result.diagnostic, isNull);
      expect(result.patches, hasLength(1));
      expect(result.patches.single.state, PatchworkManifestPatchState.invalid);
      expect(result.patches.single.diagnostic?.code, 'patchwork.patch_invalid');
      expect(result.patches.single.diagnostic?.location, patchLink.path);
    });
  });
}
