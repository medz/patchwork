import 'dart:io' as io;

import '../../error.dart';
import '../../apply/model.dart';
import '../../patchwork.dart';
import '../arguments.dart';
import '../json.dart';
import '../path.dart';
import '../pub_get.dart';

/// Runs `patchwork apply`.
///
/// Without a package operand this applies every committed patch that currently
/// needs generated output. By default the command also refreshes pub resolution
/// so the generated overrides are effective immediately.
Future<int> runApplyCommand(
  Patchwork patchwork,
  List<String> arguments,
  io.IOSink out,
  String workingDirectory,
) async {
  final parsed = parseCommandArguments('apply', arguments);
  final options = parsePubGetOption('apply', parsed.rest);
  final package = singlePackage('apply', options.rest, required: false);
  final applied = package == null
      ? patchwork.applyAll()
      : _applyPackage(patchwork, package);
  final needsPubGet = applied.isNotEmpty || _pubGetRequired(patchwork, package);
  final pubGetRan = options.pubGet && needsPubGet;
  if (pubGetRan) {
    await runPubGet(workingDirectory);
  }

  if (parsed.json) {
    printApplyJson(
      patchwork,
      applied,
      out,
      pubGetRan: pubGetRan,
      needsPubGet: needsPubGet && !pubGetRan,
    );
    return 0;
  }

  if (applied.isEmpty && !pubGetRan) {
    out.writeln('No patches need apply.');
  }

  for (final patch in applied) {
    out.writeln(
      'Applied ${patchwork.displayPath(patch.patchPath)} to '
      '${patchwork.displayPath(patch.path)}.',
    );
  }
  if (pubGetRan) {
    out.writeln('Ran dart pub get.');
  } else if (needsPubGet) {
    out.writeln('Run dart pub get.');
  }
  return 0;
}

List<AppliedPatch> _applyPackage(Patchwork patchwork, String package) {
  try {
    return [patchwork.apply(package)];
  } on PatchworkException catch (error) {
    if (error.code == 'applied.pub_get_required') {
      return const [];
    }
    rethrow;
  }
}

bool _pubGetRequired(Patchwork patchwork, String? package) {
  final state = patchwork.inspect();
  for (final status in state.packages) {
    if (package != null && status.package != package) {
      continue;
    }
    if (status.problems.any(
      (problem) => problem.code == 'applied.pub_get_required',
    )) {
      return true;
    }
  }
  return false;
}
