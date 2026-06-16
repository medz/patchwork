import 'dart:io' as io;

import 'package:path/path.dart' as p;

import '../error.dart';
import '../model.dart';
import '../patchwork.dart';

final class PatchworkCommandRunner {
  const PatchworkCommandRunner();

  Future<int> run(
    List<String> arguments, {
    io.IOSink? stdout,
    io.IOSink? stderr,
    String? workingDirectory,
  }) async {
    final out = stdout ?? io.stdout;
    final err = stderr ?? io.stderr;
    final cwd = workingDirectory ?? io.Directory.current.path;

    try {
      if (arguments.isEmpty || _isHelp(arguments.first)) {
        _printHelp(out);
        return 0;
      }

      final command = arguments.first;
      final rest = arguments.skip(1).toList(growable: false);
      final patchwork = await Patchwork.open(cwd);

      switch (command) {
        case 'patch':
          return await _patch(patchwork, rest, out);
        case 'commit':
          return await _commit(patchwork, rest, out);
        case 'apply':
          return await _apply(patchwork, rest, out);
        case 'undo':
          return await _undo(patchwork, rest, out);
        case 'status':
          if (_isHelpOnly(rest)) {
            _printStatusHelp(out);
            return 0;
          }
          _expectNoArguments('status', rest);
          await _status(patchwork, out);
          return 0;
        case 'doctor':
          if (_isHelpOnly(rest)) {
            _printDoctorHelp(out);
            return 0;
          }
          _expectNoArguments('doctor', rest);
          final state = await _status(patchwork, out);
          return state.problems.isEmpty ? 0 : 1;
        default:
          throw PatchworkException(
            'Unknown command "$command".',
            code: 'usage.unknown_command',
            hint: 'Run patchwork --help to see available commands.',
          );
      }
    } on PatchworkException catch (error) {
      _printError(err, error);
      return error.code.startsWith('usage.') ? 64 : 1;
    }
  }

