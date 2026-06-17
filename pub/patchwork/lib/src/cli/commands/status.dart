import 'dart:io' as io;

import '../../patchwork.dart';
import '../arguments.dart';
import '../output.dart';

/// Runs `patchwork status`.
Future<int> runStatusCommand(
  Patchwork patchwork,
  List<String> arguments,
  io.IOSink out,
) async {
  expectNoArguments('status', arguments);
  printStatus(patchwork, await patchwork.inspect(), out);
  return 0;
}
