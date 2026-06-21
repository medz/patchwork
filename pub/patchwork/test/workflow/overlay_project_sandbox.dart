import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:hooks/hooks.dart';
import 'package:path/path.dart' as p;
import 'package:patchwork/src/cli/application.dart';
import 'package:patchwork/src/internal/package_tree.dart';
import 'package:patchwork/src/overlay_hook.dart' as patchwork_hooks;
import 'package:test/test.dart';

final class OverlayProjectSandbox {
  OverlayProjectSandbox._({
    required this.root,
    required this.stateRoot,
    required this.appRoot,
    required this.greeterRoot,
    required this.providerBRoot,
    required this.providerCRoot,
    required this.patchworkRoot,
    required this.appDependsOnProviderC,
    required this.appDependsOnGreeter,
    required this.appDependsOnPatchwork,
    required this.appIsWorkspaceMember,
    required this.providerBIsWorkspaceMember,
    required this.environment,
  });

  final Directory root;
  final String stateRoot;
  final String appRoot;
  final String greeterRoot;
  final String providerBRoot;
  final String providerCRoot;
  final String patchworkRoot;
  final bool appDependsOnProviderC;
  final bool appDependsOnGreeter;
  final bool appDependsOnPatchwork;
  final bool appIsWorkspaceMember;
  final bool providerBIsWorkspaceMember;
  final Map<String, String> environment;

  Directory get appliedGreeterDirectory {
    return Directory(
      p.join(stateRoot, '.dart_tool', 'patchwork', 'greeter@0.1.0'),
    );
  }

  File get appliedGreeterLibrary {
    return File(p.join(appliedGreeterDirectory.path, 'lib', 'greeter.dart'));
  }

  static Future<OverlayProjectSandbox> create({
    bool appDependsOnProviderC = false,
    bool appDependsOnGreeter = false,
    bool appDependsOnPatchwork = false,
    bool appIsWorkspaceMember = false,
    bool providerBIsWorkspaceMember = false,
  }) async {
    if (providerBIsWorkspaceMember && !appIsWorkspaceMember) {
      throw ArgumentError.value(
        providerBIsWorkspaceMember,
        'providerBIsWorkspaceMember',
        'Provider B can only be a workspace member when the app is one.',
      );
    }
    final root = Directory.systemTemp.createTempSync('patchwork_overlay_');
    final patchworkRoot = await _patchworkPackageRoot();
    final pubCachePath = _resolvedPubCachePath(patchworkRoot);
    final greeterRoot = p.join(root.path, 'packages', 'greeter');
    final stateRoot = appIsWorkspaceMember
        ? p.join(root.path, 'workspace')
        : p.join(root.path, 'app');
    final appRoot = appIsWorkspaceMember ? p.join(stateRoot, 'app') : stateRoot;
    final providerBRoot = providerBIsWorkspaceMember
        ? p.join(stateRoot, 'packages', 'provider_b')
        : p.join(root.path, 'packages', 'provider_b');
    final providerCRoot = p.join(root.path, 'packages', 'provider_c');

    _writeGreeterPackage(greeterRoot);
    _writeProviderPackage(
      providerBRoot,
      name: 'provider_b',
      greeterPath: providerBIsWorkspaceMember
          ? '../../../packages/greeter'
          : '../greeter',
      patchworkPath: patchworkRoot,
      workspaceMember: providerBIsWorkspaceMember,
    );
    _writeProviderPackage(
      providerCRoot,
      name: 'provider_c',
      greeterPath: '../greeter',
      patchworkPath: patchworkRoot,
    );
    if (appIsWorkspaceMember) {
      _writeWorkspaceRoot(
        stateRoot,
        includeProviderB: providerBIsWorkspaceMember,
      );
    }
    _writeApp(
      appRoot,
      providerBPath: appIsWorkspaceMember
          ? providerBIsWorkspaceMember
                ? '../packages/provider_b'
                : '../../packages/provider_b'
          : '../packages/provider_b',
      providerCPath: appDependsOnProviderC
          ? appIsWorkspaceMember
                ? '../../packages/provider_c'
                : '../packages/provider_c'
          : null,
      greeterPath: appDependsOnGreeter
          ? appIsWorkspaceMember
                ? '../../packages/greeter'
                : '../packages/greeter'
          : null,
      patchworkPath: appDependsOnPatchwork ? patchworkRoot : null,
      workspaceMember: appIsWorkspaceMember,
    );

    return OverlayProjectSandbox._(
      root: root,
      stateRoot: stateRoot,
      appRoot: appRoot,
      greeterRoot: greeterRoot,
      providerBRoot: providerBRoot,
      providerCRoot: providerCRoot,
      patchworkRoot: patchworkRoot,
      appDependsOnProviderC: appDependsOnProviderC,
      appDependsOnGreeter: appDependsOnGreeter,
      appDependsOnPatchwork: appDependsOnPatchwork,
      appIsWorkspaceMember: appIsWorkspaceMember,
      providerBIsWorkspaceMember: providerBIsWorkspaceMember,
      environment: _pubEnvironment(pubCachePath),
    );
  }

