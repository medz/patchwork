import 'dart:io' as io;

import '../../edit/model.dart';
import '../../patchwork.dart';
import '../arguments.dart';
import '../json.dart';
import '../path.dart';

/// Runs `patchwork commit`.
///
/// With no package operand, all open edit directories are committed in the
/// order returned by [Patchwork.commitAll]. Each result is rendered according
/// to whether a patch file was written, left unchanged, or removed.
int runCommitCommand(
  Patchwork patchwork,
  List<String> arguments,
  io.IOSink out,
) {
  final parsed = parseCommandArguments('commit', arguments);
  final package = singlePackage('commit', parsed.rest, required: false);
  final writes = package == null
      ? patchwork.commitAll()
      : [patchwork.commit(package)];

  if (parsed.json) {
    printCommitJson(patchwork, writes, out);
    return 0;
  }

  if (writes.isEmpty) {
    out.writeln('No open edits.');
    return 0;
  }

  for (final write in writes) {
    _printPatchWrite(patchwork, write, out);
  }
  return 0;
}

void _printPatchWrite(Patchwork patchwork, PatchWrite write, io.IOSink out) {
  switch (write.status) {
    case PatchWriteStatus.written:
      out.writeln('Wrote ${patchwork.displayPath(write.patchPath)}.');
    case PatchWriteStatus.unchanged:
      out.writeln(
        '${write.package}@${write.version} patch is already current; '
        'removed edit directory.',
      );
    case PatchWriteStatus.removed:
      out.writeln(
        '${write.package}@${write.version} has no changes; '
        'removed patch record.',
      );
  }
}
