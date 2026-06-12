import 'package:patchwork/src/target/target_parser.dart';
import 'package:test/test.dart';

void main() {
  group('TargetParser', () {
    const parser = TargetParser();

    test('treats a bare package as a pub target', () {
      final result = parser.parsePubTarget('analyzer');

      expect(result.isSuccess, isTrue);
      expect(result.target.toString(), 'pub:analyzer');
    });

    test('keeps a package version constraint', () {
      final result = parser.parsePubTarget('analyzer@7.4.0');

      expect(result.isSuccess, isTrue);
      expect(result.target.toString(), 'pub:analyzer@7.4.0');
    });

    test('accepts an explicit pub target', () {
      final result = parser.parsePubTarget('pub:analyzer');

      expect(result.isSuccess, isTrue);
      expect(result.target.toString(), 'pub:analyzer');
    });

    test('rejects sdk targets for the pub MVP', () {
      final result = parser.parsePubTarget('sdk:flutter');

      expect(result.isSuccess, isFalse);
      expect(result.diagnostic?.code, 'target.unsupportedKind');
      expect(result.diagnostic?.message, contains('sdk'));
    });

    test('rejects path targets for the pub MVP', () {
      final result = parser.parsePubTarget('path:../local_package');

      expect(result.isSuccess, isFalse);
      expect(result.diagnostic?.code, 'target.unsupportedKind');
      expect(result.diagnostic?.message, contains('path'));
    });

    test('rejects invalid package names', () {
      final result = parser.parsePubTarget('Analyzer');

      expect(result.isSuccess, isFalse);
      expect(result.diagnostic?.code, 'target.invalidPackageName');
    });
  });
}
