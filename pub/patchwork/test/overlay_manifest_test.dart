import 'package:patchwork/src/overlay_manifest.dart';
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
}
