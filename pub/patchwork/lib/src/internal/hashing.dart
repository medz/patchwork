import 'package:crypto/crypto.dart';

/// Returns a SHA-256 digest encoded as lowercase hexadecimal.
String sha256Hex(List<int> bytes) {
  return sha256.convert(bytes).toString();
}
