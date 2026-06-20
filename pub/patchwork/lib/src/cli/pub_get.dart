import 'dart:io' as io;

import '../error.dart';

/// Runs `dart pub get` from [workingDirectory].
Future<void> runPubGet(String workingDirectory) async {
  final result = await io.Process.run(io.Platform.resolvedExecutable, [
    'pub',
    'get',
  ], workingDirectory: workingDirectory);
  if (result.exitCode == 0) {
    return;
  }

  final stdout = '${result.stdout}'.trim();
  final stderr = '${result.stderr}'.trim();
  final details = [
    if (stdout.isNotEmpty) stdout,
    if (stderr.isNotEmpty) stderr,
  ].join('\n');
  throw PatchworkException(
    'dart pub get failed.',
    code: 'pub.get_failed',
    hint: details.isEmpty ? null : details,
  );
}
