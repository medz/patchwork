import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../diagnostics/diagnostic.dart';
import '../pub/package_resolution.dart';
import '../pub/pub_workspace.dart';
import '../session/session_file_filter.dart';
import 'patchwork_manifest.dart';
import '../target/target.dart';
import 'edit_session.dart';

final class PatchworkStore {
  const PatchworkStore();

  PubPatchSessionCreateResult createPubEditSession({
    required PubWorkspace workspace,
    required ResolvedPubPackage package,
  }) {
    final sessionId = '${package.name}@${package.version}';
    final patchworkRoot = p.join(workspace.rootPath, '.dart_tool', 'patchwork');
    final baselinePath = p.join(patchworkRoot, 'baseline', 'pub', sessionId);
    final editPath = p.join(patchworkRoot, 'edit', 'pub', sessionId);
    final metadataPath = p.join(
      patchworkRoot,
      'sessions',
      'pub',
      '$sessionId.json',
    );
    final session = PubPatchSession(
      target: PubTarget(name: package.name, versionConstraint: package.version),
      package: package,
      baselinePath: baselinePath,
      editPath: editPath,
      metadataPath: metadataPath,
    );

    try {
      _refreshCopy(
        package.rootPath,
        baselinePath,
        excludedSourcePath: patchworkRoot,
      );
      _refreshCopy(baselinePath, editPath);
      _writeMetadata(
        session,
        workspaceRootPath: workspace.rootPath,
        sourceRootPath: package.rootPath,
      );
    } on FileSystemException catch (error) {
      return PubPatchSessionCreateResult.failure(
        Diagnostic(
          code: 'pub.patch_session_failed',
          message: 'Could not create pub patch edit session.',
          hint: error.message,
          location: error.path,
        ),
      );
    }

    return PubPatchSessionCreateResult.success(session);
  }

  PubPatchSessionLocateResult locatePubEditSessionForPackage({
    required PubWorkspace workspace,
    required ResolvedPubPackage package,
  }) {
    final sessionId = '${package.name}@${package.version}';
    final metadataPath = p.join(
      workspace.rootPath,
      '.dart_tool',
      'patchwork',
      'sessions',
      'pub',
      '$sessionId.json',
    );

    return _readPubEditSessionMetadata(
      metadataPath,
      workspaceRootPath: workspace.rootPath,
      package: package,
    );
  }

  PubPatchSessionLocateResult locatePubEditSessionForEditPath({
    required String editPath,
    required String currentDirectory,
  }) {
    final absoluteEditPath = p.normalize(
      p.absolute(currentDirectory, editPath),
    );
    final metadataLocation = _metadataLocationForPubEditPath(absoluteEditPath);
    if (metadataLocation == null) {
      return PubPatchSessionLocateResult.failure(
        Diagnostic(
          code: 'pub.patch_session_not_found',
          message: 'Could not find a pub patch edit session for "$editPath".',
          hint: 'Use a path printed by patchwork patch <target>.',
          location: editPath,
        ),
      );
    }

    return _readPubEditSessionMetadata(
      metadataLocation.metadataPath,
      workspaceRootPath: metadataLocation.workspaceRootPath,
      expectedEditPath: absoluteEditPath,
    );
  }

  String pubPatchFilePath({
    required String workspaceRootPath,
    required PubPatchSession session,
  }) {
    return p.join(
      workspaceRootPath,
      'patches',
      'pub',
      '${_escapePatchPathComponent(session.package.name)}@'
          '${_escapePatchPathComponent(session.package.version)}.patch',
    );
  }

  void writePubPatchFile({
    required String workspaceRootPath,
    required PubPatchSession session,
    required String content,
  }) {
    final patchFile = File(
      pubPatchFilePath(workspaceRootPath: workspaceRootPath, session: session),
    );
    patchFile.parent.createSync(recursive: true);
    patchFile.writeAsStringSync(content);
  }

