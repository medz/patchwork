import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'applied_marker.dart';
import 'edit_session.dart';
import 'error.dart';
import 'internal/package_tree.dart';
import 'internal/path_layout.dart';
import 'io/atomic_file_writer.dart';
import 'model.dart';
import 'overlay_manifest.dart';
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
    required this._protectedRootPaths,
    required this._layout,
    required this._pubResolutionReader,
    required this._editSessionStore,
    required this._appliedMarkerStore,
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
    return Patchwork._(
      rootPath: workspace.rootPath,
      currentPackageRootPath: workspace.currentPackageRootPath,
      overrideRootPaths: workspace.rootPackageRootPaths,
      protectedRootPaths: workspace.rootPackageRootPaths,
      layout: layout,
      pubResolutionReader: const PubResolutionReader(),
      editSessionStore: EditSessionStore(layout: layout),
      appliedMarkerStore: AppliedMarkerStore(layout: layout),
      packageTree: const PackageTree(),
      patchFile: const PatchFile(),
      pubspecDependencyOverrides: const PubspecDependencyOverrides(),
      pubspecOverrides: const PubspecOverrides(),
    );
  }

  final String _rootPath;
  final String _currentPackageRootPath;
  final Set<String> _overrideRootPaths;
  final Set<String> _protectedRootPaths;
  final PathLayout _layout;
  final PubResolutionReader _pubResolutionReader;
  final EditSessionStore _editSessionStore;
  final AppliedMarkerStore _appliedMarkerStore;
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
    _checkPlainPackageName(package);
    final resolution = _readResolution();
    final resolved = resolution.resolvePackage(package);
    final editPath = _layout.editPath(package, resolved.version);
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

    final editExists = Directory(editPath).existsSync();
    if (editExists) {
      if (!replaceExisting &&
          !_canReplaceEditDirectory(
            package: package,
            editPath: editPath,
            version: resolved.version,
          )) {
        throw PatchworkException(
          'Edit directory has uncommitted changes for "$package".',
          code: 'patch.edit_exists',
          hint:
              'Run patchwork commit $package, delete $editPath, or pass --force.',
          location: editPath,
        );
      }
    }

    final tempEditPath = p.join(
      _layout.editRootPath,
      '.$package@${resolved.version}.$pid.${DateTime.now().microsecondsSinceEpoch}',
    );
    _packageTree.deleteDirectory(tempEditPath);
    try {
      _packageTree.copy(resolved.rootPath, tempEditPath);
      _packageTree.copy(
        resolved.rootPath,
        p.join(tempEditPath, '.patchwork', 'source'),
      );
      _editSessionStore.write(
        package: package,
        version: resolved.version,
        source: resolved.source,
        editPath: tempEditPath,
      );
      if (continuedFromPatchContent != null) {
        _patchFile.apply(
          packagePath: tempEditPath,
          patchContent: continuedFromPatchContent,
        );
      }
      if (editExists) {
        _packageTree.deleteDirectory(editPath);
      }
      Directory(tempEditPath).renameSync(editPath);
    } catch (_) {
      _packageTree.deleteDirectory(tempEditPath);
      rethrow;
    }

    return PreparedEdit(
      package: package,
      version: resolved.version,
      path: editPath,
      sourcePath: resolved.rootPath,
      continuedFromPatchPath: continuedFromPatchPath,
    );
  }

  bool _canReplaceEditDirectory({
    required String package,
    required String editPath,
    required String version,
  }) {
    final session = _tryReadEditSession(
      PackageVersionPath(package: package, version: version, path: editPath),
    );
    if (session == null) {
      return false;
    }

    final patchFile = File(_layout.patchPath(package, version));
    final content = _patchFile.build(
      sourcePath: session.baselinePath,
      editPath: editPath,
    );
    if (content.isEmpty) {
      return true;
    }
    return patchFile.existsSync() &&
        _sha256(utf8.encode(content)) == _sha256(patchFile.readAsBytesSync());
  }

  /// Commits the open edit directory for [package] into `patches/`.
  ///
  /// The edit is diffed against its hidden baseline snapshot. Empty diffs
  /// remove the committed patch file, unchanged edits are discarded, and real
  /// changes are validated before the patch file is written.
  Future<PatchWrite> commit(String package) async {
    _checkPlainPackageName(package);
    final edit = _singleEditDirectory(package);
    return _commitEdit(edit);
  }

  /// Commits every open edit directory in package-name order.
  ///
  /// Returns an empty list when there are no open edits.
  Future<List<PatchWrite>> commitAll() async {
    final writes = <PatchWrite>[];
    for (final package in _openEditPackages()) {
      writes.add(await commit(package));
    }
    return writes;
  }

  /// Registers the committed patch for [package] in the current package's
  /// `patchwork.yaml` overlay manifest.
  ///
  /// The target package must have a committed patch file for the current pub
  /// resolution, and the current package must have `patchwork` as a regular
  /// dependency so downstream consumers receive Patchwork's hook.
  Future<RegisteredOverlay> overlay(String package, {String? reason}) async {
    _checkPlainPackageName(package);
    _ensureCurrentPackageCanPublishOverlays();

    final resolution = _readResolution();
    final resolved = resolution.resolvePackage(package);
    final patchPath = _layout.patchPath(package, resolved.version);
    final patchFile = File(patchPath);
    if (!patchFile.existsSync()) {
      throw PatchworkException(
        'No committed patch file exists for "$package".',
        code: 'overlay.patch_file_missing',
        hint: 'Run patchwork commit $package first.',
        location: patchPath,
      );
    }
    final patchBytes = patchFile.readAsBytesSync();

    final manifestPath = p.join(_currentPackageRootPath, 'patchwork.yaml');
    final overlayPatchPath = _publishableOverlayPatchPath(
      package: package,
      version: resolved.version,
      patchPath: patchPath,
      patchBytes: patchBytes,
    );
    final patchManifestPath = _currentPackageRelativePath(
      overlayPatchPath,
      code: 'overlay.patch_outside_package',
      message:
          'Overlay patch files must live inside the current package before they can be published.',
    );
    final store = OverlayManifestStore(path: manifestPath);
    final nextManifest = store.read().upsert(
      OverlayManifestEntry(
        package: package,
        version: resolved.version,
        sha256: resolved.source.sha256,
        patch: patchManifestPath,
        reason: reason,
      ),
    );
    store.write(nextManifest);

    return RegisteredOverlay(
      package: package,
      version: resolved.version,
      sha256: resolved.source.sha256,
      patchPath: patchManifestPath,
      manifestPath: manifestPath,
      reason: reason,
    );
  }

  List<String> _openEditPackages() {
    final packages =
        _layout.editDirectories().map((edit) => edit.package).toSet().toList()
          ..sort();
    return packages;
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
    final patches = _layout.patchFiles();
    if (patches.isEmpty) {
      return const [];
    }

    final edits = _layout.editDirectories();
    final openEditPackages = {for (final edit in edits) edit.package};
    final resolution = _readResolution();
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

      if (openEditPackages.contains(package)) {
        final edit = edits.firstWhere((edit) => edit.package == package);
        throw PatchworkException(
          'Package "$package" has an open edit directory.',
          code: 'apply.open_edit',
          hint: 'Run patchwork commit $package before applying.',
          location: edit.path,
        );
      }

      final applied = _appliedMarkerStore.read(package, patch.version);
      if (applied != null &&
          _patchworkAppliedPath(package, patch.version, applied.path) == null) {
        throw PatchworkException(
          _invalidAppliedPathMessage,
          code: 'apply.applied_path_not_deletable',
          location: applied.path,
        );
      }
      if (_hasForeignOverride(package, applied)) {
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
      if (_hasBlockingPendingOverride(
        package: package,
        version: patch.version,
        applied: applied,
      )) {
        _rejectBlockingOverride(
          package: package,
          command: 'apply',
          targetPath: _layout.appliedPath(package, patch.version),
        );
      }
      final patchBytes = File(patch.path).readAsBytesSync();
      final patchSha256 = _sha256(patchBytes);
      if (_needsApply(
        package: package,
        version: patch.version,
        patchSha256: patchSha256,
        source: resolved.source,
        applied: applied,
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
    final openEdits = _layout
        .editDirectories()
        .where((edit) => edit.package == package)
        .toList();
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
        : _requirePatchworkAppliedPath(
            package,
            resolved.version,
            existingApplied.path,
            code: 'apply.applied_path_not_deletable',
            message: _invalidAppliedPathMessage,
          );
    _rejectBlockingOverride(
      package: package,
      command: 'apply',
      targetPath: appliedPath,
      replaceRootOverride: existingApplied != null,
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
    final tempPath = p.join(
      _layout.appliedRootPath,
      '.$package@${resolved.version}.$pid.${DateTime.now().microsecondsSinceEpoch}',
    );
    _packageTree.deleteDirectory(tempPath);
    Directory(tempPath).createSync(recursive: true);
    try {
      _packageTree.copy(resolved.rootPath, tempPath);
      _patchFile.apply(
        packagePath: tempPath,
        patchContent: utf8.decode(patchBytes),
      );
      _packageTree.deleteDirectory(appliedPath);
      Directory(p.dirname(appliedPath)).createSync(recursive: true);
      Directory(tempPath).renameSync(appliedPath);
    } catch (_) {
      _packageTree.deleteDirectory(tempPath);
      rethrow;
    }

    final markers = _appliedMarkerStore.readAll();
    final previousMirroredPubspecDependencyOverrides =
        _mirroredPubspecDependencyOverrides(markers);
    final mirroredPubspecDependencyOverrides = _pubspecOverrides
        .upsertPathOverride(
          workspaceRootPath: _rootPath,
          package: package,
          path: appliedRecordPath,
          ownedDependencyOverrides: _ownedPubspecDependencyOverrides(markers),
          pubspecDependencyOverrides: _rootPubspecDependencyOverrides(package),
          mirroredPubspecDependencyOverrides:
              previousMirroredPubspecDependencyOverrides,
        );
    final nextMarker = AppliedMarker(
      package: package,
      version: resolved.version,
      patchSha256: patchSha256,
      path: appliedRecordPath,
      source: resolved.source,
      mirroredPubspecDependencyOverrides: mirroredPubspecDependencyOverrides,
    );
    _setMirroredPubspecDependencyOverrides([
      for (final marker in markers)
        if (!(marker.package == package && marker.version == resolved.version))
          marker,
      nextMarker,
    ], mirroredPubspecDependencyOverrides);

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

    final absoluteAppliedPath = _removeAppliedMarker(
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
    final selectedVersion = _removeVersion(package, version);
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

    final edit = _editDirectory(package, selectedVersion);
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
      if (!force) {
        throw PatchworkException(
          'Package "$package@$selectedVersion" has applied Patchwork state.',
          code: 'remove.patch_applied',
          hint: 'Run patchwork undo $package first, or pass --force.',
          location: _layout.appliedPath(package, selectedVersion),
        );
      }
      _addAppliedCleanupChanges(changes, marker);
      appliedMarkers.add(marker);
    }

    if (!dryRun) {
      for (final marker in appliedMarkers) {
        _removeAppliedMarker(marker, code: 'remove.applied_path_not_deletable');
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
    final edits = _layout.editDirectories();
    final appliedDirectories = _layout.appliedDirectories();
    final seen = <String>{};
    final resolution = _readResolution();

    for (final patch in _layout.patchFiles()) {
      if (_patchMatchesResolution(patch, resolution)) {
        continue;
      }
      final edit = _findPackageVersionPath(edits, patch.package, patch.version);
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
          marker != null && _appliedOutputHasActiveOverride(marker);
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
      if (marker != null && (force || !activeAppliedReference)) {
        _addAppliedCleanupChanges(changes, marker, seen: seen);
        appliedMarkers.add(marker);
      }
    }

    for (final appliedDirectory in appliedDirectories) {
      final marker = _tryReadAppliedMarker(appliedDirectory);
      if (marker == null) {
        continue;
      }
      if (_appliedOutputHasActiveOverride(marker)) {
        continue;
      }
      _addAppliedCleanupChanges(changes, marker, seen: seen);
      appliedMarkers.add(marker);
    }

    if (!dryRun) {
      final removedMarkers = <String>{};
      for (final marker in appliedMarkers) {
        final key = '${marker.package}@${marker.version}';
        if (!removedMarkers.add(key)) {
          continue;
        }
        _removeAppliedMarker(marker, code: 'prune.applied_path_not_deletable');
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
    final edits = _layout.editDirectories();
    final patchFiles = _layout.patchFiles();
    final appliedDirectories = _layout.appliedDirectories();
    final packages = <String>{
      ...edits.map((edit) => edit.package),
      ...patchFiles.map((patch) => patch.package),
      ...appliedDirectories.map((applied) => applied.package),
    };
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

    for (final package in packages.toList()..sort()) {
      final edit = edits
          .where((candidate) => candidate.package == package)
          .toList();
      final patches = patchFiles
          .where((candidate) => candidate.package == package)
          .toList();
      final applied = appliedDirectories
          .where((candidate) => candidate.package == package)
          .toList();
      statuses.add(
        _inspectPackage(
          package: package,
          edit: edit,
          patchFiles: patches,
          appliedDirectories: applied,
          resolution: resolution,
          resolutionError: resolutionError,
        ),
      );
    }
    return PatchworkState(packages: statuses);
  }

  String _removeVersion(String package, String? version) {
    if (version != null) {
      _checkSafeRemoveVersionSegment(version);
      return version;
    }

    final versions = <String>{
      for (final patch in _layout.patchFiles())
        if (patch.package == package) patch.version,
      for (final edit in _layout.editDirectories())
        if (edit.package == package) edit.version,
      for (final applied in _layout.appliedDirectories())
        if (applied.package == package) applied.version,
    };
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

  PackageVersionPath? _editDirectory(String package, String version) {
    return _findPackageVersionPath(_layout.editDirectories(), package, version);
  }

  PackageVersionPath? _findPackageVersionPath(
    List<PackageVersionPath> paths,
    String package,
    String version,
  ) {
    for (final path in paths) {
      if (path.package == package && path.version == version) {
        return path;
      }
    }
    return null;
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

  bool _appliedOutputHasActiveOverride(AppliedMarker marker) {
    final absoluteAppliedPath = _patchworkAppliedPath(
      marker.package,
      marker.version,
      marker.path,
    );
    if (absoluteAppliedPath == null) {
      return false;
    }

    for (final overrideRootPath in _overrideRootPaths) {
      final hasOverrideFileDependencyOverrides = _pubspecOverrides
          .hasDependencyOverrides(workspaceRootPath: overrideRootPath);
      if (_pubspecOverrides.pointsToPath(
        workspaceRootPath: overrideRootPath,
        package: marker.package,
        path: absoluteAppliedPath,
      )) {
        return true;
      }
      if (hasOverrideFileDependencyOverrides) {
        continue;
      }

      final dependencyOverrides = _pubspecDependencyOverrides
          .dependencyOverrides(packageRootPath: overrideRootPath);
      if (_overrideValuePointsToPath(
        workspaceRootPath: overrideRootPath,
        value: dependencyOverrides[marker.package],
        path: absoluteAppliedPath,
      )) {
        return true;
      }
    }

    return false;
  }

  bool _overrideValuePointsToPath({
    required String workspaceRootPath,
    required Object? value,
    required String path,
  }) {
    if (value is! Map<String, Object?>) {
      return false;
    }
    final overridePath = value['path'];
    if (overridePath is! String) {
      return false;
    }
    final absoluteOverridePath = p.normalize(
      p.isAbsolute(overridePath)
          ? overridePath
          : p.absolute(workspaceRootPath, overridePath),
    );
    return p.equals(absoluteOverridePath, p.normalize(path));
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
  }) {
    final appliedPath = _requirePatchworkAppliedPath(
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
    if (_pubspecOverrides.pointsToPath(
          workspaceRootPath: _rootPath,
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

  String _removeAppliedMarker(AppliedMarker marker, {required String code}) {
    final absoluteAppliedPath = _requirePatchworkAppliedPath(
      marker.package,
      marker.version,
      marker.path,
      code: code,
      message: _invalidAppliedPathMessage,
    );
    final markers = _appliedMarkerStore.readAll();
    final mirroredPubspecDependencyOverrides =
        _mirroredPubspecDependencyOverrides(markers);
    final nextMirroredPubspecDependencyOverrides = _pubspecOverrides
        .removePathOverrideIfMatches(
          workspaceRootPath: _rootPath,
          package: marker.package,
          path: marker.path,
          ownedDependencyOverrides: _ownedPubspecDependencyOverrides(markers),
          pubspecDependencyOverrides: _rootPubspecDependencyOverrides(),
          mirroredPubspecDependencyOverrides:
              mirroredPubspecDependencyOverrides,
        );
    _packageTree.deleteDirectory(absoluteAppliedPath);

    _setMirroredPubspecDependencyOverrides([
      for (final existing in markers)
        if (!(existing.package == marker.package &&
            existing.version == marker.version))
          existing,
    ], nextMirroredPubspecDependencyOverrides);

    return absoluteAppliedPath;
  }

  PubResolution _readResolution() {
    return _pubResolutionReader.readFromDirectory(_currentPackageRootPath);
  }

  void _ensureCurrentPackageCanPublishOverlays() {
    final pubspecPath = p.join(_currentPackageRootPath, 'pubspec.yaml');
    try {
      final decoded = loadYaml(File(pubspecPath).readAsStringSync());
      if (decoded is! YamlMap) {
        throw PatchworkException(
          'pubspec.yaml must contain a YAML object.',
          code: 'overlay.malformed_pubspec',
          location: pubspecPath,
        );
      }
      final dependencies = decoded['dependencies'];
      if (dependencies is YamlMap && dependencies.containsKey('patchwork')) {
        return;
      }
      throw PatchworkException(
        'The current package must depend on patchwork before publishing overlays.',
        code: 'overlay.patchwork_dependency_missing',
        hint: 'Add patchwork under dependencies, not dev_dependencies.',
        location: pubspecPath,
      );
    } on YamlException catch (error) {
      throw PatchworkException(
        'Malformed pubspec.yaml.',
        code: 'overlay.malformed_pubspec',
        hint: error.message,
        location: pubspecPath,
      );
    } on FileSystemException catch (error) {
      throw PatchworkException(
        'Could not read pubspec.yaml.',
        code: 'overlay.pubspec_not_readable',
        hint: error.message,
        location: pubspecPath,
      );
    }
  }

  String _currentPackageRelativePath(
    String path, {
    required String code,
    required String message,
    String? hint,
  }) {
    final absolutePath = p.normalize(p.absolute(path));
    final currentRoot = p.normalize(p.absolute(_currentPackageRootPath));
    if (!p.equals(absolutePath, currentRoot) &&
        !p.isWithin(currentRoot, absolutePath)) {
      throw PatchworkException(message, code: code, hint: hint, location: path);
    }
    return p.posix.joinAll(
      p.split(p.relative(absolutePath, from: currentRoot)),
    );
  }

  String _publishableOverlayPatchPath({
    required String package,
    required String version,
    required String patchPath,
    required List<int> patchBytes,
  }) {
    final absolutePath = p.normalize(p.absolute(patchPath));
    final currentRoot = p.normalize(p.absolute(_currentPackageRootPath));
    if (p.equals(absolutePath, currentRoot) ||
        p.isWithin(currentRoot, absolutePath)) {
      return patchPath;
    }

    final packagePatchPath = PathLayout(
      _currentPackageRootPath,
    ).patchPath(package, version);
    writeBytesFileAtomically(packagePatchPath, patchBytes);
    return packagePatchPath;
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
  }) {
    final conflict = _blockingOverrideConflict(
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

  _OverrideConflict? _blockingOverrideConflict({
    required String package,
    required String targetPath,
    bool replaceRootOverride = false,
  }) {
    for (final overrideRootPath in _overrideRootPaths) {
      final canReplaceHere =
          replaceRootOverride && p.equals(overrideRootPath, _rootPath);
      if (_pubspecOverrides.hasBlockingPathOverride(
        workspaceRootPath: overrideRootPath,
        package: package,
        path: targetPath,
        replaceExisting: canReplaceHere,
      )) {
        return _OverrideConflict(
          fileName: 'pubspec_overrides.yaml',
          path: p.join(overrideRootPath, 'pubspec_overrides.yaml'),
        );
      }
      if (_pubspecOverrides.hasDependencyOverrides(
        workspaceRootPath: overrideRootPath,
      )) {
        continue;
      }
      if (_pubspecDependencyOverrides.hasOverride(
        packageRootPath: overrideRootPath,
        package: package,
      )) {
        return _OverrideConflict(
          fileName: 'pubspec.yaml',
          path: p.join(overrideRootPath, 'pubspec.yaml'),
        );
      }
    }
    return null;
  }

  PackageVersionPath _singleEditDirectory(String package) {
    final edits = _layout
        .editDirectories()
        .where((edit) => edit.package == package)
        .toList();
    if (edits.isEmpty) {
      throw PatchworkException(
        'No edit directory exists for "$package".',
        code: 'commit.edit_missing',
        hint: 'Run patchwork patch $package first.',
      );
    }
    if (edits.length > 1) {
      throw PatchworkException(
        'More than one edit directory exists for "$package".',
        code: 'commit.ambiguous_edit',
        hint:
            'Commit or delete the extra .patchwork/$package@<version> directories.',
      );
    }
    return edits.single;
  }

  EditSession? _tryReadEditSession(PackageVersionPath edit) {
    try {
      return _editSessionStore.read(edit);
    } on PatchworkException {
      return null;
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
    final absoluteAppliedPath = _patchworkAppliedPath(
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

  Future<PatchWrite> _commitEdit(PackageVersionPath edit) async {
    final session = _editSessionStore.read(edit);
    final patchPath = _layout.patchPath(edit.package, edit.version);
    final existingPatchFile = File(patchPath);
    final content = _patchFile.build(
      sourcePath: session.baselinePath,
      editPath: edit.path,
    );
    if (content.isEmpty) {
      if (existingPatchFile.existsSync()) {
        existingPatchFile.deleteSync();
      }
      _packageTree.deleteDirectory(edit.path);
      return PatchWrite(
        package: edit.package,
        version: edit.version,
        status: PatchWriteStatus.removed,
        editPath: edit.path,
        patchPath: patchPath,
      );
    }

    final patchBytes = utf8.encode(content);
    if (existingPatchFile.existsSync() &&
        _sha256(existingPatchFile.readAsBytesSync()) == _sha256(patchBytes)) {
      _packageTree.deleteDirectory(edit.path);
      return PatchWrite(
        package: edit.package,
        version: edit.version,
        status: PatchWriteStatus.unchanged,
        editPath: edit.path,
        patchPath: patchPath,
      );
    }

    _patchFile.validate(
      sourcePath: session.baselinePath,
      patchContent: content,
    );
    writeBytesFileAtomically(patchPath, patchBytes);
    _packageTree.deleteDirectory(edit.path);

    return PatchWrite(
      package: edit.package,
      version: edit.version,
      status: PatchWriteStatus.written,
      editPath: edit.path,
      patchPath: patchPath,
    );
  }

  bool _hasBlockingPendingOverride({
    required String package,
    required String version,
    required AppliedMarker? applied,
  }) {
    if (applied != null) {
      return false;
    }
    return _blockingOverrideConflict(
          package: package,
          targetPath: _layout.appliedPath(package, version),
        ) !=
        null;
  }

  bool _hasForeignOverride(String package, AppliedMarker? applied) {
    for (final overrideRootPath in _overrideRootPaths) {
      final hasOverrideFileDependencyOverrides = _pubspecOverrides
          .hasDependencyOverrides(workspaceRootPath: overrideRootPath);
      if (_pubspecOverrides.hasOverride(
        workspaceRootPath: overrideRootPath,
        package: package,
      )) {
        if (p.equals(overrideRootPath, _rootPath) &&
            applied != null &&
            _pubspecOverrides.pointsToPath(
              workspaceRootPath: overrideRootPath,
              package: package,
              path: applied.path,
            )) {
          continue;
        }
        return true;
      }
      if (hasOverrideFileDependencyOverrides) {
        continue;
      }
      if (_pubspecDependencyOverrides.hasOverride(
        packageRootPath: overrideRootPath,
        package: package,
      )) {
        return true;
      }
    }
    return false;
  }

  Map<String, Object?> _rootPubspecDependencyOverrides([
    String? skippedPackage,
  ]) {
    final dependencyOverrides = <String, Object?>{};
    // `pubspec_overrides.yaml` replaces only the state-root pubspec fields.
    // Workspace member overrides remain active in their own pubspec files.
    final rootOverrides = _pubspecDependencyOverrides.dependencyOverrides(
      packageRootPath: _rootPath,
    );
    for (final entry in rootOverrides.entries) {
      if (entry.key == skippedPackage) {
        continue;
      }
      dependencyOverrides[entry.key] = _rootRelativePathOverride(entry.value);
    }
    return dependencyOverrides;
  }

  Map<String, Object?> _mirroredPubspecDependencyOverrides(
    List<AppliedMarker> markers,
  ) {
    final dependencyOverrides = <String, Object?>{};
    for (final marker in markers) {
      dependencyOverrides.addAll(marker.mirroredPubspecDependencyOverrides);
    }
    return dependencyOverrides;
  }

  Map<String, Object?> _ownedPubspecDependencyOverrides(
    List<AppliedMarker> markers,
  ) {
    final dependencyOverrides = <String, Object?>{};
    for (final marker in markers) {
      dependencyOverrides.addAll(marker.mirroredPubspecDependencyOverrides);
      dependencyOverrides[marker.package] = {'path': marker.path};
    }
    return dependencyOverrides;
  }

  void _setMirroredPubspecDependencyOverrides(
    List<AppliedMarker> markers,
    Map<String, Object?> dependencyOverrides,
  ) {
    for (final marker in markers) {
      _appliedMarkerStore.write(
        marker.copyWith(
          mirroredPubspecDependencyOverrides: dependencyOverrides,
        ),
      );
    }
  }

  Object? _rootRelativePathOverride(Object? value) {
    if (value is Map<String, Object?> && value['path'] is String) {
      final path = value['path'] as String;
      final absolutePath = p.normalize(
        p.isAbsolute(path) ? path : p.absolute(_rootPath, path),
      );
      return {
        ...value,
        'path': p.posix.joinAll(
          p.split(p.relative(absolutePath, from: _rootPath)),
        ),
      };
    }
    return value;
  }

  bool _needsApply({
    required String package,
    required String version,
    required String patchSha256,
    required PackageSource source,
    required AppliedMarker? applied,
  }) {
    if (applied == null) {
      return true;
    }
    final appliedPath = _patchworkAppliedPath(package, version, applied.path);
    if (appliedPath == null) {
      return false;
    }

    return !Directory(appliedPath).existsSync() ||
        !_pubspecOverrides.pointsToPath(
          workspaceRootPath: _rootPath,
          package: package,
          path: applied.path,
        ) ||
        applied.patchSha256 != patchSha256 ||
        (applied.source != null && applied.source != source);
  }

  PatchStatus _inspectPackage({
    required String package,
    required List<PackageVersionPath> edit,
    required List<PackageVersionPath> patchFiles,
    required List<PackageVersionPath> appliedDirectories,
    required PubResolution? resolution,
    required PatchworkException? resolutionError,
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
      try {
        _editSessionStore.read(edit.single);
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

    AppliedMarker? applied;
    final appliedForVersion = appliedDirectories
        .where((candidate) => candidate.version == version)
        .toList();
    if (appliedForVersion.isNotEmpty) {
      try {
        applied = _appliedMarkerStore.read(package, version);
      } on PatchworkException catch (error) {
        problems.add(
          PatchProblem(
            code: error.code,
            message: error.message,
            hint: error.hint,
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
                'Remove ${relativePath(_layout.appliedPath(package, version))} before applying again if it is safe.',
          ),
        );
      }
    }
    for (final appliedDirectory in appliedDirectories) {
      if (appliedDirectory.version == version) {
        continue;
      }
      problems.add(
        PatchProblem(
          code: 'applied.stale',
          message:
              'Generated output ${relativePath(appliedDirectory.path)} targets "$package@${appliedDirectory.version}", but current state is "$package@$version".',
          hint: 'Run patchwork prune to remove unreferenced generated output.',
        ),
      );
    }

    if (!hasPatchFile && edit.isNotEmpty) {
      problems.add(
        PatchProblem(
          code: 'commit.open_edit',
          message: 'Package "$package" has an uncommitted edit directory.',
          hint:
              'Run patchwork commit $package, or patchwork remove $package $version --force to discard it.',
        ),
      );
    } else if (edit.isNotEmpty) {
      problems.add(
        PatchProblem(
          code: 'apply.open_edit',
          message: 'Package "$package" has an open edit directory.',
          hint: 'Run patchwork commit $package before applying this patch.',
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
                'Patch file ${relativePath(patch.path)} targets "$package@${patch.version}", but current pub resolution is "$package@${resolved.version}".',
            hint:
                'Use patchwork patch $package --continue ${patch.version} to carry it forward, or patchwork remove $package ${patch.version} to remove it.',
          ),
        );
      }
    }

    final appliedPathInProject = applied == null
        ? (appliedForVersion.isEmpty
              ? null
              : _patchworkAppliedPath(
                  package,
                  version,
                  _layout.relativeAppliedPath(package, version),
                ))
        : _patchworkAppliedPath(package, version, applied.path);
    final appliedAbsolutePath = applied == null
        ? appliedPathInProject
        : _absoluteFromRoot(applied.path);
    final appliedExists =
        appliedPathInProject != null &&
        Directory(appliedPathInProject).existsSync();
    final overridePointsToApplied =
        applied != null &&
        _pubspecOverrides.pointsToPath(
          workspaceRootPath: _rootPath,
          package: package,
          path: applied.path,
        );
    final hasBlockingOverride =
        hasPatchFile &&
        (_hasBlockingPendingOverride(
              package: package,
              version: version,
              applied: applied,
            ) ||
            _hasForeignOverride(package, applied));
    final repairHint = pubResolutionMatchesSource
        ? 'Run patchwork apply $package.'
        : 'Run patchwork undo $package, dart pub get, then patchwork apply $package.';
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
                  _needsApply(
                    package: package,
                    version: version,
                    patchSha256: patchSha256,
                    source: resolved.source,
                    applied: applied,
                  ))),
      problems: problems,
    );
  }

  String _absoluteFromRoot(String path) {
    final absolute = p.isAbsolute(path) ? path : p.absolute(_rootPath, path);
    return p.normalize(absolute);
  }

  String? _projectChildPath(String path) {
    final absolute = _absoluteFromRoot(path);
    final root = p.normalize(p.absolute(_rootPath));
    if (p.equals(root, absolute) || !p.isWithin(root, absolute)) {
      return null;
    }
    final canonical = _canonicalPathThroughExistingAncestors(absolute);
    final canonicalRoot = _canonicalPathThroughExistingAncestors(root);
    if (canonical == null ||
        canonicalRoot == null ||
        p.equals(canonicalRoot, canonical) ||
        !p.isWithin(canonicalRoot, canonical)) {
      return null;
    }
    return absolute;
  }

  String? _deletableProjectChildPath(String path) {
    final absolute = _projectChildPath(path);
    if (absolute == null || _isProtectedRootPath(absolute)) {
      return null;
    }
    return absolute;
  }

  String? _patchworkAppliedPath(String package, String version, String path) {
    final absolute = _deletableProjectChildPath(path);
    if (absolute == null) {
      return null;
    }
    final expected = p.normalize(_layout.appliedPath(package, version));
    if (!p.equals(absolute, expected)) {
      return null;
    }
    return absolute;
  }

  String _requirePatchworkAppliedPath(
    String package,
    String version,
    String path, {
    required String code,
    required String message,
  }) {
    final absolute = _patchworkAppliedPath(package, version, path);
    if (absolute == null) {
      throw PatchworkException(message, code: code, location: path);
    }
    return absolute;
  }

  bool _isProtectedRootPath(String path) {
    final normalized = p.normalize(path);
    final canonical = _canonicalPathIfExists(path);
    for (final protectedRoot in _protectedRootPaths) {
      if (p.equals(normalized, protectedRoot)) {
        return true;
      }
      final canonicalProtectedRoot = _canonicalPathIfExists(protectedRoot);
      if (canonical != null &&
          canonicalProtectedRoot != null &&
          p.equals(canonical, canonicalProtectedRoot)) {
        return true;
      }
    }
    return false;
  }
}

final class _OverrideConflict {
  const _OverrideConflict({required this.fileName, required this.path});

  final String fileName;
  final String path;
}

String? _canonicalPathIfExists(String path) {
  try {
    return p.normalize(_resolveExistingPath(path));
  } on FileSystemException {
    return null;
  }
}

String? _canonicalPathThroughExistingAncestors(String path) {
  final missingSegments = <String>[];
  var current = p.normalize(path);
  while (FileSystemEntity.typeSync(current, followLinks: false) ==
      FileSystemEntityType.notFound) {
    final parent = p.dirname(current);
    if (p.equals(parent, current)) {
      return null;
    }
    missingSegments.add(p.basename(current));
    current = parent;
  }

  try {
    var canonical = p.normalize(_resolveExistingPath(current));
    for (final segment in missingSegments.reversed) {
      canonical = p.join(canonical, segment);
    }
    return p.normalize(canonical);
  } on FileSystemException {
    return null;
  }
}

String _resolveExistingPath(String path) {
  return switch (FileSystemEntity.typeSync(path, followLinks: false)) {
    FileSystemEntityType.directory => Directory(
      path,
    ).resolveSymbolicLinksSync(),
    FileSystemEntityType.file => File(path).resolveSymbolicLinksSync(),
    FileSystemEntityType.link => Link(path).resolveSymbolicLinksSync(),
    _ => throw FileSystemException('Path cannot be resolved.', path),
  };
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
