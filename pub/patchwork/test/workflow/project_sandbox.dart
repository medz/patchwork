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
    required this.manualOverrideRoot,
  });

  final Directory root;
  final String stateRoot;
  final String commandRoot;
  final String appRoot;
  final String manualOverrideRoot;

  File get editFile {
    return File(
      p.join(stateRoot, '.patchwork', 'greeter@0.1.0', 'lib', 'greeter.dart'),
    );
  }

  File get overrideFile => File(p.join(stateRoot, 'pubspec_overrides.yaml'));

  Directory get appliedDirectory {
    return Directory(
      p.join(stateRoot, '.dart_tool', 'patchwork', 'greeter@0.1.0'),
    );
  }

  static Future<ProjectSandbox> standalone() async {
    final root = Directory.systemTemp.createTempSync('patchwork_standalone_');
    final patchworkRoot = await _patchworkPackageRoot();
    final appRoot = p.join(root.path, 'app');
    final dependencyRoot = p.join(root.path, 'packages', 'greeter');
    final manualRoot = p.join(root.path, 'manual_greeter');

    _writeGreeterPackage(dependencyRoot, 'Hello, \$name!');
    _writeGreeterPackage(manualRoot, 'Hello from a manual override, \$name!');
    _writeApp(appRoot, greeterPath: '../packages/greeter');
    _writePatchworkDevDependency(appRoot, patchworkPath: patchworkRoot);

    return ProjectSandbox._(
      root: root,
      stateRoot: appRoot,
      commandRoot: appRoot,
      appRoot: appRoot,
      manualOverrideRoot: manualRoot,
    );
  }

  static Future<ProjectSandbox> workspace() async {
    final root = Directory.systemTemp.createTempSync('patchwork_workspace_');
    final patchworkRoot = await _patchworkPackageRoot();
    final workspaceRoot = p.join(root.path, 'workspace');
    final appRoot = p.join(workspaceRoot, 'app');
    final dependencyRoot = p.join(root.path, 'deps', 'greeter');
    final manualRoot = p.join(root.path, 'manual_greeter');
    final memberRoot = p.join(workspaceRoot, 'packages', 'member_greeter');

    _writeGreeterPackage(dependencyRoot, 'Hello, \$name!');
    _writeGreeterPackage(manualRoot, 'Hello from a manual override, \$name!');
    _writeWorkspaceMember(memberRoot);
    _writeWorkspaceRoot(workspaceRoot, patchworkPath: patchworkRoot);
    _writeApp(
      appRoot,
      greeterPath: '../../deps/greeter',
      workspaceMember: true,
    );

    return ProjectSandbox._(
      root: root,
      stateRoot: workspaceRoot,
      commandRoot: appRoot,
      appRoot: appRoot,
      manualOverrideRoot: manualRoot,
    );
  }

  Future<void> pubGet() async {
    await _run('dart', ['pub', 'get'], cwd: commandRoot);
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
    );
    if (stdoutContains != null) {
      expect(result.stdout, contains(stdoutContains));
    }
    if (stderrContains != null) {
      expect(result.stderr, contains(stderrContains));
    }
  }

  Future<void> runApp(String expectedOutput) async {
    final result = await _run('dart', ['run', 'bin/app.dart'], cwd: appRoot);
    expect(result.stdout, contains(expectedOutput));
  }

  void writeEdit(String greetingPrefix) {
    editFile.writeAsStringSync('''
String greeting(String name) {
  return '$greetingPrefix, \$name!';
}
''');
  }

  void writeManualOverride() {
    overrideFile.writeAsStringSync('''
dependency_overrides:
  greeter:
    path: ${p.relative(manualOverrideRoot, from: stateRoot)}
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
${workspaceMember ? '  member_greeter: ^0.1.0\n' : ''}
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

void _writeGreeterPackage(String root, String greeting) {
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
  return '$greeting';
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
}) async {
  final result = await Process.run(
    executable,
    arguments,
    workingDirectory: cwd,
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

final class _RunResult {
  const _RunResult({required this.stdout, required this.stderr});

  final String stdout;
  final String stderr;
}
