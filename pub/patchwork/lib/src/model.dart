/// Identifies the committed patch file used to seed a new edit directory.
///
/// `patchwork patch --continue` creates a fresh edit tree from the currently
/// resolved dependency source and then applies a committed patch into that tree.
/// A [PatchRef] chooses whether that seed patch comes from the current resolved
/// version or from an explicitly named older version.
final class PatchRef {
  const PatchRef._(this.version);

  /// Selects `patches/<pkg>@<current-version>.patch`.
  const PatchRef.current() : this._(null);

  /// Selects `patches/<pkg>@<version>.patch`.
  const PatchRef.version(String version) : this._(version);

  /// The explicit patch version, or `null` when the current resolution is used.
  final String? version;
}

/// The pub source that Patchwork used as the baseline for a package patch.
///
/// Patchwork records this value in local edit/applied metadata and provider
/// overlay manifests when source identity is needed for safety diagnostics.
/// The [fields] map contains source-specific identity such as hosted URL, path,
/// Git URL, branch, or commit.
final class PackageSource {
  /// Creates a resolved source description.
  const PackageSource({
    required this.type,
    required this.sha256,
    this.fields = const {},
  });

  /// The pub source kind, such as `hosted`, `path`, or `git`.
  final String type;

  /// A deterministic hash of the resolved package contents.
  ///
  /// Generated files ignored by Patchwork, such as `.dart_tool` and
  /// `pubspec.lock`, are not included in this hash.
  final String sha256;

  /// Source-specific identity fields copied from pub resolution metadata.
  final Map<String, String> fields;

  @override
  bool operator ==(Object other) {
    return other is PackageSource &&
        other.type == type &&
        other.sha256 == sha256 &&
        _stringMapsEqual(other.fields, fields);
  }

  @override
  int get hashCode {
    var result = Object.hash(type, sha256);
    final keys = fields.keys.toList()..sort();
    for (final key in keys) {
      result = Object.hash(result, key, fields[key]);
    }
    return result;
  }
}

/// The editable package copy prepared by `patchwork patch`.
///
/// The edit directory is a disposable workspace. Calling [Patchwork.commit]
/// consumes it by writing the corresponding `patches/<pkg>@<version>.patch`
/// file and then removing the directory.
final class PreparedEdit {
  /// Creates a prepared edit result.
  const PreparedEdit({
    required this.package,
    required this.version,
    required this.path,
    required this.sourcePath,
    this.continuedFromPatchPath,
  });

  /// The dependency package being edited.
  final String package;

  /// The resolved package version copied into [path].
  final String version;

  /// The edit directory under `.patchwork/`.
  final String path;

  /// The resolved pub package root that was copied into [path].
  final String sourcePath;

  /// The patch file that was applied before returning, if this was a continue.
  final String? continuedFromPatchPath;
}

/// How `patchwork commit` changed the committed patch artifact.
enum PatchWriteStatus {
  /// A patch file was written or replaced because the edit changed the source.
  written,

  /// The edit matched the existing patch artifact and no file changed.
  unchanged,

  /// The edit matched the source, so the committed patch artifact was removed.
  removed,
}

/// The result of committing one edit directory.
///
/// A value is returned for each edit processed by [Patchwork.commit] or
/// [Patchwork.commitAll]. The [status] field distinguishes a newly written
/// patch from an unchanged edit or an edit whose changes disappeared.
final class PatchWrite {
  /// Creates a commit result.
  const PatchWrite({
    required this.package,
    required this.version,
    required this.status,
    required this.editPath,
    required this.patchPath,
  });

  /// The dependency package whose edit directory was committed.
  final String package;

  /// The version encoded by [patchPath].
  final String version;

  /// The artifact change made by the commit operation.
  final PatchWriteStatus status;

  /// The edit directory that was removed after the commit completed.
  final String editPath;

  /// The committed patch file path for this package version.
  final String patchPath;
}

/// A committed patch materialized into generated pub override output.
///
/// `patchwork apply` writes a generated package copy under `.dart_tool` and
/// points `pubspec_overrides.yaml` at that copy. Callers should run
/// `dart pub get` after applying so pub refreshes package resolution.
final class AppliedPatch {
  /// Creates an apply result.
  const AppliedPatch({
    required this.package,
    required this.version,
    required this.path,
    required this.patchPath,
  });

  /// The dependency package that was applied.
  final String package;

  /// The version encoded by [patchPath] and generated into [path].
  final String version;

  /// The generated package copy under `.dart_tool/patchwork/`.
  final String path;

  /// The committed patch file used to produce [path].
  final String patchPath;
}

/// The result of `patchwork undo` for one package.
///
/// Undo is intentionally conservative: [changed] is false when no Patchwork
/// applied state exists, and true only after Patchwork removes generated output
/// and the matching override it owns.
final class UnappliedPatch {
  /// Creates an undo result.
  const UnappliedPatch({
    required this.package,
    required this.changed,
    this.path,
  });

  /// The dependency package requested by the caller.
  final String package;