  static Future<OverlayProjectSandbox> providerWorkspace() async {
    final root = Directory.systemTemp.createTempSync(
      'patchwork_overlay_workspace_provider_',
    );
    final patchworkRoot = await _patchworkPackageRoot();
    final pubCachePath = _resolvedPubCachePath(patchworkRoot);
    final stateRoot = p.join(root.path, 'workspace');
    final appRoot = p.join(root.path, 'app');
    final greeterRoot = p.join(root.path, 'packages', 'greeter');
    final providerBRoot = p.join(stateRoot, 'packages', 'provider_b');
    final providerCRoot = p.join(root.path, 'packages', 'provider_c');

    _writeGreeterPackage(greeterRoot);
    _writeProviderWorkspaceRoot(stateRoot);
    _writeProviderPackage(
      providerBRoot,
      name: 'provider_b',
      greeterPath: '../../../packages/greeter',
      patchworkPath: patchworkRoot,
      workspaceMember: true,
    );
    _writeProviderPackage(
      providerCRoot,
      name: 'provider_c',
      greeterPath: '../greeter',
      patchworkPath: patchworkRoot,
    );
    _writeApp(
      appRoot,
      providerBPath: '../workspace/packages/provider_b',
      providerCPath: null,
      greeterPath: null,
      patchworkPath: null,
    );

    return OverlayProjectSandbox._(
      root: root,
      stateRoot: stateRoot,
      appRoot: appRoot,
      greeterRoot: greeterRoot,
      providerBRoot: providerBRoot,
      providerCRoot: providerCRoot,
      patchworkRoot: patchworkRoot,
      appDependsOnProviderC: false,
      appDependsOnGreeter: false,
      appDependsOnPatchwork: false,
      appIsWorkspaceMember: false,
      providerBIsWorkspaceMember: true,
      environment: _pubEnvironment(pubCachePath),
    );
  }

  Future<void> pubGet(String root) async {
    await _run(
      'dart',
      ['pub', 'get', '--offline'],
      cwd: root,
      environment: environment,
    );
  }

