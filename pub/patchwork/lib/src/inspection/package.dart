import 'dart:io';

import 'package:path/path.dart' as p;

import '../state/applied_marker.dart';
import '../state/edit_session.dart';
import '../error.dart';
import 'model.dart';
import '../pub/resolution.dart';
import '../state/applied_marker_reader.dart';
import '../apply/freshness.dart';
import '../state/applied_path_policy.dart';
import '../state/applied_resolution.dart';
import '../state/dependency_override_state.dart';
import '../patch/hash.dart';
import '../state/path_layout.dart';
import '../state/project_paths.dart';

/// Builds diagnostics for one package represented in Patchwork state.
final class PackageInspector {
  /// Creates a package inspector for one Patchwork state root.
  const PackageInspector({
    required String rootPath,
    required PathLayout layout,
    required EditSessionStore editSessionStore,
    required AppliedMarkerStore appliedMarkerStore,
    required AppliedPathPolicy appliedPaths,
  }) : _rootPath = rootPath,
       _layout = layout,
       _editSessionStore = editSessionStore,
       _appliedMarkerStore = appliedMarkerStore,
       _appliedPaths = appliedPaths;

  final String _rootPath;
  final PathLayout _layout;
  final EditSessionStore _editSessionStore;
  final AppliedMarkerStore _appliedMarkerStore;
  final AppliedPathPolicy _appliedPaths;

