import 'apply/activation.dart';
import 'apply/executor.dart';
import 'apply/materializer.dart';
import 'apply/model.dart';
import 'apply/planner.dart';
import 'cleanup/applied.dart';
import 'cleanup/executor.dart';
import 'cleanup/model.dart';
import 'cleanup/prune.dart';
import 'cleanup/remove.dart';
import 'cleanup/undo.dart';
import 'edit/committer.dart';
import 'edit/model.dart';
import 'edit/planner.dart';
import 'edit/preparer.dart';
import 'error.dart';
import 'inspection/model.dart';
import 'inspection/setup.dart';
import 'inspection/state.dart';
import 'overlay/inspector.dart';
import 'overlay/model.dart';
import 'overlay/publisher.dart';
import 'patch/file.dart';
import 'patch/materializer.dart';
import 'patch/package_tree.dart';
import 'pub/dependency_overrides.dart';
import 'pub/overrides.dart';
import 'pub/resolution.dart';
import 'pub/resolution_reader.dart';
import 'pub/workspace.dart';
import 'state/applied_marker.dart';
import 'state/applied_path_policy.dart';
import 'state/artifact_identity.dart';
import 'state/dependency_override_state.dart';
import 'state/edit_session.dart';
import 'state/path_layout.dart';

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

  /// Opens the Patchwork project containing [path].
  ///
  /// [path] may point anywhere inside a Dart package or workspace member. The
  /// nearest package root is used as the current package, while the owning pub
  /// resolution root becomes the Patchwork state root.
  ///
  /// Throws a [PatchworkException] if no usable pub project can be found.
  factory Patchwork.open(String path) {
    final workspace = const PubWorkspaceLocator().locate(path);
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
        packageMaterializer: const PackageMaterializer(
          packageTree: packageTree,
        ),
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

  /// The workspace root that owns Patchwork state.
  String get rootPath => _rootPath;

  /// Inspects repository setup recommendations without mutating files.
  ///
  /// The report focuses on Patchwork's project contract: commit patch files,
  /// ignore generated edit and activation state, and use high-level commands in
  /// CI unless a script intentionally handles pub resolution itself.
  SetupReport inspectSetup() {
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
  OverlayInspection inspectOverlays() {
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
  PreparedEdit patch(
    String package, {
    PatchRef? fromPatch,
    bool replaceExisting = false,
  }) {
    _checkPlainPackageName(package);
    return _executeEditPlan(
      _editPlanner().patch(
        package,
        fromPatch: fromPatch,
        replaceExisting: replaceExisting,
      ),
    );
  }

  PreparedEdit _executeEditPlan(EditPlan plan) {
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
  PreparedEdit carry(
    String package, {
    String? fromVersion,
    bool partial = false,
  }) {
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
  PatchWrite commit(String package) {
    _checkPlainPackageName(package);
    return _committer.commit(package);
  }

  /// Commits every open edit directory in package-name order.
  ///
  /// Returns an empty list when there are no open edits.
  List<PatchWrite> commitAll() {
    return List.unmodifiable(_committer.commitAll());
  }

  /// Registers the committed patch for [package] in the current package's
  /// `patchwork.yaml` overlay manifest.
  ///
  /// The target package must have a committed patch file for the current pub
  /// resolution, and the current package must have `patchwork` as a regular
  /// dependency so downstream consumers receive Patchwork's hook.
  RegisteredOverlay overlay(String package, {String? reason}) {
    _checkPlainPackageName(package);
    return OverlayPublisher(
      currentPackageRootPath: _currentPackageRootPath,
      layout: _layout,
      pubResolutionReader: _pubResolutionReader,
    ).overlay(package, reason: reason);
  }

  /// Applies every committed patch that needs generated output in package-name
  /// order.
  ///
  /// Packages with open edit directories are rejected before any output is
  /// generated, because applying while edits are uncommitted would make the
  /// project state ambiguous.
  List<AppliedPatch> applyAll() {
    final applied = <AppliedPatch>[];
    final executor = _applyExecutor();
    for (final plan in _applyPlanner().plansNeedingApply()) {
      applied.add(executor.execute(plan));
    }
    return List.unmodifiable(applied);
  }

  /// Applies the committed patch for [package] into generated output.
  ///
  /// The patch is applied to a fresh copy of the resolved source and then moved
  /// into `.dart_tool/patchwork/` atomically with respect to the final
  /// directory. The method also updates `pubspec_overrides.yaml`; callers should
  /// run `dart pub get` afterwards so pub resolves the generated package.
  AppliedPatch apply(String package) {
    _checkPlainPackageName(package);
    return _applyExecutor().execute(_applyPlanner().plan(package));
  }

  /// Removes Patchwork-generated output and override state for [package].
  ///
  /// The override is removed only if it still points at the path recorded by
  /// Patchwork. User-owned overrides and paths outside the generated Patchwork
  /// output tree are left untouched or rejected.
  UnappliedPatch undo(String package) {
    _checkPlainPackageName(package);
    return _cleanupExecutor().undo(_undoPlanner().plan(package));
  }

  /// Removes Patchwork artifacts for [package] and optional [version].
  ///
  /// By default this refuses to discard open edit directories or applied output
  /// markers. Set [force] to explicitly remove those local states too. When
  /// [dryRun] is true, the returned changes are planned but no files are
  /// modified.
  CleanupResult remove(
    String package, {
    String? version,
    bool dryRun = false,
    bool force = false,
  }) {
    _checkPlainPackageName(package);
    final plan = _removePlanner().plan(
      package,
      version: version,
      dryRun: dryRun,
      force: force,
    );
    _cleanupExecutor().execute(
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
  CleanupResult prune({bool dryRun = false, bool force = false}) {
    final plan = _prunePlanner().plan(dryRun: dryRun, force: force);
    _cleanupExecutor().execute(
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
  PatchworkState inspect() {
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

  ApplyExecutor _applyExecutor() {
    return ApplyExecutor(
      materializer: _appliedMaterializer,
      activation: _appliedActivation(),
    );
  }

  CleanupExecutor _cleanupExecutor() {
    return CleanupExecutor(
      activation: _appliedActivation(),
      packageTree: _packageTree,
    );
  }

  EditPlanner _editPlanner() {
    return EditPlanner(
      rootPath: _rootPath,
      layout: _layout,
      appliedPaths: _appliedPaths,
      appliedMarkerStore: _appliedMarkerStore,
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

  RemovePlanner _removePlanner() {
    return RemovePlanner(
      layout: _layout,
      appliedMarkerStore: _appliedMarkerStore,
      readResolution: _readResolution,
      readOverrideState: _overrideState,
      appliedCleanup: _appliedCleanup(),
    );
  }

  PrunePlanner _prunePlanner() {
    return PrunePlanner(
      layout: _layout,
      appliedMarkerStore: _appliedMarkerStore,
      readResolution: _readResolution,
      readOverrideState: _overrideState,
      appliedCleanup: _appliedCleanup(),
    );
  }

  AppliedCleanup _appliedCleanup() {
    return AppliedCleanup(
      rootPath: _rootPath,
      appliedPaths: _appliedPaths,
      invalidAppliedPathMessage: _invalidAppliedPathMessage,
    );
  }

  UndoPlanner _undoPlanner() {
    return UndoPlanner(appliedMarkerStore: _appliedMarkerStore);
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
