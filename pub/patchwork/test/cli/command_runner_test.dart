import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:patchwork/src/cli/command_runner.dart';
import 'package:patchwork/src/diagnostics/exit_code.dart';
import 'package:patchwork/src/store/patchwork_manifest.dart';
import 'package:test/test.dart';

import '../pub/pub_resolution_fixture.dart';

void main() {
  group('PatchworkCommandRunner', () {
    const runner = PatchworkCommandRunner();

    test('prints a useful top-level help overview', () {
      final stdout = StringBuffer();
      final stderr = StringBuffer();

      final exitCode = runner.run(['--help'], stdout: stdout, stderr: stderr);

      expect(exitCode, PatchworkExitCode.success);
      expect(stderr.toString(), isEmpty);
      expect(stdout.toString(), contains('Usage: patchwork <command>'));
      expect(stdout.toString(), contains('patch <target>'));
      expect(stdout.toString(), contains('doctor'));
    });

    test('creates a pub patch edit session', () {
      final fixture = PubResolutionFixture.create();
      addTearDown(fixture.dispose);
      final stdout = StringBuffer();
      final stderr = StringBuffer();

      final exitCode = runner.run(
        ['patch', 'analyzer@7.4.0'],
        stdout: stdout,
        stderr: stderr,
        currentDirectory: fixture.rootPath,
      );

      expect(exitCode, PatchworkExitCode.success);
      expect(stderr.toString(), isEmpty);
      final editPath = p.join(
        fixture.rootPath,
        '.dart_tool',
        'patchwork',
        'edit',
        'pub',
        'analyzer@7.4.0',
      );
      expect(
        stdout.toString(),
        'Edit directory: $editPath\n'
        "Commit changes with: patchwork patch --commit '$editPath'\n",
      );
      expect(Directory(editPath).existsSync(), isTrue);
    });

    test('commits a pub patch edit session', () {
      final fixture = PubResolutionFixture.create();
      addTearDown(fixture.dispose);
      final startStdout = StringBuffer();
      final startStderr = StringBuffer();
      final startExitCode = runner.run(
        ['patch', 'analyzer'],
        stdout: startStdout,
        stderr: startStderr,
        currentDirectory: fixture.rootPath,
      );
      expect(startExitCode, PatchworkExitCode.success);
      final editFile = File(
        p.join(
          fixture.rootPath,
          '.dart_tool',
          'patchwork',
          'edit',
          'pub',
          'analyzer@7.4.0',
          'lib',
          'analyzer.dart',
        ),
      );
      editFile.writeAsStringSync("String analyzerVersion() => '7.4.1';\n");
      final stdout = StringBuffer();
      final stderr = StringBuffer();

      final exitCode = runner.run(
        ['patch', '--commit', 'analyzer'],
        stdout: stdout,
        stderr: stderr,
        currentDirectory: fixture.rootPath,
      );

      expect(exitCode, PatchworkExitCode.success);
      expect(stderr.toString(), isEmpty);
      expect(
        stdout.toString(),
        'Patch file: ${p.join('patches', 'pub', 'analyzer@7.4.0.patch')}\n',
      );
      expect(
        File(
          p.join(fixture.rootPath, 'patches', 'pub', 'analyzer@7.4.0.patch'),
        ).existsSync(),
        isTrue,
      );
    });

    test('applies committed pub patches', () {
      final fixture = PubResolutionFixture.create();
      addTearDown(fixture.dispose);
      final startExitCode = runner.run(
        ['patch', 'analyzer'],
        stdout: StringBuffer(),
        stderr: StringBuffer(),
        currentDirectory: fixture.rootPath,
      );
      expect(startExitCode, PatchworkExitCode.success);
      final editFile = File(
        p.join(
          fixture.rootPath,
          '.dart_tool',
          'patchwork',
          'edit',
          'pub',
          'analyzer@7.4.0',
          'lib',
          'analyzer.dart',
        ),
      );
      editFile.writeAsStringSync("String analyzerVersion() => '7.4.1';\n");
      final commitExitCode = runner.run(
        ['patch', '--commit', 'analyzer'],
        stdout: StringBuffer(),
        stderr: StringBuffer(),
        currentDirectory: fixture.rootPath,
      );
      expect(commitExitCode, PatchworkExitCode.success);
      final stdout = StringBuffer();
      final stderr = StringBuffer();

      final exitCode = runner.run(
        ['apply'],
        stdout: stdout,
        stderr: stderr,
        currentDirectory: fixture.rootPath,
      );

      expect(exitCode, PatchworkExitCode.success);
      expect(stderr.toString(), isEmpty);
      expect(stdout.toString(), contains('Applied pub:analyzer@7.4.0:'));
      expect(
        File(p.join(fixture.rootPath, 'pubspec_overrides.yaml')).existsSync(),
        isTrue,
      );
    });

    test('reports clean status after applying pub patches', () {
      final fixture = PubResolutionFixture.create();
      addTearDown(fixture.dispose);
      _commitAnalyzerPatch(runner, fixture, version: '7.4.1');
      final applyExitCode = runner.run(
        ['apply'],
        stdout: StringBuffer(),
        stderr: StringBuffer(),
        currentDirectory: fixture.rootPath,
      );
      expect(applyExitCode, PatchworkExitCode.success);
      final stdout = StringBuffer();
      final stderr = StringBuffer();

      final exitCode = runner.run(
        ['status'],
        stdout: stdout,
        stderr: stderr,
        currentDirectory: fixture.rootPath,
      );

      expect(exitCode, PatchworkExitCode.success);
      expect(stderr.toString(), isEmpty);
      expect(stdout.toString(), contains('Workspace: ${fixture.rootPath}'));
      expect(stdout.toString(), contains('pub:analyzer@7.4.0 [clean]'));
      expect(stdout.toString(), contains('patch:'));
      expect(stdout.toString(), contains('(hash ok)'));
      expect(stdout.toString(), contains('store:'));
      expect(stdout.toString(), contains('(current)'));
      expect(stdout.toString(), contains('override: analyzer ->'));
    });

    test('reports unapplied status before generated overrides exist', () {
      final fixture = PubResolutionFixture.create();
      addTearDown(fixture.dispose);
      _commitAnalyzerPatch(runner, fixture, version: '7.4.1');
      final stdout = StringBuffer();
      final stderr = StringBuffer();

      final exitCode = runner.run(
        ['status'],
        stdout: stdout,
        stderr: stderr,
        currentDirectory: fixture.rootPath,
      );

      expect(exitCode, PatchworkExitCode.failure);
      expect(stderr.toString(), isEmpty);
      expect(stdout.toString(), contains('pub:analyzer@7.4.0 [unapplied]'));
      expect(stdout.toString(), contains('store:'));
      expect(stdout.toString(), contains('(missing or stale)'));
      expect(stdout.toString(), contains('override: analyzer -> missing'));
    });

    test('reports stale status when a patch file hash changes', () {
      final fixture = PubResolutionFixture.create();
      addTearDown(fixture.dispose);
      _commitAnalyzerPatch(runner, fixture, version: '7.4.1');
      File(
        p.join(fixture.rootPath, 'patches', 'pub', 'analyzer@7.4.0.patch'),
      ).writeAsStringSync('stale patch\n');
      final stdout = StringBuffer();
      final stderr = StringBuffer();

      final exitCode = runner.run(
        ['status'],
        stdout: stdout,
        stderr: stderr,
        currentDirectory: fixture.rootPath,
      );

      expect(exitCode, PatchworkExitCode.failure);
      expect(stderr.toString(), isEmpty);
      expect(stdout.toString(), contains('pub:analyzer@7.4.0 [stale]'));
      expect(stdout.toString(), contains('(hash mismatch)'));
    });

    test('reports malformed overrides when reading status', () {
      final fixture = PubResolutionFixture.create();
      addTearDown(fixture.dispose);
      File(
        p.join(fixture.rootPath, 'pubspec_overrides.yaml'),
      ).writeAsStringSync('dependency_overrides: [');
      final stdout = StringBuffer();
      final stderr = StringBuffer();

      final exitCode = runner.run(
        ['status'],
        stdout: stdout,
        stderr: stderr,
        currentDirectory: fixture.rootPath,
      );

      expect(exitCode, PatchworkExitCode.failure);
      expect(stdout.toString(), isEmpty);
      expect(
        stderr.toString(),
        contains('pubspec_overrides.yaml is malformed'),
      );
    });

    test('reports stale managed overrides without manifest entries', () {
      final fixture = PubResolutionFixture.create();
      addTearDown(fixture.dispose);
      File(
        p.join(fixture.rootPath, 'pubspec_overrides.yaml'),
      ).writeAsStringSync('''
dependency_overrides:
  analyzer:
    path: .dart_tool/patchwork/store/pub/analyzer@7.4.0_patch_hash=aaaaaaaa
''');
      final stdout = StringBuffer();
      final stderr = StringBuffer();

      final exitCode = runner.run(
        ['status'],
        stdout: stdout,
        stderr: stderr,
        currentDirectory: fixture.rootPath,
      );

      expect(exitCode, PatchworkExitCode.failure);
      expect(stderr.toString(), isEmpty);
      expect(stdout.toString(), contains('Patches: none'));
      expect(stdout.toString(), contains('Stale overrides:'));
      expect(stdout.toString(), contains('analyzer ->'));
      expect(stdout.toString(), contains('[stale]'));
    });

    test('reports missing status when a patch file is gone', () {
      final fixture = PubResolutionFixture.create();
      addTearDown(fixture.dispose);
      _commitAnalyzerPatch(runner, fixture, version: '7.4.1');
      File(
        p.join(fixture.rootPath, 'patches', 'pub', 'analyzer@7.4.0.patch'),
      ).deleteSync();
      final stdout = StringBuffer();
      final stderr = StringBuffer();

      final exitCode = runner.run(
        ['status'],
        stdout: stdout,
        stderr: stderr,
        currentDirectory: fixture.rootPath,
      );

      expect(exitCode, PatchworkExitCode.failure);
      expect(stderr.toString(), isEmpty);
      expect(stdout.toString(), contains('pub:analyzer@7.4.0 [missing]'));
      expect(stdout.toString(), contains('patch:'));
      expect(stdout.toString(), contains('(missing)'));
    });

    test('reports root package manifest entries as broken status', () {
      final fixture = PubResolutionFixture.create();
      addTearDown(fixture.dispose);
      _writeRootPatchManifest(fixture);
      final stdout = StringBuffer();
      final stderr = StringBuffer();

      final exitCode = runner.run(
        ['status'],
        stdout: stdout,
        stderr: stderr,
        currentDirectory: fixture.rootPath,
      );

      expect(exitCode, PatchworkExitCode.failure);
      expect(stderr.toString(), isEmpty);
      expect(stdout.toString(), contains('pub:app@0.0.0 [broken]'));
      expect(stdout.toString(), contains('Cannot patch the current package'));
    });

    test('reports doctor checks for a ready pub workspace', () {
      final fixture = PubResolutionFixture.create();
      addTearDown(fixture.dispose);
      final stdout = StringBuffer();
      final stderr = StringBuffer();

      final exitCode = runner.run(
        ['doctor'],
        stdout: stdout,
        stderr: stderr,
        currentDirectory: fixture.rootPath,
      );

      expect(exitCode, PatchworkExitCode.success);
      expect(stderr.toString(), isEmpty);
      expect(stdout.toString(), contains('Doctor:'));
      expect(stdout.toString(), contains('[ok] dart executable:'));
      expect(stdout.toString(), contains('[ok] workspace:'));
      expect(stdout.toString(), contains('[ok] package config:'));
      expect(stdout.toString(), contains('[ok] pub resolution metadata:'));
      expect(stdout.toString(), contains('[ok] write access:'));
    });

    test('reports malformed lockfiles in doctor checks', () {
      final fixture = PubResolutionFixture.create();
      addTearDown(fixture.dispose);
      fixture.overwriteLockfile('packages: [');
      final stdout = StringBuffer();
      final stderr = StringBuffer();

      final exitCode = runner.run(
        ['doctor'],
        stdout: stdout,
        stderr: stderr,
        currentDirectory: fixture.rootPath,
      );

      expect(exitCode, PatchworkExitCode.failure);
      expect(stderr.toString(), isEmpty);
      expect(
        stdout.toString(),
        contains('[error] pub resolution metadata: Malformed pubspec.lock'),
      );
    });

    test('reports doctor failures outside a pub workspace', () {
      final root = Directory.systemTemp.createTempSync('patchwork doctor ');
      addTearDown(() {
        if (root.existsSync()) {
          root.deleteSync(recursive: true);
        }
      });
      final stdout = StringBuffer();
      final stderr = StringBuffer();

      final exitCode = runner.run(
        ['doctor'],
        stdout: stdout,
        stderr: stderr,
        currentDirectory: root.path,
      );

      expect(exitCode, PatchworkExitCode.failure);
      expect(stderr.toString(), isEmpty);
      expect(stdout.toString(), contains('[ok] dart executable:'));
      expect(stdout.toString(), contains('[error] workspace:'));
      expect(stdout.toString(), contains('Run dart pub get'));
    });

    test('prints a clean no-op when committing an unchanged edit session', () {
      final fixture = PubResolutionFixture.create();
      addTearDown(fixture.dispose);
      final startExitCode = runner.run(
        ['patch', 'analyzer'],
        stdout: StringBuffer(),
        stderr: StringBuffer(),
        currentDirectory: fixture.rootPath,
      );
      expect(startExitCode, PatchworkExitCode.success);
      final stdout = StringBuffer();
      final stderr = StringBuffer();

      final exitCode = runner.run(
        ['patch', '--commit', 'analyzer'],
        stdout: stdout,
        stderr: stderr,
        currentDirectory: fixture.rootPath,
      );

      expect(exitCode, PatchworkExitCode.success);
      expect(stderr.toString(), isEmpty);
      expect(stdout.toString(), 'No changes to commit.\n');
    });

    test('maps session creation failures to failure exit code', () {
      final fixture = PubResolutionFixture.create();
      addTearDown(fixture.dispose);
      File(
        p.join(fixture.rootPath, '.dart_tool', 'patchwork'),
      ).writeAsStringSync('not a directory');
      final stdout = StringBuffer();
      final stderr = StringBuffer();

      final exitCode = runner.run(
        ['patch', 'analyzer@7.4.0'],
        stdout: stdout,
        stderr: stderr,
        currentDirectory: fixture.rootPath,
      );

      expect(exitCode, PatchworkExitCode.failure);
      expect(stdout.toString(), isEmpty);
      expect(
        stderr.toString(),
        contains('Could not create pub patch edit session'),
      );
    });

    test('maps usage errors to usage exit code', () {
      final stdout = StringBuffer();
      final stderr = StringBuffer();

      final exitCode = runner.run(['unknown'], stdout: stdout, stderr: stderr);

      expect(exitCode, PatchworkExitCode.usage);
      expect(stdout.toString(), isEmpty);
      expect(stderr.toString(), contains('error: Unknown command "unknown".'));
    });

    test('maps unsupported targets to failure exit code', () {
      final stdout = StringBuffer();
      final stderr = StringBuffer();

      final exitCode = runner.run(
        ['patch', 'sdk:flutter'],
        stdout: stdout,
        stderr: stderr,
      );

      expect(exitCode, PatchworkExitCode.failure);
      expect(stdout.toString(), isEmpty);
      expect(stderr.toString(), contains('Target kind "sdk" is not supported'));
    });
  });
}

