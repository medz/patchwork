import 'dart:io';

import '../patch/package_tree.dart';
import '../state/applied_activation.dart';
import 'model.dart';
import 'plan.dart';
import 'undo.dart';

/// Executes checked undo and cleanup plans.
final class CleanupExecutor {
  /// Creates a cleanup executor.
  const CleanupExecutor({required this.activation, required this.packageTree});

  /// Applied marker and pub override activation.
  final AppliedStateActivation activation;

  /// Filesystem tree helper.
  final PackageTree packageTree;

  /// Executes one checked undo plan.
  UnappliedPatch undo(UndoPlan plan) {
    final marker = plan.marker;
    if (marker == null) {
      return UnappliedPatch(package: plan.package, changed: false);
    }
    final path = activation.remove(
      marker,
      code: 'undo.applied_path_not_deletable',
    );
    return UnappliedPatch(package: plan.package, changed: true, path: path);
  }

  /// Executes [plan] unless it is a dry run.
  void execute(CleanupPlan plan, {required String appliedPathCode}) {
    if (plan.result.dryRun) {
      return;
    }
    for (final marker in plan.appliedMarkers) {
      activation.remove(marker, code: appliedPathCode);
    }
    for (final change in plan.result.changes) {
      switch (change.kind) {
        case CleanupChangeKind.patchFile:
          final file = File(change.path);
          if (file.existsSync()) {
            file.deleteSync();
          }
        case CleanupChangeKind.editDirectory:
          packageTree.deleteDirectory(change.path);
        case CleanupChangeKind.appliedDirectory ||
            CleanupChangeKind.pubspecOverride:
          break;
      }
    }
  }
}
