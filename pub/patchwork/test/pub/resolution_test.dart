import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:patchwork/src/error.dart';
import 'package:patchwork/src/patch/package_tree.dart';
import 'package:patchwork/src/pub/resolution.dart';
import 'package:patchwork/src/pub/resolution_reader.dart';
import 'package:patchwork/src/pub/workspace.dart';
import 'package:test/test.dart';

void main() {
  test('records hosted, path, and git source fields', () {
    final root = Directory.systemTemp.createTempSync('patchwork_resolution_');
    addTearDown(() => root.deleteSync(recursive: true));

    final appRoot = p.join(root.path, 'app');
    final hostedRoot = p.join(root.path, 'cache', 'hosted_pkg');
    final pathRoot = p.join(root.path, 'packages', 'path_pkg');
    final gitRoot = p.join(root.path, 'git', 'git_pkg');
    _writePackage(appRoot, 'app');
    _writePackage(hostedRoot, 'hosted_pkg');
    _writePackage(pathRoot, 'path_pkg');
    _writePackage(gitRoot, 'git_pkg');
    _writePubspec(appRoot, '''
name: app
publish_to: none

environment:
  sdk: ^3.10.0

dependencies:
  hosted_pkg: any
  path_pkg: any
  git_pkg: any
''');
    _writePackageConfig(appRoot, {
      'app': appRoot,
      'hosted_pkg': hostedRoot,
      'path_pkg': pathRoot,
      'git_pkg': gitRoot,
    });
    _writeLockfile(appRoot, '''
sdks:
  dart: ">=3.10.0 <4.0.0"
packages:
  hosted_pkg:
    dependency: "direct main"
    description:
      name: hosted_pkg
      sha256: ignored-by-patchwork
      url: "https://pub.example"
    source: hosted
    version: "1.2.3"
  path_pkg:
    dependency: "direct main"
    description:
      path: "../packages/path_pkg"
      relative: true
    source: path
    version: "0.1.0"
  git_pkg:
    dependency: "direct main"
    description:
      url: "https://example.com/git_pkg.git"
      ref: "main"
      resolved-ref: "abc123"
      path: "packages/git_pkg"
    source: git
    version: "0.2.0"
''');

    final resolution = const PubResolutionReader().readFromDirectory(appRoot);

    final hosted = resolution.resolvePackage('hosted_pkg');
    expect(hosted.source.type, 'hosted');
    expect(hosted.source.fields, {'url': 'https://pub.example'});
    expect(hosted.source.sha256, isNotEmpty);
    expect(resolution.resolvePackage('hosted_pkg'), same(hosted));

    final path = resolution.resolvePackage('path_pkg');
    expect(path.source.type, 'path');
    expect(path.source.fields, {'path': '../packages/path_pkg'});

    final git = resolution.resolvePackage('git_pkg');
    expect(git.source.type, 'git');
    expect(git.source.fields, {
      'url': 'https://example.com/git_pkg.git',
      'branch': 'main',
      'commit': 'abc123',
      'path': 'packages/git_pkg',
    });
  });

  test('requires direct dependencies only when requested', () {
    final root = Directory.systemTemp.createTempSync('patchwork_resolution_');
    addTearDown(() => root.deleteSync(recursive: true));

    final appRoot = p.join(root.path, 'app');
    final directRoot = p.join(root.path, 'packages', 'direct_pkg');
    final transitiveRoot = p.join(root.path, 'packages', 'transitive_pkg');
    _writePackage(appRoot, 'app');
    _writePackage(directRoot, 'direct_pkg');
    _writePackage(transitiveRoot, 'transitive_pkg');
    _writePubspec(appRoot, '''
name: app
publish_to: none

environment:
  sdk: ^3.10.0

dependencies:
  direct_pkg: any
''');
    _writePackageConfig(appRoot, {
      'app': appRoot,
      'direct_pkg': directRoot,
      'transitive_pkg': transitiveRoot,
    });
    _writeLockfile(appRoot, '''
sdks:
  dart: ">=3.10.0 <4.0.0"
packages:
  direct_pkg:
    dependency: "direct main"
    description:
      path: "../packages/direct_pkg"
      relative: true
    source: path
    version: "0.1.0"
  transitive_pkg:
    dependency: transitive
    description:
      path: "../packages/transitive_pkg"
      relative: true
    source: path
    version: "0.1.0"
''');

    final resolution = const PubResolutionReader().readFromDirectory(appRoot);

    expect(resolution.resolvePackage('direct_pkg').rootPath, directRoot);
    expect(
      () => resolution.resolvePackage('transitive_pkg'),
      throwsA(
        isA<PatchworkException>().having(
          (error) => error.code,
          'code',
          'pub.package_not_direct_dependency',
        ),
      ),
    );
    expect(
      resolution
          .resolvePackage('transitive_pkg', requireDirectDependency: false)
          .rootPath,
      transitiveRoot,
    );
    expect(
      () => resolution.resolvePackage('transitive_pkg'),
      throwsA(
        isA<PatchworkException>().having(
          (error) => error.code,
          'code',
          'pub.package_not_direct_dependency',
        ),
      ),
    );
  });

  test('defers source-tree hashing until source identity is requested', () {
    final root = Directory.systemTemp.createTempSync('patchwork_resolution_');
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    final packageRoot = p.join(root.path, 'greeter');
    _writePackage(packageRoot, 'greeter');
    final workspace = PubWorkspace(
      rootPath: root.path,
      currentPackageRootPath: root.path,
      rootPackageRootPaths: {root.path},
      packageConfigPath: p.join(root.path, '.dart_tool', 'package_config.json'),
      lockfilePath: p.join(root.path, 'pubspec.lock'),
      packageGraphPath: p.join(root.path, '.dart_tool', 'package_graph.json'),
    );
    final resolution = PubResolution(
      workspace: workspace,
      packageRoots: {'greeter': packageRoot},
      metadata: {
        'greeter': PubPackageMetadata(
          version: '0.1.0',
          sourceKind: PubPackageSourceKind.path,
          description: const {'path': 'greeter'},
        ),
      },
      rootNames: const {},
      directDependencies: const {'greeter'},
      packageTree: const PackageTree(),
    );

    final resolved = resolution.resolvePackage('greeter');
    Directory(packageRoot).deleteSync(recursive: true);

    expect(resolved.version, '0.1.0');
    expect(
      () => resolved.source,
      throwsA(
        isA<PatchworkException>().having(
          (error) => error.code,
          'code',
          'fs.package_tree_missing',
        ),
      ),
    );
  });

  test('rejects workspace members when package graph is missing', () {
    final root = Directory.systemTemp.createTempSync('patchwork_resolution_');
    addTearDown(() => root.deleteSync(recursive: true));

    final workspaceRoot = p.join(root.path, 'workspace');
    final appRoot = p.join(workspaceRoot, 'app');
    final memberRoot = p.join(workspaceRoot, 'packages', 'member_greeter');
    _writePubspec(workspaceRoot, '''
name: workspace
publish_to: none

environment:
  sdk: ^3.10.0

workspace:
  - app
  - packages/member_greeter
''');
    _writePubspec(appRoot, '''
name: app
publish_to: none

environment:
  sdk: ^3.10.0

resolution: workspace

dependencies:
  member_greeter: any
''');
    _writePackage(memberRoot, 'member_greeter');
    _writePackageConfig(workspaceRoot, {
      'workspace': workspaceRoot,
      'app': appRoot,
      'member_greeter': memberRoot,
    });
    _writeLockfile(workspaceRoot, '''
sdks:
  dart: ">=3.10.0 <4.0.0"
packages:
  member_greeter:
    dependency: "direct main"
    description:
      path: "packages/member_greeter"
      relative: true
    source: path
    version: "0.1.0"
''');

    final resolution = const PubResolutionReader().readFromDirectory(appRoot);

    expect(
      () => resolution.resolvePackage('member_greeter'),
      throwsA(
        isA<PatchworkException>().having(
          (error) => error.code,
          'code',
          'pub.package_is_project',
        ),
      ),
    );
  });

  test('rejects unknown pub source kinds', () {
    final root = Directory.systemTemp.createTempSync('patchwork_resolution_');
    addTearDown(() => root.deleteSync(recursive: true));

    final appRoot = p.join(root.path, 'app');
    final unknownRoot = p.join(root.path, 'packages', 'unknown_pkg');
    _writePackage(appRoot, 'app');
    _writePackage(unknownRoot, 'unknown_pkg');
    _writePubspec(appRoot, '''
name: app
publish_to: none

environment:
  sdk: ^3.10.0

dependencies:
  unknown_pkg: any
''');
    _writePackageConfig(appRoot, {'app': appRoot, 'unknown_pkg': unknownRoot});
    _writeLockfile(appRoot, '''
sdks:
  dart: ">=3.10.0 <4.0.0"
packages:
  unknown_pkg:
    dependency: "direct main"
    description:
      path: "../packages/unknown_pkg"
    source: future_source
    version: "0.1.0"
''');

    final resolution = const PubResolutionReader().readFromDirectory(appRoot);

    expect(
      () => resolution.resolvePackage('unknown_pkg'),
      throwsA(
        isA<PatchworkException>().having(
          (error) => error.code,
          'code',
          'pub.unsupported_source',
        ),
      ),
    );
  });
}

