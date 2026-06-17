import 'dart:io' as io;

import '../../patchwork.dart';
import '../arguments.dart';

/// Runs `patchwork undo`.
///
/// Undo removes Patchwork-generated output and matching override state for one
/// package. When state is removed, the command reminds the user to refresh pub
/// resolution with `dart pub get`.
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
