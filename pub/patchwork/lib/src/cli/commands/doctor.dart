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
  final parsed = parseCommandArguments('doctor', arguments);
  final options = _parseDoctorOptions(parsed.rest);
  expectNoArguments('doctor', options.rest);
  final state = await patchwork.inspect();
  if (parsed.json) {
    printStatusJson(patchwork, state, out, explain: options.explain);
  } else {
    printStatus(patchwork, state, out, explain: options.explain);
  }
  return state.problems.isEmpty && state.needsApply.isEmpty ? 0 : 1;
}

({bool explain, List<String> rest}) _parseDoctorOptions(
  List<String> arguments,
) {
  var explain = false;
  final rest = <String>[];
  for (final argument in arguments) {
    if (argument == '--explain') {
      if (explain) {
        throw duplicateOption('--explain');
      }
      explain = true;
      continue;
    }
    if (argument.startsWith('--explain=')) {
      throw unknownOption(argument, 'doctor');
    }
    rest.add(argument);
  }
  return (explain: explain, rest: List.unmodifiable(rest));
}
