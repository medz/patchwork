/// A recoverable Patchwork failure with a stable error code.
///
/// Patchwork uses this exception for command and library errors that should be
/// shown to users instead of treated as programming bugs. The [code] is intended
/// for tests and automation, while [message], [hint], and [location] provide the
/// human-readable report.
final class PatchworkException implements Exception {
  /// Creates an exception that can be rendered by the CLI or handled by callers.
  const PatchworkException(
    this.message, {
    required this.code,
    this.hint,
    this.location,
  });

  /// A stable identifier for the failure category.
  ///
  /// Codes use dotted namespaces such as `pub.package_not_found` and should not
  /// depend on localized wording in [message].
  final String code;

  /// The primary human-readable error message.
  final String message;

  /// Additional recovery guidance, when Patchwork can suggest a next step.
  final String? hint;

  /// A filesystem path or document location that caused the failure, if known.
  final String? location;

  @override
  String toString() {
    final buffer = StringBuffer('$code: $message');
    if (hint != null && hint!.isNotEmpty) {
      buffer.write('\n$hint');
    }
    if (location != null && location!.isNotEmpty) {
      buffer.write('\n$location');
    }
    return buffer.toString();
  }
}
