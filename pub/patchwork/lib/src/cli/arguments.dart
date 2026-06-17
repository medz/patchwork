import '../error.dart';

/// Returns whether [argument] requests CLI help.
bool isHelp(String argument) {
  return argument == '-h' || argument == '--help' || argument == 'help';
}

/// Returns whether the full argument list is exactly one help argument.
bool isHelpOnly(List<String> arguments) {
  return arguments.length == 1 && isHelp(arguments.single);
}

/// Parses zero or one package operand for [command].
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

/// Throws when [arguments] contains any command operands.
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
