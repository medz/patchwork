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
}
