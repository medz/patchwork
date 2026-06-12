import 'dart:io';

import '../app/apply_patches.dart';
import '../app/commit_patch_session.dart';
import '../app/pub_doctor.dart';
import '../app/pub_status.dart';
import '../app/start_patch_session.dart';
import '../diagnostics/diagnostic.dart';
import '../diagnostics/exit_code.dart';
import '../store/patchwork_manifest.dart';
import '../target/target_parser.dart';
import 'command_intent.dart';

final class ParseResult {
  const ParseResult._({this.intent, this.diagnostic});

  factory ParseResult.success(CommandIntent intent) {
    return ParseResult._(intent: intent);
  }

  factory ParseResult.failure(Diagnostic diagnostic) {
    return ParseResult._(diagnostic: diagnostic);
  }

  final CommandIntent? intent;
  final Diagnostic? diagnostic;

  bool get isSuccess => intent != null;
}

final class PatchworkCommandParser {
  const PatchworkCommandParser({this.targetParser = const TargetParser()});

  final TargetParser targetParser;

  ParseResult parse(List<String> arguments) {
    if (arguments.isEmpty) {
      return ParseResult.failure(
        const Diagnostic(
          code: 'usage.missing_command',
          message: 'Expected a command.',
          hint: 'Run patchwork --help to see available commands.',
        ),
      );
    }

    final command = arguments.first;
    final rest = arguments.skip(1).toList(growable: false);

    if (_isHelp(command)) {
      return ParseResult.success(const HelpIntent());
    }

    switch (command) {
      case 'patch':
        return _parsePatch(rest);
      case 'apply':
        return _parseApply(rest);
      case 'status':
        return _parseNoArgumentCommand(rest, const StatusIntent(), 'status');
      case 'doctor':
        return _parseNoArgumentCommand(rest, const DoctorIntent(), 'doctor');
      default:
        if (command.startsWith('-')) {
          return ParseResult.failure(
            Diagnostic(
              code: 'usage.unknown_option',
              message: 'Unknown option "$command".',
              hint: 'Run patchwork --help to see available commands.',
            ),
          );
        }

        return ParseResult.failure(
          Diagnostic(
            code: 'usage.unknown_command',
            message: 'Unknown command "$command".',
            hint: 'Run patchwork --help to see available commands.',
          ),
        );
    }
  }

  ParseResult _parsePatch(List<String> arguments) {
    if (_isHelpOnly(arguments)) {
      return ParseResult.success(const HelpIntent('patch'));
    }

    var isCommit = false;
    final operands = <String>[];

    for (final argument in arguments) {
      if (argument == '--commit') {
        if (isCommit) {
          return ParseResult.failure(
            const Diagnostic(
              code: 'usage.duplicate_option',
              message: 'Option "--commit" can only be passed once.',
            ),
          );
        }

        isCommit = true;
      } else if (argument.startsWith('-')) {
        return _unknownOption(argument, command: 'patch');
      } else {
        operands.add(argument);
      }
    }

    if (operands.isEmpty) {
      return ParseResult.failure(
        Diagnostic(
          code: 'usage.missing_target',
          message: isCommit
              ? 'Expected a target or edit directory.'
              : 'Expected a target.',
          hint: isCommit
              ? 'Use patchwork patch --commit analyzer or an edit directory.'
              : 'Use patchwork patch analyzer.',
        ),
      );
    }

    if (operands.length > 1) {
      return _tooManyArguments('patch');
    }

    final operand = operands.single;

    if (isCommit) {
      return _parseCommitSubject(operand);
    }

    final targetResult = targetParser.parsePubTarget(operand);
    final diagnostic = targetResult.diagnostic;
    if (diagnostic != null) {
      return ParseResult.failure(diagnostic);
    }

    return ParseResult.success(PatchIntent.start(targetResult.target!));
  }

  ParseResult _parseCommitSubject(String operand) {
    if (_looksLikeWindowsEditDirectory(operand)) {
      return ParseResult.success(
        PatchIntent.commit(PatchCommitDirectory(operand)),
      );
    }

    if (_hasTargetKindPrefix(operand)) {
      final targetResult = targetParser.parsePubTarget(operand);
      final diagnostic = targetResult.diagnostic;
      if (diagnostic != null) {
        return ParseResult.failure(diagnostic);
      }

      return ParseResult.success(
        PatchIntent.commit(PatchCommitTarget(targetResult.target!)),
      );
    }

    if (_looksLikeEditDirectory(operand)) {
      return ParseResult.success(
        PatchIntent.commit(PatchCommitDirectory(operand)),
      );
    }

    final targetResult = targetParser.parsePubTarget(operand);
    final diagnostic = targetResult.diagnostic;
    if (diagnostic != null) {
      return ParseResult.failure(diagnostic);
    }

    return ParseResult.success(
      PatchIntent.commit(PatchCommitTarget(targetResult.target!)),
    );
  }

