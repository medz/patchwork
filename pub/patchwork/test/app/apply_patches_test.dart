import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:patchwork/src/app/apply_patches.dart';
import 'package:patchwork/src/app/commit_patch_session.dart';
import 'package:patchwork/src/app/start_patch_session.dart';
import 'package:patchwork/src/store/patchwork_manifest.dart';
import 'package:patchwork/src/target/target.dart';
import 'package:test/test.dart';

import '../pub/pub_resolution_fixture.dart';

void main() {
  group('ApplyPatches', () {
    late PubResolutionFixture fixture;

    setUp(() {
      fixture = PubResolutionFixture.create();
    });

    tearDown(() {
      fixture.dispose();
    });

    test('applies committed pub patches through generated path overrides', () {
      final originalPubspec = File(
        p.join(fixture.rootPath, 'pubspec.yaml'),
      ).readAsStringSync();
      _commitAnalyzerPatch(fixture, version: '7.4.1');

      final result = const ApplyPatches().apply(
        currentDirectory: fixture.memberPath,
      );

      expect(result.diagnostic, isNull);
      expect(result.applied, hasLength(1));
      final applied = result.applied.single;
      expect(applied.target, 'pub:analyzer@7.4.0');
      expect(applied.rebuilt, isTrue);
      expect(
        File(
          p.join(applied.storePath, 'lib', 'analyzer.dart'),
        ).readAsStringSync(),
        "String analyzerVersion() => '7.4.1';\n",
      );
      expect(
        File(
          p.join(applied.storePath, '.patchwork-patch-hash'),
        ).readAsStringSync(),
        '${applied.hash}\n',
      );
      expect(
        File(p.join(fixture.rootPath, 'pubspec.yaml')).readAsStringSync(),
        originalPubspec,
      );
      expect(
        File(fixture.analyzerLibFilePath).readAsStringSync(),
        "String analyzerVersion() => '7.4.0';\n",
      );
      expect(
        File(
          p.join(fixture.rootPath, 'pubspec_overrides.yaml'),
        ).readAsStringSync(),
        '''
dependency_overrides:
  analyzer:
    path: ${patchworkManifestPath(p.relative(applied.storePath, from: fixture.rootPath))}
''',
      );
    });

    test('is idempotent when the generated store copy matches the hash', () {
      _commitAnalyzerPatch(fixture, version: '7.4.1');
      final firstResult = const ApplyPatches().apply(
        currentDirectory: fixture.rootPath,
      );
      expect(firstResult.diagnostic, isNull);
      final sentinel = File(
        p.join(firstResult.applied.single.storePath, 'sentinel.txt'),
      )..writeAsStringSync('kept\n');

      final secondResult = const ApplyPatches().apply(
        currentDirectory: fixture.rootPath,
      );

      expect(secondResult.diagnostic, isNull);
      expect(secondResult.applied.single.rebuilt, isFalse);
      expect(sentinel.readAsStringSync(), 'kept\n');
    });

    test('rebuilds generated store copy when the patch hash changes', () {
      _commitAnalyzerPatch(fixture, version: '7.4.1');
      final firstResult = const ApplyPatches().apply(
        currentDirectory: fixture.rootPath,
      );
      expect(firstResult.diagnostic, isNull);
      final firstStorePath = firstResult.applied.single.storePath;
      _commitAnalyzerPatch(fixture, version: '7.4.2');

      final secondResult = const ApplyPatches().apply(
        currentDirectory: fixture.rootPath,
      );

      expect(secondResult.diagnostic, isNull);
      final second = secondResult.applied.single;
      expect(second.rebuilt, isTrue);
      expect(second.storePath, isNot(firstStorePath));
      expect(
        File(
          p.join(second.storePath, 'lib', 'analyzer.dart'),
        ).readAsStringSync(),
        "String analyzerVersion() => '7.4.2';\n",
      );
      expect(
        File(
          p.join(fixture.rootPath, 'pubspec_overrides.yaml'),
        ).readAsStringSync(),
        contains(
          patchworkManifestPath(
            p.relative(second.storePath, from: fixture.rootPath),
          ),
        ),
      );
    });

    test('rebuilds from baseline when pub resolves to an older store copy', () {
      _commitAnalyzerPatch(fixture, version: '7.4.1');
      final firstResult = const ApplyPatches().apply(
        currentDirectory: fixture.rootPath,
      );
      expect(firstResult.diagnostic, isNull);
      _runPubGetOffline(fixture);
      _writeAnalyzerPatch(fixture, version: '7.4.2');

      final secondResult = const ApplyPatches().apply(
        currentDirectory: fixture.rootPath,
      );

      expect(secondResult.diagnostic, isNull);
      expect(
        File(
          p.join(secondResult.applied.single.storePath, 'lib', 'analyzer.dart'),
        ).readAsStringSync(),
        "String analyzerVersion() => '7.4.2';\n",
      );
    });

    test(
      'bad patches fail without corrupting baseline or edit directories',
      () {
        final startResult = const StartPatchSession()(
          const PubTarget(name: 'analyzer'),
          currentDirectory: fixture.rootPath,
        );
        expect(startResult.diagnostic, isNull);
        final session = startResult.session!;
        File(
          p.join(session.editPath, 'lib', 'analyzer.dart'),
        ).writeAsStringSync("String analyzerVersion() => 'edit';\n");
        final patchFile = File(
          p.join(fixture.rootPath, 'patches', 'pub', 'analyzer@7.4.0.patch'),
        );
        patchFile.parent.createSync(recursive: true);
        patchFile.writeAsStringSync('not a valid patch\n');
        const manifestStore = PatchworkManifestStore();
        manifestStore.upsertPatch(
          workspaceRootPath: fixture.rootPath,
          entry: PatchworkManifestPatch(
            target: 'pub:analyzer@7.4.0',
            path: 'patches/pub/analyzer@7.4.0.patch',
            hash: manifestStore.hashFile(patchFile.path),
          ),
        );

        final result = const ApplyPatches().apply(
          currentDirectory: fixture.rootPath,
        );

        expect(result.diagnostic?.code, 'patch.apply_failed');
        expect(
          Directory(
            p.join(fixture.rootPath, '.dart_tool', 'patchwork', 'store'),
          ).existsSync(),
          isFalse,
        );
        expect(
          File(
            p.join(session.baselinePath, 'lib', 'analyzer.dart'),
          ).readAsStringSync(),
          "String analyzerVersion() => '7.4.0';\n",
        );
        expect(
          File(
            p.join(session.editPath, 'lib', 'analyzer.dart'),
          ).readAsStringSync(),
          "String analyzerVersion() => 'edit';\n",
        );
        expect(
          File(p.join(fixture.rootPath, 'pubspec_overrides.yaml')).existsSync(),
          isFalse,
        );
      },
    );

    test('generated overrides resolve with dart pub get', () {
      _commitAnalyzerPatch(fixture, version: '7.4.1');
      final applyResult = const ApplyPatches().apply(
        currentDirectory: fixture.rootPath,
      );
      expect(applyResult.diagnostic, isNull);

      _runPubGetOffline(fixture);
      final packageConfig =
          jsonDecode(File(fixture.packageConfigPath).readAsStringSync())
              as Map<String, Object?>;
      final packages = packageConfig['packages'] as List<Object?>;
      final analyzer = packages.cast<Map<String, Object?>>().singleWhere(
        (package) => package['name'] == 'analyzer',
      );
      final analyzerRootUri = Uri.parse(analyzer['rootUri']! as String);
      final analyzerRootPath = analyzerRootUri.hasScheme
          ? analyzerRootUri.toFilePath()
          : Directory(
              p.dirname(fixture.packageConfigPath),
            ).uri.resolveUri(analyzerRootUri).toFilePath();
      expect(
        p.normalize(analyzerRootPath),
        applyResult.applied.single.storePath,
      );
    });

    test(
      'updates existing pubspec overrides without dropping other entries',
      () {
        File(
          p.join(fixture.rootPath, 'pubspec_overrides.yaml'),
        ).writeAsStringSync('''
dependency_overrides:
  collection:
    path: ../collection
''');
        _commitAnalyzerPatch(fixture, version: '7.4.1');

        final result = const ApplyPatches().apply(
          currentDirectory: fixture.rootPath,
        );

        expect(result.diagnostic, isNull);
        final overrides = File(
          p.join(fixture.rootPath, 'pubspec_overrides.yaml'),
        ).readAsStringSync();
        expect(overrides, contains('collection:'));
        expect(overrides, contains('path: ../collection'));
        expect(overrides, contains('analyzer:'));
        expect(overrides, contains('path: .dart_tool/patchwork/store/pub/'));
      },
    );

    test('applies only the selected target when requested', () {
      _commitAnalyzerPatch(fixture, version: '7.4.1');

      final result = const ApplyPatches().apply(
        target: const PubTarget(name: 'analyzer'),
        currentDirectory: fixture.rootPath,
      );

      expect(result.diagnostic, isNull);
      expect(result.applied.single.target, 'pub:analyzer@7.4.0');
    });

    test('does not write overrides when there are no committed patches', () {
      final result = const ApplyPatches().apply(
        currentDirectory: fixture.rootPath,
      );

      expect(result.diagnostic, isNull);
      expect(result.applied, isEmpty);
      expect(
        File(p.join(fixture.rootPath, 'pubspec_overrides.yaml')).existsSync(),
        isFalse,
      );
    });
  });
}

