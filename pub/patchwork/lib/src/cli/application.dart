import 'dart:io' as io;

import '../error.dart';
import '../patchwork.dart';
import 'arguments.dart';
import 'commands/apply.dart';
import 'commands/commit.dart';
import 'commands/doctor.dart';
import 'commands/patch.dart';
import 'commands/status.dart';
import 'commands/undo.dart';
import 'output.dart';

final class Application {
  const Application({this.stdout, this.stderr, this.workingDirectory});

  final io.IOSink? stdout;
  final io.IOSink? stderr;
  final String? workingDirectory;

  Future<int> run(List<String> arguments) async {
    final out = stdout ?? io.stdout;
    final err = stderr ?? io.stderr;

    try {
      if (arguments.isEmpty || isHelp(arguments.first)) {
        printGeneralHelp(out);
        return 0;
      }

      final command = arguments.first;
      final rest = arguments.skip(1).toList(growable: false);
      if (isHelpOnly(rest)) {
        printCommandHelp(command, out);
        return 0;
      }
      if (!isKnownCommand(command)) {
        throw PatchworkException(
          'Unknown command "$command".',
          code: 'usage.unknown_command',
          hint: 'Run patchwork --help to see available commands.',
        );
      }

      final cwd = workingDirectory ?? io.Directory.current.path;
      final patchwork = await Patchwork.open(cwd);
      return switch (command) {
        'patch' => await runPatchCommand(patchwork, rest, out),
        'commit' => await runCommitCommand(patchwork, rest, out),
        'apply' => await runApplyCommand(patchwork, rest, out),
        'undo' => await runUndoCommand(patchwork, rest, out),
        'status' => await runStatusCommand(patchwork, rest, out),
        'doctor' => await runDoctorCommand(patchwork, rest, out),
        _ => throw StateError('unreachable command: $command'),
      };
    } on PatchworkException catch (error) {
      printError(err, error);
      return error.code.startsWith('usage.') ? 64 : 1;
    }
  }
}

bool isKnownCommand(String command) {
  return switch (command) {
    'patch' || 'commit' || 'apply' || 'undo' || 'status' || 'doctor' => true,
    _ => false,
  };
}

void printGeneralHelp(io.IOSink out) {
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

void printCommandHelp(String command, io.IOSink out) {
  switch (command) {
    case 'patch':
      out.writeln(
        'Usage: patchwork patch <pkg> [--continue [version]] [--force]',
      );
    case 'commit':
      out.writeln('Usage: patchwork commit [pkg]');
    case 'apply':
      out.writeln('Usage: patchwork apply [pkg]');
    case 'undo':
      out.writeln('Usage: patchwork undo <pkg>');
    case 'status':
      out.writeln('Usage: patchwork status');
    case 'doctor':
      out.writeln('Usage: patchwork doctor');
    default:
      throw PatchworkException(
        'Unknown command "$command".',
        code: 'usage.unknown_command',
        hint: 'Run patchwork --help to see available commands.',
      );
  }
}
