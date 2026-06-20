import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../error.dart';

/// A parsed `.dart_tool/package_config.json` file.
final class PackageConfigFile {
  PackageConfigFile._({
    required this.content,
    required this.json,
    required this.packages,
  });

  /// Reads and parses a package config file at [path].
  factory PackageConfigFile.read(String path) {
    return PackageConfigFile.fromContent(
      path: path,
      content: File(path).readAsStringSync(),
    );
  }

  /// Parses [content] as a package config located at [path].
  factory PackageConfigFile.fromContent({
    required String path,
    required String content,
  }) {
    final decoded = jsonDecode(content);
    if (decoded is! Map<String, Object?>) {
      throw PatchworkException(
        'Malformed pub package_config.json: Expected a JSON object.',
        code: 'pub.malformed_package_config',
        location: path,
      );
    }
    final rawPackages = decoded['packages'];
    if (rawPackages is! List<Object?>) {
      throw PatchworkException(
        'Malformed pub package_config.json: Expected packages to be a list.',
        code: 'pub.malformed_package_config',
        location: path,
      );
    }
    final baseUri = Directory(p.dirname(path)).uri;
    final packages = <PackageConfigPackage>[];
    for (final rawPackage in rawPackages) {
      if (rawPackage is! Map<String, Object?>) {
        continue;
      }
      final name = rawPackage['name'];
      final rootUri = rawPackage['rootUri'];
      if (name is! String || rootUri is! String) {
        continue;
      }
      packages.add(
        PackageConfigPackage(
          name: name,
          rootPath: p.normalize(
            baseUri.resolveUri(Uri.parse(rootUri)).toFilePath(),
          ),
        ),
      );
    }
    return PackageConfigFile._(
      content: content,
      json: decoded,
      packages: List.unmodifiable(packages),
    );
  }

  /// The raw file contents.
  final String content;

  /// The decoded package config JSON object.
  final Map<String, Object?> json;

  /// Package names and root paths listed in the config.
  final List<PackageConfigPackage> packages;

  /// Whether any package root points into Patchwork generated output.
  bool hasGeneratedPatchworkRoots(String appliedRootPath) {
    final root = p.normalize(p.absolute(appliedRootPath));
    return packages.any((package) {
      final packageRoot = p.normalize(p.absolute(package.rootPath));
      return p.isWithin(root, packageRoot);
    });
  }

  /// Returns a mutable deep copy of [json].
  Map<String, Object?> deepCopyJson() {
    return jsonDecode(jsonEncode(json)) as Map<String, Object?>;
  }
}

/// A single package entry from `package_config.json`.
final class PackageConfigPackage {
  /// Creates parsed package config package metadata.
  const PackageConfigPackage({required this.name, required this.rootPath});

  /// The package name.
  final String name;

  /// The resolved package root path.
  final String rootPath;
}

/// A parsed `.dart_tool/package_graph.json` file.
final class PackageGraph {
  /// Creates parsed package graph metadata.
  const PackageGraph({required this.roots, required this.packages});

  /// Reads and parses `package_graph.json` under [dartToolPath].
  factory PackageGraph.read(String dartToolPath) {
    final path = p.join(dartToolPath, 'package_graph.json');
    final decoded = jsonDecode(File(path).readAsStringSync());
    if (decoded is! Map<String, Object?>) {
      throw PatchworkException(
        'Malformed .dart_tool/package_graph.json: Expected a JSON object.',
        code: 'pub.malformed_package_graph',
        location: path,
      );
    }
    final roots = decoded['roots'];
    final rawPackages = decoded['packages'];
    if (roots is! List<Object?> || rawPackages is! List<Object?>) {
      throw PatchworkException(
        'Malformed .dart_tool/package_graph.json: Expected roots and packages lists.',
        code: 'pub.malformed_package_graph',
        location: path,
      );
    }
    return PackageGraph(
      roots: {
        for (final root in roots)
          if (root is String) root,
      },
      packages: {
        for (final rawPackage in rawPackages)
          if (rawPackage is Map<String, Object?> &&
              rawPackage['name'] is String)
            rawPackage['name'] as String: GraphPackage.fromJson(
              rawPackage,
              path,
            ),
      },
    );
  }

  /// Package graph root package names.
  final Set<String> roots;

  /// Package graph packages keyed by package name.
  final Map<String, GraphPackage> packages;

  /// Whether another package depends on [packageName].
  bool hasIncomingDependency(String packageName) {
    return packages.values.any((package) {
      return package.dependencies.contains(packageName);
    });
  }
}

/// A package entry from `package_graph.json`.
final class GraphPackage {
  /// Creates parsed package graph package metadata.
  const GraphPackage({required this.dependencies});

  /// Parses a package graph package object.
  factory GraphPackage.fromJson(Map<String, Object?> json, String path) {
    return GraphPackage(
      dependencies: _stringList(json['dependencies'], path, 'dependencies'),
    );
  }

  /// Direct dependencies recorded by pub.
  final Set<String> dependencies;
}

Set<String> _stringList(Object? value, String path, String field) {
  if (value is! List<Object?>) {
    throw PatchworkException(
      'Malformed .dart_tool/package_graph.json: Expected $field to be a list.',
      code: 'pub.malformed_package_graph',
      location: path,
    );
  }
  return {
    for (final item in value)
      if (item is String) item,
  };
}