  void writeResolution() {
    final dartTool = Directory(p.join(stateRoot, '.dart_tool'))
      ..createSync(recursive: true);
    final packageRoots = <String, String>{
      if (appIsWorkspaceMember) 'patchwork_overlay_workspace': stateRoot,
      'patchwork_overlay_app': appRoot,
      'provider_b': providerBRoot,
      if (appDependsOnProviderC) 'provider_c': providerCRoot,
      'greeter': greeterRoot,
      'patchwork': patchworkRoot,
    };
    final hostedPackages = _currentHostedPackageConfigEntries(patchworkRoot);
    final localPackageNames = packageRoots.keys.toSet();

    File(p.join(dartTool.path, 'package_config.json')).writeAsStringSync(
      '${jsonEncode({
        'configVersion': 2,
        'packages': [
          for (final entry in hostedPackages)
            if (!localPackageNames.contains(entry['name'])) entry,
          for (final entry in packageRoots.entries) {'name': entry.key, 'rootUri': entry.key == 'patchwork' ? Directory(entry.value).absolute.uri.toString() : _relativeDirectoryUri(entry.value, from: dartTool.path), 'packageUri': 'lib/'},
        ],
      })}\n',
    );

    File(p.join(dartTool.path, 'package_graph.json')).writeAsStringSync(
      '${jsonEncode({
        'roots': [if (appIsWorkspaceMember) 'patchwork_overlay_workspace', 'patchwork_overlay_app', if (providerBIsWorkspaceMember) 'provider_b'],
        'packages': [
          if (appIsWorkspaceMember) {'name': 'patchwork_overlay_workspace', 'dependencies': <String>[]},
          {
            'name': 'patchwork_overlay_app',
            'dependencies': ['provider_b', if (appDependsOnProviderC) 'provider_c', if (appDependsOnGreeter) 'greeter', if (appDependsOnPatchwork) 'patchwork'],
          },
          {
            'name': 'provider_b',
            'dependencies': ['greeter', 'patchwork'],
          },
          if (appDependsOnProviderC) {
              'name': 'provider_c',
              'dependencies': ['greeter', 'patchwork'],
            },
          {'name': 'greeter', 'dependencies': <String>[]},
          {
            'name': 'patchwork',
            'dependencies': ['crypto', 'hooks', 'path', 'yaml'],
          },
          for (final entry in hostedPackages) {'name': entry['name'], 'dependencies': <String>[]},
        ],
      })}\n',
    );

    File(p.join(stateRoot, 'pubspec.lock')).writeAsStringSync('''
packages:
  greeter:
    dependency: "transitive"
    description:
      path: ${p.relative(greeterRoot, from: stateRoot)}
      relative: true
    source: path
    version: "0.1.0"
  provider_b:
    dependency: "direct main"
    description:
      path: ${p.relative(providerBRoot, from: stateRoot)}
      relative: true
    source: path
    version: "0.1.0"
${appDependsOnProviderC ? '''  provider_c:
    dependency: "direct main"
    description:
      path: ${p.relative(providerCRoot, from: stateRoot)}
      relative: true
    source: path
    version: "0.1.0"
''' : ''}  patchwork:
    dependency: "transitive"
    description:
      path: ${p.relative(patchworkRoot, from: stateRoot)}
      relative: true
    source: path
    version: "0.4.0"
sdks:
  dart: ">=3.12.0 <4.0.0"
''');
  }

  Future<void> patchwork(
    String root,
    List<String> arguments, {
    Set<int> exitCodes = const {0},
    String? stdoutContains,
    String? stderrContains,
  }) async {
    final result = await patchworkResult(root, arguments, exitCodes: exitCodes);
    if (stdoutContains != null) {
      expect(
        result.stdout,
        contains(stdoutContains),
        reason: 'stderr:\n${result.stderr}',
      );
    }
    if (stderrContains != null) {
      expect(
        result.stderr,
        contains(stderrContains),
        reason: 'stdout:\n${result.stdout}',
      );
    }
  }

  Future<CommandResult> patchworkResult(
    String root,
    List<String> arguments, {
    Set<int> exitCodes = const {0},
  }) {
    return _run(
      'dart',
      ['run', 'patchwork', ...arguments],
      cwd: root,
      exitCodes: exitCodes,
      environment: environment,
    );
  }

  Future<void> application(
    String root,
    List<String> arguments, {
    Set<int> exitCodes = const {0},
    String? stdoutContains,
    String? stderrContains,
  }) async {
    final result = await applicationResult(
      root,
      arguments,
      exitCodes: exitCodes,
    );
    if (stdoutContains != null) {
      expect(
        result.stdout,
        contains(stdoutContains),
        reason: 'stderr:\n${result.stderr}',
      );
    }
    if (stderrContains != null) {
      expect(
        result.stderr,
        contains(stderrContains),
        reason: 'stdout:\n${result.stdout}',
      );
    }
  }

  Future<CommandResult> applicationResult(
    String root,
    List<String> arguments, {
    Set<int> exitCodes = const {0},
  }) async {
    final stdoutFile = File(
      p.join(
        this.root.path,
        '.patchwork_stdout_${DateTime.now().microsecondsSinceEpoch}.txt',
      ),
    );
    final stderrFile = File(
      p.join(
        this.root.path,
        '.patchwork_stderr_${DateTime.now().microsecondsSinceEpoch}.txt',
      ),
    );
    final stdout = stdoutFile.openWrite();
    final stderr = stderrFile.openWrite();
    final exitCode = await Application(
      stdout: stdout,
      stderr: stderr,
      workingDirectory: root,
    ).run(arguments);
    await stdout.close();
    await stderr.close();
    final result = CommandResult(
      exitCode: exitCode,
      stdout: stdoutFile.readAsStringSync(),
      stderr: stderrFile.readAsStringSync(),
    );
    if (!exitCodes.contains(result.exitCode)) {
      fail(
        [
          'Application failed in $root',
          '\$ patchwork ${arguments.join(' ')}',
          'exit code: ${result.exitCode}, expected: ${exitCodes.join(', ')}',
          if (result.stdout.isNotEmpty) 'stdout:\n${result.stdout}',
          if (result.stderr.isNotEmpty) 'stderr:\n${result.stderr}',
        ].join('\n'),
      );
    }
    return result;
  }

  Future<CommandResult> runApp({Set<int> exitCodes = const {0}}) {
    return _run(
      'dart',
      ['run', 'bin/app.dart'],
      cwd: appRoot,
      exitCodes: exitCodes,
      environment: environment,
    );
  }

  Future<void> applyOverlays() async {
    final output = BuildOutputBuilder();
    await patchwork_hooks.applyPackageOverlaysFromPackageConfig(
      p.join(stateRoot, '.dart_tool', 'package_config.json'),
      output,
    );
  }

  void writePrefixEdit(String providerRoot, String prefix) {
    _writeGreeterLibrary(
      p.join(
        _editStateRoot(providerRoot),
        '.patchwork',
        'greeter@0.1.0',
        'lib',
      ),
      prefix: prefix,
      punctuation: '!',
    );
  }

  void writePunctuationEdit(String providerRoot, String punctuation) {
    _writeGreeterLibrary(
      p.join(
        _editStateRoot(providerRoot),
        '.patchwork',
        'greeter@0.1.0',
        'lib',
      ),
      prefix: 'Hello',
      punctuation: punctuation,
    );
  }

  String _editStateRoot(String providerRoot) {
    final providerEdit = Directory(
      p.join(providerRoot, '.patchwork', 'greeter@0.1.0'),
    );
    if (providerEdit.existsSync()) {
      return providerRoot;
    }
    final workspaceEdit = Directory(
      p.join(stateRoot, '.patchwork', 'greeter@0.1.0'),
    );
    if (workspaceEdit.existsSync()) {
      return stateRoot;
    }
    return providerRoot;
  }

  Future<void> registerPrefixOverlay(
    String providerRoot,
    String prefix, {
    String reason = 'Test overlay',
  }) async {
    await pubGet(providerRoot);
    await application(providerRoot, ['patch', 'greeter']);
    writePrefixEdit(providerRoot, prefix);
    await application(providerRoot, ['commit', 'greeter']);
    await application(providerRoot, [
      'overlay',
      'add',
      'greeter',
      '--reason',
      reason,
    ]);
  }

  void writePrefixOverlay(
    String providerRoot,
    String prefix, {
    String reason = 'Test overlay',
  }) {
    _writeOverlay(providerRoot, _prefixPatch(prefix), reason: reason);
  }

  void writeRootPrefixPatch(String prefix) {
    final patchPath = p.join(stateRoot, 'patches', 'greeter@0.1.0.patch');
    File(patchPath)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(_prefixPatch(prefix));
  }

  Future<void> registerPunctuationOverlay(
    String providerRoot,
    String punctuation, {
    String reason = 'Test overlay',
  }) async {
    await pubGet(providerRoot);
    await application(providerRoot, ['patch', 'greeter']);
    writePunctuationEdit(providerRoot, punctuation);
    await application(providerRoot, ['commit', 'greeter']);
    await application(providerRoot, [
      'overlay',
      'add',
      'greeter',
      '--reason',
      reason,
    ]);
  }

  void writePunctuationOverlay(
    String providerRoot,
    String punctuation, {
    String reason = 'Test overlay',
  }) {
    _writeOverlay(providerRoot, _punctuationPatch(punctuation), reason: reason);
  }

  void _writeOverlay(
    String providerRoot,
    String patchContent, {
    required String reason,
  }) {
    final patchPath = p.join(providerRoot, 'patches', 'greeter@0.1.0.patch');
    File(patchPath)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(patchContent);
    manifestFor(providerRoot).writeAsStringSync('''
overlays:
  - package: "greeter"
    version: "0.1.0"
    sha256: "${const PackageTree().sha256Of(greeterRoot)}"
    patch: "patches/greeter@0.1.0.patch"
    reason: "$reason"
''');
  }

  void expectGreeterResolvedToAppliedOutput() {
    final packageConfig = File(
      p.join(stateRoot, '.dart_tool', 'package_config.json'),
    );
    final decoded = jsonDecode(packageConfig.readAsStringSync());
    if (decoded is! Map<String, Object?>) {
      fail('package_config.json is malformed.');
    }
    final packages = decoded['packages'];
    if (packages is! List<Object?>) {
      fail('package_config.json does not contain packages.');
    }

    final baseUri = Directory(p.dirname(packageConfig.path)).uri;
    final expected = p.normalize(p.absolute(appliedGreeterDirectory.path));
    for (final entry in packages) {
      if (entry is! Map<String, Object?> || entry['name'] != 'greeter') {
        continue;
      }
      final rootUri = entry['rootUri'];
      if (rootUri is! String) {
        fail('greeter rootUri is missing.');
      }
      final resolved = p.normalize(
        baseUri.resolveUri(Uri.parse(rootUri)).toFilePath(),
      );
      expect(resolved, expected);
      return;
    }
    fail('package_config.json does not contain greeter.');
  }

  void expectGreeterResolvedToSource() {
    final packageConfig = File(
      p.join(stateRoot, '.dart_tool', 'package_config.json'),
    );
    final decoded = jsonDecode(packageConfig.readAsStringSync());
    if (decoded is! Map<String, Object?>) {
      fail('package_config.json is malformed.');
    }
    final packages = decoded['packages'];
    if (packages is! List<Object?>) {
      fail('package_config.json does not contain packages.');
    }

    final baseUri = Directory(p.dirname(packageConfig.path)).uri;
    final expected = p.normalize(p.absolute(greeterRoot));
    for (final entry in packages) {
      if (entry is! Map<String, Object?> || entry['name'] != 'greeter') {
        continue;
      }
      final rootUri = entry['rootUri'];
      if (rootUri is! String) {
        fail('greeter rootUri is missing.');
      }
      final resolved = p.normalize(
        baseUri.resolveUri(Uri.parse(rootUri)).toFilePath(),
      );
      expect(resolved, expected);
      return;
    }
    fail('package_config.json does not contain greeter.');
  }

  File manifestFor(String providerRoot) {
    return File(p.join(providerRoot, 'patchwork.yaml'));
  }

  void dispose() {
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  }
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
  _writeGreeterLibrary(p.join(root, 'lib'), prefix: 'Hello', punctuation: '!');
}

