import '../inspection/model.dart';

/// A diagnostic next action printed by `patchwork doctor --explain`.
///
/// These entries are intentionally CLI guidance, not a long-term API schema.
/// They are derived from the current problem code, package, and Patchwork state.
final class SuggestedAction {
  /// Creates a suggested action.
  const SuggestedAction({this.command, required this.description});

  /// A command the user can run, when the remediation has one.
  final String? command;

  /// Why the action helps.
  final String description;
}

/// Returns the action that refreshes generated output for [status].
SuggestedAction applyAction(PatchStatus status) {
  return SuggestedAction(
    command: 'patchwork apply ${status.package}',
    description:
        'Regenerate the Patchwork output for ${status.package}@${status.version} and refresh pub resolution.',
  );
}

/// Returns remediation actions for a status or doctor [problem].
List<SuggestedAction> remediationActions(
  PatchStatus status,
  PatchProblem problem,
) {
  final package = status.package;
  final version = problem.remediationVersion ?? status.version;

  return switch (problem.code) {
    'commit.ambiguous_edit' => [
      SuggestedAction(
        description:
            'Keep exactly one .patchwork/$package@<version> edit directory before committing or applying.',
      ),
    ],
    'commit.edit_manifest_missing' ||
    'commit.edit_manifest_invalid' ||
    'commit.edit_baseline_missing' => _editRepairActions(status, problem),
    'applied.marker_invalid' ||
    'applied.marker_missing' => _markerRepairActions(status, problem),
    'applied.stale' => _staleAppliedActions(status, problem),
    'commit.open_edit' => [
      SuggestedAction(
        command: 'patchwork commit $package',
        description: 'Commit the open edit directory into a patch file.',
      ),
      if (problem.remediationVersion != null)
        SuggestedAction(
          command: 'patchwork remove $package $version --force',
          description: 'Discard the open edit directory if it is not needed.',
        )
      else
        const SuggestedAction(
          description:
              'Remove any extra edit directories before discarding one by version.',
        ),
    ],
    'apply.open_edit' => [
      SuggestedAction(
        command: 'patchwork commit $package',
        description: 'Commit the open edit directory before applying patches.',
      ),
    ],
    'patch.stale' => _stalePatchActions(status, problem),
    'pub.override_conflict' => [
      SuggestedAction(
        description:
            'Remove or merge the existing dependency override for "$package" before Patchwork writes its generated override.',
      ),
      applyAction(status),
    ],
    'applied.output_missing' ||
    'applied.patch_stale' ||
    'applied.source_stale' ||
    'applied.override_missing' => _appliedRepairActions(status, problem),
    'applied.patch_missing' => [
      SuggestedAction(
        command: 'patchwork undo $package',
        description:
            'Remove the generated output because the committed patch file is gone.',
      ),
    ],
    'applied.pub_get_required' => [
      applyAction(status),
      const SuggestedAction(
        command: 'dart pub get',
        description: 'Refresh pub resolution without changing Patchwork files.',
      ),
    ],
    'undo.applied_path_not_deletable' => [
      const SuggestedAction(
        description:
            'Review the applied output path and remove it manually only after confirming it is Patchwork-generated.',
      ),
    ],
    _ when problem.code.startsWith('pub.') => _pubActions(status, problem),
    _ => _fallbackActions(problem),
  };
}

List<SuggestedAction> _editRepairActions(
  PatchStatus status,
  PatchProblem problem,
) {
  final package = status.package;
  final version = problem.remediationVersion ?? status.version;
  final editPath = _PatchworkPath.edit(package, version);
  final canContinuePatch =
      problem.remediationCanContinuePatch ||
      (status.hasPatch && version == status.version);

  return [
    SuggestedAction(
      description:
          'Back up any useful edits from $editPath before recreating the edit session.',
    ),
    SuggestedAction(
      description:
          'Delete only the broken edit directory at $editPath; do not remove the committed patch file.',
    ),
    SuggestedAction(
      command: canContinuePatch
          ? 'patchwork patch $package --continue $version'
          : 'patchwork patch $package',
      description: canContinuePatch
          ? 'Recreate a valid edit directory from the committed patch.'
          : 'Create a fresh edit directory with valid Patchwork metadata.',
    ),
  ];
}

List<SuggestedAction> _stalePatchActions(
  PatchStatus status,
  PatchProblem problem,
) {
  final package = status.package;
  final version = problem.remediationVersion ?? status.version;
  if (status.hasOpenEdit) {
    return [
      SuggestedAction(
        command: 'patchwork commit $package',
        description:
            'Commit the open edit directory before continuing the stale patch.',
      ),
      const SuggestedAction(
        description:
            'Remove the open edit directory if it is not needed, then rerun patchwork doctor --explain for stale patch actions.',
      ),
    ];
  }

  return [
    SuggestedAction(
      command: 'patchwork carry $package --from $version',
      description:
          'Carry the stale patch content into a fresh edit for the currently resolved version.',
    ),
    SuggestedAction(
      command: 'patchwork remove $package $version',
      description: 'Remove the stale patch file if it is no longer needed.',
    ),
  ];
}

