/// Selects which committed patch file should seed a new edit directory.
final class PatchRef {
  const PatchRef._(this.version);

  /// Uses the patch file for the currently resolved package version.
  const PatchRef.current() : this._(null);

  /// Uses the patch file for an explicit package [version].
  const PatchRef.version(String version) : this._(version);

  /// The explicit patch version, or `null` for the current resolved version.
  final String? version;
}

/// Describes the resolved source tree that a patch is based on.
final class PackageSource {
  /// Creates source metadata for a resolved pub dependency.
  const PackageSource({
    required this.type,
    required this.sha256,
    this.fields = const {},
  });

  /// The pub source type, such as `hosted`, `path`, or `git`.
  final String type;

  /// The Patchwork content hash for the resolved source tree.
  final String sha256;

  /// Source-specific metadata, such as hosted URL, path, branch, or commit.
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

/// Describes an editable package copy created by `patchwork patch`.
final class PreparedEdit {
  /// Creates metadata for a prepared edit directory.
  const PreparedEdit({
    required this.package,
    required this.version,
    required this.path,
    required this.sourcePath,
    this.continuedFromPatchPath,
  });

  /// The package being edited.
  final String package;

  /// The resolved package version being edited.
  final String version;

  /// The edit directory path under `.patchwork/`.
  final String path;

  /// The source package path copied into the edit directory.
  final String sourcePath;

  /// The patch file used as a continuation seed, if any.
  final String? continuedFromPatchPath;
}

/// The result category for committing an edit directory.
enum PatchWriteStatus {
  /// A patch file was written or replaced.
  written,

  /// The existing patch file already matched the edit directory.
  unchanged,

  /// The edit directory contained no changes, so the patch was removed.
  removed,
}

/// Describes the result of `patchwork commit`.
final class PatchWrite {
  /// Creates metadata for a committed edit directory.
  const PatchWrite({
    required this.package,
    required this.version,
    required this.status,
    required this.editPath,
    required this.patchPath,
  });

  /// The package whose edit was committed.
  final String package;

  /// The package version associated with the patch file.
  final String version;

  /// Whether the commit wrote, reused, or removed a patch file.
  final PatchWriteStatus status;

  /// The edit directory path that was consumed.
  final String editPath;

  /// The committed patch file path.
  final String patchPath;
}

/// Describes a patch that was materialized by `patchwork apply`.
final class AppliedPatch {
  /// Creates metadata for an applied patch.
  const AppliedPatch({
    required this.package,
    required this.version,
    required this.path,
    required this.patchPath,
  });

  /// The package that was applied.
  final String package;

  /// The package version that was applied.
  final String version;

  /// The generated package path under `.dart_tool/patchwork/`.
  final String path;

  /// The patch file used to produce the generated package.
  final String patchPath;
}

/// Describes the result of removing a generated Patchwork override.
final class UnappliedPatch {
  /// Creates metadata for an undo operation.
  const UnappliedPatch({
    required this.package,
    required this.changed,
    this.path,
  });

  /// The package passed to `patchwork undo`.
  final String package;

  /// Whether Patchwork removed generated output or override state.
  final bool changed;

  /// The generated package path that was removed, when [changed] is true.
  final String? path;
}

/// Describes a status or doctor problem for a patch package.
final class PatchProblem {
  /// Creates a problem with a stable [code] and human-readable [message].
  const PatchProblem({required this.code, required this.message, this.hint});

  /// A stable identifier for the problem category.
  final String code;

  /// The human-readable problem summary.
  final String message;

  /// Optional guidance for resolving the problem.
  final String? hint;
}

/// Describes Patchwork state for one package.
final class PatchStatus {
  /// Creates a package status snapshot.
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

  /// The package represented by this status.
  final String package;

  /// The package version represented by this status.
  final String version;

  /// The expected or existing edit directory path.
  final String editPath;

  /// The expected or existing committed patch file path.
  final String patchPath;

  /// The generated applied package path, when currently applied.
  final String? appliedPath;

  /// Whether an edit directory currently exists for the package.
  final bool hasOpenEdit;

  /// Whether a committed patch file currently exists for the package.
  final bool hasPatch;

  /// Whether the committed patch should be applied to generated output.
  final bool needsApply;

  /// Problems detected for this package.
  final List<PatchProblem> problems;
}

/// Describes the full Patchwork state for a project.
final class PatchworkState {
  /// Creates a project state snapshot.
  const PatchworkState({required this.packages});

  /// Package statuses sorted for deterministic output.
  final List<PatchStatus> packages;

  /// Packages whose committed patch output is stale or absent.
  Iterable<PatchStatus> get needsApply {
    return packages.where((package) => package.needsApply);
  }

  /// Problems across all tracked packages.
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
