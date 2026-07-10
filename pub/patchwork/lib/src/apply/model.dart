/// A committed patch materialized into generated pub override output.
///
/// `patchwork apply` writes a generated package copy under `.dart_tool` and
/// points `pubspec_overrides.yaml` at that copy. Callers should run
/// `dart pub get` afterwards so pub refreshes package resolution.
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

/// The outcome of applying one or more committed patches.
final class ApplyResult {
  /// Creates an apply result.
  ApplyResult({required List<AppliedPatch> applied, required this.needsPubGet})
    : applied = List.unmodifiable(applied);

  /// Patches that regenerated applied output during this operation.
  final List<AppliedPatch> applied;

  /// Whether pub resolution must be refreshed for the current applied state.
  final bool needsPubGet;

  /// Whether this operation regenerated any applied output.
  bool get changed => applied.isNotEmpty;
}
