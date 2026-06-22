import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:patchwork/src/pub/pubspec_overrides.dart';
import 'package:test/test.dart';

void main() {
  test('writes dependency overrides with yaml_edit block-map style', () {
    final root = Directory.systemTemp.createTempSync('patchwork_overrides_');
    addTearDown(() => root.deleteSync(recursive: true));

    const overrides = PubspecOverrides();

    overrides.upsertPathOverride(
      workspaceRootPath: root.path,
      package: 'greeter',
      path: '.dart_tool/patchwork/greeter@0.1.0',
    );

    final file = File(p.join(root.path, 'pubspec_overrides.yaml'));
    expect(file.readAsStringSync(), '''
dependency_overrides:
  greeter:
    path: .dart_tool/patchwork/greeter@0.1.0
''');

    final snapshot = overrides.readDependencyOverrides(
      workspaceRootPath: root.path,
    );
    expect(snapshot.dependencyOverrides['greeter'], {
      'path': '.dart_tool/patchwork/greeter@0.1.0',
    });
  });
}
