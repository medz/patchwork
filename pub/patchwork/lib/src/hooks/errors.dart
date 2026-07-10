import 'dart:async';

import 'package:hooks/hooks.dart';

import '../error.dart';

/// Converts Patchwork failures into Dart hook failures.
Future<T> wrapPatchworkHookErrors<T>(FutureOr<T> Function() run) async {
  try {
    return await run();
  } on HookError {
    rethrow;
  } on PatchworkException catch (error, stackTrace) {
    throw BuildError(
      message: formatPatchworkException(error),
      wrappedException: error,
      wrappedTrace: stackTrace,
    );
  }
}

/// Renders a Patchwork failure for hook output.
String formatPatchworkException(PatchworkException error) {
  return [
    '${error.code}: ${error.message}',
    if (error.hint != null && error.hint!.isNotEmpty) error.hint!,
    if (error.location != null && error.location!.isNotEmpty) error.location!,
  ].join('\n');
}
