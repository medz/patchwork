import 'dart:io' as io;

import '../../patchwork.dart';
import '../arguments.dart';
import '../output.dart';

/// Runs `patchwork status`.
///
/// Status is read-only. It reports open edits, committed patches, generated
/// output, and any problems Patchwork can infer from the current project state.
Future<int> runStatusCommand(
  Patchwork patchwork,
  List<String> arguments,
  io.IOSink out,
) async {
  final parsed = parseCommandArguments('status', arguments);
  expectNoArguments('status', parsed.rest);
  final state = await patchwork.inspect();
  if (parsed.json) {
    printStatusJson(patchwork, state, out);
  } else {
    printStatus(patchwork, state, out);
  }
  return 0;
}
