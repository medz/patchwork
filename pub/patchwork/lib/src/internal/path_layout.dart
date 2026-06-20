import 'dart:io';

import 'package:path/path.dart' as p;

/// Computes Patchwork-owned paths relative to a project state root.
///
/// The layout centralizes the filenames that make up Patchwork state so command
/// code does not hand-assemble paths such as `.patchwork/<pkg>@<version>` or
/// `.dart_tool/patchwork/<pkg>@<version>`.
final class PathLayout {
  /// Creates a path layout rooted at [rootPath].
  const PathLayout(this.rootPath);

  /// The directory where Patchwork state files are stored.
  final String rootPath;

  /// The root directory for editable package copies.
  String get editRootPath => p.join(rootPath, '.patchwork');

  /// The root directory for committed patch files.
  String get patchesRootPath => p.join(rootPath, 'patches');

  /// The root directory for generated applied package copies.
  String get appliedRootPath => p.join(rootPath, '.dart_tool', 'patchwork');

  /// Returns `.patchwork/<package>@<version>`.
  String editPath(String package, String version) {
    return p.join(editRootPath, packageVersionName(package, version));
  }

  /// Returns `.patchwork/<package>@<version>/.patchwork`.
  String editMetadataPath(String package, String version) {
    return p.join(editPath(package, version), '.patchwork');
  }

  /// Returns `.patchwork/<package>@<version>/.patchwork/source`.
  String editBaselinePath(String package, String version) {
    return p.join(editMetadataPath(package, version), 'source');
  }

  /// Returns `.patchwork/<package>@<version>/.patchwork/edit.json`.
  String editManifestPath(String package, String version) {
    return p.join(editMetadataPath(package, version), 'edit.json');
  }

  /// Returns `patches/<package>@<version>.patch`.
  String patchPath(String package, String version) {
    return p.join(
      patchesRootPath,
      '${packageVersionName(package, version)}.patch',
    );
  }

  /// Returns `.dart_tool/patchwork/<package>@<version>`.
  String appliedPath(String package, String version) {
    return p.join(appliedRootPath, packageVersionName(package, version));
  }

  /// Returns `.dart_tool/patchwork/<package>@<version>/.patchwork/applied.json`.
  String appliedMarkerPath(String package, String version) {
    return p.join(appliedPath(package, version), '.patchwork', 'applied.json');
  }

  /// Returns the project-relative applied path stored in override state.
  ///
  /// Keeping this path relative makes generated overrides portable across
  /// checkout locations.
  String relativeAppliedPath(String package, String version) {
    return p.posix.join(
      '.dart_tool',
      'patchwork',
      packageVersionName(package, version),
    );
  }

  /// Lists valid edit directories currently present under `.patchwork/`.
  ///
  /// Entries that do not parse as `<package>@<version>` directories are ignored
  /// so unrelated scratch files do not become package state.
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

  /// Lists valid committed patch files currently present under `patches/`.
  ///
  /// Only regular files whose basename is a safe `<package>@<version>.patch`
  /// identity are returned. Other files are ignored so scratch notes or editor
  /// artifacts do not become patch inventory.
  List<PackageVersionPath> patchFiles() {
    final root = Directory(patchesRootPath);
    if (!root.existsSync()) {
      return const [];
    }

    final entries = <PackageVersionPath>[];
    for (final entity in root.listSync(followLinks: false)) {
      if (FileSystemEntity.typeSync(entity.path, followLinks: false) !=
          FileSystemEntityType.file) {
        continue;
      }
      final basename = p.basename(entity.path);
      if (!basename.endsWith('.patch')) {
        continue;
      }
      final parsed = parsePackageVersionName(
        basename.substring(0, basename.length - '.patch'.length),
      );
      if (parsed == null ||
          !_isPlainPackageName(parsed.package) ||
          !_isSafePathSegment(parsed.version)) {
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

  /// Lists valid generated package directories under `.dart_tool/patchwork/`.
  List<PackageVersionPath> appliedDirectories() {
    final root = Directory(appliedRootPath);
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
      if (parsed == null ||
          !_isPlainPackageName(parsed.package) ||
          !_isSafePathSegment(parsed.version)) {
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

/// A filesystem path whose basename encodes a package and version.
final class PackageVersionPath {
  /// Creates a parsed path record.
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
///
/// The final `@` separates the package from the version, which allows package
/// names to remain ordinary pub package names while versions may contain other
/// punctuation.
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

bool _isPlainPackageName(String value) {
  return RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(value);
}

bool _isSafePathSegment(String value) {
  return value.isNotEmpty &&
      value != '.' &&
      value != '..' &&
      !value.contains('/') &&
      !value.contains(r'\');
}
