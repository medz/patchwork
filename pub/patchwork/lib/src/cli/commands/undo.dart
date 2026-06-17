import 'dart:io' as io;

import '../../patchwork.dart';
import '../arguments.dart';

Future<int> runUndoCommand(
  Patchwork patchwork,
  List<String> arguments,
  io.IOSink out,
) async {
  final package = singlePackage('undo', arguments, required: true)!;
  final result = await patchwork.undo(package);
  if (!result.changed) {
    out.writeln('No applied patch for $package.');
    return 0;
  }

  out.writeln('Unapplied $package.');
  out.writeln('Run dart pub get.');
  return 0;
}
