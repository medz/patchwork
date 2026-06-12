final class PubTarget {
  const PubTarget({required this.name, this.versionConstraint});

  final String name;
  final String? versionConstraint;

  String get packageRef {
    final versionConstraint = this.versionConstraint;
    return versionConstraint == null ? name : '$name@$versionConstraint';
  }

  @override
  String toString() => 'pub:$packageRef';

  @override
  bool operator ==(Object other) {
    return other is PubTarget &&
        other.name == name &&
        other.versionConstraint == versionConstraint;
  }

  @override
  int get hashCode => Object.hash(name, versionConstraint);
}
