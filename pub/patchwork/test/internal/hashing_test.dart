import 'dart:convert';

import 'package:patchwork/src/internal/hashing.dart';
import 'package:test/test.dart';

void main() {
  test('computes lowercase SHA-256 hex digests', () {
    expect(
      sha256Hex(utf8.encode('patchwork')),
      '3af082fc9b78b977a20298c0243fbe5b0566268107dad60d3d9b6b8c8906a068',
    );
  });
}