  ParseResult _parseApply(List<String> arguments) {
    if (_isHelpOnly(arguments)) {
      return ParseResult.success(const HelpIntent('apply'));
    }

    if (arguments.isEmpty) {
      return ParseResult.success(const ApplyIntent());
    }

    if (arguments.length > 1) {
      return _tooManyArguments('apply');
    }

    final argument = arguments.single;
    if (argument.startsWith('-')) {
      return _unknownOption(argument, command: 'apply');
    }

    final targetResult = targetParser.parsePubTarget(argument);
    final diagnostic = targetResult.diagnostic;
    if (diagnostic != null) {
      return ParseResult.failure(diagnostic);
    }

    return ParseResult.success(ApplyIntent(targetResult.target));
  }

  ParseResult _parseNoArgumentCommand(
    List<String> arguments,
    CommandIntent intent,
    String command,
  ) {
    if (_isHelpOnly(arguments)) {
      return ParseResult.success(HelpIntent(command));
    }

    if (arguments.isEmpty) {
      return ParseResult.success(intent);
    }

    if (arguments.length > 1) {
      return _tooManyArguments(command);
    }

    final argument = arguments.single;
    if (argument.startsWith('-')) {
      return _unknownOption(argument, command: command);
    }

    return _tooManyArguments(command);
  }

  ParseResult _unknownOption(String option, {required String command}) {
    return ParseResult.failure(
      Diagnostic(
        code: 'usage.unknown_option',
        message: 'Unknown option "$option" for patchwork $command.',
      ),
    );
  }

  ParseResult _tooManyArguments(String command) {
    return ParseResult.failure(
      Diagnostic(
        code: 'usage.too_many_arguments',
        message: 'Too many arguments for patchwork $command.',
      ),
    );
  }

  bool _isHelpOnly(List<String> arguments) {
    return arguments.length == 1 && _isHelp(arguments.single);
  }

  bool _isHelp(String argument) => argument == '--help' || argument == '-h';

  bool _looksLikeEditDirectory(String operand) {
    return operand.startsWith('/') ||
        operand.startsWith('./') ||
        operand.startsWith('../') ||
        operand.contains('/') ||
        _looksLikeWindowsEditDirectory(operand);
  }

  bool _looksLikeWindowsEditDirectory(String operand) {
    return RegExp(r'^[A-Za-z]:[\\/]').hasMatch(operand) ||
        operand.startsWith('.\\') ||
        operand.startsWith('..\\') ||
        operand.startsWith('\\\\') ||
        operand.contains('\\');
  }

  bool _hasTargetKindPrefix(String operand) {
    final separatorIndex = operand.indexOf(':');
    if (separatorIndex <= 0) {
      return false;
    }

    final slashIndex = operand.indexOf('/');
    if (slashIndex != -1 && slashIndex < separatorIndex) {
      return false;
    }

    final kind = operand.substring(0, separatorIndex);
    return RegExp(r'^[a-z]+$').hasMatch(kind);
  }
}

final class PatchworkCommandRunner {
  const PatchworkCommandRunner({
    this.parser = const PatchworkCommandParser(),
    this.startPatchSession = const StartPatchSession(),
    this.commitPatchSession = const CommitPatchSession(),
    this.applyPatches = const ApplyPatches(),
    this.pubStatus = const PubStatus(),
    this.pubDoctor = const PubDoctor(),
  });

  final PatchworkCommandParser parser;
  final StartPatchSession startPatchSession;
  final CommitPatchSession commitPatchSession;
  final ApplyPatches applyPatches;
  final PubStatus pubStatus;
  final PubDoctor pubDoctor;

