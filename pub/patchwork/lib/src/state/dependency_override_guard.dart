import '../error.dart';
import 'dependency_override_state.dart';

/// Rejects an override that Patchwork cannot safely replace.
void rejectBlockingOverride({
  required DependencyOverrideState overrideState,
  required String package,
  required String command,
  required String targetPath,
  bool replaceRootOverride = false,
}) {
  final conflict = overrideState.blockingConflict(
    package: package,
    targetPath: targetPath,
    replaceRootOverride: replaceRootOverride,
  );
  if (conflict == null) {
    return;
  }
  throw PatchworkException(
    '${conflict.fileName} already has a dependency override for "$package".',
    code: 'pub.override_conflict',
    hint:
        'Remove or resolve the existing override before running patchwork $command $package.',
    location: conflict.path,
  );
}
