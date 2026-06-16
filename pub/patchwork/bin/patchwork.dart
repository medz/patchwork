import 'dart:io';

import 'package:patchwork/src/cli/command_runner.dart';

Future<void> main(List<String> arguments) async {
  exitCode = await const PatchworkCommandRunner().run(
    arguments,
    stdout: stdout,
    stderr: stderr,
  );
}
