import 'dart:io';

import 'applied_marker.dart';
import 'edit_session.dart';
import 'error.dart';
import 'internal/applied_patch_activation.dart';
import 'internal/applied_patch_materializer.dart';
import 'internal/applied_path_policy.dart';
import 'internal/apply_planner.dart';
import 'internal/artifact_identity.dart';
import 'internal/cleanup_planner.dart';
import 'internal/dependency_override_state.dart';
import 'internal/edit_preparer.dart';
import 'internal/edit_planner.dart';
import 'internal/package_tree.dart';
import 'internal/overlay_inspector.dart';
import 'internal/overlay_publisher.dart';
import 'internal/path_layout.dart';
import 'internal/patch_committer.dart';
import 'internal/project_paths.dart';
import 'internal/setup_inspector.dart';
import 'internal/state_inspector.dart';
import 'internal/undo_planner.dart';
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
    required String rootPath,
    required String currentPackageRootPath,
    required Set<String> overrideRootPaths,
    required PathLayout layout,
    required AppliedPathPolicy appliedPaths,
    required PubResolutionReader pubResolutionReader,
    required EditSessionStore editSessionStore,
    required AppliedMarkerStore appliedMarkerStore,
    required EditPreparer editPreparer,
    required PatchCommitter committer,
    required AppliedPatchMaterializer appliedMaterializer,
    required PackageTree packageTree,
    required PatchFile patchFile,
    required PubspecDependencyOverrides pubspecDependencyOverrides,
    required PubspecOverrides pubspecOverrides,
  }) : _rootPath = rootPath,
       _currentPackageRootPath = currentPackageRootPath,
       _overrideRootPaths = overrideRootPaths,
       _layout = layout,
       _appliedPaths = appliedPaths,
       _pubResolutionReader = pubResolutionReader,
       _editSessionStore = editSessionStore,
       _appliedMarkerStore = appliedMarkerStore,
       _editPreparer = editPreparer,
       _committer = committer,
       _appliedMaterializer = appliedMaterializer,
       _packageTree = packageTree,
       _patchFile = patchFile,
       _pubspecDependencyOverrides = pubspecDependencyOverrides,
       _pubspecOverrides = pubspecOverrides;

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
    return relativeToProjectRoot(rootPath: _rootPath, path: path);
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
  /// The package must be selected by the current pub resolution and must not
  /// already resolve to Patchwork generated output. The edit directory carries a
  /// hidden baseline snapshot used later by [commit].
  Future<PreparedEdit> patch(
    String package, {
    PatchRef? fromPatch,
    bool replaceExisting = false,
  }) async {
    _checkPlainPackageName(package);
    return _executeEditPlan(
      _editPlanner().patch(
        package,
        fromPatch: fromPatch,
        replaceExisting: replaceExisting,
      ),
    );
  }

  Future<PreparedEdit> _executeEditPlan(EditPlan plan) {
    return _editPreparer.prepare(
      package: plan.package,
      resolved: plan.resolved,
      continuedFromPatchPath: plan.continuedFromPatchPath,
      continuedFromPatchContent: plan.continuedFromPatchContent,
      replaceExisting: plan.replaceExisting,
      preserveFailedPatchApply: plan.preserveFailedPatchApply,
      partialPatchApply: plan.partialPatchApply,
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
    return _executeEditPlan(
      _editPlanner().carry(package, fromVersion: fromVersion, partial: partial),
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
    for (final plan in _applyPlanner().plansNeedingApply()) {
      applied.add(_executeApplyPlan(plan));
    }
    return applied;
  }

  /// Applies the committed patch for [package] into generated output.
  ///
  /// The patch is applied to a fresh copy of the resolved source and then moved
  /// into `.dart_tool/patchwork/` atomically with respect to the final
  /// directory. The method also updates `pubspec_overrides.yaml`; callers should
  /// run `dart pub get` afterwards so pub resolves the generated package.
  Future<AppliedPatch> apply(String package) async {
    _checkPlainPackageName(package);
    return _executeApplyPlan(_applyPlanner().plan(package));
  }

  AppliedPatch _executeApplyPlan(ApplyPlan plan) {
    _appliedMaterializer.materialize(
      package: plan.package,
      version: plan.version,
      sourcePath: plan.sourcePath,
      appliedPath: plan.appliedPath,
      patchContent: plan.patchContent,
    );

    _appliedActivation().activate(
      package: plan.package,
      version: plan.version,
      patchSha256: plan.patchSha256,
      path: plan.appliedRecordPath,
      source: plan.source,
    );

    return AppliedPatch(
      package: plan.package,
      version: plan.version,
      path: plan.appliedPath,
      patchPath: plan.patchPath,
    );
  }

  /// Removes Patchwork-generated output and override state for [package].
  ///
  /// The override is removed only if it still points at the path recorded by
  /// Patchwork. User-owned overrides and paths outside the generated Patchwork
  /// output tree are left untouched or rejected.
  Future<UnappliedPatch> undo(String package) async {
    _checkPlainPackageName(package);
    return _executeUndoPlan(_undoPlanner().plan(package));
  }

  UnappliedPatch _executeUndoPlan(UndoPlan plan) {
    final marker = plan.marker;
    if (marker == null) {
      return UnappliedPatch(package: plan.package, changed: false);
    }

    final absoluteAppliedPath = _appliedActivation().remove(
      marker,
      code: 'undo.applied_path_not_deletable',
    );

    return UnappliedPatch(
      package: plan.package,
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
    final plan = _cleanupPlanner().remove(
      package,
      version: version,
      dryRun: dryRun,
      force: force,
    );
    _executeCleanupPlan(
      plan,
      appliedPathCode: 'remove.applied_path_not_deletable',
    );
    return plan.result;
  }

  /// Removes stale Patchwork artifacts that can be proven safe to clean.
  ///
  /// Stale patch files are selected when they no longer match current pub
  /// resolution. Generated output is selected only when its valid marker points
  /// at Patchwork's deterministic generated directory and no active override
  /// references it. Set [force] to also discard open edits or active applied
  /// state associated with stale patches.
  Future<CleanupResult> prune({bool dryRun = false, bool force = false}) async {
    final plan = _cleanupPlanner().prune(dryRun: dryRun, force: force);
    _executeCleanupPlan(
      plan,
      appliedPathCode: 'prune.applied_path_not_deletable',
    );
    return plan.result;
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

  EditPlanner _editPlanner() {
    return EditPlanner(
      rootPath: _rootPath,
      layout: _layout,
      appliedPaths: _appliedPaths,
      appliedMarkerStore: _appliedMarkerStore,
      pubspecOverrides: _pubspecOverrides,
      readResolution: _readResolution,
      readOverrideState: _overrideState,
    );
  }

  ApplyPlanner _applyPlanner() {
    return ApplyPlanner(
      rootPath: _rootPath,
      layout: _layout,
      appliedPaths: _appliedPaths,
      appliedMarkerStore: _appliedMarkerStore,
      patchFile: _patchFile,
      readResolution: _readResolution,
      readOverrideState: _overrideState,
      invalidAppliedPathMessage: _invalidAppliedPathMessage,
    );
  }

  CleanupPlanner _cleanupPlanner() {
    return CleanupPlanner(
      rootPath: _rootPath,
      layout: _layout,
      appliedPaths: _appliedPaths,
      appliedMarkerStore: _appliedMarkerStore,
      readResolution: _readResolution,
      readOverrideState: _overrideState,
      invalidAppliedPathMessage: _invalidAppliedPathMessage,
    );
  }

  UndoPlanner _undoPlanner() {
    return UndoPlanner(appliedMarkerStore: _appliedMarkerStore);
  }

  void _executeCleanupPlan(
    CleanupPlan plan, {
    required String appliedPathCode,
  }) {
    if (plan.result.dryRun) {
      return;
    }
    for (final marker in plan.appliedMarkers) {
      _appliedActivation().remove(marker, code: appliedPathCode);
    }
    for (final change in plan.result.changes) {
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
}

void _checkPlainPackageName(String package) {
  if (!isPlainPackageName(package)) {
    throw PatchworkException(
      'Expected a plain package name, got "$package".',
      code: 'usage.invalid_package',
      hint:
          'Use patchwork patch foo, not pub:foo, foo@1.2.3, path:foo, or a filesystem path.',
    );
  }
}
