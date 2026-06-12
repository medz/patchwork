import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:patchwork/src/cli/command_runner.dart';
import 'package:patchwork/src/diagnostics/exit_code.dart';
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