void _writeGreeterLibrary(
  String libRoot, {
  required String prefix,
  required String punctuation,
}) {
  Directory(libRoot).createSync(recursive: true);
  File(p.join(libRoot, 'greeter.dart')).writeAsStringSync('''
String greeting(String name) {
  return '\${prefix()}, \$name\${punctuation()}';
}

String prefix() {
  return ${jsonEncode(prefix)};
}

String punctuation() {
  return ${jsonEncode(punctuation)};
}
''');
}

void _writeProviderPackage(
  String root, {
  required String name,
  required String greeterPath,
  required String patchworkPath,
  bool workspaceMember = false,
}) {
  Directory(p.join(root, 'lib')).createSync(recursive: true);
  File(p.join(root, 'pubspec.yaml')).writeAsStringSync('''
name: $name
version: 0.1.0
publish_to: none

environment:
  sdk: ^3.12.0

${workspaceMember ? 'resolution: workspace\n' : ''}dependencies:
  greeter:
    path: $greeterPath
  patchwork:
    path: $patchworkPath
''');
  File(p.join(root, 'lib', '$name.dart')).writeAsStringSync('''
import 'package:greeter/greeter.dart';

String providerGreeting(String name) {
  return greeting(name);
}
''');
}

void _writeApp(
  String root, {
  required String providerBPath,
  required String? providerCPath,
  required String? greeterPath,
  required String? patchworkPath,
  bool workspaceMember = false,
}) {
  Directory(p.join(root, 'bin')).createSync(recursive: true);
  File(p.join(root, 'pubspec.yaml')).writeAsStringSync('''
name: patchwork_overlay_app
publish_to: none

environment:
  sdk: ^3.12.0

${workspaceMember ? 'resolution: workspace\n' : ''}dependencies:
  provider_b:
    path: $providerBPath
${providerCPath == null ? '' : '  provider_c:\n    path: $providerCPath\n'}${greeterPath == null ? '' : '  greeter:\n    path: $greeterPath\n'}${patchworkPath == null ? '' : 'dev_dependencies:\n  patchwork:\n    path: $patchworkPath\n'}
''');
  File(p.join(root, 'bin', 'app.dart')).writeAsStringSync('''
import 'package:provider_b/provider_b.dart';

void main() {
  print(providerGreeting('Patchwork'));
}
''');
}

