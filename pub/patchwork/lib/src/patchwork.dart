import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'error.dart';
import 'internal/package_tree.dart';
import 'internal/path_layout.dart';
import 'io/atomic_file_writer.dart';
import 'lock/patchwork_lock.dart';
import 'model.dart';
import 'patch/patch_file.dart';
import 'pub/package_resolution.dart';
import 'pub/pubspec_overrides.dart';
import 'pub/pub_workspace.dart';

final class Patchwork {
  Patchwork._({
    required this.rootPath,
    required this.layout,
    required this.pubResolutionReader,
    required this.lockStore,
    required this.packageTree,
    required this.patchFile,
    required this.pubspecOverrides,
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
      layout: layout,
      pubResolutionReader: const PubResolutionReader(),
      lockStore: PatchworkLockStore(path: layout.lockfilePath),
      packageTree: const PackageTree(),
      patchFile: const PatchFile(),
      pubspecOverrides: const PubspecOverrides(),
    );
  }

  final String rootPath;
  final PathLayout layout;
  final PubResolutionReader pubResolutionReader;
  final PatchworkLockStore lockStore;
  final PackageTree packageTree;
  final PatchFile patchFile;
  final PubspecOverrides pubspecOverrides;

  Future<PreparedEdit> prepareEdit(
    String package, {
    PatchRef? fromPatch,
    bool replaceExisting = false,
  }) async {
    _checkPlainPackageName(package);
    final resolution = _readResolution();
    final resolved = _resolveRealPackage(resolution, package);
    final editPath = layout.editPath(package, resolved.version);

    if (Directory(editPath).existsSync()) {
      if (!replaceExisting) {
        throw PatchworkException(
          'Edit directory already exists for "$package".',
          code: 'patch.edit_exists',
          hint:
              'Run patchwork commit $package, delete $editPath, or pass --force.',
          location: editPath,
        );
      }
      packageTree.deleteDirectory(editPath);
    }

    packageTree.copy(resolved.rootPath, editPath);

    String? continuedFromVersion;
    if (fromPatch != null) {
      final patchVersion = fromPatch.version ?? resolved.version;
      final patchPath = layout.patchPath(package, patchVersion);
      final patch = File(patchPath);
      if (!patch.existsSync()) {
        packageTree.deleteDirectory(editPath);
        throw PatchworkException(
          'Patch file does not exist for "$package@$patchVersion".',
          code: 'patch.continue_patch_missing',
          location: patchPath,
        );
      }
      try {
        patchFile.apply(
          packagePath: editPath,
          patchContent: patch.readAsStringSync(),
        );
      } on PatchworkException {
        packageTree.deleteDirectory(editPath);
        rethrow;
      }
      continuedFromVersion = patchVersion;
    }

    final lock = lockStore.read();
    lock.packages[package] = _packageRecordAfterSourceRefresh(
      previous: lock.packages[package],
      resolved: resolved,
    );
    lockStore.write(lock);

    return PreparedEdit(
      package: package,
      version: resolved.version,
      path: editPath,
      sourcePath: resolved.rootPath,
      source: resolved.source,
      continuedFromVersion: continuedFromVersion,
    );
  }

  Future<PatchWrite> writePatch(String package) async {
    _checkPlainPackageName(package);
    final edit = _singleEditDirectory(package);
    return _writePatchFromEdit(edit);
  }

  Future<AppliedPatch> applyPatch(String package) async {
    _checkPlainPackageName(package);
    final lock = lockStore.read();
    final record = lock.packages[package];
    if (record == null || record.patch == null) {
      throw PatchworkException(
        'No committed patch exists for "$package".',
        code: 'apply.patch_missing',
        hint: 'Run patchwork commit $package first.',
      );
    }

    final resolution = _readResolution();
    final resolved = _resolveRealPackage(resolution, package);
    _ensureResolutionMatchesLock(package, resolved, record);

    final patchPath = layout.patchPath(package, record.version);
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

    final appliedPath = layout.appliedPath(package, record.version);
    final tempPath = p.join(
      layout.appliedRootPath,
      '.$package@${record.version}.$pid.${DateTime.now().microsecondsSinceEpoch}',
    );
    packageTree.deleteDirectory(tempPath);
    Directory(tempPath).createSync(recursive: true);
    try {
      packageTree.copy(resolved.rootPath, tempPath);
      patchFile.apply(
        packagePath: tempPath,
        patchContent: utf8.decode(patchBytes),
      );
      packageTree.deleteDirectory(appliedPath);
      Directory(p.dirname(appliedPath)).createSync(recursive: true);
      Directory(tempPath).renameSync(appliedPath);
    } catch (_) {
      packageTree.deleteDirectory(tempPath);
      rethrow;
    }

    final relativePath = layout.relativeAppliedPath(package, record.version);
    pubspecOverrides.upsertPathOverride(
      workspaceRootPath: rootPath,
      package: package,
      path: relativePath,
    );
    lock.packages[package] = record.copyWith(
      applied: LockApplied(patchSha256: patchSha256, path: relativePath),
    );
    lockStore.write(lock);

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
    final lock = lockStore.read();
    final record = lock.packages[package];
    final applied = record?.applied;
    if (record == null || applied == null) {
      return UnappliedPatch(package: package, changed: false);
    }

    final absoluteAppliedPath = p.normalize(p.absolute(rootPath, applied.path));
    final overrideRemoved = pubspecOverrides.removePathOverrideIfMatches(
      workspaceRootPath: rootPath,
      package: package,
      path: applied.path,
    );
    final generated = Directory(absoluteAppliedPath);
    final generatedExisted = generated.existsSync();
    if (generatedExisted) {
      generated.deleteSync(recursive: true);
    }

    lock.packages[package] = record.copyWith(clearApplied: true);
    lockStore.write(lock);

    return UnappliedPatch(
      package: package,
      changed: overrideRemoved || generatedExisted,
      path: absoluteAppliedPath,
    );
  }

