import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'error.dart';
import 'internal/package_tree.dart';
import 'internal/path_layout.dart';
import 'io/atomic_file_writer.dart';
import 'lockfile.dart';
import 'model.dart';
import 'patch_file.dart';
import 'pub/package_resolution.dart';
import 'pub/pubspec_overrides.dart';
import 'pub/pub_workspace.dart';

final class Patchwork {
  Patchwork._({
    required this._rootPath,
    required this._currentPackageRootPath,
    required this._layout,
    required this._pubResolutionReader,
    required this._lockStore,
    required this._packageTree,
    required this._patchFile,
    required this._pubspecOverrides,
  });

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
      layout: layout,
      pubResolutionReader: const PubResolutionReader(),
      lockStore: LockfileStore(path: layout.lockfilePath),
      packageTree: const PackageTree(),
      patchFile: const PatchFile(),
      pubspecOverrides: const PubspecOverrides(),
    );
  }

  final String _rootPath;
  final String _currentPackageRootPath;
  final PathLayout _layout;
  final PubResolutionReader _pubResolutionReader;
  final LockfileStore _lockStore;
  final PackageTree _packageTree;
  final PatchFile _patchFile;
  final PubspecOverrides _pubspecOverrides;

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

  Future<PreparedEdit> prepareEdit(
    String package, {
    PatchRef? fromPatch,
    bool replaceExisting = false,
  }) async {
    _checkPlainPackageName(package);
    final resolution = _readResolution();
    final resolved = _resolveRealPackage(resolution, package);
    final editPath = _layout.editPath(package, resolved.version);
    final existingRecord = _lockStore.read().packages[package];
    if (existingRecord?.applied != null) {
      throw PatchworkException(
        'Package "$package" already has an applied Patchwork patch.',
        code: 'patch.package_applied',
        hint:
            'Run patchwork undo $package, then dart pub get, before patching it again.',
      );
    }
    _rejectBlockingOverride(
      package: package,
      version: resolved.version,
      command: 'patch',
    );

    String? continuedFromVersion;
    String? continuedFromPatchPath;
    String? continuedFromPatchContent;
    if (fromPatch != null) {
      final patchVersion = fromPatch.version ?? resolved.version;
      final patchPath = _layout.patchPath(package, patchVersion);
      final patch = File(patchPath);
      if (!patch.existsSync()) {
        throw PatchworkException(
          'Patch file does not exist for "$package@$patchVersion".',
          code: 'patch.continue_patch_missing',
          location: patchPath,
        );
      }
      _verifyContinuedPatch(
        package: package,
        version: patchVersion,
        patchPath: patchPath,
      );
      continuedFromPatchContent = patch.readAsStringSync();
      continuedFromPatchPath = patchPath;
      continuedFromVersion = patchVersion;
    }

    final editExists = Directory(editPath).existsSync();
    if (editExists) {
      if (!replaceExisting) {
        throw PatchworkException(
          'Edit directory already exists for "$package".',
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

    final lock = _lockStore.read();
    lock.packages[package] = _packageRecordAfterSourceRefresh(
      previous: lock.packages[package],
      resolved: resolved,
    );
    _lockStore.write(lock);

    return PreparedEdit(
      package: package,
      version: resolved.version,
      path: editPath,
      sourcePath: resolved.rootPath,
      source: resolved.source,
      continuedFromVersion: continuedFromVersion,
      continuedFromPatchPath: continuedFromPatchPath,
    );
  }

  Future<PatchWrite> writePatch(String package) async {
    _checkPlainPackageName(package);
    final edit = _singleEditDirectory(package);
    return _writePatchFromEdit(edit);
  }

  Future<AppliedPatch> applyPatch(String package) async {
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

    final lock = _lockStore.read();
    final record = lock.packages[package];
    if (record == null || record.patch == null) {
      throw PatchworkException(
        'No committed patch exists for "$package".',
        code: 'apply.patch_missing',
        hint: 'Run patchwork commit $package first.',
      );
    }

    final patchPath = _layout.patchPath(package, record.version);
    final patchFileOnDisk = File(patchPath);
    if (!patchFileOnDisk.existsSync()) {
      throw PatchworkException(
        'Committed patch file is missing for "$package".',
        code: 'apply.patch_file_missing',
        location: patchPath,
      );
    }

    final patchBytes = patchFileOnDisk.readAsBytesSync();
    final patchSha256 = _sha256(patchBytes);
    if (patchSha256 != record.patch!.sha256) {
      throw PatchworkException(
        'Patch file sha256 does not match patchwork.lock.',
        code: 'apply.patch_sha_mismatch',
        location: patchPath,
      );
    }

    final appliedPath = _layout.appliedPath(package, record.version);
    final relativePath = _layout.relativeAppliedPath(package, record.version);
    final existingApplied = record.applied;
    final canReplaceApplied =
        existingApplied != null &&
        existingApplied.path == relativePath &&
        _layout.isExpectedAppliedPath(
          package,
          record.version,
          existingApplied.path,
        );
    if (!canReplaceApplied && Directory(appliedPath).existsSync()) {
      throw PatchworkException(
        'Applied output path already exists for "$package".',
        code: 'apply.applied_path_exists',
        hint:
            'Patchwork cannot replace it without a matching patchwork.lock applied record.',
        location: appliedPath,
      );
    }
    _pubspecOverrides.assertCanUpsertPathOverride(
      workspaceRootPath: _rootPath,
      package: package,
      path: relativePath,
      replaceExisting: canReplaceApplied,
    );

    final resolution = _readResolution();
    final resolved = _resolveRealPackage(resolution, package);
    _ensureResolutionMatchesLock(package, resolved, record);

    final tempPath = p.join(
      _layout.appliedRootPath,
      '.$package@${record.version}.$pid.${DateTime.now().microsecondsSinceEpoch}',
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

    _pubspecOverrides.upsertPathOverride(
      workspaceRootPath: _rootPath,
      package: package,
      path: relativePath,
      replaceExisting: canReplaceApplied,
    );
    lock.packages[package] = record.copyWith(
      applied: AppliedPatchRecord(patchSha256: patchSha256, path: relativePath),
    );
    _lockStore.write(lock);

    return AppliedPatch(
      package: package,
      version: record.version,
      path: appliedPath,
      patchPath: patchPath,
      patchSha256: patchSha256,
    );
  }

  Future<UnappliedPatch> unapplyPatch(String package) async {
    _checkPlainPackageName(package);
    final lock = _lockStore.read();
    final record = lock.packages[package];
    final applied = record?.applied;
    if (record == null || applied == null) {
      return UnappliedPatch(package: package, changed: false);
    }

    if (!_layout.isExpectedAppliedPath(package, record.version, applied.path)) {
      throw PatchworkException(
        'patchwork.lock applied path does not match the package being undone.',
        code: 'undo.unsafe_applied_path',
        location: applied.path,
      );
    }
    final absoluteAppliedPath = p.normalize(
      p.absolute(_rootPath, applied.path),
    );
    _pubspecOverrides.removePathOverrideIfMatches(
      workspaceRootPath: _rootPath,
      package: package,
      path: applied.path,
    );
    final generated = Directory(absoluteAppliedPath);
    final generatedExisted = generated.existsSync();
    if (generatedExisted) {
      generated.deleteSync(recursive: true);
    }

    lock.packages[package] = record.copyWith(clearApplied: true);
    _lockStore.write(lock);

    return UnappliedPatch(
      package: package,
      changed: true,
      path: absoluteAppliedPath,
    );
  }

  Future<PatchworkState> inspect() async {
    final lock = _lockStore.read();
    final edits = _layout.editDirectories();
    final packages = <String>{
      ...lock.packages.keys,
      ...edits.map((edit) => edit.package),
    };
    final statuses = <PatchStatus>[];
    PubResolution? resolution;
    PatchworkException? resolutionError;
    try {
      resolution = _readResolution();
    } on PatchworkException catch (error) {
      resolutionError = error;
    }

    for (final package in packages.toList()..sort()) {
      final record = lock.packages[package];
      final edit = edits
          .where((candidate) => candidate.package == package)
          .toList();
      final version =
          record?.version ?? (edit.isNotEmpty ? edit.first.version : 'unknown');
      statuses.add(
        _inspectPackage(
          package: package,
          version: version,
          record: record,
          edit: edit,
          resolution: resolution,
          resolutionError: resolutionError,
        ),
      );
    }
    return PatchworkState(packages: statuses);
  }

  PubResolution _readResolution() {
    return _pubResolutionReader.readFromDirectory(_currentPackageRootPath);
  }

  ResolvedPubPackage _resolveRealPackage(
    PubResolution resolution,
    String package,
  ) {
    final resolved = resolution.resolvePackage(package);
    if (_layout.isAppliedPath(resolved.rootPath)) {
      throw PatchworkException(
        'Package "$package" currently resolves to a Patchwork applied copy.',
        code: 'pub.package_resolves_to_applied',
        hint:
            'Run patchwork undo $package, then dart pub get, before patching it again.',
        location: resolved.rootPath,
      );
    }
    return resolved;
  }

  LockfilePackage _packageRecordAfterSourceRefresh({
    required LockfilePackage? previous,
    required ResolvedPubPackage resolved,
  }) {
    final canPreservePatch =
        previous != null &&
        previous.version == resolved.version &&
        previous.source == resolved.source;
    final patchHistory = <String, HistoricalPatch>{
      if (previous != null) ...previous.patchHistory,
    };
    if (!canPreservePatch && previous?.patch != null) {
      patchHistory[previous!.version] = HistoricalPatch(
        sha256: previous.patch!.sha256,
      );
    }

    return LockfilePackage(
      version: resolved.version,
      source: resolved.source,
      patch: canPreservePatch ? previous.patch : null,
      patchHistory: patchHistory,
      applied: canPreservePatch ? previous.applied : null,
    );
  }

  void _verifyContinuedPatch({
    required String package,
    required String version,
    required String patchPath,
  }) {
    final record = _lockStore.read().packages[package];
    final expectedSha256 = record == null
        ? null
        : record.version == version
        ? record.patch?.sha256
        : record.patchHistory[version]?.sha256;
    if (expectedSha256 == null) {
      throw PatchworkException(
        'patchwork.lock has no committed patch record for "$package@$version".',
        code: 'patch.continue_patch_unlocked',
        hint: 'Commit the patch before using --continue.',
      );
    }
    final patchSha256 = _sha256(File(patchPath).readAsBytesSync());
    if (patchSha256 != expectedSha256) {
      throw PatchworkException(
        'Patch file sha256 does not match patchwork.lock.',
        code: 'patch.continue_patch_sha_mismatch',
        location: patchPath,
      );
    }
  }

  void _rejectBlockingOverride({
    required String package,
    required String version,
    required String command,
  }) {
    if (!_pubspecOverrides.hasBlockingPathOverride(
      workspaceRootPath: _rootPath,
      package: package,
      path: _layout.relativeAppliedPath(package, version),
      replaceExisting: false,
    )) {
      return;
    }

    throw PatchworkException(
      'pubspec_overrides.yaml already has a dependency override for "$package".',
      code: 'pub.override_conflict',
      hint:
          'Remove or resolve the existing override before running patchwork $command $package.',
      location: p.join(_rootPath, 'pubspec_overrides.yaml'),
    );
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

  Future<PatchWrite> _writePatchFromEdit(PackageVersionPath edit) async {
    final resolution = _readResolution();
    final resolved = _resolveRealPackage(resolution, edit.package);
    if (resolved.version != edit.version) {
      throw PatchworkException(
        'Current pub resolution selects ${resolved.version}, but the edit directory is ${edit.version}.',
        code: 'commit.version_mismatch',
        hint:
            'Commit before upgrading, or recreate the edit directory with patchwork patch ${edit.package}.',
        location: edit.path,
      );
    }

    final lock = _lockStore.read();
    final record = lock.packages[edit.package];
    if (record == null) {
      throw PatchworkException(
        'patchwork.lock has no source record for "${edit.package}".',
        code: 'commit.source_missing',
        hint: 'Create edits with patchwork patch ${edit.package}.',
      );
    }
    _ensureResolutionMatchesLock(edit.package, resolved, record);

    final patchPath = _layout.patchPath(edit.package, edit.version);
    final editSha256 = _packageTree.sha256Of(edit.path);
    final currentPatch = record.patch;
    if (currentPatch != null &&
        currentPatch.editSha256 == editSha256 &&
        File(patchPath).existsSync() &&
        _sha256(File(patchPath).readAsBytesSync()) == currentPatch.sha256) {
      _packageTree.deleteDirectory(edit.path);
      return PatchWrite(
        package: edit.package,
        version: edit.version,
        status: PatchWriteStatus.unchanged,
        editPath: edit.path,
        patchPath: patchPath,
        patchSha256: currentPatch.sha256,
        editSha256: editSha256,
      );
    }

    final content = _patchFile.build(
      sourcePath: resolved.rootPath,
      editPath: edit.path,
    );
    if (content.isEmpty) {
      final patch = File(patchPath);
      if (patch.existsSync()) {
        patch.deleteSync();
      }
      lock.packages.remove(edit.package);
      _lockStore.write(lock);
      _packageTree.deleteDirectory(edit.path);
      return PatchWrite(
        package: edit.package,
        version: edit.version,
        status: PatchWriteStatus.removed,
        editPath: edit.path,
        patchPath: patchPath,
        editSha256: editSha256,
      );
    }

    _patchFile.validate(sourcePath: resolved.rootPath, patchContent: content);
    final patchBytes = utf8.encode(content);
    final patchSha256 = _sha256(patchBytes);
    writeBytesFileAtomically(patchPath, patchBytes);
    final patchHistory = Map<String, HistoricalPatch>.of(record.patchHistory)
      ..remove(edit.version);
    lock.packages[edit.package] = record.copyWith(
      patch: CommittedPatch(editSha256: editSha256, sha256: patchSha256),
      patchHistory: patchHistory,
    );
    _lockStore.write(lock);
    _packageTree.deleteDirectory(edit.path);

    return PatchWrite(
      package: edit.package,
      version: edit.version,
      status: PatchWriteStatus.written,
      editPath: edit.path,
      patchPath: patchPath,
      patchSha256: patchSha256,
      editSha256: editSha256,
    );
  }

  void _ensureResolutionMatchesLock(
    String package,
    ResolvedPubPackage resolved,
    LockfilePackage record,
  ) {
    if (resolved.version != record.version) {
      throw PatchworkException(
        'Package "$package" resolved to ${resolved.version}, but patchwork.lock records ${record.version}.',
        code: 'pub.dependency_changed',
        hint:
            'If you upgraded the dependency, run patchwork undo $package, dart pub get, then patchwork patch $package --continue ${record.version}.',
      );
    }
    if (resolved.source != record.source) {
      throw PatchworkException(
        'Package "$package" source does not match patchwork.lock.',
        code: 'pub.source_changed',
        hint:
            'The dependency source may have changed. Recreate the edit from the current source when this is intentional.',
      );
    }
  }

  PatchStatus _inspectPackage({
    required String package,
    required String version,
    required LockfilePackage? record,
    required List<PackageVersionPath> edit,
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

    final patchPath = _layout.patchPath(package, version);
    final patchFileOnDisk = File(patchPath);
    final hasPatchFile = patchFileOnDisk.existsSync();
    String? actualPatchSha256;
    if (hasPatchFile) {
      actualPatchSha256 = _sha256(patchFileOnDisk.readAsBytesSync());
    }
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
    } else if (resolution != null && record != null) {
      try {
        final resolved = resolution.resolvePackage(package);
        if (_layout.isAppliedPath(resolved.rootPath)) {
          final expectedAppliedPath = record.applied == null
              ? null
              : p.normalize(p.absolute(_rootPath, record.applied!.path));
          final resolvedPath = p.normalize(p.absolute(resolved.rootPath));
          pubResolutionPointsToApplied =
              expectedAppliedPath != null &&
              p.equals(resolvedPath, expectedAppliedPath);
          if (!pubResolutionPointsToApplied) {
            problems.add(
              PatchProblem(
                code: 'pub.package_resolves_to_applied',
                message: 'Package resolves to a Patchwork applied copy.',
                hint: 'Run patchwork undo $package, then dart pub get.',
              ),
            );
          }
        } else if (resolved.version != record.version ||
            resolved.source != record.source) {
          problems.add(
            PatchProblem(
              code: 'pub.source_changed',
              message: 'Current dependency source differs from patchwork.lock.',
              hint:
                  'Use patchwork undo $package and dart pub get before upgrading or carrying the patch forward.',
            ),
          );
        } else {
          pubResolutionMatchesSource = true;
        }
        final applied = record.applied;
        if (applied != null &&
            !_layout.isAppliedPath(resolved.rootPath) &&
            p.normalize(p.absolute(resolved.rootPath)) !=
                p.normalize(p.absolute(_rootPath, applied.path))) {
          problems.add(
            PatchProblem(
              code: 'applied.pub_get_required',
              message:
                  'pub resolution has not activated the applied patch yet.',
              hint: 'Run dart pub get.',
            ),
          );
        }
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

    final lockPatch = record?.patch;
    final applied = record?.applied;
    if (lockPatch != null && edit.isNotEmpty) {
      problems.add(
        PatchProblem(
          code: 'apply.open_edit',
          message: 'Package "$package" has an open edit directory.',
          hint: 'Commit or delete the edit before applying this patch.',
        ),
      );
    }
    if (lockPatch != null && !hasPatchFile) {
      problems.add(
        PatchProblem(
          code: 'patch.file_missing',
          message:
              'patchwork.lock records a patch, but the patch file is missing.',
          hint: 'Run patchwork commit $package to recreate it.',
        ),
      );
    }
    if (record != null &&
        lockPatch == null &&
        applied == null &&
        edit.isEmpty &&
        record.patchHistory.isNotEmpty) {
      problems.add(
        PatchProblem(
          code: 'patch.history_only',
          message: 'patchwork.lock has only historical patches for "$package".',
          hint:
              'Create and commit a new edit, or remove the stale lockfile entry.',
        ),
      );
    }
    if (lockPatch != null &&
        actualPatchSha256 != null &&
        actualPatchSha256 != lockPatch.sha256) {
      problems.add(
        PatchProblem(
          code: 'patch.sha_mismatch',
          message: 'Patch file sha256 differs from patchwork.lock.',
          hint:
              'Review the patch file and run patchwork commit $package again if the edit is intentional.',
        ),
      );
    }

    final appliedPathExpected =
        applied == null ||
        _layout.isExpectedAppliedPath(package, version, applied.path);
    final appliedAbsolutePath = applied == null
        ? null
        : p.absolute(_rootPath, applied.path);
    final appliedExists =
        appliedAbsolutePath != null &&
        Directory(appliedAbsolutePath).existsSync();
    final overridePointsToApplied =
        applied != null &&
        _pubspecOverrides.pointsToPath(
          workspaceRootPath: _rootPath,
          package: package,
          path: applied.path,
        );
    final pendingAppliedPath = _layout.relativeAppliedPath(package, version);
    final hasBlockingOverride =
        lockPatch != null &&
        hasPatchFile &&
        applied == null &&
        _pubspecOverrides.hasBlockingPathOverride(
          workspaceRootPath: _rootPath,
          package: package,
          path: pendingAppliedPath,
          replaceExisting: false,
        );
    final repairHint = pubResolutionMatchesSource
        ? 'Run patchwork apply $package.'
        : 'Run patchwork undo $package, dart pub get, then patchwork apply $package.';
    if (hasBlockingOverride) {
      problems.add(
        PatchProblem(
          code: 'pub.override_conflict',
          message:
              'pubspec_overrides.yaml already has a dependency override for "$package".',
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
              'patchwork.lock records an applied patch, but the generated directory is missing.',
          hint: repairHint,
        ),
      );
    }
    if (applied != null && lockPatch == null) {
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
        lockPatch != null &&
        applied.patchSha256 != lockPatch.sha256) {
      problems.add(
        PatchProblem(
          code: 'applied.patch_stale',
          message: 'Applied patch sha256 differs from the committed patch.',
          hint: repairHint,
        ),
      );
    }
    if (applied != null && !appliedPathExpected) {
      problems.add(
        PatchProblem(
          code: 'undo.unsafe_applied_path',
          message:
              'patchwork.lock applied path does not match this package and version.',
          hint: 'Review patchwork.lock before running patchwork undo $package.',
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
      hasCommittedPatch: lockPatch != null,
      hasPatch: lockPatch != null && hasPatchFile,
      isApplied:
          applied != null &&
          appliedPathExpected &&
          appliedExists &&
          overridePointsToApplied &&
          pubResolutionPointsToApplied,
      needsApply:
          lockPatch != null &&
          hasPatchFile &&
          edit.isEmpty &&
          pubResolutionMatchesSource &&
          !hasBlockingOverride &&
          (applied == null ||
              !appliedExists ||
              !overridePointsToApplied ||
              applied.patchSha256 != lockPatch.sha256),
      source: record?.source,
      patchSha256: lockPatch?.sha256,
      appliedPatchSha256: applied?.patchSha256,
      problems: problems,
    );
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

String _sha256(List<int> bytes) {
  return sha256.convert(bytes).toString();
}
