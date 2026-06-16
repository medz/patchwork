import 'dart:io' as io;

import '../../patchwork.dart';
import '../arguments.dart';
import '../output.dart';

Future<int> runDoctorCommand(
  Patchwork patchwork,
  List<String> arguments,
  io.IOSink out,
) async {
  expectNoArguments('doctor', arguments);
  final state = await patchwork.inspect();
  printStatus(patchwork, state, out);
  return state.problems.isEmpty ? 0 : 1;
}