void _commitAnalyzerPatch(
  PatchworkCommandRunner runner,
  PubResolutionFixture fixture, {
  required String version,
}) {
  final startExitCode = runner.run(
    ['patch', 'analyzer'],
    stdout: StringBuffer(),
    stderr: StringBuffer(),
    currentDirectory: fixture.rootPath,
  );
  expect(startExitCode, PatchworkExitCode.success);
  final editFile = File(
    p.join(
      fixture.rootPath,
      '.dart_tool',
      'patchwork',
      'edit',
      'pub',
      'analyzer@7.4.0',
      'lib',
      'analyzer.dart',
    ),
  );
  editFile.writeAsStringSync("String analyzerVersion() => '$version';\n");
  final commitExitCode = runner.run(
    ['patch', '--commit', 'analyzer'],
    stdout: StringBuffer(),
    stderr: StringBuffer(),
    currentDirectory: fixture.rootPath,
  );
  expect(commitExitCode, PatchworkExitCode.success);
}

void _writeRootPatchManifest(PubResolutionFixture fixture) {
  final patchFile = File(
    p.join(fixture.rootPath, 'patches', 'pub', 'app@0.0.0.patch'),
  );
  patchFile.parent.createSync(recursive: true);
  patchFile.writeAsStringSync(
    'not applied because root targets are rejected\n',
  );

  const manifestStore = PatchworkManifestStore();
  manifestStore.upsertPatch(
    workspaceRootPath: fixture.rootPath,
    entry: PatchworkManifestPatch(
      target: 'pub:app@0.0.0',
      path: 'patches/pub/app@0.0.0.patch',
      hash: manifestStore.hashFile(patchFile.path),
    ),
  );
}
