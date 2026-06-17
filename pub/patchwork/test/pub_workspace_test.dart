import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:patchwork/src/error.dart';
import 'package:patchwork/src/pub/pub_workspace.dart';
import 'package:test/test.dart';

void main() {
  group('PubWorkspaceLocator', () {
    test('does not use an unrelated ancestor pub resolution', () {
      final root = Directory.systemTemp.createTempSync(
        'patchwork_pub_workspace_',
      );
      addTearDown(() => root.deleteSync(recursive: true));

      _writePubspec(root.path, 'outer_project');
      _writePackageConfig(root.path, [
        const _PackageConfigEntry(name: 'outer_project', rootUri: '..'),
      ]);

      final appRoot = p.join(root.path, 'app');
      _writePubspec(appRoot, 'app');

      expect(
        () => const PubWorkspaceLocator().locate(appRoot),
        throwsA(
          isA<PatchworkException>().having(
            (error) => error.code,
            'code',
            'pub.resolution_not_found',
          ),
        ),
      );
    });

    test('uses a workspace resolution that contains the current package', () {
      final workspaceRoot = Directory.systemTemp.createTempSync(
        'patchwork_pub_workspace_',
      );
      addTearDown(() => workspaceRoot.deleteSync(recursive: true));

      _writeWorkspacePubspec(workspaceRoot.path);
      final appRoot = p.join(workspaceRoot.path, 'app');
      _writePubspec(appRoot, 'app');
      _writePackageConfig(workspaceRoot.path, [
        const _PackageConfigEntry(name: 'workspace', rootUri: '..'),
        const _PackageConfigEntry(name: 'app', rootUri: '../app'),
        const _PackageConfigEntry(
          name: 'member_greeter',
          rootUri: '../packages/member_greeter',
        ),
      ]);
      _writePackageGraph(workspaceRoot.path, [
        'workspace',
        'app',
        'member_greeter',
      ]);

      final workspace = const PubWorkspaceLocator().locate(appRoot);

      expect(workspace.rootPath, workspaceRoot.path);
      expect(workspace.currentPackageRootPath, appRoot);
      expect(workspace.rootPackageRootPaths, {
        workspaceRoot.path,
        appRoot,
        p.join(workspaceRoot.path, 'packages', 'member_greeter'),
      });
    });

    test('protects workspace members when package graph is missing', () {
      final workspaceRoot = Directory.systemTemp.createTempSync(
        'patchwork_pub_workspace_',
      );
      addTearDown(() => workspaceRoot.deleteSync(recursive: true));

      _writeWorkspacePubspec(workspaceRoot.path);
      final appRoot = p.join(workspaceRoot.path, 'app');
      _writePubspec(appRoot, 'app');
      _writePackageConfig(workspaceRoot.path, [
        const _PackageConfigEntry(name: 'workspace', rootUri: '..'),
        const _PackageConfigEntry(name: 'app', rootUri: '../app'),
        const _PackageConfigEntry(
          name: 'member_greeter',
          rootUri: '../packages/member_greeter',
        ),
      ]);

      final workspace = const PubWorkspaceLocator().locate(appRoot);

      expect(
        workspace.rootPackageRootPaths,
        contains(p.join(workspaceRoot.path, 'packages', 'member_greeter')),
      );
    });

    test('expands wildcard workspace members without package graph', () {
      final workspaceRoot = Directory.systemTemp.createTempSync(
        'patchwork_pub_workspace_',
      );
      addTearDown(() => workspaceRoot.deleteSync(recursive: true));

      _writeWorkspacePubspec(workspaceRoot.path, memberPath: 'pub/*');
      final appRoot = p.join(workspaceRoot.path, 'app');
      final memberRoot = p.join(workspaceRoot.path, 'pub', 'patchwork');
      _writePubspec(appRoot, 'app');
      _writePubspec(memberRoot, 'patchwork');
      _writePackageConfig(workspaceRoot.path, [
        const _PackageConfigEntry(name: 'workspace', rootUri: '..'),
        const _PackageConfigEntry(name: 'app', rootUri: '../app'),
        const _PackageConfigEntry(
          name: 'patchwork',
          rootUri: '../pub/patchwork',
        ),
      ]);

      final workspace = const PubWorkspaceLocator().locate(appRoot);

      expect(workspace.rootPackageRootPaths, contains(memberRoot));
    });
  });
}

void _writePubspec(String root, String name) {
  Directory(root).createSync(recursive: true);
  File(p.join(root, 'pubspec.yaml')).writeAsStringSync('''
name: $name
publish_to: none

environment:
  sdk: ^3.12.0
''');
}

void _writeWorkspacePubspec(
  String root, {
  String memberPath = 'packages/member_greeter',
}) {
  Directory(root).createSync(recursive: true);
  File(p.join(root, 'pubspec.yaml')).writeAsStringSync('''
name: workspace
publish_to: none

environment:
  sdk: ^3.12.0

workspace:
  - app
  - $memberPath
''');
}

void _writePackageConfig(String root, List<_PackageConfigEntry> packages) {
  final dotDartTool = Directory(p.join(root, '.dart_tool'))
    ..createSync(recursive: true);
  File(p.join(dotDartTool.path, 'package_config.json')).writeAsStringSync(
    jsonEncode({
      'configVersion': 2,
      'packages': [
        for (final package in packages)
          {
            'name': package.name,
            'rootUri': package.rootUri,
            'packageUri': 'lib/',
            'languageVersion': '3.12',
          },
      ],
    }),
  );
}

void _writePackageGraph(String root, List<String> roots) {
  final dotDartTool = Directory(p.join(root, '.dart_tool'))
    ..createSync(recursive: true);
  File(
    p.join(dotDartTool.path, 'package_graph.json'),
  ).writeAsStringSync(jsonEncode({'roots': roots}));
}

final class _PackageConfigEntry {
  const _PackageConfigEntry({required this.name, required this.rootUri});

  final String name;
  final String rootUri;
}