void _writeWorkspaceRoot(String root, {bool includeProviderB = false}) {
  Directory(root).createSync(recursive: true);
  File(p.join(root, 'pubspec.yaml')).writeAsStringSync('''
name: patchwork_overlay_workspace
publish_to: none

environment:
  sdk: ^3.12.0

workspace:
  - app
${includeProviderB ? '  - packages/provider_b\n' : ''}
''');
}

void _writeProviderWorkspaceRoot(String root) {
  Directory(root).createSync(recursive: true);
  File(p.join(root, 'pubspec.yaml')).writeAsStringSync('''
name: patchwork_overlay_provider_workspace
publish_to: none

environment:
  sdk: ^3.12.0

workspace:
  - packages/provider_b
''');
}

String _prefixPatch(String prefix) {
  return 'diff --git a/lib/greeter.dart b/lib/greeter.dart\n'
      '--- a/lib/greeter.dart\n'
      '+++ b/lib/greeter.dart\n'
      '@@ -4,7 +4,7 @@ String greeting(String name) {\n'
      ' }\n'
      ' \n'
      ' String prefix() {\n'
      '-  return "Hello";\n'
      '+  return ${jsonEncode(prefix)};\n'
      ' }\n'
      ' \n'
      ' String punctuation() {\n';
}

