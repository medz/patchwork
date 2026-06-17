import 'dart:io' as io;

import '../../error.dart';
import '../../model.dart';
import '../../patchwork.dart';
import '../arguments.dart';
import '../output.dart';

/// Runs `patchwork patch`.
///
/// This command accepts exactly one package operand plus optional `--force` and
/// `--continue` flags. `--continue` may either use the currently resolved patch
/// file or an explicit historical version.
Future<int> runPatchCommand(
  Patchwork patchwork,
  List<String> arguments,
  io.IOSink out,
) async {
  final parsed = parseCommandArguments('patch', arguments);
  var force = false;
  PatchRef? continueFrom;
  final packages = <String>[];

  for (var index = 0; index < parsed.rest.length; index += 1) {
    final argument = parsed.rest[index];
    if (argument == '--force') {
      force = true;
    } else if (argument == '--continue') {
      if (continueFrom != null) {
        throw duplicateOption('--continue');
      }
      final next = index + 1 < parsed.rest.length
          ? parsed.rest[index + 1]
          : null;
      if (next != null &&
          !next.startsWith('-') &&
          (packages.isNotEmpty ||
              _hasLaterOperand(parsed.rest, index + 2) ||
              _looksLikeVersion(next))) {
        continueFrom = PatchRef.version(next);
        index += 1;
      } else {
        continueFrom = const PatchRef.current();
      }
    } else if (argument.startsWith('--continue=')) {
      if (continueFrom != null) {
        throw duplicateOption('--continue');
      }
      final version = argument.substring('--continue='.length);
      if (version.isEmpty) {
        throw PatchworkException(
          'Expected a version after --continue=.',
          code: 'usage.missing_continue_version',
        );
      }
      continueFrom = PatchRef.version(version);
    } else if (argument.startsWith('-')) {
      throw unknownOption(argument, 'patch');
    } else {
      packages.add(argument);
    }
  }

  final package = singlePackage('patch', packages, required: true)!;
  final edit = await patchwork.patch(
    package,
    fromPatch: continueFrom,
    replaceExisting: force,
  );
  if (parsed.json) {
    printPatchJson(patchwork, edit, out);
    return 0;
  }
  out.writeln(
    'Created edit ${patchwork.relativePath(edit.path)} from '
    '${patchwork.relativePath(edit.sourcePath)}.',
  );
  if (edit.continuedFromPatchPath != null) {
    out.writeln(
      'Applied ${patchwork.relativePath(edit.continuedFromPatchPath!)}.',
    );
  }
  return 0;
}

bool _hasLaterOperand(List<String> arguments, int startIndex) {
  for (var index = startIndex; index < arguments.length; index += 1) {
    if (!arguments[index].startsWith('-')) {
      return true;
    }
  }
  return false;
}

bool _looksLikeVersion(String argument) {
  return RegExp(r'^[0-9]+([.+-]|$)').hasMatch(argument);
}
