import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../applied_marker.dart';
import '../edit_session.dart';
import '../error.dart';
import '../model.dart';
import '../pub/package_resolution.dart';
import 'applied_patch_freshness.dart';
import 'applied_path_policy.dart';
import 'artifact_inventory.dart';
import 'dependency_override_state.dart';
import 'path_layout.dart';

/// Builds read-only Patchwork state diagnostics for status and doctor output.
final class PatchworkStateInspector {
  /// Creates an inspector for one Patchwork state root.
  const PatchworkStateInspector({
    required this._rootPath,
    required this._currentPackageRootPath,
    required this._layout,
    required this._pubResolutionReader,
    required this._editSessionStore,
    required this._appliedMarkerStore,
    required this._appliedPaths,
    required this._readOverrideState,
  });

  final String _rootPath;
  final String _currentPackageRootPath;
  final PathLayout _layout;
  final PubResolutionReader _pubResolutionReader;
  final EditSessionStore _editSessionStore;
  final AppliedMarkerStore _appliedMarkerStore;
  final AppliedPathPolicy _appliedPaths;
  final DependencyOverrideState Function() _readOverrideState;

  /// Inspects edit directories, patch files, applied output, and pub state.
  Future<PatchworkState> inspect() async {
    final inventory = PatchworkArtifactInventory.read(_layout);
    final packages = inventory.packages;
    if (packages.isEmpty) {
      return const PatchworkState(packages: []);
    }

    final statuses = <PatchStatus>[];
    PubResolution? resolution;
    PatchworkException? resolutionError;
    try {
      resolution = _readResolution();
    } on PatchworkException catch (error) {
      resolutionError = error;
    }

    final overrideState = _readOverrideState();
    for (final package in packages) {
      statuses.add(
        _inspectPackage(
          package: package,
          edit: inventory.editsFor(package),
          patchFiles: inventory.patchesFor(package),
          appliedDirectories: inventory.appliedFor(package),
          resolution: resolution,
          resolutionError: resolutionError,
          overrideState: overrideState,
        ),
      );
    }
    return PatchworkState(packages: statuses);
  }

  PatchStatus _inspectPackage({
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
        pubResolutionPointsToApplied = _resolvesToAppliedPath(
          package,
          resolved.version,
          resolved,
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
        ? _sha256(File(patchPath).readAsBytesSync())
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
      final staleAppliedMarker = _tryReadAppliedMarker(appliedDirectory);
      final staleAppliedCanPrune =
          staleAppliedMarker != null &&
          _appliedPaths.patchworkAppliedPath(
                package,
                appliedDirectory.version,
                staleAppliedMarker.path,
              ) !=
              null;
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
              : _appliedPaths.patchworkAppliedPath(
                  package,
                  version,
                  _layout.relativeAppliedPath(package, version),
                ))
        : _appliedPaths.patchworkAppliedPath(package, version, applied.path);
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

  PubResolution _readResolution() {
    return _pubResolutionReader.readFromDirectory(_currentPackageRootPath);
  }

  bool _resolvesToAppliedPath(
    String package,
    String version,
    ResolvedPubPackage resolved,
  ) {
    final marker = _appliedMarkerStore.read(package, version);
    if (marker == null) {
      return false;
    }
    final absoluteAppliedPath = _appliedPaths.patchworkAppliedPath(
      package,
      version,
      marker.path,
    );
    return absoluteAppliedPath != null &&
        p.equals(
          p.normalize(p.absolute(_rootPath, resolved.rootPath)),
          absoluteAppliedPath,
        );
  }

  AppliedMarker? _tryReadAppliedMarker(PackageVersionPath appliedDirectory) {
    try {
      return _appliedMarkerStore.read(
        appliedDirectory.package,
        appliedDirectory.version,
      );
    } on PatchworkException {
      return null;
    }
  }

  String _relativePath(String path) {
    final absolute = p.normalize(p.absolute(path));
    final root = p.normalize(p.absolute(_rootPath));
    if (p.equals(root, absolute)) {
      return '.';
    }
    if (p.isWithin(root, absolute)) {
      return p.posix.joinAll(p.split(p.relative(absolute, from: root)));
    }
    return path;
  }
}

String _sha256(List<int> bytes) {
  return sha256.convert(bytes).toString();
}
