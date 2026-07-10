/// The pub source that Patchwork used as the baseline for a package patch.
///
/// Patchwork records this value in local edit/applied metadata and provider
/// overlay manifests when source identity is needed for safety diagnostics.
/// The [fields] map contains source-specific identity such as hosted URL, path,
/// Git URL, branch, or commit.
final class PackageSource {
  /// Creates a resolved source description.
  PackageSource({
    required this.type,
    required this.sha256,
    Map<String, String> fields = const {},
  }) : fields = Map.unmodifiable(fields);

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
