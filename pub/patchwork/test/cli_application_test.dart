import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:patchwork/src/cli/application.dart';
import 'package:test/test.dart';

void main() {
  test('unknown commands are reported before pub project discovery', () async {
    final root = Directory.systemTemp.createTempSync('patchwork_cli_');
    addTearDown(() => root.deleteSync(recursive: true));

    final stdoutFile = File(p.join(root.path, 'stdout.txt'));
    final stderrFile = File(p.join(root.path, 'stderr.txt'));
    final stdout = stdoutFile.openWrite();
    final stderr = stderrFile.openWrite();

    final exitCode = await Application(
      stdout: stdout,
      stderr: stderr,
      workingDirectory: root.path,
    ).run(['bogus']);

    await stdout.close();
    await stderr.close();

    expect(exitCode, 64);
    final stderrText = stderrFile.readAsStringSync();
    expect(stderrText, contains('Unknown command "bogus"'));
    expect(stderrText, isNot(contains('pub project')));
  });

  test('help documents JSON output options', () async {
    final root = Directory.systemTemp.createTempSync('patchwork_cli_');
    addTearDown(() => root.deleteSync(recursive: true));

    final generalHelp = await _runApplication(root, ['--help']);
    expect(generalHelp.exitCode, 0);
    expect(generalHelp.stdout, contains('status [--json]'));
    expect(generalHelp.stdout, contains('doctor [--json]'));
    expect(generalHelp.stdout, contains('patch <pkg>'));
    expect(generalHelp.stdout, contains('[--json]'));

    final statusHelp = await _runApplication(root, ['status', '--help']);
    expect(statusHelp.exitCode, 0);
    expect(statusHelp.stdout, contains('Usage: patchwork status [--json]'));
  });
}

Future<_ApplicationResult> _runApplication(
  Directory root,
  List<String> arguments,
) async {
  final stdoutFile = File(p.join(root.path, '${arguments.join('_')}.stdout'));
  final stderrFile = File(p.join(root.path, '${arguments.join('_')}.stderr'));
  final stdout = stdoutFile.openWrite();
  final stderr = stderrFile.openWrite();

  final exitCode = await Application(
    stdout: stdout,
    stderr: stderr,
    workingDirectory: root.path,
  ).run(arguments);

  await stdout.close();
  await stderr.close();

  return _ApplicationResult(
    exitCode: exitCode,
    stdout: stdoutFile.readAsStringSync(),
    stderr: stderrFile.readAsStringSync(),
  );
}

final class _ApplicationResult {
  const _ApplicationResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
}
