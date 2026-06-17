import 'dart:io' as io;

import '../error.dart';
import '../model.dart';
import '../patchwork.dart';

void printError(io.IOSink err, PatchworkException error) {
  err.writeln('error: ${error.message}');
  if (error.hint != null && error.hint!.isNotEmpty) {
    err.writeln(error.hint);
  }
  if (error.location != null && error.location!.isNotEmpty) {
    err.writeln(error.location);
  }
}

void printStatus(Patchwork patchwork, PatchworkState state, io.IOSink out) {
  if (state.packages.isEmpty) {
    out.writeln('No patchwork packages.');
    return;
  }

  for (final package in state.packages) {
    out.writeln('${package.package}@${package.version}');
    if (package.hasOpenEdit) {
      out.writeln('  edit: ${patchwork.relativePath(package.editPath)}');
    }
    if (package.hasPatch) {
      out.writeln('  patch: ${patchwork.relativePath(package.patchPath)}');
    }
    if (package.appliedPath != null) {
      out.writeln('  applied: ${patchwork.relativePath(package.appliedPath!)}');
    }
    if (package.needsApply) {
      out.writeln('  action: patchwork apply ${package.package}');
    }
    for (final problem in package.problems) {
      out.writeln('  problem: ${problem.message}');
      if (problem.hint != null) {
        out.writeln('    ${problem.hint}');
      }
    }
  }
}
