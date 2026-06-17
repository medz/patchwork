final class PatchworkException implements Exception {
  const PatchworkException(
    this.message, {
    required this.code,
    this.hint,
    this.location,
  });

  final String code;
  final String message;
  final String? hint;
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
