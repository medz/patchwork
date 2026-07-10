import 'override_value.dart';

/// Mutates one already-read `pubspec_overrides.yaml` document.
final class PubspecOverridesEditor {
  /// Creates an editor with a persistence callback.
  PubspecOverridesEditor({
    required this.workspaceRootPath,
    required Map<String, Object?> document,
    required Map<String, Object?> dependencyOverrides,
    required bool hasDependencyOverrides,
    required void Function(Map<String, Object?> document) write,
  }) : _document = document,
       _dependencyOverrides = dependencyOverrides,
       _hasDependencyOverrides = hasDependencyOverrides,
       _write = write;

  /// Root used to resolve relative path overrides.
  final String workspaceRootPath;

  final Map<String, Object?> _document;
  final Map<String, Object?> _dependencyOverrides;
  final void Function(Map<String, Object?> document) _write;
  bool _hasDependencyOverrides;

  /// Inserts or replaces one Patchwork-owned path override.
  Map<String, Object?> upsertPathOverride({
    required String package,
    required String path,
    Map<String, Object?> ownedDependencyOverrides = const {},
    Map<String, Object?> pubspecDependencyOverrides = const {},
    Map<String, Object?> mirroredPubspecDependencyOverrides = const {},
  }) {
    _removeMirrored(mirroredPubspecDependencyOverrides, _dependencyOverrides);
    final canIntroduceMirrors =
        !_hasDependencyOverrides ||
        _hasOnlyOwned(_dependencyOverrides, ownedDependencyOverrides);
    final nextMirrors = _restoreMirrors(
      dependencyOverrides: _dependencyOverrides,
      pubspecDependencyOverrides: pubspecDependencyOverrides,
      previousMirrors: mirroredPubspecDependencyOverrides,
      canIntroduceMirrors: canIntroduceMirrors,
      retainPreviousMirrors: true,
    );
    _dependencyOverrides[package] = {'path': path};
    _document['dependency_overrides'] = _dependencyOverrides;
    _hasDependencyOverrides = true;
    _write(_document);
    return nextMirrors;
  }

  /// Removes one matching Patchwork-owned path override.
  Map<String, Object?> removePathOverrideIfMatches({
    required String package,
    required String path,
    Map<String, Object?> ownedDependencyOverrides = const {},
    Map<String, Object?> pubspecDependencyOverrides = const {},
    Map<String, Object?> mirroredPubspecDependencyOverrides = const {},
  }) {
    final existing = _dependencyOverrides[package];
    var removedPackageOverride = false;
    if (existing is Map<String, Object?> && existing['path'] is String) {
      final existingPath = existing['path'] as String;
      if (dependencyOverridePathsEqual(workspaceRootPath, existingPath, path)) {
        _dependencyOverrides.remove(package);
        removedPackageOverride = true;
      }
    }
    final removedMirrors = _removeMirrored(
      mirroredPubspecDependencyOverrides,
      _dependencyOverrides,
    );
    final hasActiveOverrides = _dependencyOverrides.isNotEmpty;
    final nextMirrors = _restoreMirrors(
      dependencyOverrides: _dependencyOverrides,
      pubspecDependencyOverrides: pubspecDependencyOverrides,
      previousMirrors: mirroredPubspecDependencyOverrides,
      canIntroduceMirrors: _hasOnlyOwned(
        _dependencyOverrides,
        ownedDependencyOverrides,
      ),
      retainPreviousMirrors: hasActiveOverrides,
    );
    final changed =
        removedPackageOverride || removedMirrors || nextMirrors.isNotEmpty;
    if (!changed) {
      return nextMirrors;
    }
    if (_dependencyOverrides.isEmpty) {
      _document.remove('dependency_overrides');
      _hasDependencyOverrides = false;
    } else {
      _document['dependency_overrides'] = _dependencyOverrides;
      _hasDependencyOverrides = true;
    }
    _write(_document);
    return nextMirrors;
  }

  Map<String, Object?> _restoreMirrors({
    required Map<String, Object?> dependencyOverrides,
    required Map<String, Object?> pubspecDependencyOverrides,
    required Map<String, Object?> previousMirrors,
    required bool canIntroduceMirrors,
    required bool retainPreviousMirrors,
  }) {
    final nextMirrors = <String, Object?>{};
    for (final entry in pubspecDependencyOverrides.entries) {
      if (dependencyOverrides.containsKey(entry.key)) {
        continue;
      }
      final wasMirrored = previousMirrors.containsKey(entry.key);
      if (!canIntroduceMirrors && (!retainPreviousMirrors || !wasMirrored)) {
        continue;
      }
      dependencyOverrides[entry.key] = entry.value;
      nextMirrors[entry.key] = entry.value;
    }
    return nextMirrors;
  }

  bool _removeMirrored(
    Map<String, Object?> mirrors,
    Map<String, Object?> dependencyOverrides,
  ) {
    var removed = false;
    for (final entry in mirrors.entries) {
      if (sameDependencyOverrideValue(
        workspaceRootPath,
        dependencyOverrides[entry.key],
        entry.value,
      )) {
        dependencyOverrides.remove(entry.key);
        removed = true;
      }
    }
    return removed;
  }

  bool _hasOnlyOwned(
    Map<String, Object?> dependencyOverrides,
    Map<String, Object?> ownedDependencyOverrides,
  ) {
    return dependencyOverrides.isNotEmpty &&
        dependencyOverrides.entries.every(
          (entry) =>
              ownedDependencyOverrides.containsKey(entry.key) &&
              sameDependencyOverrideValue(
                workspaceRootPath,
                entry.value,
                ownedDependencyOverrides[entry.key],
              ),
        );
  }
}
