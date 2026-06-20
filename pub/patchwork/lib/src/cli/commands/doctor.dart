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
  if (options.setup) {
    final report = await patchwork.inspectSetup();
    if (parsed.json) {
      printSetupJson(patchwork, report, out);
    } else {
      printSetup(patchwork, report, out);
    }
    return report.hasWarnings ? 1 : 0;
  }

  final state = await patchwork.inspect();
  if (parsed.json) {
    printStatusJson(patchwork, state, out, explain: options.explain);
  } else {
    printStatus(patchwork, state, out, explain: options.explain);
  }
  return state.problems.isEmpty && state.needsApply.isEmpty ? 0 : 1;
}

({bool explain, bool setup, List<String> rest}) _parseDoctorOptions(
  List<String> arguments,
) {
  var explain = false;
  var setup = false;
  final rest = <String>[];
  for (final argument in arguments) {
    if (argument == '--explain') {
      if (explain) {
        throw duplicateOption('--explain');
      }
      explain = true;
      continue;
    }
    if (argument == '--setup') {
      if (setup) {
        throw duplicateOption('--setup');
      }
      setup = true;
      continue;
    }
    if (argument.startsWith('--explain=')) {
      throw unknownOption(argument, 'doctor');
    }
    if (argument.startsWith('--setup=')) {
      throw unknownOption(argument, 'doctor');
    }
    rest.add(argument);
  }
  return (explain: explain, setup: setup, rest: List.unmodifiable(rest));
}