void _writePackage(String root, String name) {
  Directory(p.join(root, 'lib')).createSync(recursive: true);
  _writePubspec(root, '''
name: $name
version: 0.1.0
publish_to: none

environment:
  sdk: ^3.10.0
''');
  File(p.join(root, 'lib', '$name.dart')).writeAsStringSync('''
String name() => '$name';
''');
}

void _writePubspec(String root, String content) {
  Directory(root).createSync(recursive: true);
  File(p.join(root, 'pubspec.yaml')).writeAsStringSync(content);
}

void _writePackageConfig(String root, Map<String, String> packages) {
  final dotDartTool = Directory(p.join(root, '.dart_tool'))
    ..createSync(recursive: true);
  final baseUri = dotDartTool.uri;
  File(p.join(dotDartTool.path, 'package_config.json')).writeAsStringSync(
    jsonEncode({
      'configVersion': 2,
      'packages': [
        for (final entry in packages.entries)
          {
            'name': entry.key,
            'rootUri': baseUri
                .resolveUri(Directory(entry.value).absolute.uri)
                .toString(),
            'packageUri': 'lib/',
            'languageVersion': '3.12',
          },
      ],
    }),
  );
}

void _writeLockfile(String root, String content) {
  File(p.join(root, 'pubspec.lock')).writeAsStringSync(content);
}
