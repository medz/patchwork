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

/// The editable package copy prepared by `patchwork patch`.
///
/// The edit directory is a disposable workspace. Committing it consumes the
/// directory by writing `patches/<pkg>@<version>.patch` and removing the edit.
final class PreparedEdit {
  /// Creates a prepared edit result.
  PreparedEdit({
    required this.package,
    required this.version,
    required this.path,
    required this.sourcePath,
    this.continuedFromPatchPath,
    this.partialRepairLogPath,
    List<String> partialRejectPaths = const [],
  }) : partialRejectPaths = List.unmodifiable(partialRejectPaths);

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

  /// The partial repair log written under `.patchwork/`, if rejects occurred.
  final String? partialRepairLogPath;

  /// Reject files moved under `.patchwork/rejects/`, relative to [path].
  final List<String> partialRejectPaths;
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
