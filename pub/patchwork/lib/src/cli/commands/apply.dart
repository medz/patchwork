import 'dart:io' as io;

import '../../patchwork.dart';
import '../arguments.dart';
import '../output.dart';

/// Runs `patchwork apply`.
///
/// Without a package operand this applies every committed patch that currently
/// needs generated output. When at least one patch is applied, the command also
/// reminds the user to run `dart pub get` so pub sees the generated overrides.
Future<int> runApplyCommand(
  Patchwork patchwork,
  List<String> arguments,
  io.IOSink out,
) async {
  final parsed = parseCommandArguments('apply', arguments);
  final package = singlePackage('apply', parsed.rest, required: false);
  final applied = package == null
      ? await patchwork.applyAll()
      : [await patchwork.apply(package)];

  if (parsed.json) {
    printApplyJson(patchwork, applied, out);
    return 0;
  }

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
