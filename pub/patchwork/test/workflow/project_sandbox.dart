import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

final class ProjectSandbox {
  ProjectSandbox._({
    required this.root,
    required this.stateRoot,
    required this.commandRoot,
    required this.appRoot,
    required this.greeterRoot,
    required this.manualOverrideRoot,
    required this.otherOverrideRoot,
    required this.environment,
  });

  final Directory root;
  final String stateRoot;
  final String commandRoot;
  final String appRoot;
  final String greeterRoot;
  final String manualOverrideRoot;
  final String? otherOverrideRoot;
  final Map<String, String> environment;

  File get editFile => editFileFor('0.1.0');

  File editFileFor(String version) {
    return File(
      p.join(
        stateRoot,
        '.patchwork',
        'greeter@$version',
        'lib',
        'greeter.dart',
      ),
    );
  }

  Directory editDirectoryFor(String version) {
    return Directory(p.join(stateRoot, '.patchwork', 'greeter@$version'));
  }

  File get lockfile => File(p.join(stateRoot, 'patchwork.lock'));

  File get overrideFile => File(p.join(stateRoot, 'pubspec_overrides.yaml'));

  Directory get appliedDirectory {
    return Directory(
      p.join(stateRoot, '.dart_tool', 'patchwork', 'greeter@0.1.0'),
    );
  }

  static Future<ProjectSandbox> standalone({
    bool includeOtherDependency = false,
  }) async {
    final root = Directory.systemTemp.createTempSync('patchwork_standalone_');
    final patchworkRoot = await _patchworkPackageRoot();
    final pubCachePath = _resolvedPubCachePath(patchworkRoot);
    final appRoot = p.join(root.path, 'app');
    final dependencyRoot = p.join(root.path, 'packages', 'greeter');
    final manualRoot = p.join(root.path, 'manual_greeter');
    final otherRoot = includeOtherDependency
        ? p.join(root.path, 'packages', 'other_pkg')
        : null;
    final otherOverrideRoot = includeOtherDependency
        ? p.join(root.path, 'manual_other_pkg')
        : null;

    _writeGreeterPackage(dependencyRoot, 'Hello, \$name!');
    _writeGreeterPackage(manualRoot, 'Hello from a manual override, \$name!');
    if (otherRoot != null && otherOverrideRoot != null) {
      _writeOtherPackage(otherRoot);
      _writeOtherPackage(otherOverrideRoot);
    }
    _writeApp(
      appRoot,
      greeterPath: '../packages/greeter',
      otherPath: includeOtherDependency ? '../packages/other_pkg' : null,
    );
    _writePatchworkDevDependency(appRoot, patchworkPath: patchworkRoot);

    return ProjectSandbox._(
      root: root,
      stateRoot: appRoot,
      commandRoot: appRoot,
      appRoot: appRoot,
      greeterRoot: dependencyRoot,
      manualOverrideRoot: manualRoot,
      otherOverrideRoot: otherOverrideRoot,
      environment: _pubEnvironment(pubCachePath),
    );
  }

  static Future<ProjectSandbox> workspace({
    bool includeOtherDependency = false,
  }) async {
    final root = Directory.systemTemp.createTempSync('patchwork_workspace_');
    final patchworkRoot = await _patchworkPackageRoot();
    final pubCachePath = _resolvedPubCachePath(patchworkRoot);
    final workspaceRoot = p.join(root.path, 'workspace');
    final appRoot = p.join(workspaceRoot, 'app');
    final dependencyRoot = p.join(root.path, 'deps', 'greeter');
    final manualRoot = p.join(root.path, 'manual_greeter');
    final otherRoot = includeOtherDependency
        ? p.join(root.path, 'deps', 'other_pkg')
        : null;
    final otherOverrideRoot = includeOtherDependency
        ? p.join(root.path, 'manual_other_pkg')
        : null;
    final memberRoot = p.join(workspaceRoot, 'packages', 'member_greeter');

    _writeGreeterPackage(dependencyRoot, 'Hello, \$name!');
    _writeGreeterPackage(manualRoot, 'Hello from a manual override, \$name!');
    if (otherRoot != null && otherOverrideRoot != null) {
      _writeOtherPackage(otherRoot);
      _writeOtherPackage(otherOverrideRoot);
    }
    _writeWorkspaceMember(memberRoot);
    _writeWorkspaceRoot(workspaceRoot, patchworkPath: patchworkRoot);
    _writeApp(
      appRoot,
      greeterPath: '../../deps/greeter',
      otherPath: includeOtherDependency ? '../../deps/other_pkg' : null,
      workspaceMember: true,
    );

    return ProjectSandbox._(
      root: root,
      stateRoot: workspaceRoot,
      commandRoot: appRoot,
      appRoot: appRoot,
      greeterRoot: dependencyRoot,
      manualOverrideRoot: manualRoot,
      otherOverrideRoot: otherOverrideRoot,
      environment: _pubEnvironment(pubCachePath),
    );
  }

