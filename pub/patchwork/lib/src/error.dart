/// An error raised when Patchwork cannot complete a command or API operation.
final class PatchworkException implements Exception {
  /// Creates a Patchwork exception with a stable machine-readable [code].
  const PatchworkException(
    this.message, {
    required this.code,
    this.hint,
    this.location,
  });

  /// A stable identifier for the failure category.
  final String code;

  /// The human-readable error message.
  final String message;

  /// Optional recovery guidance for the user.
  final String? hint;

  /// Optional filesystem path or document location related to the error.
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
