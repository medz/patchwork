import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:patchwork/src/cli/command_runner.dart';
import 'package:test/test.dart';

import '../pub/pub_resolution_fixture.dart';

void main() {
  late PubResolutionFixture fixture;
  late Directory outputRoot;

  setUp(() {
    fixture = PubResolutionFixture.create();
    outputRoot = Directory.systemTemp.createTempSync('patchwork_cli_');
  });

  tearDown(() {
    fixture.dispose();
    if (outputRoot.existsSync()) {
      outputRoot.deleteSync(recursive: true);
    }
  });

  test('patch and commit are separate commands', () async {
    final patchResult = await _run(
      ['patch', 'foo'],
      fixture: fixture,
      outputRoot: outputRoot,
    );
    expect(patchResult.exitCode, 0);
    expect(patchResult.stdout, contains('.patchwork/foo@0.1.0'));

    File(
      p.join(fixture.rootPath, '.patchwork', 'foo@0.1.0', 'lib', 'foo.dart'),
    ).writeAsStringSync("String foo() => 'cli';\n");

    final commitResult = await _run(
      ['commit', 'foo'],
      fixture: fixture,
      outputRoot: outputRoot,
    );
    expect(commitResult.exitCode, 0);
    expect(commitResult.stdout, contains('patches/foo@0.1.0.patch'));
    expect(
      File(p.join(fixture.rootPath, 'patches', 'foo@0.1.0.patch')).existsSync(),
      isTrue,
    );

    final oldCommitResult = await _run(
      ['patch', '--commit', 'foo'],
      fixture: fixture,
      outputRoot: outputRoot,
    );
    expect(oldCommitResult.exitCode, 64);
    expect(oldCommitResult.stderr, contains('Unknown option "--commit"'));
  });

  test('rejects non-plain package targets', () async {
    final result = await _run(
      ['patch', 'foo@0.1.0'],
      fixture: fixture,
      outputRoot: outputRoot,
    );

    expect(result.exitCode, 64);
    expect(result.stderr, contains('Expected a plain package name'));
  });

  test(
    'apply without a package fails when a committed patch file is missing',
    () async {
      await _run(['patch', 'foo'], fixture: fixture, outputRoot: outputRoot);
      File(
        p.join(fixture.rootPath, '.patchwork', 'foo@0.1.0', 'lib', 'foo.dart'),
      ).writeAsStringSync("String foo() => 'cli';\n");
      await _run(['commit', 'foo'], fixture: fixture, outputRoot: outputRoot);
      File(p.join(fixture.rootPath, 'patches', 'foo@0.1.0.patch')).deleteSync();

      final result = await _run(
        ['apply'],
        fixture: fixture,
        outputRoot: outputRoot,
      );

      expect(result.exitCode, 1);
      expect(result.stderr, contains('Committed patch file is missing'));
    },
  );
}

Future<_CommandResult> _run(
  List<String> arguments, {
  required PubResolutionFixture fixture,
  required Directory outputRoot,
}) async {
  final id = DateTime.now().microsecondsSinceEpoch;
  final stdoutFile = File(p.join(outputRoot.path, '$id.stdout.txt'));
  final stderrFile = File(p.join(outputRoot.path, '$id.stderr.txt'));
  final stdout = stdoutFile.openWrite();
  final stderr = stderrFile.openWrite();
  final exitCode = await const PatchworkCommandRunner().run(
    arguments,
    workingDirectory: fixture.appPath,
    stdout: stdout,
    stderr: stderr,
  );
  await stdout.close();
  await stderr.close();
  return _CommandResult(
    exitCode: exitCode,
    stdout: stdoutFile.readAsStringSync(),
    stderr: stderrFile.readAsStringSync(),
  );
}

final class _CommandResult {
  const _CommandResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
}
