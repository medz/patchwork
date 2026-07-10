/// The result of `patchwork undo` for one package.
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

/// A cleanup operation that can produce a [CleanupResult].
enum CleanupCommand {
  /// Remove one selected package version.
  remove,

  /// Remove stale Patchwork artifacts.
  prune,
}

/// One artifact that `patchwork remove` or `patchwork prune` selected.
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
final class CleanupResult {
  /// Creates a cleanup command result.
  CleanupResult({
    required this.command,
    required this.dryRun,
    required this.force,
    required List<CleanupChange> changes,
  }) : changes = List.unmodifiable(changes);

  /// The cleanup command that produced this result.
  final CleanupCommand command;

  /// Whether the command only planned cleanup without mutating files.
  final bool dryRun;

  /// Whether the command was allowed to discard open edit or applied state.
  final bool force;

  /// Planned or completed cleanup changes.
  final List<CleanupChange> changes;
}
