/// A machine-readable status or doctor problem.
final class PatchProblem {
  /// Creates a problem entry.
  const PatchProblem({
    required this.code,
    required this.message,
    this.hint,
    this.remediationVersion,
    this.remediationCanContinuePatch = false,
    this.remediationRequiresUndoFirst = false,
    this.remediationRequiresOverrideCleanup = false,
    this.remediationRequiresManualCleanup = false,
  });

  /// A stable identifier for the problem category.
  final String code;

  /// The primary human-readable problem summary.
  final String message;

  /// Optional guidance for resolving the problem.
  final String? hint;

  /// Optional version a remediation command should target.
  final String? remediationVersion;

  /// Whether edit remediation can continue from a committed patch.
  final bool remediationCanContinuePatch;

  /// Whether remediation must remove applied output before applying again.
  final bool remediationRequiresUndoFirst;

  /// Whether remediation must remove a generated override.
  final bool remediationRequiresOverrideCleanup;

  /// Whether ownership is too uncertain for automatic cleanup.
  final bool remediationRequiresManualCleanup;
}

/// The inspected Patchwork state for a single dependency package.
final class PatchStatus {
  /// Creates a package status entry.
  PatchStatus({
    required this.package,
    required this.version,
    required this.editPath,
    required this.patchPath,
    required this.appliedPath,
    required this.hasOpenEdit,
    required this.hasPatch,
    required this.needsApply,
    List<PatchProblem> problems = const [],
  }) : problems = List.unmodifiable(problems);

  /// The dependency package represented by this status.
  final String package;

  /// The package version currently associated with Patchwork state.
  final String version;

  /// The edit directory path for this package version.
  final String editPath;

  /// The committed patch file path for this package version.
  final String patchPath;

  /// The generated package path currently wired into pub, if any.
  final String? appliedPath;

  /// Whether [editPath] exists and still needs to be committed or deleted.
  final bool hasOpenEdit;

  /// Whether [patchPath] exists and is tracked by Patchwork state.
  final bool hasPatch;

  /// Whether the committed patch should be applied or refreshed.
  final bool needsApply;

  /// Problems that make this package unsafe, stale, or inconsistent.
  final List<PatchProblem> problems;
}

/// The severity of a project setup check.
enum SetupCheckLevel {
  /// The project satisfies the setup check.
  ok,

  /// The project should change configuration before relying on Patchwork.
  warning,

  /// Informational guidance for optional setup choices.
  info,
}

/// A setup recommendation reported by `patchwork doctor --setup`.
final class SetupCheck {
  /// Creates a setup check result.
  const SetupCheck({
    required this.code,
    required this.level,
    required this.message,
    this.hint,
    this.path,
  });

  /// A stable identifier for the setup check.
  final String code;

  /// Whether this check passed, warns, or only provides optional guidance.
  final SetupCheckLevel level;

  /// Human-readable setup status.
  final String message;

  /// Optional concrete remediation guidance.
  final String? hint;

  /// Optional file or directory path related to this check.
  final String? path;
}

/// Setup diagnostics for a Patchwork project.
final class SetupReport {
  /// Creates a setup report.
  SetupReport({required List<SetupCheck> checks})
    : checks = List.unmodifiable(checks);

  /// Setup checks in deterministic presentation order.
  final List<SetupCheck> checks;

  /// Checks that should make `patchwork doctor --setup` fail.
  Iterable<SetupCheck> get warnings {
    return checks.where((check) => check.level == SetupCheckLevel.warning);
  }

  /// Whether the setup report contains warning-level diagnostics.
  bool get hasWarnings => warnings.isNotEmpty;
}

/// The inspected Patchwork state for an entire project.
final class PatchworkState {
  /// Creates a project state snapshot.
  PatchworkState({required List<PatchStatus> packages})
    : packages = List.unmodifiable(packages);

  /// Package statuses sorted by package name for deterministic output.
  final List<PatchStatus> packages;

  /// Packages whose committed patch output is stale or not yet generated.
  Iterable<PatchStatus> get needsApply {
    return packages.where((package) => package.needsApply);
  }

  /// Problems across all inspected packages.
  Iterable<PatchProblem> get problems {
    return packages.expand((package) => package.problems);
  }
}
