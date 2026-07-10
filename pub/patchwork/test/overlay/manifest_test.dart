import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:patchwork/src/overlay/manifest.dart';
import 'package:test/test.dart';

void main() {
  test('upsert keeps entries sorted when replacing an existing overlay', () {
    final manifest = OverlayManifest(
      overlays: const [
        OverlayManifestEntry(
          package: 'zeta',
          version: '1.0.0',
          sha256: 'z',
          patch: 'patches/zeta@1.0.0.patch',
        ),
        OverlayManifestEntry(
          package: 'alpha',
          version: '1.0.0',
          sha256: 'a',
          patch: 'patches/alpha@1.0.0.patch',
        ),
      ],
    );

    final next = manifest.upsert(
      const OverlayManifestEntry(
        package: 'zeta',
        version: '1.0.0',
        sha256: 'z',
        patch: 'patches/zeta@1.0.0.patch',
        reason: 'Updated reason.',
      ),
    );

    expect(next.overlays.map((overlay) => overlay.package), ['alpha', 'zeta']);
    expect(next.overlays.last.reason, 'Updated reason.');
  });

  test('write emits one overlay entry in yaml_edit block-list map style', () {
    final root = Directory.systemTemp.createTempSync('patchwork_manifest_');
    addTearDown(() => root.deleteSync(recursive: true));

    final store = OverlayManifestStore(
      path: p.join(root.path, 'patchwork.yaml'),
    );

    store.write(
      OverlayManifest(
        overlays: const [
          OverlayManifestEntry(
            package: 'greeter',
            version: '0.1.0',
            sha256: 'abc123',
            patch: 'patches/greeter@0.1.0.patch',
            reason: 'Fix greeting.',
          ),
        ],
      ),
    );

    expect(File(store.path).readAsStringSync(), '''
overlays:
  - package: greeter
    version: 0.1.0
    sha256: abc123
    patch: patches/greeter@0.1.0.patch
    reason: Fix greeting.
''');
    expect(store.read().overlays.single.package, 'greeter');
  });

  test('write preserves sorted overlay order from upsert', () {
    final root = Directory.systemTemp.createTempSync('patchwork_manifest_');
    addTearDown(() => root.deleteSync(recursive: true));

    final store = OverlayManifestStore(
      path: p.join(root.path, 'patchwork.yaml'),
    );
    final manifest = OverlayManifest.empty()
        .upsert(
          const OverlayManifestEntry(
            package: 'zeta',
            version: '1.0.0',
            sha256: 'z',
            patch: 'patches/zeta@1.0.0.patch',
          ),
        )
        .upsert(
          const OverlayManifestEntry(
            package: 'alpha',
            version: '1.0.0',
            sha256: 'a',
            patch: 'patches/alpha@1.0.0.patch',
          ),
        );

    store.write(manifest);

    final content = File(store.path).readAsStringSync();
    expect(content, contains('  - package: alpha\n'));
    expect(
      content.indexOf('package: alpha'),
      lessThan(content.indexOf('package: zeta')),
    );
  });

  test('write updates an existing overlay entry', () {
    final root = Directory.systemTemp.createTempSync('patchwork_manifest_');
    addTearDown(() => root.deleteSync(recursive: true));

    final store = OverlayManifestStore(
      path: p.join(root.path, 'patchwork.yaml'),
    );
    final manifest = OverlayManifest.empty()
        .upsert(
          const OverlayManifestEntry(
            package: 'greeter',
            version: '0.1.0',
            sha256: 'abc123',
            patch: 'patches/greeter@0.1.0.patch',
            reason: 'Old reason.',
          ),
        )
        .upsert(
          const OverlayManifestEntry(
            package: 'greeter',
            version: '0.1.0',
            sha256: 'abc123',
            patch: 'patches/greeter@0.1.0.patch',
            reason: 'Updated reason.',
          ),
        );

    store.write(manifest);

    final content = File(store.path).readAsStringSync();
    expect(content, contains('reason: Updated reason.'));
    expect(content, isNot(contains('Old reason')));
    expect(store.read().overlays, hasLength(1));
  });
}
