import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'applied_marker.dart';
import 'edit_session.dart';
import 'error.dart';
import 'internal/applied_patch_freshness.dart';
import 'internal/applied_patch_activation.dart';
import 'internal/applied_patch_materializer.dart';
import 'internal/applied_path_policy.dart';
import 'internal/artifact_inventory.dart';
import 'internal/dependency_override_state.dart';
import 'internal/edit_preparer.dart';
import 'internal/package_tree.dart';
import 'internal/overlay_inspector.dart';
import 'internal/overlay_publisher.dart';
import 'internal/path_layout.dart';
import 'internal/patch_committer.dart';
import 'internal/setup_inspector.dart';
import 'internal/state_inspector.dart';
import 'model.dart';
import 'patch_file.dart';
import 'pub/package_resolution.dart';
import 'pub/pubspec_dependency_overrides.dart';
import 'pub/pubspec_overrides.dart';
import 'pub/pub_workspace.dart';

const _invalidAppliedPathMessage =
    'Applied output must point at the generated Patchwork output for this package.';

/// Performs Patchwork operations for one Dart package or workspace.
///
/// A [Patchwork] instance is rooted at the pub resolution discovered by
/// [open]. Each operation re-reads the relevant project files before changing
/// state, so callers may keep the instance for a command sequence without using
/// it as an in-memory cache.
///
/// Patchwork keeps three kinds of project-local state:
///
///  * edit directories under `.patchwork/`, created by [patch] and consumed by
///    [commit].
///  * committed patch files under `patches/`, written by [commit] and applied
///    by [apply].
///  * generated package copies under `.dart_tool/patchwork/`, wired into pub by
///    [apply] and removed by [undo].
final class Patchwork {
  Patchwork._({
    required this._rootPath,
    required this._currentPackageRootPath,
    required this._overrideRootPaths,
    required this._layout,
    required this._appliedPaths,
    required this._pubResolutionReader,
    required this._editSessionStore,
    required this._appliedMarkerStore,
    required this._editPreparer,
    required this._committer,
    required this._appliedMaterializer,
    required this._packageTree,
    required this._patchFile,
    required this._pubspecDependencyOverrides,
    required this._pubspecOverrides,
  });

  /// Opens the Patchwork project containing [root].
  ///
  /// [root] may be a [Directory] or path string inside a Dart package or
  /// workspace member. The nearest package root is used as the current package,
  /// while the owning pub resolution root becomes the Patchwork state root.
  ///
  /// Throws a [PatchworkException] if [root] is not a directory or path string,
  /// or if no usable pub project can be found.
  static Future<Patchwork> open(Object root) async {
    final rootPath = switch (root) {
      Directory directory => directory.path,
      String path => path,
      _ => throw PatchworkException(
        'Patchwork.open expects a Directory or path string.',
        code: 'usage.invalid_root',
      ),
    };
    final workspace = const PubWorkspaceLocator().locate(rootPath);
    final layout = PathLayout(workspace.rootPath);
    final editSessionStore = EditSessionStore(layout: layout);
    const packageTree = PackageTree();
    const patchFile = PatchFile();
    return Patchwork._(
      rootPath: workspace.rootPath,
      currentPackageRootPath: workspace.currentPackageRootPath,
      overrideRootPaths: workspace.rootPackageRootPaths,
      layout: layout,
      appliedPaths: AppliedPathPolicy(
        rootPath: workspace.rootPath,
        layout: layout,
        protectedRootPaths: workspace.rootPackageRootPaths,
      ),
      pubResolutionReader: const PubResolutionReader(),
      editSessionStore: editSessionStore,
      appliedMarkerStore: AppliedMarkerStore(layout: layout),
      editPreparer: EditPreparer(
        rootPath: workspace.rootPath,
        layout: layout,
        packageTree: packageTree,
        patchFile: patchFile,
        editSessionStore: editSessionStore,
      ),
      committer: PatchCommitter(
        layout: layout,
        editSessionStore: editSessionStore,
        packageTree: packageTree,
        patchFile: patchFile,
      ),
      appliedMaterializer: AppliedPatchMaterializer(
        layout: layout,
        packageTree: packageTree,
        patchFile: patchFile,
      ),
      packageTree: packageTree,
      patchFile: patchFile,
      pubspecDependencyOverrides: const PubspecDependencyOverrides(),
      pubspecOverrides: const PubspecOverrides(),
    );
  }

