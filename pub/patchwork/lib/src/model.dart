final class PatchRef {
  const PatchRef._(this.version);

  const PatchRef.current() : this._(null);

  const PatchRef.version(String version) : this._(version);

  final String? version;

  bool get isCurrent => version == null;
}

final class PackageSource {
  const PackageSource({
    required this.type,
    required this.sha256,
    this.fields = const {},
  });

  final String type;
  final String sha256;
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

final class PreparedEdit {
  const PreparedEdit({
    required this.package,
    required this.version,
    required this.path,
    required this.sourcePath,
    this.continuedFromPatchPath,
  });

  final String package;
  final String version;
  final String path;
  final String sourcePath;
  final String? continuedFromPatchPath;
}

enum PatchWriteStatus { written, unchanged, removed }

final class PatchWrite {
  const PatchWrite({
    required this.package,
    required this.version,
    required this.status,
    required this.editPath,
    required this.patchPath,
  });

  final String package;
  final String version;
  final PatchWriteStatus status;
  final String editPath;
  final String patchPath;
}

final class AppliedPatch {
  const AppliedPatch({
    required this.package,
    required this.version,
    required this.path,
    required this.patchPath,
  });

  final String package;
  final String version;
  final String path;
  final String patchPath;
}

final class UnappliedPatch {
  const UnappliedPatch({
    required this.package,
    required this.changed,
    this.path,
  });

  final String package;
  final bool changed;
  final String? path;
}

final class PatchProblem {
  const PatchProblem({required this.code, required this.message, this.hint});

  final String code;
  final String message;
  final String? hint;
}

final class PatchStatus {
  const PatchStatus({
    required this.package,
    required this.version,
    required this.editPath,
    required this.patchPath,
    required this.appliedPath,
    required this.hasOpenEdit,
    required this.hasPatch,
    required this.isApplied,
    required this.needsApply,
    this.problems = const [],
  });

  final String package;
  final String version;
  final String editPath;
  final String patchPath;
  final String? appliedPath;
  final bool hasOpenEdit;
  final bool hasPatch;
  final bool isApplied;
  final bool needsApply;
  final List<PatchProblem> problems;
}

final class PatchworkState {
  const PatchworkState({required this.packages});

  final List<PatchStatus> packages;

  Iterable<PatchStatus> get needsApply {
    return packages.where((package) => package.needsApply);
  }

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
