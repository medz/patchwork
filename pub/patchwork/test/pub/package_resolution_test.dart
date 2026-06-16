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

    final bar = resolution.resolvePackage('bar').source;
    expect(bar.type, 'path');
    expect(bar.fields, {'path': '../../deps/bar'});
    expect(bar.sha256, isNotEmpty);

    final baz = resolution.resolvePackage('baz').source;
    expect(baz.type, 'git');
    expect(baz.fields, {
      'url': 'https://example.com/baz.git',
      'branch': 'main',
      'commit': 'abc123',
    });
    expect(baz.sha256, isNotEmpty);

    final qux = resolution.resolvePackage('qux').source;
    expect(qux.type, 'hosted');
    expect(qux.fields, {'url': 'https://pub.example.test'});
    expect(qux.sha256, isNotEmpty);
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
