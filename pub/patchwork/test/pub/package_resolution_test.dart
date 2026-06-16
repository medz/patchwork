import 'package:patchwork/src/error.dart';
import 'package:patchwork/src/pub/package_resolution.dart';
import 'package:test/test.dart';

import 'pub_resolution_fixture.dart';

void main() {
  late PubResolutionFixture fixture;

  setUp(() {
    fixture = PubResolutionFixture.create();
  });

  tearDown(() {
    fixture.dispose();
  });

  test('resolves hosted source without redundant package name', () {
    final resolution = const PubResolutionReader().readFromDirectory(
      fixture.appPath,
    );

    final foo = resolution.resolvePackage('foo');

    expect(foo.version, '0.1.0');
    expect(foo.source.type, 'hosted');
    expect(foo.source.fields, {'url': 'https://pub.dev'});
    expect(foo.source.sha256, isNotEmpty);
  });

  test('resolves path and git source fields', () {
    final resolution = const PubResolutionReader().readFromDirectory(
      fixture.appPath,
    );

    expect(resolution.resolvePackage('bar').source.toYaml(), {
      'type': 'path',
      'path': '../../deps/bar',
      'sha256': isNotEmpty,
    });
    expect(resolution.resolvePackage('baz').source.toYaml(), {
      'type': 'git',
      'url': 'https://example.com/baz.git',
      'branch': 'main',
      'commit': 'abc123',
      'sha256': isNotEmpty,
    });
    expect(resolution.resolvePackage('qux').source.toYaml(), {
      'type': 'hosted',
      'url': 'https://pub.example.test',
      'sha256': isNotEmpty,
    });
  });

  test('rejects workspace root packages', () {
    final resolution = const PubResolutionReader().readFromDirectory(
      fixture.appPath,
    );

    expect(
      () => resolution.resolvePackage('app'),
      throwsA(
        isA<PatchworkException>().having(
          (error) => error.code,
          'code',
          'pub.package_is_project',
        ),
      ),
    );
  });
}
