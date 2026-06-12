import 'package:patchwork/src/pub/package_resolution.dart';
import 'package:patchwork/src/target/target.dart';
import 'package:test/test.dart';

import 'pub_resolution_fixture.dart';

void main() {
  group('PubResolutionReader', () {
    late PubResolutionFixture fixture;

    setUp(() {
      fixture = PubResolutionFixture.create();
    });

    tearDown(() {
      fixture.dispose();
    });

    test(
      'resolves a direct dependency by bare name from the workspace root',
      () {
        final resolution = _readResolution(fixture.rootPath);
        final result = resolution.resolve(const PubTarget(name: 'analyzer'));

        expect(result.diagnostic, isNull);
        expect(result.package?.name, 'analyzer');
        expect(result.package?.version, '7.4.0');
        expect(result.package?.sourceKind, PubPackageSourceKind.hosted);
        expect(
          result.package?.dependencyKind,
          PubPackageDependencyKind.directMain,
        );
        expect(result.package?.rootPath, fixture.analyzerRootPath);
        expect(result.package?.packageUri, 'lib/');
        expect(result.package?.languageVersion, '3.4');
      },
    );

    test('resolves a direct dependency by exact version from a member', () {
      final resolution = _readResolution(fixture.memberPath);
      final result = resolution.resolve(
        const PubTarget(name: 'analyzer', versionConstraint: '7.4.0'),
      );

      expect(result.diagnostic, isNull);
      expect(result.package?.name, 'analyzer');
      expect(result.package?.version, '7.4.0');
      expect(result.package?.rootPath, fixture.analyzerRootPath);
    });

    test('reports an unknown package', () {
      final resolution = _readResolution(fixture.rootPath);
      final result = resolution.resolve(
        const PubTarget(name: 'missing_package'),
      );

      expect(result.isSuccess, isFalse);
      expect(result.diagnostic?.code, 'pub.packageNotFound');
    });

    test('reports a requested version that is not selected', () {
      final resolution = _readResolution(fixture.rootPath);
      final result = resolution.resolve(
        const PubTarget(name: 'analyzer', versionConstraint: '7.5.0'),
      );

      expect(result.isSuccess, isFalse);
      expect(result.diagnostic?.code, 'pub.versionNotSelected');
      expect(result.diagnostic?.message, contains('7.4.0'));
      expect(result.diagnostic?.message, contains('7.5.0'));
    });

    test('reports duplicate package_config entries as ambiguous', () {
      fixture.writeDuplicatePackageConfig();

      final result = const PubResolutionReader().readFromDirectory(
        fixture.rootPath,
      );

      expect(result.isSuccess, isFalse);
      expect(result.diagnostic?.code, 'pub.ambiguousPackage');
    });

    test('reports a missing resolved package root', () {
      fixture.deleteAnalyzerRoot();

      final resolution = _readResolution(fixture.rootPath);
      final result = resolution.resolve(const PubTarget(name: 'analyzer'));

      expect(result.isSuccess, isFalse);
      expect(result.diagnostic?.code, 'pub.packageRootMissing');
      expect(result.diagnostic?.location, fixture.analyzerRootPath);
    });

    test('reports a malformed package_config.json', () {
      fixture.overwritePackageConfig('{');

      final result = const PubResolutionReader().readFromDirectory(
        fixture.rootPath,
      );

      expect(result.isSuccess, isFalse);
      expect(result.diagnostic?.code, 'pub.malformedPackageConfig');
    });

    test('reports a malformed pubspec.lock', () {
      fixture.overwriteLockfile('packages: [');

      final result = const PubResolutionReader().readFromDirectory(
        fixture.rootPath,
      );

      expect(result.isSuccess, isFalse);
      expect(result.diagnostic?.code, 'pub.malformedLockfile');
    });

    test(
      'falls back to package_graph metadata when pubspec.lock is absent',
      () {
        fixture.deleteLockfile();

        final resolution = _readResolution(fixture.rootPath);
        final result = resolution.resolve(const PubTarget(name: 'analyzer'));

        expect(result.diagnostic, isNull);
        expect(result.package?.version, '7.4.0');
        expect(result.package?.sourceKind, PubPackageSourceKind.unknown);
        expect(
          result.package?.dependencyKind,
          PubPackageDependencyKind.directMain,
        );
      },
    );
  });
}

PubResolution _readResolution(String currentDirectory) {
  final result = const PubResolutionReader().readFromDirectory(
    currentDirectory,
  );

  expect(result.diagnostic, isNull);
  expect(result.resolution, isNotNull);

  return result.resolution!;
}
