import 'dart:io' as io;

import '../../patchwork.dart';
import '../arguments.dart';
import '../output.dart';

Future<int> runApplyCommand(
  Patchwork patchwork,
  List<String> arguments,
  io.IOSink out,
) async {
  final package = singlePackage('apply', arguments, required: false);
  final packages = package == null
      ? (await patchwork.inspect()).packages
            .where((status) => status.hasCommittedPatch)
            .map((status) => status.package)
      : [package];

  if (packages.isEmpty) {
    out.writeln('No committed patches.');
    return 0;
  }

  for (final package in packages) {
    final applied = await patchwork.applyPatch(package);
    out.writeln(
      'Applied ${relativePath(patchwork, applied.patchPath)} to '
      '${relativePath(patchwork, applied.path)}.',
    );
  }
  out.writeln('Run dart pub get.');
  return 0;
}
