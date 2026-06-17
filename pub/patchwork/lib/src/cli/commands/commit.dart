import 'dart:io' as io;

import '../../model.dart';
import '../../patchwork.dart';
import '../arguments.dart';

Future<int> runCommitCommand(
  Patchwork patchwork,
  List<String> arguments,
  io.IOSink out,
) async {
  final package = singlePackage('commit', arguments, required: false);
  final writes = package == null
      ? await patchwork.commitAll()
      : [await patchwork.commit(package)];

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
      out.writeln('Wrote ${patchwork.relativePath(write.patchPath)}.');
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
