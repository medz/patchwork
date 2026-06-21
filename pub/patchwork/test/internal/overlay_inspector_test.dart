import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:patchwork/src/internal/overlay_inspector.dart';
import 'package:patchwork/src/internal/package_tree.dart';
import 'package:patchwork/src/internal/path_layout.dart';
import 'package:patchwork/src/model.dart';
import 'package:test/test.dart';

void main() {
  test('matches providers and deduplicates identical patch files', () async {
    final fixture = _OverlayFixture.create();
    addTearDown(fixture.dispose);

    fixture.writeProviderOverlay('provider_a', _prefixPatch('Hi'));
    fixture.writeProviderOverlay('provider_b', _prefixPatch('Hi'));

    final inspection = await fixture.inspect();

    expect(inspection.providers.map((provider) => provider.package), [
      'provider_a',
      'provider_b',
    ]);
    expect(
      inspection.providers
          .expand((provider) => provider.entries)
          .map((entry) => entry.status),
      [OverlayEntryStatus.matched, OverlayEntryStatus.matched],
    );
    final target = inspection.targets.single;
    expect(target.package, 'greeter');
    expect(target.conflict, isNull);
    expect(target.contributions.map((entry) => entry.provider), [
      'provider_a',
      'provider_b',
    ]);
    expect(target.contributions.map((entry) => entry.status), [
      OverlayContributionStatus.active,
      OverlayContributionStatus.deduplicated,
    ]);
  });

  test(
    'reports missing provider patch files without creating targets',
    () async {
      final fixture = _OverlayFixture.create();
      addTearDown(fixture.dispose);

      fixture.writeProviderManifest(
        'provider_a',
        patchPath: 'patches/missing.patch',
      );

      final inspection = await fixture.inspect();

      final entry = inspection.providers.single.entries.single;
      expect(entry.status, OverlayEntryStatus.failed);
      expect(entry.skipReason, 'overlay.patch_file_missing');
      expect(inspection.targets, isEmpty);
    },
  );

  test('skips stale provider overlays before checking patch files', () async {
    final fixture = _OverlayFixture.create();
    addTearDown(fixture.dispose);

    fixture.writeProviderManifest(
      'provider_a',
      patchPath: 'patches/missing.patch',
      version: '0.0.1',
    );

    final inspection = await fixture.inspect();

    final entry = inspection.providers.single.entries.single;
    expect(entry.status, OverlayEntryStatus.skipped);
    expect(entry.skipReason, 'overlay.version_mismatch');
    expect(entry.resolvedVersion, '0.1.0');
    expect(inspection.targets, isEmpty);
  });

  test(
    'fails provider overlays that do not target provider dependencies',
    () async {
      final fixture = _OverlayFixture.create();
      addTearDown(fixture.dispose);

      fixture.writeProviderManifest(
        'provider_a',
        package: 'provider_b',
        patchPath: 'patches/provider_b@0.1.0.patch',
        sha256: 'unused',
      );

      final inspection = await fixture.inspect();

      final entry = inspection.providers.single.entries.single;
      expect(entry.status, OverlayEntryStatus.failed);
      expect(entry.skipReason, 'overlay.provider_not_dependency');
      expect(inspection.targets, isEmpty);
    },
  );

  test('reports deterministic conflicts from fixture patch files', () async {
    final fixture = _OverlayFixture.create();
    addTearDown(fixture.dispose);

    fixture.writeProviderOverlay('provider_a', _prefixPatch('Hi'));
    fixture.writeProviderOverlay('provider_b', _prefixPatch('Yo'));

    final inspection = await fixture.inspect();

    final conflict = inspection.targets.single.conflict;
    expect(conflict, isNotNull);
    expect(conflict!.provider, 'provider_b');
    expect(conflict.patchPath, contains('provider_b'));
    expect(conflict.message, contains('Could not apply patch'));
  });
}

final class _OverlayFixture {
  _OverlayFixture._(this.root, this.greeterSha256);

  final Directory root;
  final String greeterSha256;

  String get greeterRoot => p.join(root.path, 'packages', 'greeter');

  static _OverlayFixture create() {
    final root = Directory.systemTemp.createTempSync('patchwork_overlay_unit_');
    final greeterRoot = p.join(root.path, 'packages', 'greeter');
    _writePackage(
      root.path,
      'app',
      dependencies: const ['greeter', 'provider_a', 'provider_b'],
    );
    _writeGreeterPackage(greeterRoot);
    _writePackage(
      p.join(root.path, 'packages', 'provider_a'),
      'provider_a',
      dependencies: const ['greeter'],
    );
    _writePackage(
      p.join(root.path, 'packages', 'provider_b'),
      'provider_b',
      dependencies: const ['greeter'],
    );
    _writePubResolution(root.path);
    return _OverlayFixture._(root, const PackageTree().sha256Of(greeterRoot));
  }

