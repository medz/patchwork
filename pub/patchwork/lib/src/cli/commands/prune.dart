import 'dart:io' as io;

import '../../cleanup/model.dart';
import '../../patchwork.dart';
import '../arguments.dart';
import '../json.dart';
import '../output.dart';
import '../pub_get.dart';

/// Runs `patchwork prune`.
///
/// Prune scans existing Patchwork artifacts and removes stale patch files plus
/// unreferenced generated output that Patchwork can prove it owns.
Future<int> runPruneCommand(
  Patchwork patchwork,
  List<String> arguments,
  io.IOSink out,
  String workingDirectory,
) async {
  final parsed = parseCommandArguments('prune', arguments);
  final pubGetOptions = parsePubGetOption('prune', parsed.rest);
  final options = parseCleanupOptions('prune', pubGetOptions.rest);
  expectNoArguments('prune', options.rest);
  final result = patchwork.prune(dryRun: options.dryRun, force: options.force);
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

bool _cleanupNeedsPubGet(CleanupResult result) {
  return !result.dryRun &&
      result.changes.any(
        (change) =>
            change.kind == CleanupChangeKind.appliedDirectory ||
            change.kind == CleanupChangeKind.pubspecOverride,
      );
}
