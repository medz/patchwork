import '../error.dart';

/// Whether [argument] is one of Patchwork's accepted help spellings.
bool isHelp(String argument) {
  return argument == '-h' || argument == '--help' || argument == 'help';
}

/// Whether [arguments] contains only a help request.
bool isHelpOnly(List<String> arguments) {
  return arguments.length == 1 && isHelp(arguments.single);
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
