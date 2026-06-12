import '../diagnostics/diagnostic.dart';
import '../pub/package_resolution.dart';
import '../target/target.dart';

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

  String get commitCommand => 'patchwork patch --commit $editPath';
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