  Future<PatchworkState> inspect() async {
    final lock = lockStore.read();
    final edits = layout.editDirectories();
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
    return pubResolutionReader.readFromDirectory(rootPath);
  }

  ResolvedPubPackage _resolveRealPackage(
    PubResolution resolution,
    String package,
  ) {
    final resolved = resolution.resolvePackage(package);
    if (layout.isAppliedPath(resolved.rootPath)) {
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

  LockPackage _packageRecordAfterSourceRefresh({
    required LockPackage? previous,
    required ResolvedPubPackage resolved,
  }) {
    final canPreservePatch =
        previous != null &&
        previous.version == resolved.version &&
        previous.source == resolved.source;
    return LockPackage(
      version: resolved.version,
      source: resolved.source,
      patch: canPreservePatch ? previous.patch : null,
      applied: canPreservePatch ? previous.applied : null,
    );
  }

  PackageVersionPath _singleEditDirectory(String package) {
    final edits = layout
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

    final lock = lockStore.read();
    final record = lock.packages[edit.package];
    if (record == null) {
      throw PatchworkException(
        'patchwork.lock has no source record for "${edit.package}".',
        code: 'commit.source_missing',
        hint: 'Create edits with patchwork patch ${edit.package}.',
      );
    }
    _ensureResolutionMatchesLock(edit.package, resolved, record);

    final patchPath = layout.patchPath(edit.package, edit.version);
    final editSha256 = packageTree.sha256Of(edit.path);
    final currentPatch = record.patch;
    if (currentPatch != null &&
        currentPatch.editSha256 == editSha256 &&
        File(patchPath).existsSync() &&
        _sha256(File(patchPath).readAsBytesSync()) == currentPatch.sha256) {
      packageTree.deleteDirectory(edit.path);
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

    final content = patchFile.build(
      sourcePath: resolved.rootPath,
      editPath: edit.path,
    );
    if (content.isEmpty) {
      final patch = File(patchPath);
      if (patch.existsSync()) {
        patch.deleteSync();
      }
      lock.packages[edit.package] = record.copyWith(clearPatch: true);
      lockStore.write(lock);
      packageTree.deleteDirectory(edit.path);
      return PatchWrite(
        package: edit.package,
        version: edit.version,
        status: PatchWriteStatus.removed,
        editPath: edit.path,
        patchPath: patchPath,
        editSha256: editSha256,
      );
    }

    patchFile.validate(sourcePath: resolved.rootPath, patchContent: content);
    final patchBytes = utf8.encode(content);
    final patchSha256 = _sha256(patchBytes);
    writeBytesFileAtomically(patchPath, patchBytes);
    lock.packages[edit.package] = record.copyWith(
      patch: LockPatch(editSha256: editSha256, sha256: patchSha256),
    );
    lockStore.write(lock);
    packageTree.deleteDirectory(edit.path);

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
    LockPackage record,
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
    required LockPackage? record,
    required List<PackageVersionPath> edit,
    required PubResolution? resolution,
    required PatchworkException? resolutionError,
  }) {
    final problems = <PatchProblem>[];
    final patchPath = layout.patchPath(package, version);
    final patchFileOnDisk = File(patchPath);
    final hasPatchFile = patchFileOnDisk.existsSync();
    String? actualPatchSha256;
    if (hasPatchFile) {
      actualPatchSha256 = _sha256(patchFileOnDisk.readAsBytesSync());
    }

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
        if (layout.isAppliedPath(resolved.rootPath)) {
          final expectedAppliedPath = record.applied == null
              ? null
              : p.normalize(p.absolute(rootPath, record.applied!.path));
          final resolvedPath = p.normalize(p.absolute(resolved.rootPath));
          if (expectedAppliedPath == null ||
              !p.equals(resolvedPath, expectedAppliedPath)) {
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

    final applied = record?.applied;
    final appliedAbsolutePath = applied == null
        ? null
        : p.absolute(rootPath, applied.path);
    final appliedExists =
        appliedAbsolutePath != null &&
        Directory(appliedAbsolutePath).existsSync();
    if (applied != null && !appliedExists) {
      problems.add(
        PatchProblem(
          code: 'applied.output_missing',
          message:
              'patchwork.lock records an applied patch, but the generated directory is missing.',
          hint: 'Run patchwork apply $package.',
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
          hint: 'Run patchwork apply $package.',
        ),
      );
    }
    if (applied != null &&
        !pubspecOverrides.pointsToPath(
          workspaceRootPath: rootPath,
          package: package,
          path: applied.path,
        )) {
      problems.add(
        PatchProblem(
          code: 'applied.override_missing',
          message:
              'pubspec_overrides.yaml no longer points at the applied patch.',
          hint: 'Run patchwork apply $package or patchwork undo $package.',
        ),
      );
    }

    return PatchStatus(
      package: package,
      version: version,
      editPath: layout.editPath(package, version),
      patchPath: patchPath,
      appliedPath: appliedAbsolutePath,
      hasOpenEdit: edit.isNotEmpty,
      hasPatch: lockPatch != null && hasPatchFile,
      isApplied: applied != null,
      needsApply:
          lockPatch != null &&
          hasPatchFile &&
          (applied == null || applied.patchSha256 != lockPatch.sha256),
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
