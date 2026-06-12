import 'diagnostic.dart';

abstract final class PatchworkExitCode {
  static const success = 0;
  static const failure = 1;
  static const usage = 2;
  static const internal = 70;

  static int forDiagnostic(Diagnostic diagnostic) {
    if (diagnostic.code.startsWith('usage.')) {
      return usage;
    }

    return failure;
  }
}
