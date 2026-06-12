import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:patchwork/src/app/start_patch_session.dart';
import 'package:patchwork/src/target/target.dart';
import 'package:test/test.dart';

import '../pub/pub_resolution_fixture.dart';

void main() {
  group('StartPatchSession', () {
    late PubResolutionFixture fixture;

    setUp(() {
      fixture = PubResolutionFixture.create();
    });

    tearDown(() {
      fixture.dispose();
    });

    test('creates baseline and edit copies without transient files', () {
      final result = const StartPatchSession()(
        const PubTarget(name: 'analyzer'),
        currentDirectory: fixture.rootPath,
      );

      expect(result.diagnostic, isNull);
      final session = result.session!;

      expect(session.baselinePath, _sessionPath(fixture, 'baseline'));
      expect(session.editPath, _sessionPath(fixture, 'edit'));
      expect(
        File(
          p.join(session.baselinePath, 'lib', 'analyzer.dart'),
        ).readAsStringSync(),
        File(fixture.analyzerLibFilePath).readAsStringSync(),
      );
      expect(
        File(
          p.join(session.editPath, 'lib', 'analyzer.dart'),
        ).readAsStringSync(),
        File(fixture.analyzerLibFilePath).readAsStringSync(),
      );
      expect(
        File(p.join(session.baselinePath, 'pubspec.yaml')).existsSync(),
        isTrue,
      );
      expect(
        File(p.join(session.editPath, 'pubspec.yaml')).existsSync(),
        isTrue,
      );
      expect(
        Directory(p.join(session.editPath, '.dart_tool')).existsSync(),
        isFalse,
      );
      expect(
        Directory(p.join(session.editPath, 'build')).existsSync(),
        isFalse,
      );
      expect(File(p.join(session.editPath, '.packages')).existsSync(), isFalse);
      expect(
        File(p.join(session.editPath, 'pubspec.lock')).existsSync(),
        isFalse,
      );
      expect(
        File(fixture.analyzerLibFilePath).readAsStringSync(),
        contains('7.4.0'),
      );
    });

    test('refreshes repeat edit sessions predictably', () {
      const startPatchSession = StartPatchSession();
      final first = startPatchSession(
        const PubTarget(name: 'analyzer'),
        currentDirectory: fixture.rootPath,
      );
      expect(first.diagnostic, isNull);

      final editFile = File(
        p.join(first.session!.editPath, 'lib', 'analyzer.dart'),
      );
      editFile.writeAsStringSync('edited');

      final second = startPatchSession(
        const PubTarget(name: 'analyzer'),
        currentDirectory: fixture.rootPath,
      );

      expect(second.diagnostic, isNull);
      expect(second.session?.editPath, first.session?.editPath);
      expect(
        editFile.readAsStringSync(),
        File(fixture.analyzerLibFilePath).readAsStringSync(),
      );
    });

    test('records session metadata for patch commit', () {
      final result = const StartPatchSession()(
        const PubTarget(name: 'analyzer'),
        currentDirectory: fixture.memberPath,
      );

      expect(result.diagnostic, isNull);
      final session = result.session!;
      final metadata =
          jsonDecode(File(session.metadataPath).readAsStringSync())
              as Map<String, Object?>;

      expect(metadata['schemaVersion'], 1);
      expect(metadata['target'], 'pub:analyzer@7.4.0');
      expect(metadata['package'], {'name': 'analyzer', 'version': '7.4.0'});
      expect(metadata['paths'], {
        'workspaceRoot': fixture.rootPath,
        'sourceRoot': fixture.analyzerRootPath,
        'baseline': p.join(
          '.dart_tool',
          'patchwork',
          'baseline',
          'pub',
          'analyzer@7.4.0',
        ),
        'edit': p.join(
          '.dart_tool',
          'patchwork',
          'edit',
          'pub',
          'analyzer@7.4.0',
        ),
      });
    });
  });
}

String _sessionPath(PubResolutionFixture fixture, String kind) {
  return p.join(
    fixture.rootPath,
    '.dart_tool',
    'patchwork',
    kind,
    'pub',
    'analyzer@7.4.0',
  );
}
