import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:patchwork/src/app/commit_patch_session.dart';
import 'package:patchwork/src/app/start_patch_session.dart';
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

      final result = const CommitPatchSession().commitTarget(
        const PubTarget(name: 'analyzer'),
        currentDirectory: fixture.rootPath,
      );

      expect(result.diagnostic, isNull);
      expect(result.noChanges, isTrue);
      expect(result.patchPath, isNull);
      expect(patchFile.existsSync(), isFalse);
    });
  });
}
