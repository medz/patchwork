enum DiagnosticSeverity { error, warning, info }

final class Diagnostic {
  const Diagnostic({
    required this.code,
    required this.message,
    this.hint,
    this.location,
    this.severity = DiagnosticSeverity.error,
  });

  final String code;
  final String message;
  final String? hint;
  final String? location;
  final DiagnosticSeverity severity;
}
