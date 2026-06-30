import 'dart:io';

import '../applied_marker.dart';
import '../error.dart';
import '../model.dart';
import '../pub/package_resolution.dart';
import '../pub/pubspec_overrides.dart';
import 'applied_path_policy.dart';
import 'applied_resolution.dart';
import 'artifact_identity.dart';
import 'artifact_inventory.dart';
import 'dependency_override_guard.dart';
import 'dependency_override_state.dart';
import 'path_layout.dart';

/// Plans Patchwork edit preparation before any edit directory is written.
///
/// The planner owns pub resolution, stale patch selection, continue-patch
/// loading, and state refusal checks. [EditPreparer] remains responsible for the
/// filesystem transaction that materializes the returned [EditPlan].
final class EditPlanner {
  /// Creates an edit planner for one Patchwork state root.
  const EditPlanner({
    required this.rootPath,
    required this.layout,
    required this.appliedPaths,
    required this.appliedMarkerStore,
    required this.pubspecOverrides,
    required this.readResolution,
    required this.readOverrideState,
  });

  /// Patchwork state root.
  final String rootPath;

  /// Patchwork artifact paths.
  final PathLayout layout;

  /// Applied output path safety policy.
  final AppliedPathPolicy appliedPaths;

  /// Applied output marker store.
  final AppliedMarkerStore appliedMarkerStore;

  /// Project override file helper.
  final PubspecOverrides pubspecOverrides;

  /// Reads the current pub resolution.
  final PubResolution Function() readResolution;

  /// Reads dependency override state across relevant pub roots.
  final DependencyOverrideState Function() readOverrideState;

  /// Plans `patchwork patch`.
  EditPlan patch(
    String package, {
    PatchRef? fromPatch,
    bool replaceExisting = false,
  }) {
    final resolved = _resolveEditablePackage(
      package,
      appliedHint:
          'Run patchwork undo $package, then dart pub get, before patching it again.',
    );
    _rejectPatchOverride(package, resolved);
    final seed = _seedForPatchRef(
      package: package,
      resolvedVersion: resolved.version,
      fromPatch: fromPatch,
    );

    return EditPlan(
      package: package,
      resolved: resolved,
      continuedFromPatchPath: seed?.path,
      continuedFromPatchContent: seed?.content,
      replaceExisting: replaceExisting,
      preserveFailedPatchApply: false,
      partialPatchApply: false,
    );
  }

  /// Plans `patchwork carry`.
  EditPlan carry(String package, {String? fromVersion, bool partial = false}) {
    if (fromVersion != null) {
      checkSafePathSegment(
        fromVersion,
        label: 'Patch version',
        code: 'patch.continue_version_invalid',
      );
    }

    final resolved = _resolveEditablePackage(
      package,
      appliedHint:
          'Run patchwork undo $package, then dart pub get, before carrying it forward.',
    );
    final selectedVersion = _carryPatchVersion(
      package: package,
      currentVersion: resolved.version,
      fromVersion: fromVersion,
      inventory: PatchworkArtifactInventory.read(layout),
    );
    _rejectPatchOverride(package, resolved);
    final seed = _readSeedPatch(
      package: package,
      version: selectedVersion,
      missingCode: 'patch.continue_patch_missing',
    );

    return EditPlan(
      package: package,
      resolved: resolved,
      continuedFromPatchPath: seed.path,
      continuedFromPatchContent: seed.content,
      replaceExisting: false,
      preserveFailedPatchApply: true,
      partialPatchApply: partial,
    );
  }

  ResolvedPubPackage _resolveEditablePackage(
    String package, {
    required String appliedHint,
  }) {
    final resolution = readResolution();
    final resolved = resolution.resolvePackage(
      package,
      requireDirectDependency: false,
    );
    if (_isPackageApplied(package, resolved)) {
      throw PatchworkException(
        'Package "$package" already has an applied Patchwork patch.',
        code: 'patch.package_applied',
        hint: appliedHint,
      );
    }
    return resolved;
  }

  _SeedPatch? _seedForPatchRef({
    required String package,
    required String resolvedVersion,
    required PatchRef? fromPatch,
  }) {
    if (fromPatch == null) {
      return null;
    }
    final patchVersion = fromPatch.version ?? resolvedVersion;
    if (fromPatch.version != null) {
      checkSafePathSegment(
        patchVersion,
        label: 'Patch version',
        code: 'patch.continue_version_invalid',
      );
    }
    return _readSeedPatch(
      package: package,
      version: patchVersion,
      missingCode: 'patch.continue_patch_missing',
    );
  }