  static Future<ProjectSandbox> gitDependency() async {
    final root = Directory.systemTemp.createTempSync('patchwork_git_');
    final patchworkRoot = await _patchworkPackageRoot();
    final pubCachePath = _resolvedPubCachePath(patchworkRoot);
    final appRoot = p.join(root.path, 'app');
    final repoRoot = p.join(root.path, 'greeter_repo');
    final manualRoot = p.join(root.path, 'manual_greeter');

    _writeGreeterPackage(repoRoot, 'Hello, \$name!');
    _writeGreeterPackage(manualRoot, 'Hello from a manual override, \$name!');
    await _run('git', ['init', '-b', 'main'], cwd: repoRoot);
    await _run('git', ['add', '.'], cwd: repoRoot);
    await _run(
      'git',
      ['commit', '-m', 'initial greeter'],
      cwd: repoRoot,
      environment: _gitEnvironment,
    );
    _writeGitApp(
      appRoot,
      greeterGitUrl: Directory(repoRoot).absolute.uri.toString(),
    );
    _writePatchworkDevDependency(appRoot, patchworkPath: patchworkRoot);

    return ProjectSandbox._(
      root: root,
      stateRoot: appRoot,
      commandRoot: appRoot,
      appRoot: appRoot,
      greeterRoot: repoRoot,
      manualOverrideRoot: manualRoot,
      otherOverrideRoot: null,
      environment: _pubEnvironment(pubCachePath),
    );
  }

  Future<void> pubGet() async {
    await _run(
      'dart',
      ['pub', 'get', '--offline'],
      cwd: commandRoot,
      environment: environment,
    );
  }

  Future<void> patchwork(
    List<String> arguments, {
    Set<int> exitCodes = const {0},
    String? stdoutContains,
    String? stderrContains,
  }) async {
    final result = await _run(
      'dart',
      ['run', 'patchwork', ...arguments],
      cwd: commandRoot,
      exitCodes: exitCodes,
      environment: environment,
    );
    if (stdoutContains != null) {
      expect(result.stdout, contains(stdoutContains));
    }
    if (stderrContains != null) {
      expect(result.stderr, contains(stderrContains));
    }
  }

  Future<void> runApp(String expectedOutput) async {
    final result = await _run(
      'dart',
      ['run', 'bin/app.dart'],
      cwd: appRoot,
      environment: environment,
    );
    expect(result.stdout, contains(expectedOutput));
  }

  void expectPackageResolvedTo(String package, String rootPath) {
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
    final expected = p.normalize(p.absolute(rootPath));
    for (final entry in packages) {
      if (entry is! Map<String, Object?>) {
        continue;
      }
      if (entry['name'] != package) {
        continue;
      }
      final rootUri = entry['rootUri'];
      if (rootUri is! String) {
        fail('package_config entry for $package has no rootUri.');
      }
      expect(_resolveRootUri(baseUri, rootUri), expected);
      return;
    }
    fail('package_config.json does not contain $package.');
  }

  void writeEdit(String greetingPrefix) {
    editFile.writeAsStringSync('''
String greeting(String name) {
  return '$greetingPrefix, \$name!';
}
''');
  }

  void updateGreeterPackage({
    required String version,
    required String greeting,
  }) {
    _writeGreeterPackage(greeterRoot, greeting, version: version);
  }

  void writeManualOverride() {
    overrideFile.writeAsStringSync('''
dependency_overrides:
  greeter:
    path: ${p.relative(manualOverrideRoot, from: stateRoot)}
''');
  }

  void writeOtherOverride() {
    final otherRoot = otherOverrideRoot;
    if (otherRoot == null) {
      fail('ProjectSandbox was not created with other_pkg.');
    }
    overrideFile.writeAsStringSync('''
dependency_overrides:
  other_pkg:
    path: ${p.relative(otherRoot, from: stateRoot)}
''');
  }

  void writeManualAndOtherOverrides() {
    final otherRoot = otherOverrideRoot;
    if (otherRoot == null) {
      fail('ProjectSandbox was not created with other_pkg.');
    }
    overrideFile.writeAsStringSync('''
dependency_overrides:
  greeter:
    path: ${p.relative(manualOverrideRoot, from: stateRoot)}
  other_pkg:
    path: ${p.relative(otherRoot, from: stateRoot)}
''');
  }

  void dispose() {
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  }
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
    final name = package['name'];
    final rootUri = package['rootUri'];
    if (name is! String || rootUri is! String) {
      fail('Current package_config.json package entries are incomplete.');
    }

