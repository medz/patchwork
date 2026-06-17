import 'dart:io' as io;

import '../../error.dart';
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
      ? await _applyAllPackages(patchwork)
      : [package];

  if (packages.isEmpty) {
    out.writeln('No patches need apply.');
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

Future<List<String>> _applyAllPackages(Patchwork patchwork) async {
  final state = await patchwork.inspect();
  final blockedOpenEdit = state.packages
      .where((status) => status.hasCommittedPatch && status.hasOpenEdit)
      .toList();
  if (blockedOpenEdit.isNotEmpty) {
    final package = blockedOpenEdit.first;
    throw PatchworkException(
      'Package "${package.package}" has an open edit directory.',
      code: 'apply.open_edit',
      hint: 'Run patchwork commit ${package.package} before applying.',
      location: package.editPath,
    );
  }
  return state.needsApply.map((status) => status.package).toList();
}
