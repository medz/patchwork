import 'dart:io';

import 'package:path/path.dart' as p;

/// Reads the repository ignore rules needed by setup diagnostics.
final class GitignoreRules {
  const GitignoreRules._({
    required this.rootPath,
    required List<_GitignoreRule> rules,
    required this.displayPath,
  }) : _rules = rules;

  /// Absolute root used to resolve candidate paths.
  final String rootPath;
  final List<_GitignoreRule> _rules;

  /// The closest discovered `.gitignore`, used in setup output.
  final String? displayPath;

  /// Reads applicable `.gitignore` files from the repository hierarchy.
  static GitignoreRules read(String rootPath) {
    final normalizedRoot = p.normalize(p.absolute(rootPath));
    final files = _gitignoreFiles(normalizedRoot);
    final rules = <_GitignoreRule>[];
    for (final file in files) {
      for (final rawLine in file.readAsLinesSync()) {
        final line = rawLine.trim();
        if (line.isEmpty || line.startsWith('#')) {
          continue;
        }
        final negated = line.startsWith('!');
        final pattern = (negated ? line.substring(1) : line).trim();
        if (pattern.isEmpty) {
          continue;
        }
        rules.add(
          _GitignoreRule(
            basePath: p.dirname(file.path),
            pattern: pattern,
            negated: negated,
          ),
        );
      }
    }
    return GitignoreRules._(
      rootPath: normalizedRoot,
      rules: rules,
      displayPath: files.isEmpty ? null : files.last.path,
    );
  }

  /// Whether [path] is ignored by the applicable rules.
  bool ignores(String path, {required bool directory}) {
    final absolute = p.normalize(
      p.isAbsolute(path) ? path : p.absolute(rootPath, path),
    );
    if (_ignoresAbsolute(absolute, directory: directory)) {
      return true;
    }

    var parent = p.dirname(absolute);
    while (p.isWithin(rootPath, parent)) {
      if (_ignoresAbsolute(parent, directory: true)) {
        return true;
      }
      parent = p.dirname(parent);
    }
    return false;
  }

  bool _ignoresAbsolute(String absolute, {required bool directory}) {
    var ignored = false;
    for (final rule in _rules) {
      if (rule.matches(absolute, directory: directory)) {
        ignored = !rule.negated;
      }
    }
    return ignored;
  }

  static List<File> _gitignoreFiles(String rootPath) {
    final scopedAncestors = <String>[];
    var current = rootPath;
    while (true) {
      scopedAncestors.add(current);
      if (Directory(p.join(current, '.git')).existsSync()) {
        break;
      }
      final parent = p.dirname(current);
      if (p.equals(parent, current)) {
        break;
      }
      current = parent;
    }

    return [
      for (final directory in scopedAncestors.reversed)
        File(p.join(directory, '.gitignore')),
    ].where((file) => file.existsSync()).toList();
  }
}

final class _GitignoreRule {
  const _GitignoreRule({
    required this.basePath,
    required this.pattern,
    required this.negated,
  });

  final String basePath;
  final String pattern;
  final bool negated;

  bool matches(String absolutePath, {required bool directory}) {
    if (!p.equals(basePath, absolutePath) &&
        !p.isWithin(basePath, absolutePath)) {
      return false;
    }
    final path = p.equals(basePath, absolutePath)
        ? '.'
        : p.posix.joinAll(p.split(p.relative(absolutePath, from: basePath)));
    var normalizedPattern = pattern;
    final directoryOnly = normalizedPattern.endsWith('/');
    if (normalizedPattern.startsWith('/')) {
      normalizedPattern = normalizedPattern.substring(1);
    }
    if (directoryOnly) {
      normalizedPattern = normalizedPattern.substring(
        0,
        normalizedPattern.length - 1,
      );
    }
    normalizedPattern = p.posix.joinAll(p.split(normalizedPattern));
    if (directoryOnly && !directory && path == normalizedPattern) {
      return false;
    }
    if (normalizedPattern.isEmpty) {
      return false;
    }

    if (normalizedPattern.contains('/')) {
      return _matchesPathPattern(normalizedPattern, path) ||
          path.startsWith('$normalizedPattern/');
    }

    final segments = path.split('/');
    return segments.any(
          (segment) => _matchesPathPattern(normalizedPattern, segment),
        ) ||
        path.startsWith('$normalizedPattern/');
  }

  bool _matchesPathPattern(String pattern, String value) {
    if (!pattern.contains('*')) {
      return pattern == value;
    }
    final source = RegExp.escape(pattern).replaceAll(r'\*', r'[^/]*');
    return RegExp('^$source\$').hasMatch(value);
  }
}
