import 'dart:io' as io;

import '../error.dart';
import '../patchwork.dart';
import 'arguments.dart';
import 'commands/apply.dart';
import 'commands/commit.dart';
import 'commands/doctor.dart';
import 'commands/overlay.dart';
import 'commands/patch.dart';
import 'commands/status.dart';
import 'commands/undo.dart';
import 'output.dart';

/// Dispatches process arguments to Patchwork commands.
///
/// The application layer owns user-facing error rendering and exit-code
/// translation. Command implementations can throw [PatchworkException] with a
/// stable code and leave presentation to this class.
final class Application {
  /// Creates a CLI runner with optional injected IO and working directory.
  const Application({this.stdout, this.stderr, this.workingDirectory});

  /// The sink used for normal command output.
  final io.IOSink? stdout;

  /// The sink used for command errors.
  final io.IOSink? stderr;

  /// The directory used to locate the active Dart project.
  ///
  /// When omitted, [io.Directory.current] is used.
  final String? workingDirectory;

  /// Runs the CLI with process [arguments] and returns a process exit code.
  Future<int> run(List<String> arguments) async {
    final out = stdout ?? io.stdout;
    final err = stderr ?? io.stderr;
    var renderJsonError = false;

    try {
      if (arguments.isEmpty || isHelp(arguments.first)) {
        printGeneralHelp(out);
        return 0;
      }

      final command = arguments.first;
      final rest = arguments.skip(1).toList(growable: false);
      renderJsonError = rest.contains('--json');
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
        'overlay' => await runOverlayCommand(patchwork, rest, out),
        'apply' => await runApplyCommand(patchwork, rest, out),
        'undo' => await runUndoCommand(patchwork, rest, out),
        'status' => await runStatusCommand(patchwork, rest, out),
        'doctor' => await runDoctorCommand(patchwork, rest, out),
        _ => throw StateError('unreachable command: $command'),
      };
    } on PatchworkException catch (error) {
      if (renderJsonError) {
        printErrorJson(out, error);
      } else {
        printError(err, error);
      }
      return error.code.startsWith('usage.') ? 64 : 1;
    }
  }
}

/// Whether [command] is a command name handled by [Application].
bool isKnownCommand(String command) {
  return switch (command) {
    'patch' ||
    'commit' ||
    'overlay' ||
    'apply' ||
    'undo' ||
    'status' ||
    'doctor' => true,
    _ => false,
  };
}

/// Writes top-level usage help.
void printGeneralHelp(io.IOSink out) {
  out.writeln('Usage: patchwork <command> [arguments]');
  out.writeln('');
  out.writeln('Commands:');
  out.writeln('  patch <pkg> [--continue [version]] [--force] [--json]');
  out.writeln('  commit [pkg] [--json]');
  out.writeln('  overlay <pkg> [--reason <text>] [--json]');
  out.writeln('  apply [pkg] [--json]');
  out.writeln('  undo <pkg> [--json]');
  out.writeln('  status [--json]');
  out.writeln('  doctor [--json]');
}

/// Writes usage help for a single [command].
void printCommandHelp(String command, io.IOSink out) {
  switch (command) {
    case 'patch':
      out.writeln(
        'Usage: patchwork patch <pkg> [--continue [version]] [--force] [--json]',
      );
    case 'commit':
      out.writeln('Usage: patchwork commit [pkg] [--json]');
    case 'overlay':
      out.writeln('Usage: patchwork overlay <pkg> [--reason <text>] [--json]');
    case 'apply':
      out.writeln('Usage: patchwork apply [pkg] [--json]');
    case 'undo':
      out.writeln('Usage: patchwork undo <pkg> [--json]');
    case 'status':
      out.writeln('Usage: patchwork status [--json]');
    case 'doctor':
      out.writeln('Usage: patchwork doctor [--json]');
    default:
      throw PatchworkException(
        'Unknown command "$command".',
        code: 'usage.unknown_command',
        hint: 'Run patchwork --help to see available commands.',
      );
  }
}