void _commitAnalyzerPatch(
  PubResolutionFixture fixture, {
  required String version,
}) {
  final startResult = const StartPatchSession()(
    const PubTarget(name: 'analyzer'),
    currentDirectory: fixture.rootPath,
  );
  expect(startResult.diagnostic, isNull);
  File(
    p.join(startResult.session!.editPath, 'lib', 'analyzer.dart'),
  ).writeAsStringSync("String analyzerVersion() => '$version';\n");

  final commitResult = const CommitPatchSession().commitTarget(
    const PubTarget(name: 'analyzer'),
    currentDirectory: fixture.rootPath,
  );
  expect(commitResult.diagnostic, isNull);
}

void _writeAnalyzerPatch(
  PubResolutionFixture fixture, {
  required String version,
}) {
  final patchFile = File(
    p.join(fixture.rootPath, 'patches', 'pub', 'analyzer@7.4.0.patch'),
  );
  patchFile.parent.createSync(recursive: true);
  patchFile.writeAsStringSync('''
diff --git a/lib/analyzer.dart b/lib/analyzer.dart
--- a/lib/analyzer.dart
+++ b/lib/analyzer.dart
@@ -1 +1 @@
-String analyzerVersion() => '7.4.0';
+String analyzerVersion() => '$version';
''');
  const manifestStore = PatchworkManifestStore();
  manifestStore.upsertPatch(
    workspaceRootPath: fixture.rootPath,
    entry: PatchworkManifestPatch(
      target: 'pub:analyzer@7.4.0',
      path: 'patches/pub/analyzer@7.4.0.patch',
      hash: manifestStore.hashFile(patchFile.path),
    ),
  );
}

void _runPubGetOffline(PubResolutionFixture fixture) {
  final pubGet = Process.runSync('dart', [
    'pub',
    'get',
    '--offline',
  ], workingDirectory: fixture.rootPath);

  expect(pubGet.exitCode, 0, reason: '${pubGet.stderr}${pubGet.stdout}');
}
