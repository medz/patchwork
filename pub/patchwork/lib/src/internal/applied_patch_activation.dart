import '../applied_marker.dart';
import '../model.dart';
import '../pub/pubspec_overrides.dart';
import 'applied_path_policy.dart';
import 'dependency_override_state.dart';
import 'package_tree.dart';

/// Keeps applied marker metadata and generated pub overrides in sync.
final class AppliedPatchActivation {
  /// Creates an activation helper for one Patchwork state root.
  const AppliedPatchActivation({
    required this.rootPath,
    required this.appliedPaths,
    required this.appliedMarkerStore,
    required this.pubspecOverrides,
    required this.packageTree,
    required this.readOverrideState,
    required this.invalidAppliedPathMessage,
  });

  /// Patchwork state root.
  final String rootPath;

  /// Applied output path safety policy.
  final AppliedPathPolicy appliedPaths;

  /// Applied output marker store.
  final AppliedMarkerStore appliedMarkerStore;

  /// Root `pubspec_overrides.yaml` updater.
  final PubspecOverrides pubspecOverrides;

  /// Filesystem tree helper.
  final PackageTree packageTree;

  /// Reads current dependency override state.
  final DependencyOverrideState Function() readOverrideState;

  /// Error message for invalid applied marker paths.
  final String invalidAppliedPathMessage;

  /// Records [package] as applied and points pub at [path].
  void activate({
    required String package,
    required String version,
    required String patchSha256,
    required String path,
    required PackageSource source,
  }) {
    final state = _readActivationState();
    final mirroredPubspecDependencyOverrides = pubspecOverrides
        .upsertPathOverride(
          workspaceRootPath: rootPath,
          package: package,
          path: path,
          ownedDependencyOverrides:
              DependencyOverrideState.ownedPubspecDependencyOverrides(
                state.markers,
              ),
          pubspecDependencyOverrides: state.overrideState
              .rootPubspecDependencyOverrides(skippedPackage: package),
          mirroredPubspecDependencyOverrides:
              state.mirroredPubspecDependencyOverrides,
        );
    final nextMarker = AppliedMarker(
      package: package,
      version: version,
      patchSha256: patchSha256,
      path: path,
      source: source,
      mirroredPubspecDependencyOverrides: mirroredPubspecDependencyOverrides,
    );
    _setMirroredPubspecDependencyOverrides([
      for (final marker in state.markers)
        if (!(marker.package == package && marker.version == version)) marker,
      nextMarker,
    ], mirroredPubspecDependencyOverrides);
  }

  /// Removes applied output and Patchwork-owned pub override state.
  String remove(AppliedMarker marker, {required String code}) {
    final absoluteAppliedPath = appliedPaths
        .requirePatchworkAppliedPathForMarker(
          marker,
          code: code,
          message: invalidAppliedPathMessage,
        );
    final state = _readActivationState();
    final nextMirroredPubspecDependencyOverrides = pubspecOverrides
        .removePathOverrideIfMatches(
          workspaceRootPath: rootPath,
          package: marker.package,
          path: marker.path,
          ownedDependencyOverrides:
              DependencyOverrideState.ownedPubspecDependencyOverrides(
                state.markers,
              ),
          pubspecDependencyOverrides: state.overrideState
              .rootPubspecDependencyOverrides(),
          mirroredPubspecDependencyOverrides:
              state.mirroredPubspecDependencyOverrides,
        );
    packageTree.deleteDirectory(absoluteAppliedPath);

    _setMirroredPubspecDependencyOverrides([
      for (final existing in state.markers)
        if (!(existing.package == marker.package &&
            existing.version == marker.version))
          existing,
    ], nextMirroredPubspecDependencyOverrides);

    return absoluteAppliedPath;
  }

  _ActivationState _readActivationState() {
    final markers = appliedMarkerStore.readAll();
    return _ActivationState(
      markers: markers,
      overrideState: readOverrideState(),
      mirroredPubspecDependencyOverrides:
          DependencyOverrideState.mirroredPubspecDependencyOverrides(markers),
    );
  }

  void _setMirroredPubspecDependencyOverrides(
    List<AppliedMarker> markers,
    Map<String, Object?> dependencyOverrides,
  ) {
    for (final marker in markers) {
      appliedMarkerStore.write(
        marker.copyWith(
          mirroredPubspecDependencyOverrides: dependencyOverrides,
        ),
      );
    }
  }
}

final class _ActivationState {
  const _ActivationState({
    required this.markers,
    required this.overrideState,
    required this.mirroredPubspecDependencyOverrides,
  });

  final List<AppliedMarker> markers;
  final DependencyOverrideState overrideState;
  final Map<String, Object?> mirroredPubspecDependencyOverrides;
}
