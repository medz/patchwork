import '../state/applied_marker.dart';
import '../pub/source.dart';
import '../pub/override_editor.dart';
import '../pub/overrides.dart';
import '../state/applied_path_policy.dart';
import '../state/dependency_override_state.dart';
import '../patch/package_tree.dart';

/// Keeps applied marker metadata and generated pub overrides in sync.
final class AppliedPatchActivation {
  /// Creates an activation helper for one Patchwork state root.
  AppliedPatchActivation({
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

  List<AppliedMarker>? _markers;
  Map<String, Object?>? _rootPubspecDependencyOverrides;
  PubspecOverridesEditor? _pubspecOverridesEditor;

  /// Records [package] as applied and points pub at [path].
  void activate({
    required String package,
    required String version,
    required String patchSha256,
    required String path,
    required PackageSource source,
  }) {
    final state = _readActivationState();
    final mirroredPubspecDependencyOverrides = _overridesEditor()
        .upsertPathOverride(
          package: package,
          path: path,
          ownedDependencyOverrides: ownedPubspecDependencyOverrides(
            state.markers,
          ),
          pubspecDependencyOverrides: {
            for (final entry in state.rootPubspecDependencyOverrides.entries)
              if (entry.key != package) entry.key: entry.value,
          },
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
    _setMirroredPubspecDependencyOverrides(
      [
        for (final marker in state.markers)
          if (!(marker.package == package && marker.version == version)) marker,
        nextMarker,
      ],
      mirroredPubspecDependencyOverrides,
      alwaysWrite: {(package, version)},
    );
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
    final nextMirroredPubspecDependencyOverrides = _overridesEditor()
        .removePathOverrideIfMatches(
          package: marker.package,
          path: marker.path,
          ownedDependencyOverrides: ownedPubspecDependencyOverrides(
            state.markers,
          ),
          pubspecDependencyOverrides: state.rootPubspecDependencyOverrides,
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
    final markers = _markers ??= appliedMarkerStore.readAll();
    final rootPubspecDependencyOverrides = _rootPubspecDependencyOverrides ??=
        readOverrideState().rootPubspecDependencyOverrides();
    return _ActivationState(
      markers: markers,
      rootPubspecDependencyOverrides: rootPubspecDependencyOverrides,
      mirroredPubspecDependencyOverrides: mirroredPubspecDependencyOverrides(
        markers,
      ),
    );
  }

  PubspecOverridesEditor _overridesEditor() {
    return _pubspecOverridesEditor ??= pubspecOverrides.edit(
      workspaceRootPath: rootPath,
    );
  }

  void _setMirroredPubspecDependencyOverrides(
    List<AppliedMarker> markers,
    Map<String, Object?> dependencyOverrides, {
    Set<(String, String)> alwaysWrite = const {},
  }) {
    final updated = <AppliedMarker>[];
    for (final marker in markers) {
      final mirrorsChanged = !_sameValue(
        marker.mirroredPubspecDependencyOverrides,
        dependencyOverrides,
      );
      final nextMarker = mirrorsChanged
          ? marker.copyWith(
              mirroredPubspecDependencyOverrides: dependencyOverrides,
            )
          : marker;
      if (mirrorsChanged ||
          alwaysWrite.contains((marker.package, marker.version))) {
        appliedMarkerStore.write(nextMarker);
      }
      updated.add(nextMarker);
    }
    _markers = updated;
  }
}

final class _ActivationState {
  const _ActivationState({
    required this.markers,
    required this.rootPubspecDependencyOverrides,
    required this.mirroredPubspecDependencyOverrides,
  });

  final List<AppliedMarker> markers;
  final Map<String, Object?> rootPubspecDependencyOverrides;
  final Map<String, Object?> mirroredPubspecDependencyOverrides;
}

bool _sameValue(Object? left, Object? right) {
  if (identical(left, right)) {
    return true;
  }
  if (left is Map<Object?, Object?> && right is Map<Object?, Object?>) {
    if (left.length != right.length) {
      return false;
    }
    for (final entry in left.entries) {
      if (!right.containsKey(entry.key) ||
          !_sameValue(entry.value, right[entry.key])) {
        return false;
      }
    }
    return true;
  }
  if (left is List<Object?> && right is List<Object?>) {
    if (left.length != right.length) {
      return false;
    }
    for (var index = 0; index < left.length; index += 1) {
      if (!_sameValue(left[index], right[index])) {
        return false;
      }
    }
    return true;
  }
  return left == right;
}
