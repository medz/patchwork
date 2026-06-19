import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

final class OverlayProjectSandbox {
  OverlayProjectSandbox._({
    required this.root,
    required this.appRoot,
    required this.greeterRoot,
    required this.providerBRoot,
    required this.providerCRoot,
    required this.environment,
  });

  final Directory root;
  final String appRoot;
  final String greeterRoot;
  final String providerBRoot;
  final String providerCRoot;
  final Map<String, String> environment;

  Directory get appliedGreeterDirectory {
    return Directory(
      p.join(appRoot, '.dart_tool', 'patchwork', 'greeter@0.1.0'),
    );
  }

  static Future<OverlayProjectSandbox> create({
    bool appDependsOnProviderC = false,
    bool appDependsOnGreeter = false,
    bool appDependsOnPatchwork = false,
  }) async {
    final root = Directory.systemTemp.createTempSync('patchwork_overlay_');
    final patchworkRoot = await _patchworkPackageRoot();
    final pubCachePath = _resolvedPubCachePath(patchworkRoot);
    final greeterRoot = p.join(root.path, 'packages', 'greeter');
    final providerBRoot = p.join(root.path, 'packages', 'provider_b');
    final providerCRoot = p.join(root.path, 'packages', 'provider_c');
    final appRoot = p.join(root.path, 'app');

    _writeGreeterPackage(greeterRoot);
    _writeProviderPackage(
      providerBRoot,
      name: 'provider_b',
      greeterPath: '../greeter',
      patchworkPath: patchworkRoot,
    );
    _writeProviderPackage(
      providerCRoot,
      name: 'provider_c',
      greeterPath: '../greeter',
      patchworkPath: patchworkRoot,
    );
    _writeApp(
      appRoot,
      providerBPath: '../packages/provider_b',
      providerCPath: appDependsOnProviderC ? '../packages/provider_c' : null,
      greeterPath: appDependsOnGreeter ? '../packages/greeter' : null,
      patchworkPath: appDependsOnPatchwork ? patchworkRoot : null,
    );

    return OverlayProjectSandbox._(
      root: root,
      appRoot: appRoot,
      greeterRoot: greeterRoot,
      providerBRoot: providerBRoot,
      providerCRoot: providerCRoot,
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

  Future<CommandResult> runApp({Set<int> exitCodes = const {0}}) {
    return _run(
      'dart',
      ['run', 'bin/app.dart'],
      cwd: appRoot,
      exitCodes: exitCodes,
      environment: environment,
    );
  }

  void writePrefixEdit(String providerRoot, String prefix) {
    _writeGreeterLibrary(
      p.join(providerRoot, '.patchwork', 'greeter@0.1.0', 'lib'),
      prefix: prefix,
      punctuation: '!',
    );
  }

  void writePunctuationEdit(String providerRoot, String punctuation) {
    _writeGreeterLibrary(
      p.join(providerRoot, '.patchwork', 'greeter@0.1.0', 'lib'),
      prefix: 'Hello',
      punctuation: punctuation,
    );
  }

  Future<void> registerPrefixOverlay(
    String providerRoot,
    String prefix, {
    String reason = 'Test overlay',
  }) async {
    await pubGet(providerRoot);
    await patchwork(providerRoot, ['patch', 'greeter']);
    writePrefixEdit(providerRoot, prefix);
    await patchwork(providerRoot, ['commit', 'greeter']);
    await patchwork(providerRoot, ['overlay', 'greeter', '--reason', reason]);
  }

  Future<void> registerPunctuationOverlay(
    String providerRoot,
    String punctuation, {
    String reason = 'Test overlay',
  }) async {
    await pubGet(providerRoot);
    await patchwork(providerRoot, ['patch', 'greeter']);
    writePunctuationEdit(providerRoot, punctuation);
    await patchwork(providerRoot, ['commit', 'greeter']);
    await patchwork(providerRoot, ['overlay', 'greeter', '--reason', reason]);
  }

  void expectGreeterResolvedToAppliedOutput() {
    final packageConfig = File(
      p.join(appRoot, '.dart_tool', 'package_config.json'),
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
  return '$prefix';
}

String punctuation() {
  return '$punctuation';
}
''');
}

void _writeProviderPackage(
  String root, {
  required String name,
  required String greeterPath,
  required String patchworkPath,
}) {
  Directory(p.join(root, 'lib')).createSync(recursive: true);
  File(p.join(root, 'pubspec.yaml')).writeAsStringSync('''
name: $name
version: 0.1.0
publish_to: none

environment:
  sdk: ^3.12.0

dependencies:
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
}) {
  Directory(p.join(root, 'bin')).createSync(recursive: true);
  File(p.join(root, 'pubspec.yaml')).writeAsStringSync('''
name: patchwork_overlay_app
publish_to: none

environment:
  sdk: ^3.12.0

dependencies:
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
