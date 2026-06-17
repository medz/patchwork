import 'dart:io' as io;

import '../../patchwork.dart';
import '../arguments.dart';

/// Runs `patchwork apply`.
Future<int> runApplyCommand(
  Patchwork patchwork,
  List<String> arguments,
  io.IOSink out,
) async {
  final package = singlePackage('apply', arguments, required: false);
  final applied = package == null
      ? await patchwork.applyAll()
      : [await patchwork.apply(package)];

  if (applied.isEmpty) {
    out.writeln('No patches need apply.');
    return 0;
  }

  for (final patch in applied) {
    out.writeln(
      'Applied ${patchwork.relativePath(patch.patchPath)} to '
      '${patchwork.relativePath(patch.path)}.',
    );
  }
  out.writeln('Run dart pub get.');
  return 0;
}
