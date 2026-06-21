import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../error.dart';
import '../io/atomic_file_writer.dart';
import '../model.dart';
import '../overlay_manifest.dart';
import '../pub/package_resolution.dart';
import 'path_layout.dart';

/// Publishes committed patches into the current package overlay manifest.
final class OverlayPublisher {
  /// Creates an overlay publisher.
  const OverlayPublisher({
    required this.currentPackageRootPath,
    required this.layout,
    required this.pubResolutionReader,
  });

  /// Current package root that owns `patchwork.yaml`.
  final String currentPackageRootPath;

  /// Patchwork state-root path layout.
  final PathLayout layout;

  /// Pub resolution reader.
  final PubResolutionReader pubResolutionReader;

  /// Registers the committed patch for [package].
  Future<RegisteredOverlay> overlay(String package, {String? reason}) async {
    _ensureCurrentPackageCanPublishOverlays();

    final resolution = pubResolutionReader.readFromDirectory(
      currentPackageRootPath,
    );
    final resolved = resolution.resolvePackage(package);
    final patchPath = layout.patchPath(package, resolved.version);
    final patchFile = File(patchPath);
    if (!patchFile.existsSync()) {
      throw PatchworkException(
        'No committed patch file exists for "$package".',
        code: 'overlay.patch_file_missing',
        hint: 'Run patchwork commit $package first.',
        location: patchPath,
      );
    }
    final patchBytes = patchFile.readAsBytesSync();

    final manifestPath = p.join(currentPackageRootPath, 'patchwork.yaml');
    final overlayPatchPath = _publishableOverlayPatchPath(
      package: package,
      version: resolved.version,
      patchPath: patchPath,
      patchBytes: patchBytes,
    );
    final patchManifestPath = _currentPackageRelativePath(
      overlayPatchPath,
      code: 'overlay.patch_outside_package',
      message:
          'Overlay patch files must live inside the current package before they can be published.',
    );
    final store = OverlayManifestStore(path: manifestPath);
    final nextManifest = store.read().upsert(
      OverlayManifestEntry(
        package: package,
        version: resolved.version,
        sha256: resolved.source.sha256,
        patch: patchManifestPath,
        reason: reason,
      ),
    );
    store.write(nextManifest);

    return RegisteredOverlay(
      package: package,
      version: resolved.version,
      sha256: resolved.source.sha256,
      patchPath: patchManifestPath,
      manifestPath: manifestPath,
      reason: reason,
    );
  }

  void _ensureCurrentPackageCanPublishOverlays() {
    final pubspecPath = p.join(currentPackageRootPath, 'pubspec.yaml');
    try {
      final decoded = loadYaml(File(pubspecPath).readAsStringSync());
      if (decoded is! YamlMap) {
        throw PatchworkException(
          'pubspec.yaml must contain a YAML object.',
          code: 'overlay.malformed_pubspec',
          location: pubspecPath,
        );
      }
      final dependencies = decoded['dependencies'];
      if (dependencies is YamlMap && dependencies.containsKey('patchwork')) {
        return;
      }
      throw PatchworkException(
        'The current package must depend on patchwork before publishing overlays.',
        code: 'overlay.patchwork_dependency_missing',
        hint: 'Add patchwork under dependencies, not dev_dependencies.',
        location: pubspecPath,
      );
    } on YamlException catch (error) {
      throw PatchworkException(
        'Malformed pubspec.yaml.',
        code: 'overlay.malformed_pubspec',
        hint: error.message,
        location: pubspecPath,
      );
    } on FileSystemException catch (error) {
      throw PatchworkException(
        'Could not read pubspec.yaml.',
        code: 'overlay.pubspec_not_readable',
        hint: error.message,
        location: pubspecPath,
      );
    }
  }

  String _currentPackageRelativePath(
    String path, {
    required String code,
    required String message,
    String? hint,
  }) {
    final absolutePath = p.normalize(p.absolute(path));
    final currentRoot = p.normalize(p.absolute(currentPackageRootPath));
    if (!p.equals(absolutePath, currentRoot) &&
        !p.isWithin(currentRoot, absolutePath)) {
      throw PatchworkException(message, code: code, hint: hint, location: path);
    }
    return p.posix.joinAll(
      p.split(p.relative(absolutePath, from: currentRoot)),
    );
  }

  String _publishableOverlayPatchPath({
    required String package,
    required String version,
    required String patchPath,
    required List<int> patchBytes,
  }) {
    final absolutePath = p.normalize(p.absolute(patchPath));
    final currentRoot = p.normalize(p.absolute(currentPackageRootPath));
    if (p.equals(absolutePath, currentRoot) ||
        p.isWithin(currentRoot, absolutePath)) {
      return patchPath;
    }

    final packagePatchPath = PathLayout(
      currentPackageRootPath,
    ).patchPath(package, version);
    writeBytesFileAtomically(packagePatchPath, patchBytes);
    return packagePatchPath;
  }
}