  /// Whether generated Patchwork state was removed.
  final bool changed;

  /// The generated package path that was removed, or `null` when unchanged.
  final String? path;
}

/// The kind of Patchwork artifact selected by a cleanup command.
enum CleanupChangeKind {
  /// A committed patch file under `patches/`.
  patchFile,

  /// An open edit directory under `.patchwork/`.
  editDirectory,

  /// A generated package directory under `.dart_tool/patchwork/`.
  appliedDirectory,

  /// A Patchwork-owned entry in `pubspec_overrides.yaml`.
  pubspecOverride,
}

/// One artifact that `patchwork remove` or `patchwork prune` selected.
///
/// Cleanup commands return planned changes in dry-run mode and completed
/// changes after mutation. Paths are absolute when returned from the library;
/// the CLI may render them relative to the project root.
final class CleanupChange {
  /// Creates a cleanup change entry.
  const CleanupChange({
    required this.kind,
    required this.package,
    required this.version,
    required this.path,
  });

  /// The kind of artifact selected for cleanup.
  final CleanupChangeKind kind;

  /// The dependency package associated with [path].
  final String package;

  /// The package version associated with [path].
  final String version;

  /// The selected artifact path.
  final String path;
}

/// The result of a Patchwork cleanup command.
///
/// When [dryRun] is true, [changes] describes what would be removed. Otherwise
/// [changes] describes the artifacts that were removed or updated.
final class CleanupResult {
  /// Creates a cleanup command result.
  const CleanupResult({
    required this.command,
    required this.dryRun,
    required this.force,
    required this.changes,
  });

  /// The cleanup command that produced this result.
  final String command;

  /// Whether the command only planned cleanup without mutating files.
  final bool dryRun;

  /// Whether the command was allowed to discard open edit or applied state.
  final bool force;

  /// Planned or completed cleanup changes.
  final List<CleanupChange> changes;
}

/// A package-provided overlay registered in `patchwork.yaml`.
///
/// Overlay declarations let a package author publish a committed patch for one
/// of their dependencies. Downstream Patchwork hooks can compose these
/// declarations with other patch contributions for the same resolved package.
final class RegisteredOverlay {
  /// Creates an overlay registration result.
  const RegisteredOverlay({
    required this.package,
    required this.version,
    required this.sha256,
    required this.patchPath,
    required this.manifestPath,
    this.reason,
  });

  /// The dependency package targeted by the overlay.
  final String package;

  /// The resolved dependency version this overlay matches.
  final String version;

  /// The resolved source tree hash this overlay matches.
  final String sha256;

  /// The patch file path recorded in `patchwork.yaml`.
  final String patchPath;

  /// The manifest path that was created or updated.
  final String manifestPath;

  /// Optional human-readable reason for the overlay.
  final String? reason;
}

/// A machine-readable status or doctor problem.
///
/// The [code] is stable enough for tests and tools to match. The [message] and
/// [hint] are intended for human output and may provide more specific context
/// about the current filesystem or pub resolution state.
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
  });

  /// A stable identifier for the problem category.
  final String code;

  /// The primary human-readable problem summary.
  final String message;

  /// Optional guidance for resolving the problem.
  final String? hint;

  /// Optional version a remediation command should target instead of the
  /// package status version.
  ///
  /// This is used when a diagnostic describes an older artifact, such as a
  /// stale patch file, while the package status itself points at the current
  /// pub resolution.
  final String? remediationVersion;

  /// Whether edit remediation can recreate the edit directory from a committed
  /// patch file for [remediationVersion].
  final bool remediationCanContinuePatch;

  /// Whether remediation must remove applied output and refresh pub resolution
  /// before applying again.
  ///
  /// Applied output can be stale while pub still resolves the package through
  /// `.dart_tool/patchwork`. In that state `patchwork apply` cannot regenerate
  /// the output until the generated override has been unwound.
  final bool remediationRequiresUndoFirst;

  /// Whether remediation must remove a generated override and refresh pub
  /// resolution before applying again.
  final bool remediationRequiresOverrideCleanup;
}

/// The inspected Patchwork state for a single dependency package.
///
/// Status combines the durable patch artifact, any open edit directory,
/// generated applied output, and diagnostics. Paths are absolute when returned
/// from the library; the CLI may render them relative to the project root.
final class PatchStatus {
  /// Creates a package status entry.
  const PatchStatus({
    required this.package,
    required this.version,
    required this.editPath,
    required this.patchPath,
    required this.appliedPath,
    required this.hasOpenEdit,
    required this.hasPatch,
    required this.needsApply,
    this.problems = const [],
  });

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

/// The inspected Patchwork state for an entire project.
final class PatchworkState {
  /// Creates a project state snapshot.
  const PatchworkState({required this.packages});

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

bool _stringMapsEqual(Map<String, String> left, Map<String, String> right) {
  if (left.length != right.length) {
    return false;
  }
  for (final entry in left.entries) {
    if (right[entry.key] != entry.value) {
      return false;
    }
  }
  return true;
}
