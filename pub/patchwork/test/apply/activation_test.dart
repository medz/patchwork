import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:patchwork/src/apply/activation.dart';
import 'package:patchwork/src/io/atomic_file_writer.dart';
import 'package:patchwork/src/patch/package_tree.dart';
import 'package:patchwork/src/pub/dependency_overrides.dart';
import 'package:patchwork/src/pub/overrides.dart';
import 'package:patchwork/src/pub/source.dart';
import 'package:patchwork/src/state/applied_marker.dart';
import 'package:patchwork/src/state/applied_path_policy.dart';
import 'package:patchwork/src/state/dependency_override_state.dart';
import 'package:patchwork/src/state/path_layout.dart';
import 'package:test/test.dart';

void main() {
  test('writes each unchanged-mirror marker once during batch activation', () {
    final root = Directory.systemTemp.createTempSync('patchwork_activation_');
    addTearDown(() => root.deleteSync(recursive: true));
    File(p.join(root.path, 'pubspec.yaml')).writeAsStringSync('name: app\n');

    final layout = PathLayout(root.path);
    var markerWrites = 0;
    final markerStore = AppliedMarkerStore(
      layout: layout,
      fileWriter: AtomicFileWriter(
        renameFile: (sourcePath, destinationPath) {
          markerWrites += 1;
          File(sourcePath).renameSync(destinationPath);
        },
      ),
    );
    const overrides = PubspecOverrides();
    var overrideReads = 0;
    final activation = AppliedPatchActivation(
      rootPath: root.path,
      appliedPaths: AppliedPathPolicy(
        rootPath: root.path,
        layout: layout,
        protectedRootPaths: {root.path},
      ),
      appliedMarkerStore: markerStore,
      pubspecOverrides: overrides,
      packageTree: const PackageTree(),
      readOverrideState: () {
        overrideReads += 1;
        return DependencyOverrideState.read(
          rootPath: root.path,
          overrideRootPaths: {root.path},
          pubspecOverrides: overrides,
          pubspecDependencyOverrides: const PubspecDependencyOverrides(),
        );
      },
      invalidAppliedPathMessage: 'invalid applied path',
    );

    for (final package in ['alpha', 'beta']) {
      const version = '0.1.0';
      Directory(
        layout.appliedPath(package, version),
      ).createSync(recursive: true);
      activation.activate(
        package: package,
        version: version,
        patchSha256: '$package-patch',
        path: layout.relativeAppliedPath(package, version),
        source: PackageSource(
          type: 'path',
          sha256: '$package-source',
          fields: {'path': '../$package'},
        ),
      );
    }

    expect(markerWrites, 2);
    expect(overrideReads, 1);
    expect(markerStore.readAll().map((marker) => marker.package), [
      'alpha',
      'beta',
    ]);
    final dependencyOverrides = overrides
        .readDependencyOverrides(workspaceRootPath: root.path)
        .dependencyOverrides;
    expect(dependencyOverrides.keys, containsAll(['alpha', 'beta']));
  });
}
