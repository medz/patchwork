import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('real Dart projects', () {
    test(
      'standalone project patch workflow',
      () async {
        final fixture = await _RealProject.standalone();
        addTearDown(fixture.dispose);

        await fixture.pubGet();
        await fixture.patchwork(['doctor'], stdoutContains: 'No patchwork');
        await fixture.patchwork(['patch', 'greeter']);
        fixture.writeEdit("Hello from a standalone patch");
        await fixture.patchwork(['commit', 'greeter']);
        await fixture.patchwork(['apply']);
        await fixture.patchwork(
          ['doctor'],
          exitCodes: {1},
          stdoutContains: 'pub resolution has not activated',
        );
        await fixture.pubGet();
        await fixture.patchwork([
          'doctor',
        ], stdoutContains: 'applied: .dart_tool/patchwork/greeter@0.1.0');
        await fixture.runApp('Hello from a standalone patch, Patchwork!');

        await fixture.patchwork(['undo', 'greeter']);
        await fixture.pubGet();
        await fixture.patchwork(
          ['doctor'],
          exitCodes: {1},
          stdoutContains: 'action: patchwork apply greeter',
        );
        await fixture.runApp('Hello, Patchwork!');

        await fixture.patchwork(['patch', 'greeter', '--continue']);
        expect(
          fixture.editFile.readAsStringSync(),
          contains('Hello from a standalone patch'),
        );
        await fixture.patchwork(['commit', 'greeter']);

        fixture.writeManualOverride();
        await fixture.patchwork(
          ['apply', 'greeter'],
          exitCodes: {1},
          stderrContains: 'already has a dependency override',
        );
        expect(
          fixture.overrideFile.readAsStringSync(),
          contains('manual_greeter'),
        );
        expect(fixture.appliedDirectory.existsSync(), isFalse);
        fixture.overrideFile.deleteSync();
        await fixture.pubGet();

        await fixture.patchwork(['patch', 'greeter']);
        fixture.editFile.writeAsStringSync('dirty edit\n');
        await fixture.patchwork(['patch', 'greeter'], exitCodes: {1});
        await fixture.patchwork(['patch', 'greeter', '--force']);
        expect(fixture.editFile.readAsStringSync(), contains('Hello, \$name!'));
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    test(
      'workspace member project patch workflow and target boundaries',
      () async {
        final fixture = await _RealProject.workspace();
        addTearDown(fixture.dispose);

        await fixture.pubGet();
        await fixture.patchwork(['doctor'], stdoutContains: 'No patchwork');
        await fixture.patchwork(['patch', 'member_greeter'], exitCodes: {1});
        await fixture.patchwork(
          ['patch', 'patchwork'],
          exitCodes: {1},
          stderrContains: 'not a direct dependency',
        );

        await fixture.patchwork(['patch', 'greeter']);
        fixture.writeEdit("Hello from a workspace patch");
        await fixture.patchwork(['commit', 'greeter']);
        await fixture.patchwork(['apply']);
        await fixture.pubGet();
        await fixture.patchwork([
          'status',
        ], stdoutContains: 'applied: .dart_tool/patchwork/greeter@0.1.0');
        await fixture.runApp('Hello from a workspace patch, Patchwork!');

        await fixture.patchwork(['undo', 'greeter']);
        await fixture.pubGet();
        await fixture.runApp('Hello, Patchwork!');

        await fixture.patchwork(['patch', 'greeter', '--continue']);
        expect(
          fixture.editFile.readAsStringSync(),
          contains('Hello from a workspace patch'),
        );
        await fixture.patchwork(['commit', 'greeter']);

        fixture.writeManualOverride();
        await fixture.pubGet();
        await fixture.patchwork(
          ['apply', 'greeter'],
          exitCodes: {1},
          stderrContains: 'source does not match patchwork.lock',
        );
        expect(
          fixture.overrideFile.readAsStringSync(),
          contains('manual_greeter'),
        );
        expect(fixture.appliedDirectory.existsSync(), isFalse);
        fixture.overrideFile.deleteSync();
        await fixture.pubGet();

        await fixture.patchwork(['patch', 'greeter']);
        fixture.editFile.writeAsStringSync('dirty edit\n');
        await fixture.patchwork(['patch', 'greeter'], exitCodes: {1});
        await fixture.patchwork(['patch', 'greeter', '--force']);
        expect(fixture.editFile.readAsStringSync(), contains('Hello, \$name!'));
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  });
}

final class _RealProject {
  _RealProject({
    required this.root,
    required this.stateRoot,
    required this.commandRoot,
    required this.appRoot,
  });

  final Directory root;
  final String stateRoot;
  final String commandRoot;
  final String appRoot;

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

  static Future<_RealProject> standalone() async {
    final root = Directory.systemTemp.createTempSync('patchwork_standalone_');
    final appRoot = p.join(root.path, 'app');
    final dependencyRoot = p.join(root.path, 'packages', 'greeter');
    final manualRoot = p.join(root.path, 'manual_greeter');
    _writeGreeterPackage(dependencyRoot, 'Hello, \$name!');
    _writeGreeterPackage(manualRoot, 'Hello from a manual override, \$name!');
    _writeApp(appRoot, patchworkRelativePath: _patchworkPath());
    return _RealProject(
      root: root,
      stateRoot: appRoot,
      commandRoot: appRoot,
      appRoot: appRoot,
    );
  }

  static Future<_RealProject> workspace() async {
    final root = Directory.systemTemp.createTempSync('patchwork_workspace_');
    final workspaceRoot = p.join(root.path, 'workspace');
    final appRoot = p.join(workspaceRoot, 'app');
    final dependencyRoot = p.join(root.path, 'deps', 'greeter');
    final manualRoot = p.join(root.path, 'manual_greeter');
    final memberRoot = p.join(workspaceRoot, 'packages', 'member_greeter');
    _writeGreeterPackage(dependencyRoot, 'Hello, \$name!');
    _writeGreeterPackage(manualRoot, 'Hello from a manual override, \$name!');
    _writeMemberPackage(memberRoot);
    _writeWorkspace(workspaceRoot);
    _writeApp(
      appRoot,
      patchworkRelativePath: _patchworkPath(),
      workspace: true,
    );
    return _RealProject(
      root: root,
      stateRoot: workspaceRoot,
      commandRoot: appRoot,
      appRoot: appRoot,
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
    path: ../manual_greeter
''');
  }

  void dispose() {
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  }
}

void _writeWorkspace(String workspaceRoot) {
  Directory(workspaceRoot).createSync(recursive: true);
  File(p.join(workspaceRoot, 'pubspec.yaml')).writeAsStringSync('''
name: patchwork_test_workspace
publish_to: none

environment:
  sdk: ^3.12.0

workspace:
  - app
  - packages/member_greeter

dev_dependencies:
  patchwork:
    path: ${_patchworkPath()}
''');
}

void _writeApp(
  String appRoot, {
  required String patchworkRelativePath,
  bool workspace = false,
}) {
  Directory(p.join(appRoot, 'bin')).createSync(recursive: true);
  File(p.join(appRoot, 'pubspec.yaml')).writeAsStringSync('''
name: patchwork_test_app
publish_to: none

environment:
  sdk: ^3.12.0

${workspace ? 'resolution: workspace\n' : ''}
dependencies:
  greeter:
    path: ${workspace ? '../../deps/greeter' : '../packages/greeter'}
${workspace ? '  member_greeter: ^0.1.0\n' : ''}
${workspace ? '' : '''
dev_dependencies:
  patchwork:
    path: $patchworkRelativePath
'''}''');
  File(p.join(appRoot, 'bin', 'app.dart')).writeAsStringSync('''
import 'package:greeter/greeter.dart';

void main() {
  print(greeting('Patchwork'));
}
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

void _writeMemberPackage(String root) {
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

String _patchworkPath() {
  return p.normalize(p.absolute(p.join('..', '..', 'pub', 'patchwork')));
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
