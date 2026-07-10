import 'dart:convert';
import 'dart:io';

import 'package:patchwork/src/state/applied_marker.dart';
import 'package:patchwork/src/state/applied_marker_reader.dart';
import 'package:patchwork/src/state/path_layout.dart';
import 'package:test/test.dart';

void main() {
  test('reads valid applied markers for artifact paths', () {
    final root = Directory.systemTemp.createTempSync(
      'patchwork_marker_reader_',
    );
    addTearDown(() => root.deleteSync(recursive: true));

    final layout = PathLayout(root.path);
    final store = AppliedMarkerStore(layout: layout);
    store.write(
      AppliedMarker(
        package: 'greeter',
        version: '0.1.0',
        patchSha256: 'patch-sha',
        path: layout.relativeAppliedPath('greeter', '0.1.0'),
        source: null,
      ),
    );

    final marker = tryReadAppliedMarker(
      store,
      PackageVersionPath(
        package: 'greeter',
        version: '0.1.0',
        path: layout.appliedPath('greeter', '0.1.0'),
      ),
    );

    expect(marker?.package, 'greeter');
    expect(marker?.version, '0.1.0');
  });

  test('returns null for malformed applied markers', () {
    final root = Directory.systemTemp.createTempSync(
      'patchwork_marker_reader_',
    );
    addTearDown(() => root.deleteSync(recursive: true));

    final layout = PathLayout(root.path);
    final markerPath = layout.appliedMarkerPath('greeter', '0.1.0');
    File(markerPath).parent.createSync(recursive: true);
    File(markerPath).writeAsStringSync(
      '${jsonEncode({'schemaVersion': 1, 'kind': 'patchwork.applied', 'package': 'other', 'version': '0.1.0', 'patchSha256': 'patch-sha', 'path': layout.relativeAppliedPath('greeter', '0.1.0')})}\n',
    );

    final marker = tryReadAppliedMarker(
      AppliedMarkerStore(layout: layout),
      PackageVersionPath(
        package: 'greeter',
        version: '0.1.0',
        path: layout.appliedPath('greeter', '0.1.0'),
      ),
    );

    expect(marker, isNull);
  });
}