List<SuggestedAction> _markerRepairActions(
  PatchStatus status,
  PatchProblem problem,
) {
  final package = status.package;
  final version = problem.remediationVersion ?? status.version;
  final appliedPath = _PatchworkPath.applied(package, version);
  return [
    SuggestedAction(
      description:
          'Review and remove the generated directory at $appliedPath if it is safe.',
    ),
    if (problem.remediationRequiresOverrideCleanup) ...[
      SuggestedAction(
        description:
            'Remove the "$package" entry from pubspec_overrides.yaml if it points at $appliedPath.',
      ),
      const SuggestedAction(
        command: 'dart pub get',
        description:
            'Refresh pub resolution after removing the generated override.',
      ),
    ],
    if (status.hasPatch)
      applyAction(status)
    else
      const SuggestedAction(
        description:
            'No committed patch file exists, so cleanup must finish before applying again.',
      ),
  ];
}

List<SuggestedAction> _staleAppliedActions(
  PatchStatus status,
  PatchProblem problem,
) {
  final package = status.package;
  final version = problem.remediationVersion ?? status.version;
  if (problem.remediationRequiresManualCleanup) {
    return [
      SuggestedAction(
        description:
            'Review and remove ${_PatchworkPath.applied(package, version)} manually because Patchwork cannot verify its ownership marker.',
      ),
    ];
  }

  return const [
    SuggestedAction(
      command: 'patchwork prune',
      description:
          'Remove generated output that no longer matches current patch state.',
    ),
  ];
}

List<SuggestedAction> _appliedRepairActions(
  PatchStatus status,
  PatchProblem problem,
) {
  final package = status.package;
  if (!status.hasPatch) {
    return _missingPatchAppliedRepairActions(status, problem);
  }

  if (!problem.remediationRequiresUndoFirst) {
    return [applyAction(status)];
  }

  return [
    SuggestedAction(
      command: 'patchwork undo $package',
      description:
          'Remove the current generated output so pub can resolve the original dependency source.',
    ),
    const SuggestedAction(
      command: 'dart pub get',
      description:
          'Refresh pub resolution after removing the generated override.',
    ),
    applyAction(status),
  ];
}

List<SuggestedAction> _missingPatchAppliedRepairActions(
  PatchStatus status,
  PatchProblem problem,
) {
  if (problem.code == 'applied.output_missing') {
    return const [
      SuggestedAction(
        description:
            'Clean up the applied Patchwork state before applying again because the committed patch file is gone.',
      ),
    ];
  }

  final package = status.package;
  return [
    SuggestedAction(
      command: 'patchwork undo $package',
      description:
          'Remove the applied Patchwork state because the committed patch file is gone.',
    ),
    if (problem.remediationRequiresUndoFirst)
      const SuggestedAction(
        command: 'dart pub get',
        description:
            'Refresh pub resolution after removing the generated override.',
      ),
  ];
}

List<SuggestedAction> _pubActions(PatchStatus status, PatchProblem problem) {
  return switch (problem.code) {
    'pub.package_not_found' => _missingPackageActions(status),
    'pub.package_version_not_found' ||
    'pub.package_root_missing' ||
    'pub.lockfile_not_found' ||
    'pub.resolution_not_found' => [
      const SuggestedAction(
        command: 'dart pub get',
        description:
            'Regenerate pub resolution files before rerunning Patchwork.',
      ),
    ],
    'pub.package_is_project' ||
    'pub.package_not_direct_dependency' ||
    'pub.unsupported_source' => [
      SuggestedAction(
        description:
            'Choose a normal pub dependency as the patch target, then recreate the patch for that package.',
      ),
    ],
    _ => [
      const SuggestedAction(
        description:
            'Fix the reported pub configuration or generated resolution file.',
      ),
      const SuggestedAction(
        command: 'dart pub get',
        description: 'Regenerate pub resolution after the pub files are fixed.',
      ),
    ],
  };
}

List<SuggestedAction> _missingPackageActions(PatchStatus status) {
  final package = status.package;
  final version = status.version;
  return [
    const SuggestedAction(
      command: 'dart pub get',
      description: 'Refresh pub resolution after dependency changes.',
    ),
    if (status.appliedPath != null)
      SuggestedAction(
        command: 'patchwork undo $package',
        description:
            'Remove applied Patchwork output before deleting patch artifacts.',
      ),
    if (status.hasOpenEdit)
      SuggestedAction(
        description:
            'Back up any useful edits from ${_PatchworkPath.edit(package, version)} before removing local Patchwork state.',
      ),
    SuggestedAction(
      command: status.hasOpenEdit
          ? 'patchwork remove $package $version --force'
          : 'patchwork remove $package $version',
      description: status.hasOpenEdit
          ? 'Remove the patch file and open edit if "$package" is no longer part of this project.'
          : 'Remove the patch file if "$package" is no longer part of this project.',
    ),
  ];
}

List<SuggestedAction> _fallbackActions(PatchProblem problem) {
  if (problem.hint != null && problem.hint!.isNotEmpty) {
    return [SuggestedAction(description: problem.hint!)];
  }
  return const [
    SuggestedAction(
      description:
          'Review the diagnostic message, fix the reported Patchwork state, then rerun patchwork doctor --explain.',
    ),
  ];
}

abstract final class _PatchworkPath {
  static String edit(String package, String version) {
    return '.patchwork/$package@$version';
  }

  static String applied(String package, String version) {
    return '.dart_tool/patchwork/$package@$version';
  }
}
