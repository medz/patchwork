import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:patchwork/src/pub/package_resolution.dart';
import 'package:patchwork/src/pub/pub_workspace.dart';
import 'package:patchwork/src/store/edit_session.dart';
import 'package:patchwork/src/store/patchwork_store.dart';
import 'package:patchwork/src/target/target.dart';
import 'package:test/test.dart';

void main() {
  group('PatchworkStore', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('patchwork store ');
    });

    tearDown(() {
      if (root.existsSync()) {
        root.deleteSync(recursive: true);
      }
    });

    test('owns pub edit-session paths, copies, exclusions, and metadata', () {
      final packageRoot = p.join(root.path, 'cache', 'analyzer-7.4.0');
      Directory(p.join(packageRoot, 'lib')).createSync(recursive: true);
      Directory(
        p.join(packageRoot, 'lib', 'src', 'build'),
      ).createSync(recursive: true);
      Directory(p.join(packageRoot, '.dart_tool')).createSync(recursive: true);
      Directory(p.join(packageRoot, 'build')).createSync(recursive: true);
      File(
        p.join(packageRoot, 'lib', 'analyzer.dart'),
      ).writeAsStringSync('library analyzer;');
      File(
        p.join(packageRoot, 'lib', 'src', 'build', 'keep.dart'),
      ).writeAsStringSync('library nested_build;');
      File(
        p.join(packageRoot, '.dart_tool', 'package_config.json'),
      ).writeAsStringSync('{}');
      File(
        p.join(packageRoot, 'build', 'generated.txt'),
      ).writeAsStringSync('generated');
      File(p.join(packageRoot, 'pubspec.lock')).writeAsStringSync('');

      final result = const PatchworkStore().createPubEditSession(
        workspace: PubWorkspace(
          rootPath: root.path,
          currentPackageRootPath: root.path,
          packageConfigPath: p.join(
            root.path,
            '.dart_tool',
            'package_config.json',
          ),
          lockfilePath: p.join(root.path, 'pubspec.lock'),
          packageGraphPath: p.join(
            root.path,
            '.dart_tool',
            'package_graph.json',
          ),
        ),
        package: ResolvedPubPackage(
          name: 'analyzer',
          version: '7.4.0',
          sourceKind: PubPackageSourceKind.hosted,
          dependencyKind: PubPackageDependencyKind.directMain,
          rootPath: packageRoot,
          packageUri: 'lib/',
        ),
      );

      expect(result.diagnostic, isNull);
      final session = result.session!;
      expect(
        session.baselinePath,
        p.join(
          root.path,
          '.dart_tool',
          'patchwork',
          'baseline',
          'pub',
          'analyzer@7.4.0',
        ),
      );
      expect(
        File(
          p.join(session.editPath, 'lib', 'analyzer.dart'),
        ).readAsStringSync(),
        'library analyzer;',
      );
      expect(
        File(
          p.join(session.editPath, 'lib', 'src', 'build', 'keep.dart'),
        ).readAsStringSync(),
        'library nested_build;',
      );
      expect(
        Directory(p.join(session.editPath, '.dart_tool')).existsSync(),
        isFalse,
      );
      expect(
        Directory(p.join(session.editPath, 'build')).existsSync(),
        isFalse,
      );
      expect(
        File(p.join(session.editPath, 'pubspec.lock')).existsSync(),
        isFalse,
      );
      expect(
        session.commitCommand,
        "patchwork patch --commit '${session.editPath}'",
      );

      final metadata =
          jsonDecode(File(session.metadataPath).readAsStringSync())
              as Map<String, Object?>;
      expect(metadata['target'], 'pub:analyzer@7.4.0');
      expect(metadata['paths'], containsPair('workspaceRoot', root.path));
    });

    test('skips generated patchwork state inside the source package', () {
      final packageRoot = p.join(root.path, 'source');
      final workspaceRoot = p.join(packageRoot, 'examples', 'app');
      final generatedPatchworkPath = p.join(
        workspaceRoot,
        '.dart_tool',
        'patchwork',
        'edit',
        'pub',
        'stale@1.0.0',
      );
      Directory(p.join(packageRoot, 'lib')).createSync(recursive: true);
      Directory(generatedPatchworkPath).createSync(recursive: true);
      File(
        p.join(packageRoot, 'lib', 'source.dart'),
      ).writeAsStringSync('library source;');
      File(
        p.join(generatedPatchworkPath, 'stale.dart'),
      ).writeAsStringSync('library stale;');

      final result = const PatchworkStore().createPubEditSession(
        workspace: PubWorkspace(
          rootPath: workspaceRoot,
          currentPackageRootPath: workspaceRoot,
          packageConfigPath: p.join(
            workspaceRoot,
            '.dart_tool',
            'package_config.json',
          ),
          lockfilePath: p.join(workspaceRoot, 'pubspec.lock'),
          packageGraphPath: p.join(
            workspaceRoot,
            '.dart_tool',
            'package_graph.json',
          ),
        ),
        package: ResolvedPubPackage(
          name: 'source',
          version: '0.0.0',
          sourceKind: PubPackageSourceKind.path,
          dependencyKind: PubPackageDependencyKind.directMain,
          rootPath: packageRoot,
          packageUri: 'lib/',
        ),
      );

      expect(result.diagnostic, isNull);
      final session = result.session!;
      expect(
        File(p.join(session.editPath, 'lib', 'source.dart')).readAsStringSync(),
        'library source;',
      );
      expect(
        Directory(
          p.join(
            session.editPath,
            'examples',
            'app',
            '.dart_tool',
            'patchwork',
          ),
        ).existsSync(),
        isFalse,
      );
    });

    test('escapes pub patch file path components', () {
      const session = PubPatchSession(
        target: PubTarget(name: 'some_pkg', versionConstraint: '1.0.0+1'),
        package: ResolvedPubPackage(
          name: 'some_pkg',
          version: '1.0.0+1',
          sourceKind: PubPackageSourceKind.unknown,
          dependencyKind: PubPackageDependencyKind.unknown,
          rootPath: '/cache/pkg',
          packageUri: 'lib/',
        ),
        baselinePath: '/workspace/.dart_tool/patchwork/baseline/pub/pkg',
        editPath: '/workspace/.dart_tool/patchwork/edit/pub/pkg',
        metadataPath: '/workspace/.dart_tool/patchwork/sessions/pub/pkg.json',
      );

      expect(
        const PatchworkStore().pubPatchFilePath(
          workspaceRootPath: root.path,
          session: session,
        ),
        p.join(root.path, 'patches', 'pub', 'some_pkg@1.0.0%2B1.patch'),
      );
    });
  });
}
