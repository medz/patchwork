import '../state/applied_activation.dart';
import 'materializer.dart';
import 'model.dart';
import 'planner.dart';

/// Executes checked apply plans against generated package state.
final class ApplyExecutor {
  /// Creates an apply executor.
  const ApplyExecutor({required this.materializer, required this.activation});

  /// Generated package materializer.
  final AppliedPatchMaterializer materializer;

  /// Applied marker and pub override activation.
  final AppliedStateActivation activation;

  /// Materializes and activates [plan].
  AppliedPatch execute(ApplyPlan plan) {
    materializer.materialize(
      package: plan.package,
      version: plan.version,
      sourcePath: plan.sourcePath,
      appliedPath: plan.appliedPath,
      patchContent: plan.patchContent,
    );
    activation.activate(
      package: plan.package,
      version: plan.version,
      patchSha256: plan.patchSha256,
      path: plan.appliedRecordPath,
      source: plan.source,
    );
    return AppliedPatch(
      package: plan.package,
      version: plan.version,
      path: plan.appliedPath,
      patchPath: plan.patchPath,
    );
  }
}
