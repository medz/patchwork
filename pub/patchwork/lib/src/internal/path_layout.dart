import 'dart:io';

import 'package:path/path.dart' as p;

final class PathLayout {
  const PathLayout(this.rootPath);

  final String rootPath;

  String get lockfilePath => p.join(rootPath, 'patchwork.lock');
  String get editRootPath => p.join(rootPath, '.patchwork');
  String get patchesRootPath => p.join(rootPath, 'patches');
  String get appliedRootPath => p.join(rootPath, '.dart_tool', 'patchwork');

  String editPath(String package, String version) {
    return p.join(editRootPath, packageVersionName(package, version));
  }

  String patchPath(String package, String version) {
    return p.join(
      patchesRootPath,
      '${packageVersionName(package, version)}.patch',
    );
  }

  String appliedPath(String package, String version) {
    return p.join(appliedRootPath, packageVersionName(package, version));
  }

  String relativeAppliedPath(String package, String version) {
    return p.posix.join(
      '.dart_tool',
      'patchwork',
      packageVersionName(package, version),
    );
  }

  bool isExpectedAppliedPath(String package, String version, String path) {
    if (!_isSafePackageVersionName(package, version)) {
      return false;
    }
    final absolutePath = p.normalize(p.absolute(rootPath, path));
    final absoluteAppliedRoot = p.normalize(p.absolute(appliedRootPath));
    final expectedPath = p.normalize(p.absolute(appliedPath(package, version)));
    return p.equals(absolutePath, expectedPath) &&
        p.isWithin(absoluteAppliedRoot, absolutePath);
  }

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

final class PackageVersionPath {
  const PackageVersionPath({
    required this.package,
    required this.version,
    required this.path,
  });

  final String package;
  final String version;
  final String path;
}

String packageVersionName(String package, String version) {
  return '$package@$version';
}

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

final class PackageVersion {
  const PackageVersion({required this.package, required this.version});

  final String package;
  final String version;
}

bool _isSafePackageVersionName(String package, String version) {
  final name = packageVersionName(package, version);
  return p.basename(name) == name && !name.contains(r'\');
}