  /// Inspects the artifacts and pub state for [package].
  PatchStatus inspect({
    required String package,
    required List<PackageVersionPath> edit,
    required List<PackageVersionPath> patchFiles,
    required List<PackageVersionPath> appliedDirectories,
    required PubResolution? resolution,
    required PatchworkException? resolutionError,
    required DependencyOverrideState overrideState,
  }) {
    final problems = <PatchProblem>[];
    if (edit.length > 1) {
      problems.add(
        PatchProblem(
          code: 'commit.ambiguous_edit',
          message: 'More than one edit directory exists for "$package".',
          hint:
              'Commit or delete the extra .patchwork/$package@<version> directories.',
        ),
      );
    }

    ResolvedPubPackage? resolved;
    var pubResolutionPointsToApplied = false;
    var pubResolutionMatchesSource = false;

    if (resolutionError != null) {
      problems.add(
        PatchProblem(
          code: resolutionError.code,
          message: resolutionError.message,
          hint: resolutionError.hint,
        ),
      );
    } else if (resolution != null) {
      try {
        resolved = resolution.resolvePackage(
          package,
          requireDirectDependency: false,
        );
        pubResolutionPointsToApplied = resolvesToPatchworkAppliedPath(
          rootPath: _rootPath,
          appliedPaths: _appliedPaths,
          appliedMarkerStore: _appliedMarkerStore,
          package: package,
          version: resolved.version,
          resolved: resolved,
        );
        pubResolutionMatchesSource = !pubResolutionPointsToApplied;
      } on PatchworkException catch (error) {
        problems.add(
          PatchProblem(
            code: error.code,
            message: error.message,
            hint: error.hint,
          ),
        );
      }
    }

    final version =
        resolved?.version ??
        (edit.isNotEmpty
            ? edit.first.version
            : patchFiles.isNotEmpty
            ? patchFiles.first.version
            : appliedDirectories.isNotEmpty
            ? appliedDirectories.first.version
            : 'unknown');
    final patchPath = _layout.patchPath(package, version);
    final hasPatchFile = patchFiles.any(
      (patch) => patch.version == version && p.equals(patch.path, patchPath),
    );
    final patchSha256 = hasPatchFile
        ? sha256Hex(File(patchPath).readAsBytesSync())
        : null;

    if (edit.length == 1) {
      final editHasPatchFile = patchFiles.any(
        (patch) => patch.version == edit.single.version,
      );
      try {
        _editSessionStore.read(edit.single);
      } on PatchworkException catch (error) {
        problems.add(
          PatchProblem(
            code: error.code,
            message: error.message,
            hint: error.hint,
            remediationVersion: edit.single.version,
            remediationCanContinuePatch: editHasPatchFile,
          ),
        );
      }
    }

    AppliedMarker? applied;
    final appliedForVersion = appliedDirectories
        .where((candidate) => candidate.version == version)
        .toList();
    final markerlessOverridePointsToApplied =
        appliedForVersion.isNotEmpty &&
        overrideState.rootOverridePointsToPath(
          package: package,
          path: _layout.relativeAppliedPath(package, version),
        );
    if (appliedForVersion.isNotEmpty) {
      try {
        applied = _appliedMarkerStore.read(package, version);
      } on PatchworkException catch (error) {
        problems.add(
          PatchProblem(
            code: error.code,
            message: error.message,
            hint: error.hint,
            remediationRequiresOverrideCleanup:
                markerlessOverridePointsToApplied,
          ),
        );
      }
      if (applied == null) {
        problems.add(
          PatchProblem(
            code: 'applied.marker_missing',
            message:
                'Generated Patchwork output exists without an ownership marker.',
            hint:
                'Remove ${_relativePath(_layout.appliedPath(package, version))} before applying again if it is safe.',
            remediationRequiresOverrideCleanup:
                markerlessOverridePointsToApplied,
          ),
        );
      }
    }
    for (final appliedDirectory in appliedDirectories) {
      if (appliedDirectory.version == version) {
        continue;
      }
      final staleAppliedMarker = tryReadAppliedMarker(
        _appliedMarkerStore,
        appliedDirectory,
      );
      final staleAppliedCanPrune =
          staleAppliedMarker != null &&
          _patchworkAppliedPath(staleAppliedMarker) != null;
      problems.add(
        PatchProblem(
          code: 'applied.stale',
          message:
              'Generated output ${_relativePath(appliedDirectory.path)} targets "$package@${appliedDirectory.version}", but current state is "$package@$version".',
          hint: 'Run patchwork prune to remove unreferenced generated output.',
          remediationVersion: appliedDirectory.version,
          remediationRequiresManualCleanup: !staleAppliedCanPrune,
        ),
      );
    }

    final editVersion = edit.length == 1 ? edit.single.version : null;
    if (!hasPatchFile && edit.isNotEmpty) {
      problems.add(
        PatchProblem(
          code: 'commit.open_edit',
          message: 'Package "$package" has an uncommitted edit directory.',
          hint: editVersion == null
              ? 'Run patchwork commit $package after removing any extra edit directories.'
              : 'Run patchwork commit $package, or patchwork remove $package $editVersion --force to discard it.',
          remediationVersion: editVersion,
        ),
      );
    } else if (edit.isNotEmpty) {
      problems.add(
        PatchProblem(
          code: 'apply.open_edit',
          message: 'Package "$package" has an open edit directory.',
          hint: 'Run patchwork commit $package before applying this patch.',
          remediationVersion: editVersion,
        ),
      );
    }
    if (resolved != null) {
      for (final patch in patchFiles) {
        if (patch.version == resolved.version) {
          continue;
        }
        problems.add(
          PatchProblem(
            code: 'patch.stale',
            message:
                'Patch file ${_relativePath(patch.path)} targets "$package@${patch.version}", but current pub resolution is "$package@${resolved.version}".',
            hint:
                'Use patchwork carry $package --from ${patch.version} to carry it forward, or patchwork remove $package ${patch.version} to remove it.',
            remediationVersion: patch.version,
          ),
        );
      }
    }

    final appliedPathInProject = applied == null
        ? (appliedForVersion.isEmpty
              ? null
              : _defaultPatchworkAppliedPath(package, version))
        : _patchworkAppliedPath(applied);
    final appliedAbsolutePath = applied == null
        ? appliedPathInProject
        : _appliedPaths.absoluteFromRoot(applied.path);
    final appliedExists =
        appliedPathInProject != null &&
        Directory(appliedPathInProject).existsSync();
    final overridePointsToApplied =
        applied != null &&
        overrideState.rootOverridePointsToPath(
          package: package,
          path: applied.path,
        );
    final hasBlockingOverride =
        hasPatchFile &&
        ((applied == null &&
                overrideState.blockingConflict(
                      package: package,
                      targetPath: _layout.appliedPath(package, version),
                    ) !=
                    null) ||
            overrideState.hasForeignOverride(package, applied));
    final repairHint = pubResolutionMatchesSource
        ? 'Run patchwork apply $package.'
        : 'Run patchwork undo $package, dart pub get, then patchwork apply $package.';
    final repairRequiresUndoFirst = !pubResolutionMatchesSource;
    if (hasBlockingOverride) {
      problems.add(
        PatchProblem(
          code: 'pub.override_conflict',
          message:
              'A project file already has a dependency override for "$package".',
          hint:
              'Remove or resolve the existing override before running patchwork apply $package.',
        ),
      );
    }
    if (applied != null && !appliedExists) {
      problems.add(
        PatchProblem(
          code: 'applied.output_missing',
          message:
              'Applied marker exists, but the generated directory is missing.',
          hint: repairHint,
          remediationRequiresUndoFirst: repairRequiresUndoFirst,
        ),
      );
    }
    if (applied != null && !hasPatchFile) {
      problems.add(
        PatchProblem(
          code: 'applied.patch_missing',
          message:
              'An applied patch is recorded, but no committed patch exists.',
          hint: 'Run patchwork undo $package and dart pub get.',
        ),
      );
    }
    if (applied != null &&
        overridePointsToApplied &&
        resolved != null &&
        !pubResolutionPointsToApplied) {
      problems.add(
        const PatchProblem(
          code: 'applied.pub_get_required',
          message:
              'pub resolution has not been refreshed for the applied patch.',
          hint: 'Run dart pub get.',
        ),
      );
    }
    if (applied != null &&
        patchSha256 != null &&
        applied.patchSha256 != patchSha256) {
      problems.add(
        PatchProblem(
          code: 'applied.patch_stale',
          message: 'Applied patch sha256 differs from the committed patch.',
          hint: repairHint,
          remediationRequiresUndoFirst: repairRequiresUndoFirst,
        ),
      );
    }
    if (applied != null &&
        resolved != null &&
        !pubResolutionPointsToApplied &&
        applied.source != null &&
        applied.source != resolved.source) {
      problems.add(
        PatchProblem(
          code: 'applied.source_stale',
          message: 'Applied output was generated from a different source tree.',
          hint: repairHint,
          remediationRequiresUndoFirst: repairRequiresUndoFirst,
        ),
      );
    }
    if (applied != null && appliedPathInProject == null) {
      problems.add(
        PatchProblem(
          code: 'undo.applied_path_not_deletable',
          message: 'Applied output path cannot be safely deleted.',
          hint: 'Remove the generated output manually after reviewing it.',
        ),
      );
    }
    if (applied != null && !overridePointsToApplied) {
      problems.add(
        PatchProblem(
          code: 'applied.override_missing',
          message:
              'pubspec_overrides.yaml no longer points at the applied patch.',
          hint: repairHint,
          remediationRequiresUndoFirst: repairRequiresUndoFirst,
        ),
      );
    }

    return PatchStatus(
      package: package,
      version: version,
      editPath: _layout.editPath(package, version),
      patchPath: patchPath,
      appliedPath: appliedAbsolutePath,
      hasOpenEdit: edit.isNotEmpty,
      hasPatch: hasPatchFile,
      needsApply:
          hasPatchFile &&
          edit.isEmpty &&
          resolved != null &&
          resolved.version == version &&
          pubResolutionMatchesSource &&
          !hasBlockingOverride &&
          patchSha256 != null &&
          (appliedForVersion.isEmpty ||
              (applied != null &&
                  appliedPatchNeedsRefresh(
                    package: package,
                    version: version,
                    patchSha256: patchSha256,
                    source: resolved.source,
                    applied: applied,
                    appliedPaths: _appliedPaths,
                    overrideState: overrideState,
                  ))),
      problems: problems,
    );
  }

  String _relativePath(String path) {
    return relativeToProjectRoot(rootPath: _rootPath, path: path);
  }

  String? _patchworkAppliedPath(AppliedMarker marker) {
    return _appliedPaths.patchworkAppliedPathForMarker(marker);
  }

  String? _defaultPatchworkAppliedPath(String package, String version) {
    return _appliedPaths.patchworkAppliedPath(
      package,
      version,
      _layout.relativeAppliedPath(package, version),
    );
  }
}