  void deletePubPatchFile({
    required String workspaceRootPath,
    required PubPatchSession session,
  }) {
    final patchFile = File(
      pubPatchFilePath(workspaceRootPath: workspaceRootPath, session: session),
    );
    if (patchFile.existsSync()) {
      patchFile.deleteSync();
    }
  }

  String pubPatchBaselinePath({
    required String workspaceRootPath,
    required ResolvedPubPackage package,
  }) {
    return p.join(
      workspaceRootPath,
      '.dart_tool',
      'patchwork',
      'baseline',
      'pub',
      '${_escapePatchPathComponent(package.name)}@'
          '${_escapePatchPathComponent(package.version)}',
    );
  }

  String pubPatchStorePath({
    required String workspaceRootPath,
    required ResolvedPubPackage package,
    required String patchHash,
  }) {
    return p.join(
      workspaceRootPath,
      '.dart_tool',
      'patchwork',
      'store',
      'pub',
      '${_escapePatchPathComponent(package.name)}@'
          '${_escapePatchPathComponent(package.version)}'
          '_patch_hash=$patchHash',
    );
  }

  String pubPatchStoreRelativePath({
    required String workspaceRootPath,
    required ResolvedPubPackage package,
    required String patchHash,
  }) {
    return patchworkManifestPath(
      p.relative(
        pubPatchStorePath(
          workspaceRootPath: workspaceRootPath,
          package: package,
          patchHash: patchHash,
        ),
        from: workspaceRootPath,
      ),
    );
  }

  bool pubPatchStoreMatchesHash({
    required String storePath,
    required String patchHash,
  }) {
    final markerFile = File(p.join(storePath, '.patchwork-patch-hash'));
    if (!Directory(storePath).existsSync() || !markerFile.existsSync()) {
      return false;
    }

    try {
      return markerFile.readAsStringSync() == '$patchHash\n';
    } on FileSystemException {
      return false;
    }
  }

  String createPatchworkTempDirectory({
    required String workspaceRootPath,
    required String prefix,
  }) {
    final tempRoot = Directory(
      p.join(workspaceRootPath, '.dart_tool', 'patchwork', 'tmp'),
    )..createSync(recursive: true);
    return tempRoot.createTempSync(prefix).path;
  }

  void copyPubPackageToDirectory({
    required String workspaceRootPath,
    required String sourcePath,
    required String destinationPath,
  }) {
    final patchworkRootPath = p.normalize(
      p.absolute(workspaceRootPath, '.dart_tool', 'patchwork'),
    );
    final sourceRootPath = p.normalize(p.absolute(sourcePath));
    _refreshCopy(
      sourcePath,
      destinationPath,
      excludedSourcePath: _isSameOrWithin(patchworkRootPath, sourceRootPath)
          ? null
          : patchworkRootPath,
    );
  }

  void writePubPatchStoreMarker({
    required String storePath,
    required String patchHash,
  }) {
    File(
      p.join(storePath, '.patchwork-patch-hash'),
    ).writeAsStringSync('$patchHash\n', flush: true);
  }

  void replaceDirectory({
    required String sourcePath,
    required String destinationPath,
  }) {
    final destination = Directory(destinationPath);
    if (destination.existsSync()) {
      destination.deleteSync(recursive: true);
    }
    Directory(p.dirname(destinationPath)).createSync(recursive: true);
    Directory(sourcePath).renameSync(destinationPath);
  }

  void deleteDirectory(String path) {
    final directory = Directory(path);
    if (directory.existsSync()) {
      directory.deleteSync(recursive: true);
    }
  }