  _SeedPatch _readSeedPatch({
    required String package,
    required String version,
    required String missingCode,
  }) {
    final patchPath = layout.patchPath(package, version);
    final patch = File(patchPath);
    if (!patch.existsSync()) {
      throw PatchworkException(
        'Patch file does not exist for "$package@$version".',
        code: missingCode,
        location: patchPath,
      );
    }
    return _SeedPatch(path: patchPath, content: patch.readAsStringSync());
  }

  String _carryPatchVersion({
    required String package,
    required String currentVersion,
    required String? fromVersion,
    required PatchworkArtifactInventory inventory,
  }) {
    if (fromVersion != null) {
      final patchPath = layout.patchPath(package, fromVersion);
      final patchFile = File(patchPath);
      if (!patchFile.existsSync()) {
        throw PatchworkException(
          'Patch file does not exist for "$package@$fromVersion".',
          code: 'carry.patch_missing',
          location: patchPath,
        );
      }
      if (fromVersion == currentVersion) {
        throw PatchworkException(
          'Patch file for "$package@$fromVersion" already matches the current pub resolution.',
          code: 'carry.patch_not_stale',
          hint:
              'Run patchwork patch $package --continue if you want to edit the current patch.',
          location: patchPath,
        );
      }
      return fromVersion;
    }

    final stalePatches = inventory
        .patchesFor(package)
        .where((patch) => patch.version != currentVersion)
        .toList();
    if (stalePatches.isEmpty) {
      final currentPatchPath = layout.patchPath(package, currentVersion);
      final hasCurrentPatch = File(currentPatchPath).existsSync();
      throw PatchworkException(
        'No stale patch exists for "$package".',
        code: 'carry.patch_missing',
        hint: hasCurrentPatch
            ? 'Run patchwork patch $package --continue if you want to edit the current patch.'
            : 'Create a patch for "$package" before carrying it forward.',
      );
    }
    if (stalePatches.length > 1) {
      final versions = stalePatches.map((patch) => patch.version).toList()
        ..sort();
      throw PatchworkException(
        'More than one stale patch exists for "$package".',
        code: 'carry.ambiguous_patch',
        hint: 'Pass --from with one of: ${versions.join(', ')}.',
      );
    }
    return stalePatches.single.version;
  }

  void _rejectPatchOverride(String package, ResolvedPubPackage resolved) {
    rejectBlockingOverride(
      overrideState: readOverrideState(),
      package: package,
      command: 'patch',
      targetPath: layout.appliedPath(package, resolved.version),
    );
  }

  bool _isPackageApplied(String package, ResolvedPubPackage resolved) {
    if (resolvesToPatchworkAppliedPath(
      rootPath: rootPath,
      appliedPaths: appliedPaths,
      appliedMarkerStore: appliedMarkerStore,
      package: package,
      version: resolved.version,
      resolved: resolved,
    )) {
      return true;
    }
    return pubspecOverrides.pointsToPath(
      workspaceRootPath: rootPath,
      package: package,
      path: layout.relativeAppliedPath(package, resolved.version),
    );
  }
}

/// A fully checked request to materialize an edit directory.
final class EditPlan {
  /// Creates an edit plan.
  const EditPlan({
    required this.package,
    required this.resolved,
    required this.continuedFromPatchPath,
    required this.continuedFromPatchContent,
    required this.replaceExisting,
    required this.preserveFailedPatchApply,
    required this.partialPatchApply,
  });

  /// Package being edited.
  final String package;

  /// Current pub resolution used as the edit baseline.
  final ResolvedPubPackage resolved;

  /// Patch file applied into the edit tree, if any.
  final String? continuedFromPatchPath;

  /// Patch file content applied into the edit tree, if any.
  final String? continuedFromPatchContent;

  /// Whether a safe existing edit directory may be replaced.
  final bool replaceExisting;

  /// Whether failed full patch application should keep a repairable edit tree.
  final bool preserveFailedPatchApply;

  /// Whether carry should keep clean hunks and write reject repair metadata.
  final bool partialPatchApply;
}

final class _SeedPatch {
  const _SeedPatch({required this.path, required this.content});

  final String path;
  final String content;
}
