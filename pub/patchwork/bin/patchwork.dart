import 'dart:io';

import 'package:patchwork/src/cli/command_runner.dart';

void main(List<String> arguments) {
  exitCode = const PatchworkCommandRunner().run(
    arguments,
    stdout: stdout,
    stderr: stderr,
  );
}