String _punctuationPatch(String punctuation) {
  return 'diff --git a/lib/greeter.dart b/lib/greeter.dart\n'
      '--- a/lib/greeter.dart\n'
      '+++ b/lib/greeter.dart\n'
      '@@ -8,5 +8,5 @@ String prefix() {\n'
      ' }\n'
      ' \n'
      ' String punctuation() {\n'
      '-  return "!";\n'
      '+  return ${jsonEncode(punctuation)};\n'
      ' }\n';
}

List<Map<String, Object?>> _currentHostedPackageConfigEntries(
  String patchworkRoot,
) {
  final packageConfigPath = _currentPackageConfigPath(patchworkRoot);
  final decoded = jsonDecode(File(packageConfigPath).readAsStringSync());
  if (decoded is! Map<String, Object?>) {
    fail('Current package_config.json is malformed.');
  }
  final packages = decoded['packages'];
  if (packages is! List<Object?>) {
    fail('Current package_config.json does not contain packages.');
  }

  final baseUri = Directory(p.dirname(packageConfigPath)).uri;
  final entries = <Map<String, Object?>>[];
  for (final package in packages) {
    if (package is! Map<String, Object?>) {
      fail('Current package_config.json contains a malformed package entry.');
    }
    final name = package['name'];
    final rootUri = package['rootUri'];
    if (name is! String || rootUri is! String) {
      fail('Current package_config.json contains an incomplete entry.');
    }

    final rootPath = p.normalize(
      baseUri.resolveUri(Uri.parse(rootUri)).toFilePath(),
    );
    if (_hostedPubCachePath(rootPath) == null) {
      continue;
    }
    entries.add({
      'name': name,
      'rootUri': Directory(rootPath).absolute.uri.toString(),
      'packageUri': switch (package['packageUri']) {
        final String packageUri => packageUri,
        _ => 'lib/',
      },
    });
  }
  return entries;
}

String _relativeDirectoryUri(String rootPath, {required String from}) {
  var relative = p.relative(rootPath, from: from);
  if (!relative.endsWith(p.separator)) {
    relative = '$relative${p.separator}';
  }
  return p.toUri(relative).toString();
}

