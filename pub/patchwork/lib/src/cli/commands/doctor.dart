import 'dart:io' as io;

import '../../patchwork.dart';
import '../arguments.dart';
import '../output.dart';

/// Runs `patchwork doctor`.
///
/// The output is the same status report used by `patchwork status`, but the exit
/// code is non-zero when Patchwork finds problems or patches that still need to
/// be applied.
Future<int> runDoctorCommand(
  Patchwork patchwork,
  List<String> arguments,
  io.IOSink out,
) async {
  expectNoArguments('doctor', arguments);
  final state = await patchwork.inspect();
  printStatus(patchwork, state, out);
  return state.problems.isEmpty && state.needsApply.isEmpty ? 0 : 1;
}
