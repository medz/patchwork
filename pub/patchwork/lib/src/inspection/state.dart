import '../error.dart';
import '../pub/resolution.dart';
import '../pub/resolution_reader.dart';
import '../state/applied_marker.dart';
import '../state/applied_path_policy.dart';
import '../state/artifact_inventory.dart';
import '../state/dependency_override_state.dart';
import '../state/edit_session.dart';
import '../state/path_layout.dart';
import 'model.dart';
import 'package.dart';

/// Builds read-only Patchwork state diagnostics for status and doctor output.
final class PatchworkStateInspector {
  /// Creates an inspector for one Patchwork state root.
  PatchworkStateInspector({
    required String rootPath,
    required String currentPackageRootPath,
    required PathLayout layout,
    required PubResolutionReader pubResolutionReader,
    required EditSessionStore editSessionStore,
    required AppliedMarkerStore appliedMarkerStore,
    required AppliedPathPolicy appliedPaths,
    required DependencyOverrideState Function() readOverrideState,
  }) : _currentPackageRootPath = currentPackageRootPath,
       _layout = layout,
       _pubResolutionReader = pubResolutionReader,
       _readOverrideState = readOverrideState,
       _packageInspector = PackageInspector(
         rootPath: rootPath,
         layout: layout,
         editSessionStore: editSessionStore,
         appliedMarkerStore: appliedMarkerStore,
         appliedPaths: appliedPaths,
       );

  final String _currentPackageRootPath;
  final PathLayout _layout;
  final PubResolutionReader _pubResolutionReader;
  final DependencyOverrideState Function() _readOverrideState;
  final PackageInspector _packageInspector;

  /// Inspects edit directories, patch files, applied output, and pub state.
  PatchworkState inspect() {
    final inventory = PatchworkArtifactInventory.read(_layout);
    if (inventory.packages.isEmpty) {
      return PatchworkState(packages: const []);
    }

    PubResolution? resolution;
    PatchworkException? resolutionError;
    try {
      resolution = _pubResolutionReader.readFromDirectory(
        _currentPackageRootPath,
      );
    } on PatchworkException catch (error) {
      resolutionError = error;
    }

    final overrideState = _readOverrideState();
    return PatchworkState(
      packages: [
        for (final package in inventory.packages)
          _packageInspector.inspect(
            package: package,
            edit: inventory.editsFor(package),
            patchFiles: inventory.patchesFor(package),
            appliedDirectories: inventory.appliedFor(package),
            resolution: resolution,
            resolutionError: resolutionError,
            overrideState: overrideState,
          ),
      ],
    );
  }
}
