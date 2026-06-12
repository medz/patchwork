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
