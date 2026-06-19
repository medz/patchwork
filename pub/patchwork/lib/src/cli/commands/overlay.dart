import 'dart:io' as io;

import '../../error.dart';
import '../../patchwork.dart';
import '../arguments.dart';
import '../output.dart';

/// Runs `patchwork overlay`.
///
/// The command turns an already committed `patches/<pkg>@<version>.patch` file
/// into a package-provided overlay declaration in `patchwork.yaml`.
Future<int> runOverlayCommand(
  Patchwork patchwork,
  List<String> arguments,
  io.IOSink out,
) async {
  final parsed = parseCommandArguments('overlay', arguments);
  final overlayArguments = _parseOverlayArguments(parsed.rest);
  final overlay = await patchwork.overlay(
    overlayArguments.package,
    reason: overlayArguments.reason,
  );

  if (parsed.json) {
    printOverlayJson(patchwork, overlay, out);
    return 0;
  }

  out.writeln(
    'Registered ${overlay.package}@${overlay.version} in '
    '${patchwork.relativePath(overlay.manifestPath)}.',
  );
  return 0;
}

_OverlayArguments _parseOverlayArguments(List<String> arguments) {
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
      reason = argument.substring('--reason='.length);
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
  return _OverlayArguments(package: package, reason: reason);
}

final class _OverlayArguments {
  const _OverlayArguments({required this.package, required this.reason});

  final String package;
  final String? reason;
}