  void _refreshCopy(
    String sourcePath,
    String destinationPath, {
    String? excludedSourcePath,
  }) {
    final sourceRootPath = p.normalize(p.absolute(sourcePath));
    final destinationRootPath = p.normalize(p.absolute(destinationPath));
    final destination = Directory(destinationPath);
    if (destination.existsSync()) {
      destination.deleteSync(recursive: true);
    }

    destination.createSync(recursive: true);
    _copyDirectoryContents(
      sourceRootPath: sourceRootPath,
      sourcePath: sourceRootPath,
      destinationPath: destinationRootPath,
      excludedSourcePath: excludedSourcePath == null
          ? null
          : p.normalize(p.absolute(excludedSourcePath)),
    );
  }

  void _copyDirectoryContents({
    required String sourceRootPath,
    required String sourcePath,
    required String destinationPath,
    required String? excludedSourcePath,
  }) {
    for (final entity in Directory(sourcePath).listSync(followLinks: false)) {
      final entityPath = p.normalize(p.absolute(entity.path));
      if (_isSameOrWithin(excludedSourcePath, entityPath)) {
        continue;
      }

      final relativePath = p.relative(entity.path, from: sourceRootPath);
      final type = FileSystemEntity.typeSync(entity.path, followLinks: false);
      if (shouldExcludePatchSessionPath(relativePath, type)) {
        continue;
      }

      final targetPath = p.join(destinationPath, p.basename(entity.path));
      switch (type) {
        case FileSystemEntityType.directory:
          Directory(targetPath).createSync(recursive: true);
          _copyDirectoryContents(
            sourceRootPath: sourceRootPath,
            sourcePath: entity.path,
            destinationPath: targetPath,
            excludedSourcePath: excludedSourcePath,
          );
        case FileSystemEntityType.file:
          File(entity.path).copySync(targetPath);
        case FileSystemEntityType.link:
          Link(targetPath).createSync(Link(entity.path).targetSync());
        case FileSystemEntityType.notFound:
        case FileSystemEntityType.pipe:
        case FileSystemEntityType.unixDomainSock:
          break;
      }
    }
  }

  bool _isSameOrWithin(String? parentPath, String childPath) {
    if (parentPath == null) {
      return false;
    }

    return p.equals(parentPath, childPath) || p.isWithin(parentPath, childPath);
  }

  void _writeMetadata(
    PubPatchSession session, {
    required String workspaceRootPath,
    required String sourceRootPath,
  }) {
    final metadataFile = File(session.metadataPath);
    metadataFile.parent.createSync(recursive: true);
    final metadata = const JsonEncoder.withIndent('  ').convert({
      'schemaVersion': 1,
      'target': session.target.toString(),
      'package': {
        'name': session.package.name,
        'version': session.package.version,
      },
      'paths': {
        'workspaceRoot': workspaceRootPath,
        'sourceRoot': sourceRootPath,
        'baseline': p.relative(session.baselinePath, from: workspaceRootPath),
        'edit': p.relative(session.editPath, from: workspaceRootPath),
      },
    });
    metadataFile.writeAsStringSync('$metadata\n');
  }

