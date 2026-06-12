import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../diagnostics/diagnostic.dart';
import '../pub/package_resolution.dart';
import '../pub/pub_workspace.dart';
import '../target/target.dart';
import 'edit_session.dart';

const _excludedDirectoryNames = {'.dart_tool', '.git', 'build'};

const _excludedFileNames = {'.packages', 'pubspec.lock'};

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
      _refreshCopy(package.rootPath, baselinePath);
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

  void _refreshCopy(String sourcePath, String destinationPath) {
    final destination = Directory(destinationPath);
    if (destination.existsSync()) {
      destination.deleteSync(recursive: true);
    }

    destination.createSync(recursive: true);
    _copyDirectoryContents(
      sourceRootPath: sourcePath,
      sourcePath: sourcePath,
      destinationPath: destinationPath,
    );
  }

  void _copyDirectoryContents({
    required String sourceRootPath,
    required String sourcePath,
    required String destinationPath,
  }) {
    for (final entity in Directory(sourcePath).listSync(followLinks: false)) {
      final relativePath = p.relative(entity.path, from: sourceRootPath);
      final type = FileSystemEntity.typeSync(entity.path, followLinks: false);
      if (_shouldExclude(relativePath, type)) {
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

  bool _shouldExclude(String relativePath, FileSystemEntityType type) {
    final name = p.basename(relativePath);
    if (type == FileSystemEntityType.directory) {
      return _excludedDirectoryNames.contains(name);
    }

    return _excludedFileNames.contains(name);
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
}
