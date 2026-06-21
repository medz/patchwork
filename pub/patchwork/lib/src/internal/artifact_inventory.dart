import 'path_layout.dart';

/// Snapshot of Patchwork-owned filesystem artifacts.
///
/// The inventory groups edit directories, committed patch files, and generated
/// applied directories once per operation so higher-level workflows can avoid
/// repeatedly scanning the same roots and reimplementing package/version
/// lookups.
final class PatchworkArtifactInventory {
  PatchworkArtifactInventory._({
    required List<PackageVersionPath> editDirectories,
    required List<PackageVersionPath> patchFiles,
    required List<PackageVersionPath> appliedDirectories,
  }) : editDirectories = List.unmodifiable(editDirectories),
       patchFiles = List.unmodifiable(patchFiles),
       appliedDirectories = List.unmodifiable(appliedDirectories);

  /// Reads all current Patchwork artifacts from [layout].
  factory PatchworkArtifactInventory.read(PathLayout layout) {
    return PatchworkArtifactInventory._(
      editDirectories: layout.editDirectories(),
      patchFiles: layout.patchFiles(),
      appliedDirectories: layout.appliedDirectories(),
    );
  }

  /// Open edit directories under `.patchwork/`.
  final List<PackageVersionPath> editDirectories;

  /// Committed patch files under `patches/`.
  final List<PackageVersionPath> patchFiles;

  /// Generated applied directories under `.dart_tool/patchwork/`.
  final List<PackageVersionPath> appliedDirectories;

  /// All packages represented by any artifact kind.
  late final List<String> packages = _sortedPackages([
    ...editDirectories,
    ...patchFiles,
    ...appliedDirectories,
  ]);

  /// Packages with one or more open edit directories.
  late final List<String> openEditPackages = _sortedPackages(editDirectories);

  late final Map<String, List<PackageVersionPath>> _editsByPackage =
      _groupByPackage(editDirectories);

  late final Map<String, List<PackageVersionPath>> _patchesByPackage =
      _groupByPackage(patchFiles);

  late final Map<String, List<PackageVersionPath>> _appliedByPackage =
      _groupByPackage(appliedDirectories);

  late final Map<String, PackageVersionPath> _editsByIdentity = _byIdentity(
    editDirectories,
  );

  /// Returns edit directories for [package].
  List<PackageVersionPath> editsFor(String package) {
    return _editsByPackage[package] ?? const [];
  }

  /// Returns patch files for [package].
  List<PackageVersionPath> patchesFor(String package) {
    return _patchesByPackage[package] ?? const [];
  }

  /// Returns applied directories for [package].
  List<PackageVersionPath> appliedFor(String package) {
    return _appliedByPackage[package] ?? const [];
  }

  /// Returns the edit directory for [package] and [version], if present.
  PackageVersionPath? edit(String package, String version) {
    return _editsByIdentity[_identity(package, version)];
  }

  /// Returns all artifact versions known for [package].
  Set<String> versionsFor(String package) {
    return {
      for (final edit in editsFor(package)) edit.version,
      for (final patch in patchesFor(package)) patch.version,
      for (final applied in appliedFor(package)) applied.version,
    };
  }
}

List<String> _sortedPackages(Iterable<PackageVersionPath> paths) {
  return ({for (final path in paths) path.package}.toList()..sort());
}

Map<String, List<PackageVersionPath>> _groupByPackage(
  Iterable<PackageVersionPath> paths,
) {
  final grouped = <String, List<PackageVersionPath>>{};
  for (final path in paths) {
    grouped.putIfAbsent(path.package, () => []).add(path);
  }
  return {
    for (final entry in grouped.entries)
      entry.key: List.unmodifiable(entry.value),
  };
}

Map<String, PackageVersionPath> _byIdentity(
  Iterable<PackageVersionPath> paths,
) {
  return {
    for (final path in paths) _identity(path.package, path.version): path,
  };
}

String _identity(String package, String version) {
  return '$package\x00$version';
}
