import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:patchwork/src/app/commit_patch_session.dart';
import 'package:patchwork/src/app/start_patch_session.dart';
import 'package:patchwork/src/store/patchwork_manifest.dart';
import 'package:patchwork/src/target/target.dart';
import 'package:test/test.dart';

import '../pub/pub_resolution_fixture.dart';

void main() {
  group('CommitPatchSession', () {
    late PubResolutionFixture fixture;

    setUp(() {
      fixture = PubResolutionFixture.create();
    });

    tearDown(() {
      fixture.dispose();
    });

    test('commits a target edit session into a stable patch file', () {
      final startResult = const StartPatchSession()(
        const PubTarget(name: 'analyzer'),
        currentDirectory: fixture.memberPath,
      );
      expect(startResult.diagnostic, isNull);
      final session = startResult.session!;
      File(
        p.join(session.editPath, 'lib', 'analyzer.dart'),
      ).writeAsStringSync("String analyzerVersion() => '7.4.1';\n");

      final result = const CommitPatchSession().commitTarget(
        const PubTarget(name: 'analyzer'),
        currentDirectory: fixture.memberPath,
      );

      expect(result.diagnostic, isNull);
      expect(result.noChanges, isFalse);
      expect(
        result.patchPath,
        p.join('patches', 'pub', 'analyzer@7.4.0.patch'),
      );
      final patchContent = File(
        p.join(fixture.rootPath, result.patchPath),
      ).readAsStringSync();
      expect(patchContent, contains('--- a/lib/analyzer.dart'));
      expect(patchContent, contains('+++ b/lib/analyzer.dart'));
      expect(patchContent, contains("-String analyzerVersion() => '7.4.0';"));
      expect(patchContent, contains("+String analyzerVersion() => '7.4.1';"));
      expect(patchContent, isNot(contains(fixture.rootPath)));
      expect(patchContent, isNot(contains(fixture.analyzerRootPath)));
      final manifestContent = File(
        p.join(fixture.rootPath, 'patchwork.lock'),
      ).readAsStringSync();
      expect(manifestContent, contains('target: pub:analyzer@7.4.0'));
      expect(
        manifestContent,
        contains('path: patches/pub/analyzer@7.4.0.patch'),
      );
      expect(manifestContent, matches(RegExp(r'hash: [0-9a-f]{64}')));
    });

    test('uses the injected manifest hasher when recording hash', () {
      final startResult = const StartPatchSession()(
        const PubTarget(name: 'analyzer'),
        currentDirectory: fixture.memberPath,
      );
      expect(startResult.diagnostic, isNull);
      final session = startResult.session!;
      File(
        p.join(session.editPath, 'lib', 'analyzer.dart'),
      ).writeAsStringSync("String analyzerVersion() => '7.4.1';\n");
      const injectedHash =
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

      final result =
          CommitPatchSession(
            manifestStore: PatchworkManifestStore(
              hashFile: (_) => injectedHash,
            ),
          ).commitTarget(
            const PubTarget(name: 'analyzer'),
            currentDirectory: fixture.memberPath,
          );

      expect(result.diagnostic, isNull);
      expect(
        File(p.join(fixture.rootPath, 'patchwork.lock')).readAsStringSync(),
        contains('hash: $injectedHash'),
      );
    });

    test('commits an edit directory session', () {
      final startResult = const StartPatchSession()(
        const PubTarget(name: 'analyzer'),
        currentDirectory: fixture.rootPath,
      );
      expect(startResult.diagnostic, isNull);
      final session = startResult.session!;
      File(
        p.join(session.editPath, 'lib', 'new.dart'),
      ).writeAsStringSync('library new_file;\n');

      final result = const CommitPatchSession().commitEditDirectory(
        session.editPath,
        currentDirectory: fixture.rootPath,
      );

      expect(result.diagnostic, isNull);
      expect(
        result.patchPath,
        p.join('patches', 'pub', 'analyzer@7.4.0.patch'),
      );
      final patchContent = File(
        p.join(fixture.rootPath, result.patchPath),
      ).readAsStringSync();
      expect(patchContent, contains('--- /dev/null'));
      expect(patchContent, contains('+++ b/lib/new.dart'));
    });

    test('returns a clean no-op when the edit session has no changes', () {
      final startResult = const StartPatchSession()(
        const PubTarget(name: 'analyzer'),
        currentDirectory: fixture.rootPath,
      );
      expect(startResult.diagnostic, isNull);

      final result = const CommitPatchSession().commitTarget(
        const PubTarget(name: 'analyzer'),
        currentDirectory: fixture.rootPath,
      );

      expect(result.diagnostic, isNull);
      expect(result.noChanges, isTrue);
      expect(result.patchPath, isNull);
      expect(
        File(
          p.join(fixture.rootPath, 'patches', 'pub', 'analyzer@7.4.0.patch'),
        ).existsSync(),
        isFalse,
      );
    });

    test('removes an existing patch when the edit session has no changes', () {
      final startResult = const StartPatchSession()(
        const PubTarget(name: 'analyzer'),
        currentDirectory: fixture.rootPath,
      );
      expect(startResult.diagnostic, isNull);
      final patchFile = File(
        p.join(fixture.rootPath, 'patches', 'pub', 'analyzer@7.4.0.patch'),
      );
      patchFile.parent.createSync(recursive: true);
      patchFile.writeAsStringSync('stale patch\n');
      File(p.join(fixture.rootPath, 'patchwork.lock')).writeAsStringSync('''
patches:
  - target: pub:analyzer@7.4.0
    path: patches/pub/analyzer@7.4.0.patch
    hash: 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
''');

      final result = const CommitPatchSession().commitTarget(
        const PubTarget(name: 'analyzer'),
        currentDirectory: fixture.rootPath,
      );

      expect(result.diagnostic, isNull);
      expect(result.noChanges, isTrue);
      expect(result.patchPath, isNull);
      expect(patchFile.existsSync(), isFalse);
      expect(
        File(p.join(fixture.rootPath, 'patchwork.lock')).readAsStringSync(),
        'patches: []\n',
      );
    });

    test('does not delete a patch when lock removal cannot be read', () {
      final startResult = const StartPatchSession()(
        const PubTarget(name: 'analyzer'),
        currentDirectory: fixture.rootPath,
      );
      expect(startResult.diagnostic, isNull);
      final patchFile = File(
        p.join(fixture.rootPath, 'patches', 'pub', 'analyzer@7.4.0.patch'),
      );
      patchFile.parent.createSync(recursive: true);
      patchFile.writeAsStringSync('existing patch\n');
      File(p.join(fixture.rootPath, 'patchwork.lock')).writeAsStringSync('''
patches:
  - target: pub:analyzer@7.4.0
    hash: 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
''');

      final result = const CommitPatchSession().commitTarget(
        const PubTarget(name: 'analyzer'),
        currentDirectory: fixture.rootPath,
      );

      expect(result.diagnostic?.code, 'patchwork.manifest_malformed');
      expect(patchFile.readAsStringSync(), 'existing patch\n');
    });

    test('restores an existing patch when lock removal write fails', () {
      final startResult = const StartPatchSession()(
        const PubTarget(name: 'analyzer'),
        currentDirectory: fixture.rootPath,
      );
      expect(startResult.diagnostic, isNull);
      final patchFile = File(
        p.join(fixture.rootPath, 'patches', 'pub', 'analyzer@7.4.0.patch'),
      );
      patchFile.parent.createSync(recursive: true);
      patchFile.writeAsStringSync('existing patch\n');
      final manifestFile = File(p.join(fixture.rootPath, 'patchwork.lock'));
      const manifestContent = '''
patches:
  - target: pub:analyzer@7.4.0
    path: patches/pub/analyzer@7.4.0.patch
    hash: 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
''';
      manifestFile.writeAsStringSync(manifestContent);

      final result =
          CommitPatchSession(
            manifestStore: PatchworkManifestStore(
              writeFile: (_, _) => throw FileSystemException(
                'Lock write failed',
                manifestFile.path,
              ),
            ),
          ).commitTarget(
            const PubTarget(name: 'analyzer'),
            currentDirectory: fixture.rootPath,
          );

      expect(result.diagnostic, isNotNull);
      expect(patchFile.readAsStringSync(), 'existing patch\n');
      expect(manifestFile.readAsStringSync(), manifestContent);
    });

    test('updates the existing manifest entry when recommitting', () {
      final startResult = const StartPatchSession()(
        const PubTarget(name: 'analyzer'),
        currentDirectory: fixture.rootPath,
      );
      expect(startResult.diagnostic, isNull);
      final session = startResult.session!;
      final editFile = File(p.join(session.editPath, 'lib', 'analyzer.dart'));
      editFile.writeAsStringSync("String analyzerVersion() => '7.4.1';\n");

      final firstResult = const CommitPatchSession().commitTarget(
        const PubTarget(name: 'analyzer'),
        currentDirectory: fixture.rootPath,
      );
      expect(firstResult.diagnostic, isNull);
      final firstManifest = File(
        p.join(fixture.rootPath, 'patchwork.lock'),
      ).readAsStringSync();

      editFile.writeAsStringSync("String analyzerVersion() => '7.4.2';\n");
      final secondResult = const CommitPatchSession().commitTarget(
        const PubTarget(name: 'analyzer'),
        currentDirectory: fixture.rootPath,
      );

      expect(secondResult.diagnostic, isNull);
      final secondManifest = File(
        p.join(fixture.rootPath, 'patchwork.lock'),
      ).readAsStringSync();
      expect(secondManifest, isNot(firstManifest));
      expect(
        'target: pub:analyzer@7.4.0'.allMatches(secondManifest),
        hasLength(1),
      );
      expect(secondManifest, matches(RegExp(r'hash: [0-9a-f]{64}')));
    });

    test('does not overwrite a patch when lock update cannot be read', () {
      final startResult = const StartPatchSession()(
        const PubTarget(name: 'analyzer'),
        currentDirectory: fixture.rootPath,
      );
      expect(startResult.diagnostic, isNull);
      final session = startResult.session!;
      File(
        p.join(session.editPath, 'lib', 'analyzer.dart'),
      ).writeAsStringSync("String analyzerVersion() => '7.4.1';\n");
      final patchFile = File(
        p.join(fixture.rootPath, 'patches', 'pub', 'analyzer@7.4.0.patch'),
      );
      patchFile.parent.createSync(recursive: true);
      patchFile.writeAsStringSync('existing patch\n');
      File(p.join(fixture.rootPath, 'patchwork.lock')).writeAsStringSync('''
patches:
  - target: pub:analyzer@7.4.0
    hash: 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
''');

      final result = const CommitPatchSession().commitTarget(
        const PubTarget(name: 'analyzer'),
        currentDirectory: fixture.rootPath,
      );

      expect(result.diagnostic?.code, 'patchwork.manifest_malformed');
      expect(patchFile.readAsStringSync(), 'existing patch\n');
    });

    test('restores an existing patch when lock update write fails', () {
      final startResult = const StartPatchSession()(
        const PubTarget(name: 'analyzer'),
        currentDirectory: fixture.rootPath,
      );
      expect(startResult.diagnostic, isNull);
      final session = startResult.session!;
      File(
        p.join(session.editPath, 'lib', 'analyzer.dart'),
      ).writeAsStringSync("String analyzerVersion() => '7.4.1';\n");
      final patchFile = File(
        p.join(fixture.rootPath, 'patches', 'pub', 'analyzer@7.4.0.patch'),
      );
      patchFile.parent.createSync(recursive: true);
      patchFile.writeAsStringSync('existing patch\n');
      final manifestFile = File(p.join(fixture.rootPath, 'patchwork.lock'));
      const manifestContent = '''
patches:
  - target: pub:analyzer@7.4.0
    path: patches/pub/analyzer@7.4.0.patch
    hash: 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
''';
      manifestFile.writeAsStringSync(manifestContent);

      final result =
          CommitPatchSession(
            manifestStore: PatchworkManifestStore(
              writeFile: (_, _) => throw FileSystemException(
                'Lock write failed',
                manifestFile.path,
              ),
            ),
          ).commitTarget(
            const PubTarget(name: 'analyzer'),
            currentDirectory: fixture.rootPath,
          );

      expect(result.diagnostic, isNotNull);
      expect(patchFile.readAsStringSync(), 'existing patch\n');
      expect(manifestFile.readAsStringSync(), manifestContent);
    });

    test('reports patch write failures as diagnostics', () {
      final startResult = const StartPatchSession()(
        const PubTarget(name: 'analyzer'),
        currentDirectory: fixture.rootPath,
      );
      expect(startResult.diagnostic, isNull);
      final session = startResult.session!;
      File(
        p.join(session.editPath, 'lib', 'analyzer.dart'),
      ).writeAsStringSync("String analyzerVersion() => '7.4.1';\n");
      File(p.join(fixture.rootPath, 'patches')).writeAsStringSync('not a dir');

      final result = const CommitPatchSession().commitTarget(
        const PubTarget(name: 'analyzer'),
        currentDirectory: fixture.rootPath,
      );

      expect(result.diagnostic?.code, 'pub.patch_commit_failed');
      expect(result.patchPath, isNull);
    });
  });
}