  Future<OverlayInspection> inspect() {
    return OverlayInspector(
      rootPath: root.path,
      layout: PathLayout(root.path),
    ).inspect();
  }

  void writeProviderOverlay(String provider, String patchContent) {
    final providerRoot = p.join(root.path, 'packages', provider);
    final patchPath = p.join(providerRoot, 'patches', 'greeter@0.1.0.patch');
    File(patchPath)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(patchContent);
    writeProviderManifest(provider, patchPath: 'patches/greeter@0.1.0.patch');
  }

  void writeProviderManifest(
    String provider, {
    required String patchPath,
    String package = 'greeter',
    String version = '0.1.0',
    String? sha256,
  }) {
    File(
      p.join(root.path, 'packages', provider, 'patchwork.yaml'),
    ).writeAsStringSync('''
overlays:
  - package: "$package"
    version: "$version"
    sha256: "${sha256 ?? greeterSha256}"
    patch: "$patchPath"
''');
  }

  void dispose() {
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  }
}

void _writePubResolution(String rootPath) {
  final dartTool = Directory(p.join(rootPath, '.dart_tool'))
    ..createSync(recursive: true);
  final packages = {
    'app': rootPath,
    'greeter': p.join(rootPath, 'packages', 'greeter'),
    'provider_a': p.join(rootPath, 'packages', 'provider_a'),
    'provider_b': p.join(rootPath, 'packages', 'provider_b'),
  };
  File(p.join(dartTool.path, 'package_config.json')).writeAsStringSync(
    '${jsonEncode({
      'configVersion': 2,
      'packages': [
        for (final entry in packages.entries) {'name': entry.key, 'rootUri': Directory(entry.value).absolute.uri.toString(), 'packageUri': 'lib/'},
      ],
    })}\n',
  );
  File(p.join(dartTool.path, 'package_graph.json')).writeAsStringSync(
    '${jsonEncode({
      'roots': ['app'],
      'packages': [
        {
          'name': 'app',
          'dependencies': ['greeter', 'provider_a', 'provider_b'],
        },
        {'name': 'greeter', 'dependencies': <String>[]},
        {
          'name': 'provider_a',
          'dependencies': ['greeter'],
        },
        {
          'name': 'provider_b',
          'dependencies': ['greeter'],
        },
      ],
    })}\n',
  );
  File(p.join(rootPath, 'pubspec.lock')).writeAsStringSync('''
packages:
  greeter:
    dependency: transitive
    description:
      path: packages/greeter
      relative: true
    source: path
    version: "0.1.0"
  provider_a:
    dependency: "direct main"
    description:
      path: packages/provider_a
      relative: true
    source: path
    version: "0.1.0"
  provider_b:
    dependency: "direct main"
    description:
      path: packages/provider_b
      relative: true
    source: path
    version: "0.1.0"
sdks:
  dart: ">=3.12.0 <4.0.0"
''');
}

void _writePackage(
  String root,
  String name, {
  List<String> dependencies = const [],
}) {
  Directory(p.join(root, 'lib')).createSync(recursive: true);
  File(p.join(root, 'pubspec.yaml')).writeAsStringSync('''
name: $name
version: 0.1.0
publish_to: none

environment:
  sdk: ^3.12.0
${dependencies.isEmpty ? '' : '\ndependencies:\n'}${dependencies.map((dependency) => '  $dependency:\n    path: packages/$dependency\n').join()}
''');
  File(p.join(root, 'lib', '$name.dart')).writeAsStringSync('''
String ${name}Name() {
  return '$name';
}
''');
}

void _writeGreeterPackage(String root) {
  Directory(p.join(root, 'lib')).createSync(recursive: true);
  File(p.join(root, 'pubspec.yaml')).writeAsStringSync('''
name: greeter
version: 0.1.0
publish_to: none

environment:
  sdk: ^3.12.0
''');
  File(p.join(root, 'lib', 'greeter.dart')).writeAsStringSync('''
String greeting(String name) {
  return 'Hello, \$name!';
}
''');
}

String _prefixPatch(String prefix) {
  return '''
diff --git a/lib/greeter.dart b/lib/greeter.dart
--- a/lib/greeter.dart
+++ b/lib/greeter.dart
@@ -1,3 +1,3 @@
 String greeting(String name) {
-  return 'Hello, \$name!';
+  return '$prefix, \$name!';
 }
''';
}