  int run(
    List<String> arguments, {
    required StringSink stdout,
    required StringSink stderr,
    String? currentDirectory,
  }) {
    final result = parser.parse(arguments);
    final diagnostic = result.diagnostic;
    if (diagnostic != null) {
      _writeDiagnostic(stderr, diagnostic);
      return PatchworkExitCode.forDiagnostic(diagnostic);
    }

    final intent = result.intent!;
    if (intent is HelpIntent) {
      stdout.writeln(helpText(intent.command));
      return PatchworkExitCode.success;
    }

    if (intent is PatchIntent && !intent.isCommit) {
      return _startPatchSession(
        intent,
        stdout: stdout,
        stderr: stderr,
        currentDirectory: currentDirectory ?? Directory.current.path,
      );
    }

    if (intent is PatchIntent && intent.isCommit) {
      return _commitPatchSession(
        intent,
        stdout: stdout,
        stderr: stderr,
        currentDirectory: currentDirectory ?? Directory.current.path,
      );
    }

    if (intent is ApplyIntent) {
      return _applyPatches(
        intent,
        stdout: stdout,
        stderr: stderr,
        currentDirectory: currentDirectory ?? Directory.current.path,
      );
    }

    if (intent is StatusIntent) {
      return _status(
        stdout: stdout,
        stderr: stderr,
        currentDirectory: currentDirectory ?? Directory.current.path,
      );
    }

    if (intent is DoctorIntent) {
      return _doctor(
        stdout: stdout,
        currentDirectory: currentDirectory ?? Directory.current.path,
      );
    }

    _writeDiagnostic(
      stderr,
      const Diagnostic(
        code: 'usage.unknown_command',
        message: 'Command is not implemented.',
      ),
    );
    return PatchworkExitCode.usage;
  }

  int _startPatchSession(
    PatchIntent intent, {
    required StringSink stdout,
    required StringSink stderr,
    required String currentDirectory,
  }) {
    final result = startPatchSession(
      intent.target!,
      currentDirectory: currentDirectory,
    );
    final diagnostic = result.diagnostic;
    if (diagnostic != null) {
      _writeDiagnostic(stderr, diagnostic);
      return PatchworkExitCode.forDiagnostic(diagnostic);
    }

    final session = result.session!;
    stdout.writeln('Edit directory: ${session.editPath}');
    stdout.writeln('Commit changes with: ${session.commitCommand}');
    return PatchworkExitCode.success;
  }

  int _commitPatchSession(
    PatchIntent intent, {
    required StringSink stdout,
    required StringSink stderr,
    required String currentDirectory,
  }) {
    final subject = intent.commitSubject!;
    final result = switch (subject) {
      PatchCommitTarget(:final target) => commitPatchSession.commitTarget(
        target,
        currentDirectory: currentDirectory,
      ),
      PatchCommitDirectory(:final path) =>
        commitPatchSession.commitEditDirectory(
          path,
          currentDirectory: currentDirectory,
        ),
    };
    final diagnostic = result.diagnostic;
    if (diagnostic != null) {
      _writeDiagnostic(stderr, diagnostic);
      return PatchworkExitCode.forDiagnostic(diagnostic);
    }

    if (result.noChanges) {
      stdout.writeln('No changes to commit.');
      return PatchworkExitCode.success;
    }

    stdout.writeln('Patch file: ${result.patchPath}');
    return PatchworkExitCode.success;
  }

  int _applyPatches(
    ApplyIntent intent, {
    required StringSink stdout,
    required StringSink stderr,
    required String currentDirectory,
  }) {
    final result = applyPatches.apply(
      target: intent.target,
      currentDirectory: currentDirectory,
    );
    final diagnostic = result.diagnostic;
    if (diagnostic != null) {
      _writeDiagnostic(stderr, diagnostic);
      return PatchworkExitCode.forDiagnostic(diagnostic);
    }

    if (result.applied.isEmpty) {
      stdout.writeln('No pub patches to apply.');
      return PatchworkExitCode.success;
    }

    for (final patch in result.applied) {
      stdout.writeln(
        'Applied ${patch.target}: ${patch.storePath}'
        '${patch.rebuilt ? '' : ' (already current)'}',
      );
    }
    return PatchworkExitCode.success;
  }

