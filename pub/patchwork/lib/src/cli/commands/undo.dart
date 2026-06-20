import 'dart:io' as io;

import '../../patchwork.dart';
import '../arguments.dart';
import '../output.dart';
import '../pub_get.dart';

/// Runs `patchwork undo`.
///
/// Undo removes Patchwork-generated output and matching override state for one
/// package. By default it also refreshes pub resolution so the ordinary pub
/// dependency is effective immediately.
Future<int> runUndoCommand(
  Patchwork patchwork,
  List<String> arguments,
  io.IOSink out,
  String workingDirectory,
) async {
  final parsed = parseCommandArguments('undo', arguments);
  final options = parsePubGetOption('undo', parsed.rest);
  final package = singlePackage('undo', options.rest, required: true)!;
  final result = await patchwork.undo(package);
  final needsPubGet = result.changed;
  final pubGetRan = options.pubGet && needsPubGet;
  if (pubGetRan) {
    await runPubGet(workingDirectory);
  }
  if (parsed.json) {
    printUndoJson(
      patchwork,
      result,
      out,
      pubGetRan: pubGetRan,
      needsPubGet: needsPubGet && !pubGetRan,
    );
    return 0;
  }

  if (!result.changed) {
    out.writeln('No applied patch for $package.');
    return 0;
  }

  out.writeln('Unapplied $package.');
  if (pubGetRan) {
    out.writeln('Ran dart pub get.');
  } else if (needsPubGet) {
    out.writeln('Run dart pub get.');
  }
  return 0;
}