  final String _rootPath;
  final String _currentPackageRootPath;
  final Set<String> _overrideRootPaths;
  final PathLayout _layout;
  final AppliedPathPolicy _appliedPaths;
  final PubResolutionReader _pubResolutionReader;
  final EditSessionStore _editSessionStore;
  final AppliedMarkerStore _appliedMarkerStore;
  final EditPreparer _editPreparer;
  final PatchCommitter _committer;
  final AppliedPatchMaterializer _appliedMaterializer;
  final PackageTree _packageTree;
  final PatchFile _patchFile;
  final PubspecDependencyOverrides _pubspecDependencyOverrides;
  final PubspecOverrides _pubspecOverrides;

  /// Returns [path] relative to the Patchwork state root when possible.
  ///
  /// This is a presentation helper for CLI output. Absolute paths outside the
  /// project are returned unchanged so callers do not lose information.
  String relativePath(String path) {
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

  /// Inspects repository setup recommendations without mutating files.
  ///
  /// The report focuses on Patchwork's project contract: commit patch files,
  /// ignore generated edit and activation state, and use high-level commands in
  /// CI unless a script intentionally handles pub resolution itself.
  Future<SetupReport> inspectSetup() async {
    return SetupInspector(
      rootPath: _rootPath,
      currentPackageRootPath: _currentPackageRootPath,
    ).inspect();
  }

  /// Inspects package-provided overlay discovery without mutating files.
  ///
  /// The report explains provider manifests, match and skip reasons, root patch
  /// contribution, deduplication, composition order, and conflicts using the
  /// current pub resolution.
  Future<OverlayInspection> inspectOverlays() async {
    return OverlayInspector(rootPath: _rootPath, layout: _layout).inspect();
  }

  /// Creates an editable copy for [package] under `.patchwork/`.
  ///
  /// When [fromPatch] is provided, the matching committed patch is applied to
  /// the fresh edit directory as a seed. Set [replaceExisting] to discard an
  /// existing edit directory that Patchwork can prove is either unchanged from
  /// the source or already represented by the committed patch.
  ///
  /// The package must be a direct dependency of the current package and must not
  /// already resolve to Patchwork generated output. The edit directory carries a
  /// hidden baseline snapshot used later by [commit].
  Future<PreparedEdit> patch(
    String package, {
    PatchRef? fromPatch,
    bool replaceExisting = false,
  }) async {
    return _prepareEdit(
      package,
      fromPatch: fromPatch,
      replaceExisting: replaceExisting,
      preserveFailedPatchApply: false,
      partialPatchApply: false,
    );
  }

  Future<PreparedEdit> _prepareEdit(
    String package, {
    required PatchRef? fromPatch,
    required bool replaceExisting,
    required bool preserveFailedPatchApply,
    required bool partialPatchApply,
  }) async {
    _checkPlainPackageName(package);
    final resolution = _readResolution();
    final resolved = resolution.resolvePackage(package);
    if (_isPackageApplied(package, resolved)) {
      throw PatchworkException(
        'Package "$package" already has an applied Patchwork patch.',
        code: 'patch.package_applied',
        hint:
            'Run patchwork undo $package, then dart pub get, before patching it again.',
      );
    }
    _rejectBlockingOverride(
      package: package,
      command: 'patch',
      targetPath: _layout.appliedPath(package, resolved.version),
    );

    String? continuedFromPatchPath;
    String? continuedFromPatchContent;
    if (fromPatch != null) {
      final patchVersion = fromPatch.version ?? resolved.version;
      if (fromPatch.version != null) {
        _checkSafePatchVersionSegment(patchVersion);
      }
      final patchPath = _layout.patchPath(package, patchVersion);
      final patch = File(patchPath);
      if (!patch.existsSync()) {
        throw PatchworkException(
          'Patch file does not exist for "$package@$patchVersion".',
          code: 'patch.continue_patch_missing',
          location: patchPath,
        );
      }
      continuedFromPatchContent = patch.readAsStringSync();
      continuedFromPatchPath = patchPath;
    }

    return _editPreparer.prepare(
      package: package,
      resolved: resolved,
      continuedFromPatchPath: continuedFromPatchPath,
      continuedFromPatchContent: continuedFromPatchContent,
      replaceExisting: replaceExisting,
      preserveFailedPatchApply: preserveFailedPatchApply,
      partialPatchApply: partialPatchApply,
    );
  }

  /// Carries a stale committed patch for [package] into the current resolution.
  ///
  /// When [fromVersion] is omitted, exactly one stale patch file must exist for
  /// [package]. The result is an ordinary edit directory for the current resolved
  /// package version; callers should review it and then run [commit].
  Future<PreparedEdit> carry(
    String package, {
    String? fromVersion,
    bool partial = false,
  }) async {
    _checkPlainPackageName(package);
    if (fromVersion != null) {
      _checkSafePatchVersionSegment(fromVersion);
    }

    final resolution = _readResolution();
    final resolved = resolution.resolvePackage(package);
    final inventory = PatchworkArtifactInventory.read(_layout);
    if (_isPackageApplied(package, resolved)) {
      throw PatchworkException(
        'Package "$package" already has an applied Patchwork patch.',
        code: 'patch.package_applied',
        hint:
            'Run patchwork undo $package, then dart pub get, before carrying it forward.',
      );
    }
    final selectedVersion = _carryPatchVersion(
      package: package,
      currentVersion: resolved.version,
      fromVersion: fromVersion,
      inventory: inventory,
    );
    return _prepareEdit(
      package,
      fromPatch: PatchRef.version(selectedVersion),
      replaceExisting: false,
      preserveFailedPatchApply: true,
      partialPatchApply: partial,
    );
  }

  /// Commits the open edit directory for [package] into `patches/`.
  ///
  /// The edit is diffed against its hidden baseline snapshot. Empty diffs
  /// remove the committed patch file, unchanged edits are discarded, and real
  /// changes are validated before the patch file is written.
  Future<PatchWrite> commit(String package) async {
    _checkPlainPackageName(package);
    return _committer.commit(package);
  }

  /// Commits every open edit directory in package-name order.
  ///
  /// Returns an empty list when there are no open edits.
  Future<List<PatchWrite>> commitAll() async {
    return _committer.commitAll();
  }

  /// Registers the committed patch for [package] in the current package's
  /// `patchwork.yaml` overlay manifest.
  ///
  /// The target package must have a committed patch file for the current pub
  /// resolution, and the current package must have `patchwork` as a regular
  /// dependency so downstream consumers receive Patchwork's hook.
  Future<RegisteredOverlay> overlay(String package, {String? reason}) async {
    _checkPlainPackageName(package);
    return OverlayPublisher(
      currentPackageRootPath: _currentPackageRootPath,
      layout: _layout,
      pubResolutionReader: _pubResolutionReader,
    ).overlay(package, reason: reason);
  }

  /// Applies every committed patch that needs generated output.
  ///
  /// Packages with open edit directories are rejected before any output is
  /// generated, because applying while edits are uncommitted would make the
  /// project state ambiguous.
  Future<List<AppliedPatch>> applyAll() async {
    final applied = <AppliedPatch>[];
    for (final package in await _packagesNeedingApply()) {
      applied.add(await apply(package));
    }
    return applied;
  }

  Future<List<String>> _packagesNeedingApply() async {
    final inventory = PatchworkArtifactInventory.read(_layout);
    final patches = inventory.patchFiles;
    if (patches.isEmpty) {
      return const [];
    }

    final resolution = _readResolution();
    final overrideState = _overrideState();
    final packages = <String>[];
    for (final patch in patches) {
      final package = patch.package;
      late final ResolvedPubPackage resolved;
      try {
        resolved = resolution.resolvePackage(
          package,
          requireDirectDependency: false,
        );
      } on PatchworkException catch (error) {
        if (error.code == 'pub.package_not_found') {
          continue;
        }
        rethrow;
      }
      if (resolved.version != patch.version) {
        continue;
      }

      final openEdits = inventory.editsFor(package);
      if (openEdits.isNotEmpty) {
        throw PatchworkException(
          'Package "$package" has an open edit directory.',
          code: 'apply.open_edit',
          hint: 'Run patchwork commit $package before applying.',
          location: openEdits.first.path,
        );
      }

      final applied = _appliedMarkerStore.read(package, patch.version);
      if (applied != null &&
          _appliedPaths.patchworkAppliedPath(
                package,
                patch.version,
                applied.path,
              ) ==
              null) {
        throw PatchworkException(
          _invalidAppliedPathMessage,
          code: 'apply.applied_path_not_deletable',
          location: applied.path,
        );
      }
      if (overrideState.hasForeignOverride(package, applied)) {
        throw PatchworkException(
          'A project file already has a dependency override for "$package".',
          code: 'pub.override_conflict',
          hint:
              'Remove or resolve the existing override before running patchwork apply $package.',
        );
      }
      if (_resolvesToAppliedPath(package, patch.version, resolved)) {
        continue;
      }
      if (applied == null &&
          overrideState.blockingConflict(
                package: package,
                targetPath: _layout.appliedPath(package, patch.version),
              ) !=
              null) {
        _rejectBlockingOverride(
          package: package,
          command: 'apply',
          targetPath: _layout.appliedPath(package, patch.version),
          overrideState: overrideState,
        );
      }
      final patchBytes = File(patch.path).readAsBytesSync();
      final patchSha256 = _sha256(patchBytes);
      if (appliedPatchNeedsRefresh(
        package: package,
        version: patch.version,
        patchSha256: patchSha256,
        source: resolved.source,
        applied: applied,
        appliedPaths: _appliedPaths,
        overrideState: overrideState,
      )) {
        _patchFile.validate(
          sourcePath: resolved.rootPath,
          patchContent: utf8.decode(patchBytes),
        );
        packages.add(package);
      }
    }
    return packages;
  }

  /// Applies the committed patch for [package] into generated output.
  ///
  /// The patch is applied to a fresh copy of the resolved source and then moved
  /// into `.dart_tool/patchwork/` atomically with respect to the final
  /// directory. The method also updates `pubspec_overrides.yaml`; callers should
  /// run `dart pub get` afterwards so pub resolves the generated package.
  Future<AppliedPatch> apply(String package) async {
    _checkPlainPackageName(package);
    final inventory = PatchworkArtifactInventory.read(_layout);
    final openEdits = inventory.editsFor(package);
    if (openEdits.isNotEmpty) {
      throw PatchworkException(
        'Package "$package" has an open edit directory.',
        code: 'apply.open_edit',
        hint: 'Run patchwork commit $package before applying.',
        location: openEdits.first.path,
      );
    }

    final resolution = _readResolution();
    final resolved = resolution.resolvePackage(
      package,
      requireDirectDependency: false,
    );
    if (_resolvesToAppliedPath(package, resolved.version, resolved)) {
      throw PatchworkException(
        'Package "$package" still resolves to the applied Patchwork output.',
        code: 'applied.pub_get_required',
        hint:
            'Run patchwork undo $package, then dart pub get, before applying again.',
        location: resolved.rootPath,
      );
    }
    final patchPath = _layout.patchPath(package, resolved.version);
    final patchBytes = _readCommittedPatchBytes(package, resolved.version);
    final patchSha256 = _sha256(patchBytes);
    final existingApplied = _appliedMarkerStore.read(package, resolved.version);

    final appliedRecordPath = _layout.relativeAppliedPath(
      package,
      resolved.version,
    );
    final appliedPath = existingApplied == null
        ? _layout.appliedPath(package, resolved.version)
        : _appliedPaths.requirePatchworkAppliedPath(
            package,
            resolved.version,
            existingApplied.path,
            code: 'apply.applied_path_not_deletable',
            message: _invalidAppliedPathMessage,
          );
    final overrideState = _overrideState();
    _rejectBlockingOverride(
      package: package,
      command: 'apply',
      targetPath: appliedPath,
      replaceRootOverride: existingApplied != null,
      overrideState: overrideState,
    );
    if (existingApplied == null && Directory(appliedPath).existsSync()) {
      throw PatchworkException(
        'Applied output path already exists for "$package".',
        code: 'apply.applied_path_exists',
        hint:
            'Patchwork cannot replace it without a matching applied output marker.',
        location: appliedPath,
      );
    }
    _appliedMaterializer.materialize(
      package: package,
      version: resolved.version,
      sourcePath: resolved.rootPath,
      appliedPath: appliedPath,
      patchContent: utf8.decode(patchBytes),
    );

    _appliedActivation().activate(
      package: package,
      version: resolved.version,
      patchSha256: patchSha256,
      path: appliedRecordPath,
      source: resolved.source,
    );

    return AppliedPatch(
      package: package,
      version: resolved.version,
      path: appliedPath,
      patchPath: patchPath,
    );
  }

  /// Removes Patchwork-generated output and override state for [package].
  ///
  /// The override is removed only if it still points at the path recorded by
  /// Patchwork. User-owned overrides and paths outside the generated Patchwork
  /// output tree are left untouched or rejected.
  Future<UnappliedPatch> undo(String package) async {
    _checkPlainPackageName(package);
    final applied = _appliedMarkersForPackage(package);
    if (applied.isEmpty) {
      return UnappliedPatch(package: package, changed: false);
    }
    if (applied.length > 1) {
      throw PatchworkException(
        'More than one applied output marker exists for "$package".',
        code: 'undo.ambiguous_applied',
        hint:
            'Remove stale .dart_tool/patchwork/$package@<version> directories before undoing.',
      );
    }
    final marker = applied.single;

    final absoluteAppliedPath = _appliedActivation().remove(
      marker,
      code: 'undo.applied_path_not_deletable',
    );

    return UnappliedPatch(
      package: package,
      changed: true,
      path: absoluteAppliedPath,
    );
  }

  /// Removes Patchwork artifacts for [package] and optional [version].
  ///
  /// By default this refuses to discard open edit directories or applied output
  /// markers. Set [force] to explicitly remove those local states too. When
  /// [dryRun] is true, the returned changes are planned but no files are
  /// modified.
  Future<CleanupResult> remove(
    String package, {
    String? version,
    bool dryRun = false,
    bool force = false,
  }) async {
    _checkPlainPackageName(package);
    final inventory = PatchworkArtifactInventory.read(_layout);
    final selectedVersion = _removeVersion(package, version, inventory);
    final changes = <CleanupChange>[];
    final appliedMarkers = <AppliedMarker>[];

    final patchPath = _layout.patchPath(package, selectedVersion);
    if (File(patchPath).existsSync()) {
      changes.add(
        CleanupChange(
          kind: CleanupChangeKind.patchFile,
          package: package,
          version: selectedVersion,
          path: patchPath,
        ),
      );
    }

    final edit = inventory.edit(package, selectedVersion);
    if (edit != null) {
      if (!force) {
        throw PatchworkException(
          'Package "$package@$selectedVersion" has an open edit directory.',
          code: 'remove.open_edit',
          hint: 'Pass --force to discard the edit directory.',
          location: edit.path,
        );
      }
      changes.add(
        CleanupChange(
          kind: CleanupChangeKind.editDirectory,
          package: package,
          version: selectedVersion,
          path: edit.path,
        ),
      );
    }

    final marker = _appliedMarkerStore.read(package, selectedVersion);
    if (marker != null) {
      final overrideState = _overrideState();
      if (!force) {
        throw PatchworkException(
          'Package "$package@$selectedVersion" has applied Patchwork state.',
          code: 'remove.patch_applied',
          hint: 'Run patchwork undo $package first, or pass --force.',
          location: _layout.appliedPath(package, selectedVersion),
        );
      }
      _rejectUserOwnedOverrideForAppliedCleanup(
        marker,
        command: 'remove',
        code: 'remove.active_override',
        overrideState: overrideState,
      );
      _addAppliedCleanupChanges(changes, marker, overrideState: overrideState);
      appliedMarkers.add(marker);
    }

    if (!dryRun) {
      for (final marker in appliedMarkers) {
        _appliedActivation().remove(
          marker,
          code: 'remove.applied_path_not_deletable',
        );
      }
      if (edit != null) {
        _packageTree.deleteDirectory(edit.path);
      }
      final patchFile = File(patchPath);
      if (patchFile.existsSync()) {
        patchFile.deleteSync();
      }
    }

    return CleanupResult(
      command: 'remove',
      dryRun: dryRun,
      force: force,
      changes: List.unmodifiable(changes),
    );
  }

  /// Removes stale Patchwork artifacts that can be proven safe to clean.
  ///
  /// Stale patch files are selected when they no longer match current pub
  /// resolution. Generated output is selected only when its valid marker points
  /// at Patchwork's deterministic generated directory and no active override
  /// references it. Set [force] to also discard open edits or active applied
  /// state associated with stale patches.
  Future<CleanupResult> prune({bool dryRun = false, bool force = false}) async {
    final changes = <CleanupChange>[];
    final appliedMarkers = <AppliedMarker>[];
    final inventory = PatchworkArtifactInventory.read(_layout);
    final seen = <String>{};
    final resolution = _readResolution();
    DependencyOverrideState? overrideState;
    DependencyOverrideState readOverrideState() {
      return overrideState ??= _overrideState();
    }

    for (final patch in inventory.patchFiles) {
      if (_patchMatchesResolution(patch, resolution)) {
        continue;
      }
      final edit = inventory.edit(patch.package, patch.version);
      if (edit != null && !force) {
        throw PatchworkException(
          'Package "${patch.package}@${patch.version}" has an open edit directory.',
          code: 'prune.open_edit',
          hint: 'Pass --force to discard the edit directory.',
          location: edit.path,
        );
      }

      final marker = _appliedMarkerStore.read(patch.package, patch.version);
      final activeAppliedReference =
          marker != null &&
          _appliedOutputHasActiveOverride(
            marker,
            overrideState: readOverrideState(),
          );
      if (activeAppliedReference && !force) {
        throw PatchworkException(
          'Package "${patch.package}@${patch.version}" has applied Patchwork state.',
          code: 'prune.patch_applied',
          hint: 'Run patchwork undo ${patch.package} first, or pass --force.',
          location: _layout.appliedPath(patch.package, patch.version),
        );
      }

      _addCleanupChange(
        changes,
        seen,
        CleanupChange(
          kind: CleanupChangeKind.patchFile,
          package: patch.package,
          version: patch.version,
          path: patch.path,
        ),
      );
      if (edit != null) {
        _addCleanupChange(
          changes,
          seen,
          CleanupChange(
            kind: CleanupChangeKind.editDirectory,
            package: edit.package,
            version: edit.version,
            path: edit.path,
          ),
        );
      }
      if (marker != null && force) {
        _rejectUserOwnedOverrideForAppliedCleanup(
          marker,
          command: 'prune',
          code: 'prune.active_override',
          overrideState: readOverrideState(),
        );
      }
      if (marker != null && (force || !activeAppliedReference)) {
        _addAppliedCleanupChanges(
          changes,
          marker,
          seen: seen,
          overrideState: readOverrideState(),
        );
        appliedMarkers.add(marker);
      }
    }

    for (final appliedDirectory in inventory.appliedDirectories) {
      final marker = _tryReadAppliedMarker(appliedDirectory);
      if (marker == null) {
        continue;
      }
      if (_appliedOutputHasActiveOverride(
        marker,
        overrideState: readOverrideState(),
      )) {
        continue;
      }
      _addAppliedCleanupChanges(
        changes,
        marker,
        seen: seen,
        overrideState: readOverrideState(),
      );
      appliedMarkers.add(marker);
    }

    if (!dryRun) {
      final removedMarkers = <String>{};
      for (final marker in appliedMarkers) {
        final key = '${marker.package}@${marker.version}';
        if (!removedMarkers.add(key)) {
          continue;
        }
        _appliedActivation().remove(
          marker,
          code: 'prune.applied_path_not_deletable',
        );
      }
      for (final change in changes) {
        switch (change.kind) {
          case CleanupChangeKind.patchFile:
            final file = File(change.path);
            if (file.existsSync()) {
              file.deleteSync();
            }
          case CleanupChangeKind.editDirectory:
            _packageTree.deleteDirectory(change.path);
          case CleanupChangeKind.appliedDirectory ||
              CleanupChangeKind.pubspecOverride:
            break;
        }
      }
    }

    return CleanupResult(
      command: 'prune',
      dryRun: dryRun,
      force: force,
      changes: List.unmodifiable(changes),
    );
  }

  /// Inspects edit directories, patch files, applied output, and pub state.
  ///
  /// Unlike command methods, inspection is read-only. Pub resolution errors are
  /// reported as [PatchProblem] entries when possible so `status` and `doctor`
  /// can still explain existing Patchwork state.
  Future<PatchworkState> inspect() async {
    return PatchworkStateInspector(
      rootPath: _rootPath,
      currentPackageRootPath: _currentPackageRootPath,
      layout: _layout,
      pubResolutionReader: _pubResolutionReader,
      editSessionStore: _editSessionStore,
      appliedMarkerStore: _appliedMarkerStore,
      appliedPaths: _appliedPaths,
      readOverrideState: _overrideState,
    ).inspect();
  }

  String _carryPatchVersion({
    required String package,
    required String currentVersion,
    required String? fromVersion,
    required PatchworkArtifactInventory inventory,
  }) {
    if (fromVersion != null) {
      final patchPath = _layout.patchPath(package, fromVersion);
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
      final currentPatchPath = _layout.patchPath(package, currentVersion);
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

  String _removeVersion(
    String package,
    String? version,
    PatchworkArtifactInventory inventory,
  ) {
    if (version != null) {
      _checkSafeRemoveVersionSegment(version);
      return version;
    }

    final versions = inventory.versionsFor(package);
    if (versions.isEmpty) {
      throw PatchworkException(
        'No Patchwork artifacts exist for "$package".',
        code: 'remove.artifact_missing',
        hint: 'Pass an explicit version if you expected a historical artifact.',
      );
    }

    try {
      final resolved = _readResolution().resolvePackage(
        package,
        requireDirectDependency: false,
      );
      if (versions.contains(resolved.version)) {
        return resolved.version;
      }
    } on PatchworkException {
      // Fall back to artifact inventory below. Cleanup can still target stale
      // files when the package no longer resolves.
    }

    if (versions.length == 1) {
      return versions.single;
    }
    final sortedVersions = versions.toList()..sort();
    throw PatchworkException(
      'More than one Patchwork artifact version exists for "$package".',
      code: 'remove.ambiguous_version',
      hint:
          'Pass the version to remove, for example patchwork remove $package ${sortedVersions.first}.',
    );
  }

  bool _patchMatchesResolution(
    PackageVersionPath patch,
    PubResolution resolution,
  ) {
    try {
      final resolved = resolution.resolvePackage(
        patch.package,
        requireDirectDependency: false,
      );
      return resolved.version == patch.version;
    } on PatchworkException catch (error) {
      if (_isStalePatchResolutionError(error)) {
        return false;
      }
      rethrow;
    }
  }

  bool _isStalePatchResolutionError(PatchworkException error) {
    return error.code == 'pub.package_not_found' ||
        error.code == 'pub.package_is_project' ||
        error.code == 'pub.unsupported_source';
  }

  bool _appliedOutputHasActiveOverride(
    AppliedMarker marker, {
    required DependencyOverrideState overrideState,
  }) {
    final absoluteAppliedPath = _appliedPaths.patchworkAppliedPath(
      marker.package,
      marker.version,
      marker.path,
    );
    if (absoluteAppliedPath == null) {
      return false;
    }
    return overrideState.hasActiveAppliedOverride(
      marker,
      absoluteAppliedPath: absoluteAppliedPath,
    );
  }

  DependencyOverrideConflict? _userOwnedOverrideForAppliedOutput(
    AppliedMarker marker, {
    required DependencyOverrideState overrideState,
  }) {
    final absoluteAppliedPath = _appliedPaths.patchworkAppliedPath(
      marker.package,
      marker.version,
      marker.path,
    );
    if (absoluteAppliedPath == null) {
      return null;
    }
    return overrideState.userOwnedAppliedOverride(
      marker,
      absoluteAppliedPath: absoluteAppliedPath,
    );
  }

  void _rejectUserOwnedOverrideForAppliedCleanup(
    AppliedMarker marker, {
    required String command,
    required String code,
    required DependencyOverrideState overrideState,
  }) {
    final userOverride = _userOwnedOverrideForAppliedOutput(
      marker,
      overrideState: overrideState,
    );
    if (userOverride == null) {
      return;
    }
    throw PatchworkException(
      'Package "${marker.package}@${marker.version}" is still referenced by ${userOverride.fileName}.',
      code: code,
      hint:
          'Remove the dependency override that points at ${marker.path} before running patchwork $command --force.',
      location: userOverride.path,
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

  void _addAppliedCleanupChanges(
    List<CleanupChange> changes,
    AppliedMarker marker, {
    Set<String>? seen,
    required DependencyOverrideState overrideState,
  }) {
    final appliedPath = _appliedPaths.requirePatchworkAppliedPath(
      marker.package,
      marker.version,
      marker.path,
      code: 'cleanup.applied_path_not_deletable',
      message: _invalidAppliedPathMessage,
    );
    final addChange = seen == null
        ? (CleanupChange change) => changes.add(change)
        : (CleanupChange change) => _addCleanupChange(changes, seen, change);
    addChange(
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
      addChange(
        CleanupChange(
          kind: CleanupChangeKind.pubspecOverride,
          package: marker.package,
          version: marker.version,
          path: p.join(_rootPath, 'pubspec_overrides.yaml'),
        ),
      );
    }
  }

  void _addCleanupChange(
    List<CleanupChange> changes,
    Set<String> seen,
    CleanupChange change,
  ) {
    final key = '${change.kind.name}:${change.path}';
    if (seen.add(key)) {
      changes.add(change);
    }
  }

  PubResolution _readResolution() {
    return _pubResolutionReader.readFromDirectory(_currentPackageRootPath);
  }

  DependencyOverrideState _overrideState() {
    return DependencyOverrideState.read(
      rootPath: _rootPath,
      overrideRootPaths: _overrideRootPaths,
      pubspecOverrides: _pubspecOverrides,
      pubspecDependencyOverrides: _pubspecDependencyOverrides,
    );
  }

  AppliedPatchActivation _appliedActivation() {
    return AppliedPatchActivation(
      rootPath: _rootPath,
      appliedPaths: _appliedPaths,
      appliedMarkerStore: _appliedMarkerStore,
      pubspecOverrides: _pubspecOverrides,
      packageTree: _packageTree,
      readOverrideState: _overrideState,
      invalidAppliedPathMessage: _invalidAppliedPathMessage,
    );
  }

  List<int> _readCommittedPatchBytes(String package, String version) {
    final patchPath = _layout.patchPath(package, version);
    final file = File(patchPath);
    if (!file.existsSync()) {
      throw PatchworkException(
        'No committed patch exists for "$package".',
        code: 'apply.patch_file_missing',
        hint: 'Run patchwork commit $package first.',
        location: patchPath,
      );
    }
    final bytes = file.readAsBytesSync();
    return bytes;
  }

  void _rejectBlockingOverride({
    required String package,
    required String command,
    required String targetPath,
    bool replaceRootOverride = false,
    DependencyOverrideState? overrideState,
  }) {
    final conflict = (overrideState ?? _overrideState()).blockingConflict(
      package: package,
      targetPath: targetPath,
      replaceRootOverride: replaceRootOverride,
    );
    if (conflict != null) {
      throw PatchworkException(
        '${conflict.fileName} already has a dependency override for "$package".',
        code: 'pub.override_conflict',
        hint:
            'Remove or resolve the existing override before running patchwork $command $package.',
        location: conflict.path,
      );
    }
  }

  bool _isPackageApplied(String package, ResolvedPubPackage resolved) {
    if (_resolvesToAppliedPath(package, resolved.version, resolved)) {
      return true;
    }
    return _pubspecOverrides.pointsToPath(
      workspaceRootPath: _rootPath,
      package: package,
      path: _layout.relativeAppliedPath(package, resolved.version),
    );
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

  List<AppliedMarker> _appliedMarkersForPackage(String package) {
    return _appliedMarkerStore
        .readAll()
        .where((marker) => marker.package == package)
        .toList();
  }
}

void _checkPlainPackageName(String package) {
  if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(package)) {
    throw PatchworkException(
      'Expected a plain package name, got "$package".',
      code: 'usage.invalid_package',
      hint:
          'Use patchwork patch foo, not pub:foo, foo@1.2.3, path:foo, or a filesystem path.',
    );
  }
}

void _checkSafePatchVersionSegment(String version) {
  if (version.isEmpty ||
      version == '.' ||
      version == '..' ||
      version.contains('/') ||
      version.contains(r'\')) {
    throw PatchworkException(
      'Patch version "$version" is not a safe path segment.',
      code: 'patch.continue_version_invalid',
    );
  }
}

void _checkSafeRemoveVersionSegment(String version) {
  if (version.isEmpty ||
      version == '.' ||
      version == '..' ||
      version.contains('/') ||
      version.contains(r'\')) {
    throw PatchworkException(
      'Patch version "$version" is not a safe path segment.',
      code: 'remove.version_invalid',
    );
  }
}

String _sha256(List<int> bytes) {
  return sha256.convert(bytes).toString();
}