Future<String> _patchworkPackageRoot() async {
  final libraryUri = await Isolate.resolvePackageUri(
    Uri.parse('package:patchwork/patchwork.dart'),
  );
  if (libraryUri == null) {
    fail('Could not resolve package:patchwork.');
  }
  return p.dirname(p.dirname(libraryUri.toFilePath()));
}

String _resolvedPubCachePath(String patchworkRoot) {
  final packageConfigPath = _currentPackageConfigPath(patchworkRoot);
  final decoded = jsonDecode(File(packageConfigPath).readAsStringSync());
  if (decoded is! Map<String, Object?>) {
    fail('Current package_config.json is malformed.');
  }
  final packages = decoded['packages'];
  if (packages is! List<Object?>) {
    fail('Current package_config.json does not contain packages.');
  }

  final baseUri = Directory(p.dirname(packageConfigPath)).uri;
  for (final package in packages) {
    if (package is! Map<String, Object?>) {
      fail('Current package_config.json contains a malformed package entry.');
    }
    final rootUri = package['rootUri'];
    if (rootUri is! String) {
      fail('Current package_config.json package entries are incomplete.');
    }

    final pubCachePath = _hostedPubCachePath(
      p.normalize(baseUri.resolveUri(Uri.parse(rootUri)).toFilePath()),
    );
    if (pubCachePath != null) {
      return pubCachePath;
    }
  }
  fail('Current package_config.json does not contain a hosted package cache.');
}

String _currentPackageConfigPath(String patchworkRoot) {
  final expectedRoot = p.normalize(p.absolute(patchworkRoot));
  var current = expectedRoot;
  while (true) {
    final candidate = p.join(current, '.dart_tool', 'package_config.json');
    if (File(candidate).existsSync() &&
        _packageConfigContainsRoot(candidate, expectedRoot)) {
      return candidate;
    }

    final parent = p.dirname(current);
    if (parent == current) {
      fail('Could not find the current workspace package_config.json.');
    }
    current = parent;
  }
}

bool _packageConfigContainsRoot(String packageConfigPath, String packageRoot) {
  final decoded = jsonDecode(File(packageConfigPath).readAsStringSync());
  if (decoded is! Map<String, Object?>) {
    return false;
  }
  final packages = decoded['packages'];
  if (packages is! List<Object?>) {
    return false;
  }

  final baseUri = Directory(p.dirname(packageConfigPath)).uri;
  final expectedRoot = p.normalize(p.absolute(packageRoot));
  for (final package in packages) {
    if (package is! Map<String, Object?>) {
      continue;
    }
    final rootUri = package['rootUri'];
    if (rootUri is! String) {
      continue;
    }
    final resolved = p.normalize(
      baseUri.resolveUri(Uri.parse(rootUri)).toFilePath(),
    );
    if (p.equals(resolved, expectedRoot)) {
      return true;
    }
  }
  return false;
}

String? _hostedPubCachePath(String sourcePath) {
  final parts = p.split(p.normalize(sourcePath));
  final hostedIndex = parts.lastIndexOf('hosted');
  if (hostedIndex < 0) {
    return null;
  }
  return p.joinAll(parts.take(hostedIndex).toList());
}

Map<String, String> _pubEnvironment(String pubCachePath) {
  return {'PUB_CACHE': pubCachePath};
}

Future<CommandResult> _run(
  String executable,
  List<String> arguments, {
  required String cwd,
  Set<int> exitCodes = const {0},
  Map<String, String>? environment,
}) async {
  final result = await Process.run(
    executable,
    arguments,
    workingDirectory: cwd,
    environment: environment,
  );
  if (!exitCodes.contains(result.exitCode)) {
    fail(
      [
        'Command failed in $cwd',
        '\$ ${[executable, ...arguments].join(' ')}',
        'exit code: ${result.exitCode}, expected: ${exitCodes.join(', ')}',
        if (result.stdout.toString().isNotEmpty) 'stdout:\n${result.stdout}',
        if (result.stderr.toString().isNotEmpty) 'stderr:\n${result.stderr}',
      ].join('\n'),
    );
  }
  return CommandResult(
    exitCode: result.exitCode,
    stdout: result.stdout.toString(),
    stderr: result.stderr.toString(),
  );
}

final class CommandResult {
  const CommandResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
}
