import 'dart:io' as io;

import '../../error.dart';
import '../../patchwork.dart';
import '../arguments.dart';
import '../json.dart';
import '../path.dart';

/// Runs `patchwork carry`.
///
/// This command creates a current-version edit directory seeded from a stale
/// committed patch. When multiple stale patch files exist, callers must choose
/// one with `--from`.
int runCarryCommand(
  Patchwork patchwork,
  List<String> arguments,
  io.IOSink out,
) {
  final parsed = parseCommandArguments('carry', arguments);
  String? fromVersion;
  var partial = false;
  final packages = <String>[];

  for (var index = 0; index < parsed.rest.length; index += 1) {
    final argument = parsed.rest[index];
    if (argument == '--partial') {
      if (partial) {
        throw duplicateOption('--partial');
      }
      partial = true;
    } else if (argument == '--from') {
      if (fromVersion != null) {
        throw duplicateOption('--from');
      }
      final next = index + 1 < parsed.rest.length
          ? parsed.rest[index + 1]
          : null;
      if (next == null || next.startsWith('-')) {
        throw PatchworkException(
          'Expected a version after --from.',
          code: 'usage.missing_from_version',
          hint: 'Run patchwork carry --help.',
        );
      }
      fromVersion = next;
      index += 1;
    } else if (argument.startsWith('--from=')) {
      if (fromVersion != null) {
        throw duplicateOption('--from');
      }
      final version = argument.substring('--from='.length);
      if (version.isEmpty) {
        throw PatchworkException(
          'Expected a version after --from=.',
          code: 'usage.missing_from_version',
          hint: 'Run patchwork carry --help.',
        );
      }
      fromVersion = version;
    } else if (argument.startsWith('-')) {
      throw unknownOption(argument, 'carry');
    } else {
      packages.add(argument);
    }
  }

  final package = singlePackage('carry', packages, required: true)!;
  final edit = patchwork.carry(
    package,
    fromVersion: fromVersion,
    partial: partial,
  );
  if (parsed.json) {
    printEditJson(patchwork, edit, out, command: 'carry');
    return 0;
  }

  out.writeln(
    '${edit.partialRepairLogPath == null ? 'Created carry edit' : 'Created partial carry edit'} '
    '${patchwork.displayPath(edit.path)} from '
    '${patchwork.displayPath(edit.sourcePath)}.',
  );
  if (edit.partialRepairLogPath == null) {
    out.writeln(
      'Applied ${patchwork.displayPath(edit.continuedFromPatchPath!)}.',
    );
  } else {
    out.writeln(
      'Prepared partial repair from '
      '${patchwork.displayPath(edit.continuedFromPatchPath!)}.',
    );
    out.writeln(
      'Wrote conflict log '
      '${patchwork.displayPath(edit.partialRepairLogPath!)}.',
    );
    if (edit.partialRejectPaths.isNotEmpty) {
      out.writeln('Moved rejects under .patchwork/rejects/.');
    }
  }
  out.writeln('Review the edit and run patchwork commit ${edit.package}.');
  return 0;
}