  PubPatchSessionLocateResult _readPubEditSessionMetadata(
    String metadataPath, {
    required String workspaceRootPath,
    ResolvedPubPackage? package,
    String? expectedEditPath,
  }) {
    final metadataFile = File(metadataPath);
    if (!metadataFile.existsSync()) {
      return PubPatchSessionLocateResult.failure(
        Diagnostic(
          code: 'pub.patch_session_not_found',
          message: 'Could not find a pub patch edit session.',
          hint: 'Run patchwork patch <target> before committing a patch.',
          location: metadataPath,
        ),
      );
    }

    try {
      final decoded = jsonDecode(metadataFile.readAsStringSync());
      if (decoded is! Map<String, Object?>) {
        return _malformedPubEditSession(metadataPath);
      }

      final packageJson = decoded['package'];
      final pathsJson = decoded['paths'];
      if (packageJson is! Map<String, Object?> ||
          pathsJson is! Map<String, Object?>) {
        return _malformedPubEditSession(metadataPath);
      }

      final packageName = packageJson['name'];
      final packageVersion = packageJson['version'];
      final baselinePath = pathsJson['baseline'];
      final editPath = pathsJson['edit'];
      final sourceRootPath = pathsJson['sourceRoot'];
      if (packageName is! String ||
          packageVersion is! String ||
          baselinePath is! String ||
          editPath is! String ||
          sourceRootPath is! String) {
        return _malformedPubEditSession(metadataPath);
      }

      final absoluteEditPath = p.normalize(p.join(workspaceRootPath, editPath));
      if (expectedEditPath != null &&
          !p.equals(absoluteEditPath, expectedEditPath)) {
        return PubPatchSessionLocateResult.failure(
          Diagnostic(
            code: 'pub.patch_session_not_found',
            message:
                'Could not find a pub patch edit session for "$expectedEditPath".',
            hint: 'Use a path printed by patchwork patch <target>.',
            location: expectedEditPath,
          ),
        );
      }

      final resolvedPackage =
          package ??
          ResolvedPubPackage(
            name: packageName,
            version: packageVersion,
            sourceKind: PubPackageSourceKind.unknown,
            dependencyKind: PubPackageDependencyKind.unknown,
            rootPath: sourceRootPath,
            packageUri: 'lib/',
          );

      return PubPatchSessionLocateResult.success(
        workspaceRootPath: workspaceRootPath,
        session: PubPatchSession(
          target: PubTarget(
            name: resolvedPackage.name,
            versionConstraint: resolvedPackage.version,
          ),
          package: resolvedPackage,
          baselinePath: p.normalize(p.join(workspaceRootPath, baselinePath)),
          editPath: absoluteEditPath,
          metadataPath: metadataPath,
        ),
      );
    } on FormatException {
      return _malformedPubEditSession(metadataPath);
    } on FileSystemException catch (error) {
      return PubPatchSessionLocateResult.failure(
        Diagnostic(
          code: 'pub.patch_session_not_readable',
          message: 'Could not read pub patch edit session metadata.',
          hint: error.message,
          location: metadataPath,
        ),
      );
    }
  }

  PubPatchSessionLocateResult _malformedPubEditSession(String metadataPath) {
    return PubPatchSessionLocateResult.failure(
      Diagnostic(
        code: 'pub.patch_session_malformed',
        message: 'Pub patch edit session metadata is malformed.',
        location: metadataPath,
      ),
    );
  }

  _PubEditSessionMetadataLocation? _metadataLocationForPubEditPath(
    String editPath,
  ) {
    final parts = p.split(editPath);
    for (var index = 0; index <= parts.length - 5; index += 1) {
      if (parts[index] == '.dart_tool' &&
          parts[index + 1] == 'patchwork' &&
          parts[index + 2] == 'edit' &&
          parts[index + 3] == 'pub') {
        final workspaceRootPath = index == 0
            ? p.current
            : p.joinAll(parts.take(index));
        final sessionId = parts[index + 4];
        return _PubEditSessionMetadataLocation(
          workspaceRootPath: workspaceRootPath,
          metadataPath: p.join(
            workspaceRootPath,
            '.dart_tool',
            'patchwork',
            'sessions',
            'pub',
            '$sessionId.json',
          ),
        );
      }
    }

    return null;
  }

  String _escapePatchPathComponent(String value) {
    final buffer = StringBuffer();
    for (final codeUnit in value.codeUnits) {
      final character = String.fromCharCode(codeUnit);
      if (RegExp(r'[A-Za-z0-9._-]').hasMatch(character)) {
        buffer.write(character);
      } else {
        buffer.write('%');
        buffer.write(codeUnit.toRadixString(16).toUpperCase().padLeft(2, '0'));
      }
    }
    return buffer.toString();
  }
}

final class _PubEditSessionMetadataLocation {
  const _PubEditSessionMetadataLocation({
    required this.workspaceRootPath,
    required this.metadataPath,
  });

  final String workspaceRootPath;
  final String metadataPath;
}