    final pubCachePath = _hostedPubCachePath(_resolveRootUri(baseUri, rootUri));
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
    if (p.equals(_resolveRootUri(baseUri, rootUri), expectedRoot)) {
      return true;
    }
  }
  return false;
}

String _resolveRootUri(Uri baseUri, String rootUri) {
  final uri = Uri.parse(rootUri);
  final resolved = uri.hasScheme ? uri : baseUri.resolveUri(uri);
  return p.normalize(resolved.toFilePath());
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

void _writeWorkspaceRoot(String root, {required String patchworkPath}) {
  Directory(root).createSync(recursive: true);
  File(p.join(root, 'pubspec.yaml')).writeAsStringSync('''
name: patchwork_test_workspace
publish_to: none

environment:
  sdk: ^3.12.0

workspace:
  - app
  - packages/member_greeter

dev_dependencies:
  patchwork:
    path: $patchworkPath
''');
}

void _writeApp(
  String root, {
  required String greeterPath,
  String? otherPath,
  bool workspaceMember = false,
}) {
  Directory(p.join(root, 'bin')).createSync(recursive: true);
  File(p.join(root, 'pubspec.yaml')).writeAsStringSync('''
name: patchwork_test_app
publish_to: none

environment:
  sdk: ^3.12.0

${workspaceMember ? 'resolution: workspace\n' : ''}dependencies:
  greeter:
    path: $greeterPath
${otherPath == null ? '' : '  other_pkg:\n    path: $otherPath\n'}${workspaceMember ? '  member_greeter: ^0.1.0\n' : ''}
''');
  File(p.join(root, 'bin', 'app.dart')).writeAsStringSync('''
import 'package:greeter/greeter.dart';

void main() {
  print(greeting('Patchwork'));
}
''');
}

void _writeGitApp(
  String root, {
  required String greeterGitUrl,
  String? otherPath,
}) {
  Directory(p.join(root, 'bin')).createSync(recursive: true);
  File(p.join(root, 'pubspec.yaml')).writeAsStringSync('''
name: patchwork_test_app
publish_to: none

environment:
  sdk: ^3.12.0

dependencies:
  greeter:
    git:
      url: $greeterGitUrl
      ref: main
${otherPath == null ? '' : '  other_pkg:\n    path: $otherPath\n'}
''');
  File(p.join(root, 'bin', 'app.dart')).writeAsStringSync('''
import 'package:greeter/greeter.dart';

void main() {
  print(greeting('Patchwork'));
}
''');
}

void _writePatchworkDevDependency(
  String root, {
  required String patchworkPath,
}) {
  File(p.join(root, 'pubspec.yaml')).writeAsStringSync('''
${File(p.join(root, 'pubspec.yaml')).readAsStringSync()}
dev_dependencies:
  patchwork:
    path: $patchworkPath
''');
}

void _writeGreeterPackage(
  String root,
  String greeting, {
  String version = '0.1.0',
}) {
  Directory(p.join(root, 'lib')).createSync(recursive: true);
  File(p.join(root, 'pubspec.yaml')).writeAsStringSync('''
name: greeter
version: $version
publish_to: none

environment:
  sdk: ^3.12.0
''');
  File(p.join(root, 'lib', 'greeter.dart')).writeAsStringSync('''
String greeting(String name) {
  return '$greeting';
}
''');
}

void _writeOtherPackage(String root) {
  Directory(p.join(root, 'lib')).createSync(recursive: true);
  File(p.join(root, 'pubspec.yaml')).writeAsStringSync('''
name: other_pkg
version: 0.1.0
publish_to: none

environment:
  sdk: ^3.12.0
''');
  File(p.join(root, 'lib', 'other_pkg.dart')).writeAsStringSync('''
String otherName() {
  return 'other_pkg';
}
''');
}

void _writeWorkspaceMember(String root) {
  Directory(p.join(root, 'lib')).createSync(recursive: true);
  File(p.join(root, 'pubspec.yaml')).writeAsStringSync('''
name: member_greeter
version: 0.1.0
publish_to: none

environment:
  sdk: ^3.12.0

resolution: workspace
''');
  File(p.join(root, 'lib', 'member_greeter.dart')).writeAsStringSync('''
String memberGreeting(String name) {
  return 'Hello from member, \$name!';
}
''');
}

Future<_RunResult> _run(
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
  return _RunResult(
    stdout: result.stdout.toString(),
    stderr: result.stderr.toString(),
  );
}

const _gitEnvironment = {
  'GIT_AUTHOR_NAME': 'Patchwork Test',
  'GIT_AUTHOR_EMAIL': 'patchwork@example.invalid',
  'GIT_COMMITTER_NAME': 'Patchwork Test',
  'GIT_COMMITTER_EMAIL': 'patchwork@example.invalid',
};

final class _RunResult {
  const _RunResult({required this.stdout, required this.stderr});

  final String stdout;
  final String stderr;
}
