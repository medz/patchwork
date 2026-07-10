import 'dart:io' as io;

import '../../error.dart';
import '../../overlay/model.dart';
import '../../patchwork.dart';
import '../arguments.dart';
import '../json.dart';
import '../output.dart';
import '../path.dart';

/// Runs `patchwork overlay`.
///
/// `overlay add` turns an already committed `patches/<pkg>@<version>.patch`
/// file into a package-provided overlay declaration in `patchwork.yaml`.
/// `overlay inspect` reports read-only downstream overlay diagnostics.
int runOverlayCommand(
  Patchwork patchwork,
  List<String> arguments,
  io.IOSink out,
) {
  final parsed = parseCommandArguments('overlay', arguments);
  final command = _parseOverlayCommand(parsed.rest);
  if (command.inspect) {
    final inspection = patchwork.inspectOverlays();
    if (parsed.json) {
      printOverlayInspectionJson(patchwork, inspection, out);
    } else {
      printOverlayInspection(patchwork, inspection, out);
    }
    return _hasOverlayInspectionFailures(inspection) ? 1 : 0;
  }

  final overlay = patchwork.overlay(
    command.add.package,
    reason: command.add.reason,
  );

  if (parsed.json) {
    printOverlayJson(patchwork, overlay, out);
    return 0;
  }

  out.writeln(
    'Registered ${overlay.package}@${overlay.version} in '
    '${patchwork.displayPath(overlay.manifestPath)}.',
  );
  return 0;
}

bool _hasOverlayInspectionFailures(OverlayInspection inspection) {
  return inspection.targets.any((target) => target.conflict != null) ||
      inspection.providers.any((provider) {
        return provider.entries.any((entry) {
          return entry.status == OverlayEntryStatus.failed;
        });
      });
}

_OverlayCommand _parseOverlayCommand(List<String> arguments) {
  if (arguments.isEmpty) {
    throw PatchworkException(
      'Expected "add" or "inspect".',
      code: 'usage.missing_subcommand',
      hint: 'Run patchwork overlay --help.',
    );
  }

  final subcommand = arguments.first;
  final rest = arguments.skip(1).toList(growable: false);
  if (subcommand == 'inspect') {
    expectNoArguments('overlay inspect', rest);
    return _OverlayCommand.inspect();
  }
  if (subcommand == 'add') {
    return _OverlayCommand.add(_parseOverlayAddArguments(rest));
  }

  // Backward compatibility for the original `patchwork overlay <pkg>` shape.
  return _OverlayCommand.add(_parseOverlayAddArguments(arguments));
}

_OverlayAddArguments _parseOverlayAddArguments(List<String> arguments) {
  String? package;
  String? reason;
  var index = 0;
  while (index < arguments.length) {
    final argument = arguments[index];
    if (argument == '--reason') {
      if (reason != null) {
        throw duplicateOption('--reason');
      }
      index++;
      if (index >= arguments.length || arguments[index].startsWith('-')) {
        throw PatchworkException(
          'Option "--reason" expects a value.',
          code: 'usage.missing_option_value',
          hint: 'Run patchwork overlay --help.',
        );
      }
      reason = arguments[index];
      index++;
      continue;
    }
    if (argument.startsWith('--reason=')) {
      if (reason != null) {
        throw duplicateOption('--reason');
      }
      final value = argument.substring('--reason='.length);
      if (value.isEmpty) {
        throw PatchworkException(
          'Option "--reason" expects a value.',
          code: 'usage.missing_option_value',
          hint: 'Run patchwork overlay --help.',
        );
      }
      reason = value;
      index++;
      continue;
    }
    if (argument.startsWith('-')) {
      throw unknownOption(argument, 'overlay');
    }
    if (package != null) {
      throw PatchworkException(
        'Too many arguments for "overlay".',
        code: 'usage.too_many_arguments',
        hint: 'Run patchwork overlay --help.',
      );
    }
    package = argument;
    index++;
  }

  if (package == null) {
    throw PatchworkException(
      'Expected a package name.',
      code: 'usage.missing_package',
      hint: 'Run patchwork overlay --help.',
    );
  }
  return _OverlayAddArguments(package: package, reason: reason);
}

final class _OverlayCommand {
  _OverlayCommand.add(this.add) : inspect = false;

  _OverlayCommand.inspect()
    : add = const _OverlayAddArguments(package: '', reason: null),
      inspect = true;

  final _OverlayAddArguments add;
  final bool inspect;
}

final class _OverlayAddArguments {
  const _OverlayAddArguments({required this.package, required this.reason});

  final String package;
  final String? reason;
}