  Future<int> _patch(
    Patchwork patchwork,
    List<String> arguments,
    io.IOSink out,
  ) async {
    if (_isHelpOnly(arguments)) {
      _printPatchHelp(out);
      return 0;
    }

    var force = false;
    PatchRef? continueFrom;
    final operands = <String>[];

    for (var i = 0; i < arguments.length; i += 1) {
      final argument = arguments[i];
      if (argument == '--force') {
        force = true;
      } else if (argument == '--continue') {
        if (continueFrom != null) {
          throw _duplicateOption('--continue');
        }
        final next = i + 1 < arguments.length ? arguments[i + 1] : null;
        if (next != null && !next.startsWith('-') && operands.isNotEmpty) {
          continueFrom = PatchRef.version(next);
          i += 1;
        } else {
          continueFrom = const PatchRef.current();
        }
      } else if (argument.startsWith('--continue=')) {
        if (continueFrom != null) {
          throw _duplicateOption('--continue');
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
        throw _unknownOption(argument, 'patch');
      } else {
        operands.add(argument);
      }
    }

    final package = _singleOptionalOperand('patch', operands, required: true)!;
    final edit = await patchwork.prepareEdit(
      package,
      fromPatch: continueFrom,
      replaceExisting: force,
    );
    out.writeln(
      'Created edit ${_relative(patchwork, edit.path)} from ${_relative(patchwork, edit.sourcePath)}.',
    );
    if (edit.continuedFromVersion != null) {
      out.writeln(
        'Applied ${_relative(patchwork, patchwork.layout.patchPath(package, edit.continuedFromVersion!))}.',
      );
    }
    return 0;
  }

  Future<int> _commit(
    Patchwork patchwork,
    List<String> arguments,
    io.IOSink out,
  ) async {
    if (_isHelpOnly(arguments)) {
      _printCommitHelp(out);
      return 0;
    }
    final package = _singleOptionalOperand('commit', arguments);
    final packages = package == null
        ? (await patchwork.inspect()).openEdits
              .map((status) => status.package)
              .toList()
        : [package];

    if (packages.isEmpty) {
      out.writeln('No open edits.');
      return 0;
    }

    final writes = <PatchWrite>[];
    for (final package in packages) {
      writes.add(await patchwork.writePatch(package));
    }
    for (final write in writes) {
      switch (write.status) {
        case PatchWriteStatus.written:
          out.writeln('Wrote ${_relative(patchwork, write.patchPath)}.');
        case PatchWriteStatus.unchanged:
          out.writeln(
            '${write.package}@${write.version} patch is already current; removed edit directory.',
          );
        case PatchWriteStatus.removed:
          out.writeln(
            '${write.package}@${write.version} has no changes; removed patch record.',
          );
      }
    }
    return 0;
  }

  Future<int> _apply(
    Patchwork patchwork,
    List<String> arguments,
    io.IOSink out,
  ) async {
    if (_isHelpOnly(arguments)) {
      _printApplyHelp(out);
      return 0;
    }
    final package = _singleOptionalOperand('apply', arguments);
    final packages = package == null
        ? (await patchwork.inspect()).packages
              .where((status) => status.hasPatch)
              .map((status) => status.package)
              .toList()
        : [package];

    if (packages.isEmpty) {
      out.writeln('No committed patches.');
      return 0;
    }

    final applied = <AppliedPatch>[];
    for (final package in packages) {
      applied.add(await patchwork.applyPatch(package));
    }
    for (final patch in applied) {
      out.writeln(
        'Applied ${_relative(patchwork, patch.patchPath)} to ${_relative(patchwork, patch.path)}.',
      );
    }
    out.writeln('Run dart pub get.');
    return 0;
  }

  Future<int> _undo(
    Patchwork patchwork,
    List<String> arguments,
    io.IOSink out,
  ) async {
    if (_isHelpOnly(arguments)) {
      _printUndoHelp(out);
      return 0;
    }
    final package = _singleOptionalOperand('undo', arguments, required: true)!;
    final result = await patchwork.unapplyPatch(package);
    if (result.changed) {
      out.writeln('Unapplied $package.');
      out.writeln('Run dart pub get.');
    } else {
      out.writeln('No applied patch for $package.');
    }
    return 0;
  }

  Future<PatchworkState> _status(Patchwork patchwork, io.IOSink out) async {
    final state = await patchwork.inspect();
    if (state.packages.isEmpty) {
      out.writeln('No patchwork packages.');
      return state;
    }

    for (final package in state.packages) {
      out.writeln('${package.package}@${package.version}');
      if (package.hasOpenEdit) {
        out.writeln('  edit: ${_relative(patchwork, package.editPath)}');
      }
      if (package.hasPatch) {
        out.writeln('  patch: ${_relative(patchwork, package.patchPath)}');
      }
      if (package.isApplied && package.appliedPath != null) {
        out.writeln('  applied: ${_relative(patchwork, package.appliedPath!)}');
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
    return state;
  }
}

String? _singleOptionalOperand(
  String command,
  List<String> operands, {
  bool required = false,
}) {
  for (final operand in operands) {
    if (operand.startsWith('-')) {
      throw _unknownOption(operand, command);
    }
  }
  if (operands.isEmpty) {
    if (required) {
      throw PatchworkException(
        'Expected a package name.',
        code: 'usage.missing_package',
        hint: 'Run patchwork $command --help.',
      );
    }
    return null;
  }
  if (operands.length > 1) {
    throw PatchworkException(
      'Too many arguments for "$command".',
      code: 'usage.too_many_arguments',
      hint: 'Run patchwork $command --help.',
    );
  }
  return operands.single;
}

void _expectNoArguments(String command, List<String> arguments) {
  if (_isHelpOnly(arguments)) {
    return;
  }
  if (arguments.isNotEmpty) {
    throw PatchworkException(
      'Command "$command" does not accept arguments.',
      code: 'usage.too_many_arguments',
      hint: 'Run patchwork $command --help.',
    );
  }
}

PatchworkException _unknownOption(String option, String command) {
  return PatchworkException(
    'Unknown option "$option" for "$command".',
    code: 'usage.unknown_option',
    hint: 'Run patchwork $command --help.',
  );
}

PatchworkException _duplicateOption(String option) {
  return PatchworkException(
    'Option "$option" can only be passed once.',
    code: 'usage.duplicate_option',
  );
}

bool _isHelp(String argument) {
  return argument == '-h' || argument == '--help' || argument == 'help';
}

bool _isHelpOnly(List<String> arguments) {
  return arguments.length == 1 && _isHelp(arguments.single);
}

String _relative(Patchwork patchwork, String path) {
  final absolute = p.normalize(p.absolute(path));
  final root = p.normalize(p.absolute(patchwork.rootPath));
  if (p.equals(root, absolute)) {
    return '.';
  }
  if (p.isWithin(root, absolute)) {
    return p.posix.joinAll(p.split(p.relative(absolute, from: root)));
  }
  return path;
}

void _printError(io.IOSink err, PatchworkException error) {
  err.writeln('error: ${error.message}');
  if (error.hint != null && error.hint!.isNotEmpty) {
    err.writeln(error.hint);
  }
  if (error.location != null && error.location!.isNotEmpty) {
    err.writeln(error.location);
  }
}

void _printHelp(io.IOSink out) {
  out.writeln('Usage: patchwork <command> [arguments]');
  out.writeln('');
  out.writeln('Commands:');
  out.writeln('  patch <pkg> [--continue [version]] [--force]');
  out.writeln('  commit [pkg]');
  out.writeln('  apply [pkg]');
  out.writeln('  undo <pkg>');
  out.writeln('  status');
  out.writeln('  doctor');
}

void _printPatchHelp(io.IOSink out) {
  out.writeln('Usage: patchwork patch <pkg> [--continue [version]] [--force]');
}

void _printCommitHelp(io.IOSink out) {
  out.writeln('Usage: patchwork commit [pkg]');
}

void _printApplyHelp(io.IOSink out) {
  out.writeln('Usage: patchwork apply [pkg]');
}

void _printUndoHelp(io.IOSink out) {
  out.writeln('Usage: patchwork undo <pkg>');
}

void _printStatusHelp(io.IOSink out) {
  out.writeln('Usage: patchwork status');
}

void _printDoctorHelp(io.IOSink out) {
  out.writeln('Usage: patchwork doctor');
}
