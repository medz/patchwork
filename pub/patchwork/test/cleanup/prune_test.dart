import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:patchwork/src/state/applied_marker.dart';
import 'package:patchwork/src/state/applied_path_policy.dart';
import 'package:patchwork/src/cleanup/applied.dart';
import 'package:patchwork/src/cleanup/prune.dart';
import 'package:patchwork/src/state/dependency_override_state.dart';
import 'package:patchwork/src/state/path_layout.dart';
import 'package:patchwork/src/cleanup/model.dart';
import 'package:patchwork/src/pub/resolution_reader.dart';
import 'package:patchwork/src/pub/dependency_overrides.dart';
import 'package:patchwork/src/pub/overrides.dart';
import 'package:test/test.dart';

void main() {
  test(
    'prune plans one applied marker for stale patch with applied output',
    () {
      final root = Directory.systemTemp.createTempSync(
        'patchwork_cleanup_planner_',
      );
      addTearDown(() => root.deleteSync(recursive: true));

      final greeterRoot = p.join(root.path, 'packages', 'greeter');
      _writePackage(root.path, name: 'app', dependencies: {'greeter': 'path'});
      _writePackage(greeterRoot, name: 'greeter', version: '0.1.1');
      _writeResolution(root.path, greeterRoot: greeterRoot);

      final layout = PathLayout(root.path);
      File(layout.patchPath('greeter', '0.1.0'))
        ..createSync(recursive: true)
        ..writeAsStringSync(
          'diff --git a/lib/greeter.dart b/lib/greeter.dart\n',
        );

      Directory(
        layout.appliedPath('greeter', '0.1.0'),
      ).createSync(recursive: true);
      final markerStore = AppliedMarkerStore(layout: layout);
      markerStore.write(
        AppliedMarker(
          package: 'greeter',
          version: '0.1.0',
          patchSha256: 'sha',
          path: layout.relativeAppliedPath('greeter', '0.1.0'),
          source: null,
        ),
      );

      final appliedPaths = AppliedPathPolicy(
        rootPath: root.path,
        layout: layout,
        protectedRootPaths: {root.path},
      );
      final planner = PrunePlanner(
        layout: layout,
        appliedCleanup: AppliedCleanup(
          rootPath: root.path,
          appliedPaths: appliedPaths,
          invalidAppliedPathMessage: 'invalid applied path',
        ),
        appliedMarkerStore: markerStore,
        readResolution: () =>
            const PubResolutionReader().readFromDirectory(root.path),
        readOverrideState: () => DependencyOverrideState.read(
          rootPath: root.path,
          overrideRootPaths: {root.path},
          pubspecOverrides: const PubspecOverrides(),
          pubspecDependencyOverrides: const PubspecDependencyOverrides(),
        ),
      );

      final plan = planner.plan(dryRun: true);

      expect(plan.appliedMarkers, hasLength(1));
      expect(plan.appliedMarkers.single.package, 'greeter');
      expect(plan.appliedMarkers.single.version, '0.1.0');
      expect(plan.result.changes.map((change) => change.kind), [
        CleanupChangeKind.patchFile,
        CleanupChangeKind.appliedDirectory,
      ]);
    },
  );
}

void _writePackage(
  String rootPath, {
  required String name,
  String version = '1.0.0',
  Map<String, String> dependencies = const {},
}) {
  final root = Directory(rootPath)..createSync(recursive: true);
  File(p.join(root.path, 'pubspec.yaml')).writeAsStringSync('''
name: $name
version: $version
${dependencies.isEmpty ? '' : '''dependencies:
${dependencies.keys.map((dependency) => '  $dependency:\n    path: packages/$dependency').join('\n')}
'''}''');
  Directory(p.join(root.path, 'lib')).createSync(recursive: true);
  File(p.join(root.path, 'lib', '$name.dart')).writeAsStringSync('');
}

void _writeResolution(String rootPath, {required String greeterRoot}) {
  final dartTool = Directory(p.join(rootPath, '.dart_tool'))
    ..createSync(recursive: true);
  File(p.join(dartTool.path, 'package_config.json')).writeAsStringSync(
    '${jsonEncode({
      'configVersion': 2,
      'packages': [
        {'name': 'app', 'rootUri': Directory(rootPath).absolute.uri.toString(), 'packageUri': 'lib/'},
        {'name': 'greeter', 'rootUri': Directory(greeterRoot).absolute.uri.toString(), 'packageUri': 'lib/'},
      ],
    })}\n',
  );
  File(p.join(rootPath, 'pubspec.lock')).writeAsStringSync('''
packages:
  greeter:
    dependency: "direct main"
    description:
      path: packages/greeter
      relative: true
    source: path
    version: "0.1.1"
sdks:
  dart: ">=3.10.0 <4.0.0"
''');
}
