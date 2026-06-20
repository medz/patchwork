import '../error.dart';

/// Command arguments after common CLI options have been parsed.
final class CommandArguments {
  /// Creates parsed command arguments.
  const CommandArguments({required this.json, required this.rest});

  /// Whether the command should render structured diagnostic JSON.
  final bool json;

  /// Remaining command operands and command-specific options.
  final List<String> rest;
}

/// Whether [argument] is one of Patchwork's accepted help spellings.
bool isHelp(String argument) {
  return argument == '-h' || argument == '--help' || argument == 'help';
}

/// Whether [arguments] contains only a help request.
bool isHelpOnly(List<String> arguments) {
  return arguments.length == 1 && isHelp(arguments.single);
}

/// Parses common command options and returns the remaining arguments.
CommandArguments parseCommandArguments(String command, List<String> arguments) {
  var json = false;
  final rest = <String>[];

  for (final argument in arguments) {
    if (argument == '--json') {
      if (json) {
        throw duplicateOption('--json');
      }
      json = true;
      continue;
    }
    if (argument.startsWith('--json=')) {
      throw unknownOption(argument, command);
    }
    rest.add(argument);
  }

  return CommandArguments(json: json, rest: List.unmodifiable(rest));
}

/// Removes the `--no-pub-get` flag from [arguments].
({bool pubGet, List<String> rest}) parsePubGetOption(
  String command,
  List<String> arguments,
) {
  var pubGet = true;
  final rest = <String>[];
  for (final argument in arguments) {
    if (argument == '--no-pub-get') {
      if (!pubGet) {
        throw duplicateOption('--no-pub-get');
      }
      pubGet = false;
      continue;
    }
    if (argument.startsWith('--no-pub-get=')) {
      throw unknownOption(argument, command);
    }
    rest.add(argument);
  }
  return (pubGet: pubGet, rest: List.unmodifiable(rest));
}

/// Parses the optional package operand accepted by a command.
///
/// Options are rejected here because these commands do not have command-specific
/// flags. When [required] is true, omitting the package produces a usage error
/// instead of returning `null`.
String? singlePackage(
  String command,
  List<String> arguments, {
  required bool required,
}) {
  for (final argument in arguments) {
    if (argument.startsWith('-')) {
      throw unknownOption(argument, command);
    }
  }
  if (arguments.isEmpty) {
    if (!required) {
      return null;
    }
    throw PatchworkException(
      'Expected a package name.',
      code: 'usage.missing_package',
      hint: 'Run patchwork $command --help.',
    );
  }
  if (arguments.length > 1) {
    throw PatchworkException(
      'Too many arguments for "$command".',
      code: 'usage.too_many_arguments',
      hint: 'Run patchwork $command --help.',
    );
  }
  return arguments.single;
}

/// Verifies that a command received no operands or options.
void expectNoArguments(String command, List<String> arguments) {
  if (arguments.isEmpty) {
    return;
  }
  throw PatchworkException(
    'Command "$command" does not accept arguments.',
    code: 'usage.too_many_arguments',
    hint: 'Run patchwork $command --help.',
  );
}

/// Creates a usage error for an unsupported [option].
PatchworkException unknownOption(String option, String command) {
  return PatchworkException(
    'Unknown option "$option" for "$command".',
    code: 'usage.unknown_option',
    hint: 'Run patchwork $command --help.',
  );
}

/// Creates a usage error for an option that was passed more than once.
PatchworkException duplicateOption(String option) {
  return PatchworkException(
    'Option "$option" can only be passed once.',
    code: 'usage.duplicate_option',
  );
}
