import 'dart:io';

import 'package:patchwork/src/state/applied_marker.dart';
import 'package:patchwork/src/error.dart';
import 'package:patchwork/src/state/path_layout.dart';
import 'package:patchwork/src/cleanup/undo.dart';
import 'package:test/test.dart';

void main() {
  test('plans a no-op when no applied marker exists for the package', () {
    final root = Directory.systemTemp.createTempSync('patchwork_undo_');
    addTearDown(() => root.deleteSync(recursive: true));

    final planner = UndoPlanner(
      appliedMarkerStore: AppliedMarkerStore(layout: PathLayout(root.path)),
    );

    final plan = planner.plan('greeter');

    expect(plan.package, 'greeter');
    expect(plan.marker, isNull);
  });

  test('selects the single applied marker for the package', () {
    final root = Directory.systemTemp.createTempSync('patchwork_undo_');
    addTearDown(() => root.deleteSync(recursive: true));

    final layout = PathLayout(root.path);
    final store = AppliedMarkerStore(layout: layout)
      ..write(_marker(layout, package: 'greeter', version: '0.1.0'))
      ..write(_marker(layout, package: 'other', version: '0.1.0'));
    final planner = UndoPlanner(appliedMarkerStore: store);

    final plan = planner.plan('greeter');

    expect(plan.package, 'greeter');
    expect(plan.marker, isNotNull);
    expect(plan.marker!.package, 'greeter');
    expect(plan.marker!.version, '0.1.0');
  });

  test('rejects ambiguous applied markers for the package', () {
    final root = Directory.systemTemp.createTempSync('patchwork_undo_');
    addTearDown(() => root.deleteSync(recursive: true));

    final layout = PathLayout(root.path);
    final store = AppliedMarkerStore(layout: layout)
      ..write(_marker(layout, package: 'greeter', version: '0.1.0'))
      ..write(_marker(layout, package: 'greeter', version: '0.2.0'));
    final planner = UndoPlanner(appliedMarkerStore: store);

    expect(
      () => planner.plan('greeter'),
      throwsA(
        isA<PatchworkException>().having(
          (error) => error.code,
          'code',
          'undo.ambiguous_applied',
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
