import 'package:patchwork/src/cli/command_runner.dart';
import 'package:patchwork/src/diagnostics/exit_code.dart';
import 'package:test/test.dart';

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

    test('prints parsed command intent for supported skeleton commands', () {
      final stdout = StringBuffer();
      final stderr = StringBuffer();

      final exitCode = runner.run(
        ['patch', 'analyzer@7.4.0'],
        stdout: stdout,
        stderr: stderr,
      );

      expect(exitCode, PatchworkExitCode.success);
      expect(stderr.toString(), isEmpty);
      expect(
        stdout.toString(),
        contains('Parsed command: patch pub:analyzer@7.4.0'),
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
