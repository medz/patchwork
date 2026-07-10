import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:patchwork/src/pub/overrides.dart';
import 'package:test/test.dart';

void main() {
  test('writes dependency overrides with yaml_edit block-map style', () {
    final root = Directory.systemTemp.createTempSync('patchwork_overrides_');
    addTearDown(() => root.deleteSync(recursive: true));

    const overrides = PubspecOverrides();

    overrides
        .edit(workspaceRootPath: root.path)
        .upsertPathOverride(
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

  test('reuses one editor while preserving mirrors across package updates', () {
    final root = Directory.systemTemp.createTempSync('patchwork_overrides_');
    addTearDown(() => root.deleteSync(recursive: true));

    const overrides = PubspecOverrides();
    final editor = overrides.edit(workspaceRootPath: root.path);
    const pubspecOverrides = {
      'shared': {'path': 'vendor/shared'},
    };

    var mirrors = editor.upsertPathOverride(
      package: 'alpha',
      path: '.dart_tool/patchwork/alpha@0.1.0',
      pubspecDependencyOverrides: pubspecOverrides,
    );
    expect(mirrors, pubspecOverrides);

    mirrors = editor.upsertPathOverride(
      package: 'beta',
      path: '.dart_tool/patchwork/beta@0.1.0',
      ownedDependencyOverrides: {
        ...pubspecOverrides,
        'alpha': {'path': '.dart_tool/patchwork/alpha@0.1.0'},
      },
      pubspecDependencyOverrides: pubspecOverrides,
      mirroredPubspecDependencyOverrides: mirrors,
    );
    expect(mirrors, pubspecOverrides);

    mirrors = editor.removePathOverrideIfMatches(
      package: 'alpha',
      path: p.join(root.path, '.dart_tool', 'patchwork', 'alpha@0.1.0'),
      ownedDependencyOverrides: {
        ...pubspecOverrides,
        'alpha': {'path': '.dart_tool/patchwork/alpha@0.1.0'},
        'beta': {'path': '.dart_tool/patchwork/beta@0.1.0'},
      },
      pubspecDependencyOverrides: pubspecOverrides,
      mirroredPubspecDependencyOverrides: mirrors,
    );
    expect(mirrors, pubspecOverrides);

    mirrors = editor.removePathOverrideIfMatches(
      package: 'beta',
      path: '.dart_tool/patchwork/beta@0.1.0',
      ownedDependencyOverrides: {
        ...pubspecOverrides,
        'beta': {'path': '.dart_tool/patchwork/beta@0.1.0'},
      },
      pubspecDependencyOverrides: pubspecOverrides,
      mirroredPubspecDependencyOverrides: mirrors,
    );

    expect(mirrors, isEmpty);
    expect(
      File(p.join(root.path, 'pubspec_overrides.yaml')).existsSync(),
      isFalse,
    );
  });

  test('does not record the applied package as a restored mirror', () {
    final root = Directory.systemTemp.createTempSync('patchwork_overrides_');
    addTearDown(() => root.deleteSync(recursive: true));

    final mirrors = const PubspecOverrides()
        .edit(workspaceRootPath: root.path)
        .upsertPathOverride(
          package: 'greeter',
          path: '.dart_tool/patchwork/greeter@0.1.0',
          pubspecDependencyOverrides: const {
            'greeter': {'path': 'packages/greeter'},
            'shared': {'path': 'packages/shared'},
          },
        );

    expect(mirrors, {
      'shared': {'path': 'packages/shared'},
    });
  });

  test('preserves unrelated top-level fields while editing overrides', () {
    final root = Directory.systemTemp.createTempSync('patchwork_overrides_');
    addTearDown(() => root.deleteSync(recursive: true));
    final file = File(p.join(root.path, 'pubspec_overrides.yaml'));
    file.writeAsStringSync('workspace: true\n');

    final editor = const PubspecOverrides().edit(workspaceRootPath: root.path);
    editor.upsertPathOverride(
      package: 'greeter',
      path: '.dart_tool/patchwork/greeter@0.1.0',
    );
    editor.removePathOverrideIfMatches(
      package: 'greeter',
      path: '.dart_tool/patchwork/greeter@0.1.0',
    );

    expect(file.readAsStringSync(), 'workspace: true\n');
  });
}