  int _status({
    required StringSink stdout,
    required StringSink stderr,
    required String currentDirectory,
  }) {
    final result = pubStatus.read(currentDirectory: currentDirectory);
    final diagnostic = result.diagnostic;
    if (diagnostic != null) {
      _writeDiagnostic(stderr, diagnostic);
      return PatchworkExitCode.forDiagnostic(diagnostic);
    }

    stdout.writeln('Workspace: ${result.workspaceRootPath}');
    if (result.patches.isEmpty && result.staleOverrides.isEmpty) {
      stdout.writeln('Patches: none');
      return PatchworkExitCode.success;
    }

    if (result.patches.isEmpty) {
      stdout.writeln('Patches: none');
    } else {
      stdout.writeln('Patches:');
      for (final patch in result.patches) {
        stdout.writeln(
          '  - ${patch.target} [${_statusStateLabel(patch.state)}]',
        );
        stdout.writeln(
          '    patch: ${patch.patchPath} (${_patchStateLabel(patch)})',
        );
        final storePath = patch.storePath;
        if (storePath != null) {
          stdout.writeln(
            '    store: $storePath (${patch.storeCurrent ? 'current' : 'missing or stale'})',
          );
        }
        final packageName = patch.packageName;
        if (packageName != null) {
          final overridePath = patch.overridePath;
          stdout.writeln(
            '    override: $packageName -> ${overridePath ?? 'missing'} '
            '(${patch.overrideCurrent ? 'current' : 'missing or stale'})',
          );
        }
        final diagnostic = patch.diagnostic;
        if (diagnostic != null) {
          stdout.writeln('    detail: ${diagnostic.message}');
        }
      }
    }

    if (result.staleOverrides.isNotEmpty) {
      stdout.writeln('Stale overrides:');
      for (final override in result.staleOverrides) {
        stdout.writeln(
          '  - ${override.packageName} -> ${override.path} [stale]',
        );
      }
    }

    return result.hasBrokenState
        ? PatchworkExitCode.failure
        : PatchworkExitCode.success;
  }

  int _doctor({required StringSink stdout, required String currentDirectory}) {
    final result = pubDoctor.check(currentDirectory: currentDirectory);
    stdout.writeln('Doctor:');
    for (final check in result.checks) {
      stdout.writeln(
        '  [${check.state == PubDoctorCheckState.ok ? 'ok' : 'error'}] '
        '${check.name}: ${check.message}',
      );
      final location = check.location;
      if (location != null) {
        stdout.writeln('    location: $location');
      }
      final hint = check.hint;
      if (hint != null && hint.isNotEmpty) {
        stdout.writeln('    hint: $hint');
      }
    }

    return result.hasErrors
        ? PatchworkExitCode.failure
        : PatchworkExitCode.success;
  }

  String helpText([String? command]) {
    return switch (command) {
      null => _mainHelp,
      'patch' => _patchHelp,
      'apply' => _applyHelp,
      'status' => _statusHelp,
      'doctor' => _doctorHelp,
      _ => _mainHelp,
    };
  }

  void _writeDiagnostic(StringSink stderr, Diagnostic diagnostic) {
    stderr.writeln('error: ${diagnostic.message}');
    final hint = diagnostic.hint;
    if (hint != null) {
      stderr.writeln('hint: $hint');
    }
  }

  String _statusStateLabel(PubPatchStatusState state) {
    return switch (state) {
      PubPatchStatusState.clean => 'clean',
      PubPatchStatusState.stale => 'stale',
      PubPatchStatusState.missing => 'missing',
      PubPatchStatusState.unapplied => 'unapplied',
      PubPatchStatusState.broken => 'broken',
    };
  }

  String _patchStateLabel(PubPatchStatus patch) {
    return switch (patch.patchState) {
      PatchworkManifestPatchState.current => 'hash ok',
      PatchworkManifestPatchState.missing => 'missing',
      PatchworkManifestPatchState.stale => 'hash mismatch',
      PatchworkManifestPatchState.unreadable => 'unreadable',
      PatchworkManifestPatchState.invalid => 'invalid',
    };
  }
}

const _mainHelp = '''
Usage: patchwork <command> [arguments]

Commands:
  patch <target>                  Create an editable patch session.
  patch --commit <target|dir>     Commit an edit session into a patch.
  apply [target]                  Apply committed pub patches.
  status                          Show patch and session state.
  doctor                          Check Patchwork environment readiness.

Targets:
  analyzer and pub:analyzer both resolve to pub:analyzer.
  sdk: and path: targets are not supported by the pub MVP.

Run patchwork <command> --help for command-specific usage.
''';

const _patchHelp = '''
Usage:
  patchwork patch <target>
  patchwork patch --commit <target|edit-dir>

Targets default to pub:. For example, analyzer resolves to pub:analyzer.
''';

const _applyHelp = '''
Usage:
  patchwork apply [target]

Without a target, applies every committed pub patch.
''';

const _statusHelp = '''
Usage:
  patchwork status
''';

const _doctorHelp = '''
Usage:
  patchwork doctor
''';
