import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:patchwork/src/pub/pub_workspace.dart';
import 'package:test/test.dart';

import 'pub_resolution_fixture.dart';

void main() {
  group('PubWorkspaceLocator', () {
    late PubResolutionFixture fixture;

    setUp(() {
      fixture = PubResolutionFixture.create();
    });

    tearDown(() {
      fixture.dispose();
    });

    test('locates the active workspace from the workspace root', () {
      final result = const PubWorkspaceLocator().locate(fixture.rootPath);

      expect(result.diagnostic, isNull);
      expect(result.workspace?.rootPath, fixture.rootPath);
      expect(result.workspace?.currentPackageRootPath, fixture.rootPath);
      expect(
        result.workspace?.packageConfigPath,
        p.join(fixture.rootPath, '.dart_tool', 'package_config.json'),
      );
    });

    test('locates the active workspace from inside a workspace member', () {
      final result = const PubWorkspaceLocator().locate(fixture.memberLibPath);

      expect(result.diagnostic, isNull);
      expect(result.workspace?.rootPath, fixture.rootPath);
      expect(result.workspace?.currentPackageRootPath, fixture.memberPath);
    });

    test('reports a missing pub resolution', () {
      final directory = Directory.systemTemp.createTempSync(
        'patchwork_missing_resolution_',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      File(
        p.join(directory.path, 'pubspec.yaml'),
      ).writeAsStringSync('name: app');

      final result = const PubWorkspaceLocator().locate(directory.path);

      expect(result.isSuccess, isFalse);
      expect(result.diagnostic?.code, 'pub.resolutionNotFound');
    });
  });
}
