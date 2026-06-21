import 'dart:convert';
import 'dart:io';

import 'package:patchwork/src/applied_marker.dart';
import 'package:patchwork/src/error.dart';
import 'package:patchwork/src/internal/path_layout.dart';
import 'package:patchwork/src/model.dart';
import 'package:test/test.dart';

void main() {
  test('writes and reads generated output ownership markers', () {
    final root = Directory.systemTemp.createTempSync('patchwork_marker_');
    addTearDown(() => root.deleteSync(recursive: true));

    final layout = PathLayout(root.path);
    final store = AppliedMarkerStore(layout: layout);
    store.write(
      AppliedMarker(
        package: 'greeter',
        version: '0.1.0',
        patchSha256: 'patch-sha',
        path: layout.relativeAppliedPath('greeter', '0.1.0'),
        source: const PackageSource(
          type: 'path',
          sha256: 'source-sha',
          fields: {'path': '../packages/greeter'},
        ),
        mirroredPubspecDependencyOverrides: const {
          'greeter': {'path': '../packages/greeter'},
        },
      ),
    );

    final marker = store.read('greeter', '0.1.0');
    expect(marker, isNotNull);
    expect(marker!.package, 'greeter');
    expect(marker.version, '0.1.0');
    expect(marker.patchSha256, 'patch-sha');
    expect(marker.path, '.dart_tool/patchwork/greeter@0.1.0');
    expect(marker.source!.type, 'path');
    expect(marker.source!.sha256, 'source-sha');
    expect(marker.source!.fields, {'path': '../packages/greeter'});
    expect(marker.mirroredPubspecDependencyOverrides, {
      'greeter': {'path': '../packages/greeter'},
    });
  });

  test('readAll returns valid markers sorted by package and version', () {
    final root = Directory.systemTemp.createTempSync('patchwork_marker_');
    addTearDown(() => root.deleteSync(recursive: true));

    final layout = PathLayout(root.path);
    final store = AppliedMarkerStore(layout: layout);
    for (final marker in [
      _marker(layout, package: 'zeta', version: '0.1.0'),
      _marker(layout, package: 'alpha', version: '0.2.0'),
      _marker(layout, package: 'alpha', version: '0.1.0'),
    ]) {
      store.write(marker);
    }

    expect(
      store.readAll().map((marker) => '${marker.package}@${marker.version}'),
      ['alpha@0.1.0', 'alpha@0.2.0', 'zeta@0.1.0'],
    );
  });

  test('rejects malformed or mismatched marker files', () {
    final root = Directory.systemTemp.createTempSync('patchwork_marker_');
    addTearDown(() => root.deleteSync(recursive: true));

    final layout = PathLayout(root.path);
    final markerPath = layout.appliedMarkerPath('greeter', '0.1.0');
    File(markerPath).parent.createSync(recursive: true);
    File(markerPath).writeAsStringSync(
      '${jsonEncode({'schemaVersion': 1, 'kind': 'patchwork.applied', 'package': 'other', 'version': '0.1.0', 'patchSha256': 'patch-sha', 'path': layout.relativeAppliedPath('greeter', '0.1.0')})}\n',
    );

    expect(
      () => AppliedMarkerStore(layout: layout).read('greeter', '0.1.0'),
      throwsA(
        isA<PatchworkException>().having(
          (error) => error.code,
          'code',
          'applied.marker_invalid',
        ),
      ),
    );
  });
}

AppliedMarker _marker(
  PathLayout layout, {
  required String package,
  required String version,
}) {
  return AppliedMarker(
    package: package,
    version: version,
    patchSha256: '$package-$version-patch',
    path: layout.relativeAppliedPath(package, version),
    source: null,
  );
}
