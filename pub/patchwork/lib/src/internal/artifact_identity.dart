import '../error.dart';

/// Returns the canonical `<package>@<version>` artifact identity.
String packageVersionName(String package, String version) {
  return '$package@$version';
}

/// Parses a canonical `<package>@<version>` artifact identity.
///
/// The final `@` separates the package from the version, which allows versions
/// to contain other punctuation without changing Patchwork's artifact layout.
PackageVersion? parsePackageVersionName(String name) {
  final separator = name.lastIndexOf('@');
  if (separator <= 0 || separator == name.length - 1) {
    return null;
  }
  return PackageVersion(
    package: name.substring(0, separator),
    version: name.substring(separator + 1),
  );
}

/// A package and version pair parsed from a Patchwork artifact identity.
final class PackageVersion {
  /// Creates a parsed package-version identity.
  const PackageVersion({required this.package, required this.version});

  /// The parsed package name.
  final String package;

  /// The parsed package version.
  final String version;
}

/// Whether [value] is a plain pub package name Patchwork accepts in artifacts.
bool isPlainPackageName(String value) {
  return RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(value);
}

/// Whether [value] can be used as one filesystem path segment.
bool isSafePathSegment(String value) {
  return value.isNotEmpty &&
      value != '.' &&
      value != '..' &&
      !value.contains('/') &&
      !value.contains(r'\');
}

/// Rejects [value] when it cannot be used as one filesystem path segment.
void checkSafePathSegment(
  String value, {
  required String label,
  required String code,
}) {
  if (isSafePathSegment(value)) {
    return;
  }
  throw PatchworkException(
    '$label "$value" is not a safe path segment.',
    code: code,
  );
}
