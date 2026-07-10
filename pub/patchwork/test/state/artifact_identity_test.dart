import 'package:patchwork/src/error.dart';
import 'package:patchwork/src/state/artifact_identity.dart';
import 'package:test/test.dart';

void main() {
  test('formats and parses package version identities', () {
    expect(packageVersionName('greeter', '1.0.0'), 'greeter@1.0.0');

    final parsed = parsePackageVersionName('greeter@1.0.0+build');

    expect(parsed?.package, 'greeter');
    expect(parsed?.version, '1.0.0+build');
    expect(parsePackageVersionName('greeter@1.0.0+build@local'), isNull);
    expect(parsePackageVersionName('greeter'), isNull);
    expect(parsePackageVersionName('@1.0.0'), isNull);
    expect(parsePackageVersionName('greeter@'), isNull);
  });

  test('validates plain package names and safe path segments', () {
    expect(isPlainPackageName('greeter_pkg'), isTrue);
    expect(isPlainPackageName('greeter-pkg'), isFalse);
    expect(isSafePathSegment('1.0.0+build'), isTrue);
    expect(isSafePathSegment(''), isFalse);
    expect(isSafePathSegment('.'), isFalse);
    expect(isSafePathSegment('..'), isFalse);
    expect(isSafePathSegment('1/0'), isFalse);
    expect(isSafePathSegment(r'1\0'), isFalse);
  });

  test('rejects unsafe path segments with caller-specific codes', () {
    expect(
      () => checkSafePathSegment(
        '..',
        label: 'Patch version',
        code: 'remove.version_invalid',
      ),
      throwsA(
        isA<PatchworkException>()
            .having((error) => error.code, 'code', 'remove.version_invalid')
            .having(
              (error) => error.message,
              'message',
              'Patch version ".." is not a safe path segment.',
            ),
      ),
    );
  });
}
