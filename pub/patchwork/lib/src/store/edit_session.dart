import 'dart:io';

import '../diagnostics/diagnostic.dart';
import '../pub/package_resolution.dart';
import '../target/target.dart';

enum CommandShell { posix, windows }

final class PubPatchSession {
  const PubPatchSession({
    required this.target,
    required this.package,
    required this.baselinePath,
    required this.editPath,
    required this.metadataPath,
  });

  final PubTarget target;
  final ResolvedPubPackage package;
  final String baselinePath;
  final String editPath;
  final String metadataPath;

  String get commitCommand => commitCommandFor(
    Platform.isWindows ? CommandShell.windows : CommandShell.posix,
  );

  String commitCommandFor(CommandShell shell) {
    return 'patchwork patch --commit ${_shellQuote(editPath, shell)}';
  }
}

String _shellQuote(String value, CommandShell shell) {
  return switch (shell) {
    CommandShell.posix => "'${value.replaceAll("'", r"'\''")}'",
    CommandShell.windows => '"${value.replaceAll('"', r'\"')}"',
  };
}

final class PubPatchSessionCreateResult {
  const PubPatchSessionCreateResult._({this.session, this.diagnostic});

  factory PubPatchSessionCreateResult.success(PubPatchSession session) {
    return PubPatchSessionCreateResult._(session: session);
  }

  factory PubPatchSessionCreateResult.failure(Diagnostic diagnostic) {
    return PubPatchSessionCreateResult._(diagnostic: diagnostic);
  }

  final PubPatchSession? session;
  final Diagnostic? diagnostic;

  bool get isSuccess => session != null;
}
