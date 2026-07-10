import 'package:path/path.dart' as p;

import '../error.dart';
import '../state/applied_marker.dart';
import '../state/applied_path_policy.dart';
import '../state/dependency_override_state.dart';
import 'model.dart';
import 'plan.dart';

/// Safety rules and planned changes for removing applied output.
final class AppliedCleanup {
  /// Creates applied-output cleanup rules for one project.
  const AppliedCleanup({
    required this.rootPath,
    required this.appliedPaths,
    required this.invalidAppliedPathMessage,
  });

  /// Patchwork state root.
  final String rootPath;

  /// Applied output path safety policy.
  final AppliedPathPolicy appliedPaths;

  /// Error message for invalid applied marker paths.
  final String invalidAppliedPathMessage;

  /// Whether an active override still references [marker].
  bool hasActiveOverride(
    AppliedMarker marker,
    DependencyOverrideState overrideState,
  ) {
    final path = appliedPaths.patchworkAppliedPathForMarker(marker);
    return path != null &&
        overrideState.hasActiveAppliedOverride(
          marker,
          absoluteAppliedPath: path,
        );
  }

  /// Rejects cleanup when a user-owned override still references [marker].
  void rejectUserOwnedOverride(
    AppliedMarker marker, {
    required String command,
    required String code,
    required DependencyOverrideState overrideState,
  }) {
    final path = appliedPaths.patchworkAppliedPathForMarker(marker);
    final conflict = path == null
        ? null
        : overrideState.userOwnedAppliedOverride(
            marker,
            absoluteAppliedPath: path,
          );
    if (conflict == null) {
      return;
    }
    throw PatchworkException(
      'Package "${marker.package}@${marker.version}" is still referenced by ${conflict.fileName}.',
      code: code,
      hint:
          'Remove the dependency override that points at ${marker.path} before running patchwork $command --force.',
      location: conflict.path,
    );
  }

  /// Adds safe applied-output and override cleanup changes to [plan].
  void addChanges(
    CleanupPlanBuilder plan,
    AppliedMarker marker,
    DependencyOverrideState overrideState,
  ) {
    final appliedPath = appliedPaths.requirePatchworkAppliedPathForMarker(
      marker,
      code: 'cleanup.applied_path_not_deletable',
      message: invalidAppliedPathMessage,
    );
    plan.addChange(
      CleanupChange(
        kind: CleanupChangeKind.appliedDirectory,
        package: marker.package,
        version: marker.version,
        path: appliedPath,
      ),
    );
    if (overrideState.rootOverridePointsToPath(
          package: marker.package,
          path: marker.path,
        ) ||
        marker.mirroredPubspecDependencyOverrides.isNotEmpty) {
      plan.addChange(
        CleanupChange(
          kind: CleanupChangeKind.pubspecOverride,
          package: marker.package,
          version: marker.version,
          path: p.join(rootPath, 'pubspec_overrides.yaml'),
        ),
      );
    }
  }
}
