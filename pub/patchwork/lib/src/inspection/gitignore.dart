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
          (directoryOnly && _matchesPathPattern('$normalizedPattern/**', path));
    }

    final segments = path.split('/');
    return segments.any(
          (segment) => _matchesPathPattern(normalizedPattern, segment),
        ) ||
        path.startsWith('$normalizedPattern/');
  }

  bool _matchesPathPattern(String pattern, String value) {
    return RegExp('^${_gitignoreGlobSource(pattern)}\$').hasMatch(value);
  }
}

String _gitignoreGlobSource(String pattern) {
  final source = StringBuffer();
  var index = 0;
  while (index < pattern.length) {
    final character = pattern[index];
    if (character == '*') {
      final doubleStar =
          index + 1 < pattern.length && pattern[index + 1] == '*';
      final wholeSegment =
          doubleStar &&
          (index == 0 || pattern[index - 1] == '/') &&
          (index + 2 == pattern.length || pattern[index + 2] == '/');
      if (wholeSegment) {
        if (index + 2 < pattern.length && pattern[index + 2] == '/') {
          source.write(r'(?:[^/]+/)*');
          index += 3;
        } else {
          source.write('.*');
          index += 2;
        }
        continue;
      }
      source.write(r'[^/]*');
      index += doubleStar ? 2 : 1;
      continue;
    }
    if (character == '?') {
      source.write(r'[^/]');
      index += 1;
      continue;
    }
    if (character == '[') {
      final closing = pattern.indexOf(']', index + 1);
      if (closing > index + 1) {
        source.write(
          _characterClassSource(pattern.substring(index + 1, closing)),
        );
        index = closing + 1;
        continue;
      }
    }
    if (character == r'\' && index + 1 < pattern.length) {
      source.write(RegExp.escape(pattern[index + 1]));
      index += 2;
      continue;
    }
    source.write(RegExp.escape(character));
    index += 1;
  }
  return source.toString();
}

String _characterClassSource(String content) {
  final source = StringBuffer('[');
  var index = 0;
  if (content.startsWith('!') || content.startsWith('^')) {
    source.write('^');
    index = 1;
  }
  for (; index < content.length; index += 1) {
    final character = content[index];
    if (character == r'\' || character == ']') {
      source.write(r'\');
    }
    source.write(character);
  }
  source.write(']');
  return source.toString();
}
