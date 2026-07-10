import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../error.dart';
import '../io/atomic_file_writer.dart';
import '../state/artifact_identity.dart';
import '../state/path_layout.dart';
import 'composer.dart';
import 'pub_resolution.dart';

/// Stores and activates the base pub package config used by overlays.
final class OverlayPackageConfigActivation {
  /// Creates package-config activation for one Patchwork state root.
  const OverlayPackageConfigActivation({
    required this.packageConfigPath,
    required this.layout,
  });

  /// Active `.dart_tool/package_config.json` path.
  final String packageConfigPath;

  /// Patchwork generated path layout.
  final PathLayout layout;

  /// Sidecar path containing pub's package config before overlay rewrites.
  String get basePath {
    return p.join(layout.appliedRootPath, 'package_config.base.json');
  }

  /// Whether a saved base package config exists.
  bool get hasBase => File(basePath).existsSync();

  /// Restores an existing base config or saves [current] as the new base.
  PackageConfigFile restore(PackageConfigFile current) {
    final sidecar = File(basePath);
    if (current.hasGeneratedPatchworkRoots(layout.appliedRootPath)) {
      if (!sidecar.existsSync()) {
        return current;
      }
      final content = sidecar.readAsStringSync();
      final base = PackageConfigFile.fromContent(
        path: packageConfigPath,
        content: content,
      );
      writeStringFileAtomically(packageConfigPath, content);
      return base;
    }

    Directory(p.dirname(basePath)).createSync(recursive: true);
    writeStringFileAtomically(basePath, current.content);
    return current;
  }

  /// Points matching package config entries at generated [targets].
  void activate(PackageConfigFile base, Iterable<OverlayComposition> targets) {
    final outputByPackage = {
      for (final target in targets)
        target.package: p.posix.join(
          'patchwork',
          packageVersionName(target.package, target.version),
        ),
    };
    final json = base.deepCopyJson();
    final packages = json['packages'];
    if (packages is! List<Object?>) {
      throw PatchworkException(
        'Malformed pub package_config.json: Expected packages to be a list.',
        code: 'pub.malformed_package_config',
        location: packageConfigPath,
      );
    }
    for (final package in packages) {
      if (package is! Map<String, Object?>) {
        continue;
      }
      final name = package['name'];
      if (name is String && outputByPackage.containsKey(name)) {
        package['rootUri'] = outputByPackage[name];
      }
    }
    writeStringFileAtomically(packageConfigPath, '${jsonEncode(json)}\n');
  }
}
