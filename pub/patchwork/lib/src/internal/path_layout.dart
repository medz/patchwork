import 'dart:io';

import 'package:path/path.dart' as p;

/// Computes Patchwork-owned paths for a project root.
final class PathLayout {
  /// Creates a path layout rooted at [rootPath].
  const PathLayout(this.rootPath);

  /// The Patchwork project root path.
  final String rootPath;

  /// The `patchwork.lock` path.
  String get lockfilePath => p.join(rootPath, 'patchwork.lock');

  /// The root directory for editable package copies.
  String get editRootPath => p.join(rootPath, '.patchwork');

  /// The root directory for committed patch files.
  String get patchesRootPath => p.join(rootPath, 'patches');

  /// The root directory for generated applied package copies.
  String get appliedRootPath => p.join(rootPath, '.dart_tool', 'patchwork');

  /// Returns the edit directory for [package] at [version].
  String editPath(String package, String version) {
    return p.join(editRootPath, packageVersionName(package, version));
  }

  /// Returns the committed patch file path for [package] at [version].
  String patchPath(String package, String version) {
    return p.join(
      patchesRootPath,
      '${packageVersionName(package, version)}.patch',
    );
  }

  /// Returns the generated applied output path for [package] at [version].
  String appliedPath(String package, String version) {
    return p.join(appliedRootPath, packageVersionName(package, version));
  }

  /// Returns the project-relative applied path stored in override state.
  String relativeAppliedPath(String package, String version) {
    return p.posix.join(
      '.dart_tool',
      'patchwork',
      packageVersionName(package, version),
    );
  }

  /// Lists valid edit directories currently present under `.patchwork/`.
  List<PackageVersionPath> editDirectories() {
    final root = Directory(editRootPath);
    if (!root.existsSync()) {
      return const [];
    }

    final entries = <PackageVersionPath>[];
    for (final entity in root.listSync(followLinks: false)) {
      if (FileSystemEntity.typeSync(entity.path, followLinks: false) !=
          FileSystemEntityType.directory) {
        continue;
      }
      final parsed = parsePackageVersionName(p.basename(entity.path));
      if (parsed == null) {
        continue;
      }
      entries.add(
        PackageVersionPath(
          package: parsed.package,
          version: parsed.version,
          path: entity.path,
        ),
      );
    }
    entries.sort((left, right) {
      final packageCompare = left.package.compareTo(right.package);
      if (packageCompare != 0) {
        return packageCompare;
      }
      return left.version.compareTo(right.version);
    });
    return entries;
  }
}

/// A parsed Patchwork path that carries package and version identity.
final class PackageVersionPath {
  /// Creates a package-version path record.
  const PackageVersionPath({
    required this.package,
    required this.version,
    required this.path,
  });

  /// The package name encoded by the path.
  final String package;

  /// The package version encoded by the path.
  final String version;

  /// The filesystem path.
  final String path;
}

/// Returns the canonical `<package>@<version>` path segment.
String packageVersionName(String package, String version) {
  return '$package@$version';
}

/// Parses a canonical `<package>@<version>` path segment.
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

/// A package and version pair parsed from a Patchwork path segment.
final class PackageVersion {
  /// Creates a parsed package-version identity.
  const PackageVersion({required this.package, required this.version});

  /// The parsed package name.
  final String package;

  /// The parsed package version.
  final String version;
}
