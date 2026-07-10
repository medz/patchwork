/// A package-provided overlay registered in `patchwork.yaml`.
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

/// Whether a provider overlay entry affects the current pub resolution.
enum OverlayEntryStatus {
  /// The entry matches the current target package and contributes a patch.
  matched,

  /// The entry was discovered but does not apply to the current resolution.
  skipped,

  /// The entry matches the current resolution but cannot be used safely.
  failed,
}

/// Whether a patch contribution participates in overlay composition.
enum OverlayContributionStatus {
  /// The contribution is applied in the listed compose order.
  active,

  /// The contribution matches another patch's content and is not applied twice.
  deduplicated,
}

/// A `patchwork.yaml` entry inspected from a dependency package.
final class OverlayEntryInspection {
  /// Creates an inspected provider overlay entry.
  const OverlayEntryInspection({
    required this.package,
    required this.version,
    required this.sha256,
    required this.patchPath,
    required this.status,
    this.reason,
    this.skipReason,
    this.resolvedVersion,
    this.resolvedSha256,
  });

  /// The target package declared by the provider.
  final String package;

  /// The target version declared by the provider.
  final String version;

  /// The target source hash declared by the provider.
  final String sha256;

  /// The provider-relative patch path declared in `patchwork.yaml`.
  final String patchPath;

  /// Optional provider-authored explanation for this overlay.
  final String? reason;

  /// Whether this entry contributes to the current overlay plan.
  final OverlayEntryStatus status;

  /// Stable reason code when [status] is skipped or failed.
  final String? skipReason;

  /// The currently resolved target version, when the package is selected.
  final String? resolvedVersion;

  /// The currently resolved target source hash, when the package is selected.
  final String? resolvedSha256;
}

/// A dependency package that declares provider overlays.
final class OverlayProviderInspection {
  /// Creates an inspected overlay provider.
  OverlayProviderInspection({
    required this.package,
    required this.rootPath,
    required this.manifestPath,
    required List<OverlayEntryInspection> entries,
  }) : entries = List.unmodifiable(entries);

  /// The provider package name.
  final String package;

  /// The provider package root selected by pub.
  final String rootPath;

  /// The provider's `patchwork.yaml` path.
  final String manifestPath;

  /// Entries declared by the provider manifest.
  final List<OverlayEntryInspection> entries;
}

/// A patch contribution selected for one overlay target package.
final class OverlayContributionInspection {
  /// Creates an inspected overlay contribution.
  const OverlayContributionInspection({
    required this.provider,
    required this.patchPath,
    required this.sha256,
    required this.status,
  });

  /// The provider package name, or `<root>` for the application patch file.
  final String provider;

  /// The absolute patch file path used by this contribution.
  final String patchPath;

  /// The patch file content hash used for deduplication diagnostics.
  final String sha256;

  /// Whether this contribution is applied or deduplicated.
  final OverlayContributionStatus status;
}

/// A composition failure discovered during read-only overlay inspection.
final class OverlayConflictInspection {
  /// Creates an inspected overlay conflict.
  const OverlayConflictInspection({
    required this.provider,
    required this.patchPath,
    required this.message,
  });

  /// The provider whose patch failed to apply.
  final String provider;

  /// The absolute failed patch path.
  final String patchPath;

  /// The underlying patch application diagnostic.
  final String message;
}

/// The composed overlay plan for a target dependency package.
final class OverlayTargetInspection {
  /// Creates an inspected overlay target.
  OverlayTargetInspection({
    required this.package,
    required this.version,
    required this.sha256,
    required this.sourcePath,
    required List<OverlayContributionInspection> contributions,
    this.conflict,
  }) : contributions = List.unmodifiable(contributions);

  /// The target dependency package.
  final String package;

  /// The target version selected by pub.
  final String version;

  /// The target source hash selected by pub.
  final String sha256;

  /// The target source package root selected by pub.
  final String sourcePath;

  /// Provider and root contributions in deterministic compose order.
  final List<OverlayContributionInspection> contributions;

  /// Conflict details, if the active contributions cannot compose cleanly.
  final OverlayConflictInspection? conflict;
}

/// A read-only report for package-provided overlay discovery and composition.
final class OverlayInspection {
  /// Creates an overlay inspection report.
  OverlayInspection({
    required List<OverlayProviderInspection> providers,
    required List<OverlayTargetInspection> targets,
  }) : providers = List.unmodifiable(providers),
       targets = List.unmodifiable(targets);

  /// Dependency packages that declared `patchwork.yaml` overlays.
  final List<OverlayProviderInspection> providers;

  /// Target packages that have matching overlay contributions.
  final List<OverlayTargetInspection> targets;
}
