import 'dart:io' as io;

import '../../error.dart';
import '../../model.dart';
import '../../patchwork.dart';
import '../arguments.dart';
import '../output.dart';
import '../pub_get.dart';

/// Runs `patchwork remove`.
///
/// The command removes artifacts for one package/version. Open edits and
/// applied state require `--force` because they can discard local work or change
/// active pub overrides.
Future<int> runRemoveCommand(
  Patchwork patchwork,
  List<String> arguments,
  io.IOSink out,
  String workingDirectory,
) async {
  final parsed = parseCommandArguments('remove', arguments);
  final pubGetOptions = parsePubGetOption('remove', parsed.rest);
  final options = parseCleanupOptions('remove', pubGetOptions.rest);
  final operands = _removeOperands(options.rest);
  final result = await patchwork.remove(
    operands.package,
    version: operands.version,
    dryRun: options.dryRun,
    force: options.force,
  );
  final needsPubGet = _cleanupNeedsPubGet(result);
  final pubGetRan = pubGetOptions.pubGet && needsPubGet;
  if (pubGetRan) {
    await runPubGet(workingDirectory);
  }

  if (parsed.json) {
    printCleanupJson(
      patchwork,
      result,
      out,
      pubGetRan: pubGetRan,
      needsPubGet: needsPubGet && !pubGetRan,
    );
    return 0;
  }
  printCleanup(
    patchwork,
    result,
    out,
    pubGetRan: pubGetRan,
    needsPubGet: needsPubGet && !pubGetRan,
  );
  return 0;
}

({String package, String? version}) _removeOperands(List<String> arguments) {
  for (final argument in arguments) {
    if (argument.startsWith('-')) {
      throw unknownOption(argument, 'remove');
    }
  }
  if (arguments.isEmpty) {
    throw PatchworkException(
      'Expected a package name.',
      code: 'usage.missing_package',
      hint: 'Run patchwork remove --help.',
    );
  }
  if (arguments.length > 2) {
    throw PatchworkException(
      'Too many arguments for "remove".',
      code: 'usage.too_many_arguments',
      hint: 'Run patchwork remove --help.',
    );
  }
  return (
    package: arguments[0],
    version: arguments.length == 2 ? arguments[1] : null,
  );
}

bool _cleanupNeedsPubGet(CleanupResult result) {
  return !result.dryRun &&
      result.changes.any(
        (change) =>
            change.kind == CleanupChangeKind.appliedDirectory ||
            change.kind == CleanupChangeKind.pubspecOverride,
      );
}
