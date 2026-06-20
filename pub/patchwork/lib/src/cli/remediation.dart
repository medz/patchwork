import '../model.dart';

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
    'commit.edit_baseline_missing' => [
      SuggestedAction(
        description:
            'Back up any useful edits from ${_PatchworkPath.edit(package, version)} before recreating the edit session.',
      ),
      SuggestedAction(
        command: 'patchwork remove $package $version --force',
        description: 'Remove the broken edit directory metadata.',
      ),
      SuggestedAction(
        command: 'patchwork patch $package',
        description:
            'Create a fresh edit directory with valid Patchwork metadata.',
      ),
    ],
    'applied.marker_invalid' || 'applied.marker_missing' => [
      SuggestedAction(
        description:
            'Review and remove the generated directory at ${_PatchworkPath.applied(package, version)} if it is safe.',
      ),
      applyAction(status),
    ],
    'applied.stale' => [
      const SuggestedAction(
        command: 'patchwork prune',
        description:
            'Remove generated output that no longer matches current patch state.',
      ),
    ],
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
    'patch.stale' => [
      SuggestedAction(
        command: 'patchwork patch $package --continue $version',
        description:
            'Carry the stale patch content into a fresh edit for the currently resolved version.',
      ),
      SuggestedAction(
        command: 'patchwork remove $package $version',
        description: 'Remove the stale patch file if it is no longer needed.',
      ),
    ],
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
    'applied.override_missing' => [
      applyAction(status),
      SuggestedAction(
        command: 'patchwork undo $package',
        description:
            'Remove the current generated output first if pub still resolves to stale Patchwork state.',
      ),
    ],
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

List<SuggestedAction> _pubActions(PatchStatus status, PatchProblem problem) {
  final package = status.package;
  final version = status.version;

  return switch (problem.code) {
    'pub.package_not_found' => [
      const SuggestedAction(
        command: 'dart pub get',
        description: 'Refresh pub resolution after dependency changes.',
      ),
      SuggestedAction(
        command: 'patchwork remove $package $version',
        description:
            'Remove the patch file if "$package" is no longer part of this project.',
      ),
    ],
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
