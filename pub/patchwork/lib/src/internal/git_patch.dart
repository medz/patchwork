import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Returns an absolute path in the form expected inside Git patch output.
String gitArgumentPath(String path) {
  return p.absolute(path).replaceAll('\\', '/');
}

/// Removes process-local paths from Git diagnostics.
String normalizedGitOutput(
  String output, {
  required String workingDirectory,
  required String patchPath,
}) {
  return output
      .replaceAll(gitArgumentPath(patchPath), '<patch>')
      .replaceAll(patchPath, '<patch>')
      .replaceAll(gitArgumentPath(workingDirectory), '.')
      .replaceAll(workingDirectory, '.')
      .trim();
}

/// Extracts reject file paths reported by `git apply --reject`.
Set<String> gitRejectRelativePaths(String output) {
  final paths = <String>{};
  final rejectLine = RegExp(
    r'^Applying patch (.+) with [0-9]+ rejects?\.\.\.$',
  );
  for (final line in output.split('\n')) {
    final match = rejectLine.firstMatch(line.trimRight());
    if (match == null) {
      continue;
    }
    paths.add('${_decodeGitPath(match.group(1)!)}.rej');
  }
  return paths;
}

/// Extracts touched paths from `git apply --numstat -z` output.
Set<String> gitNumstatRelativePaths(ProcessResult result) {
  if (result.exitCode != 0) {
    return const {};
  }

  final paths = <String>{};
  for (final record in result.stdout.toString().split('\x00')) {
    if (record.isEmpty) {
      continue;
    }
    final firstSeparator = record.indexOf('\t');
    if (firstSeparator == -1) {
      continue;
    }
    final secondSeparator = record.indexOf('\t', firstSeparator + 1);
    if (secondSeparator == -1) {
      continue;
    }
    final path = _patchRelativePath(record.substring(secondSeparator + 1));
    if (path != null) {
      paths.add(path);
    }
  }
  return paths;
}

/// Extracts every path touched by patch headers and rename/copy metadata.
Set<String> patchTouchedRelativePaths(String patchContent) {
  final paths = <String>{};
  final normalized = patchContent.replaceAll('\r\n', '\n');
  for (final line in normalized.split('\n')) {
    if (line.startsWith('--- ')) {
      final path = _patchHeaderRelativePath(line.substring(4));
      if (path != null) {
        paths.add(path);
      }
    } else if (line.startsWith('+++ ')) {
      final path = _patchHeaderRelativePath(line.substring(4));
      if (path != null) {
        paths.add(path);
      }
    } else {
      final path = _patchMetadataRelativePath(line);
      if (path != null) {
        paths.add(path);
      }
    }
  }
  return paths;
}

String? _patchHeaderRelativePath(String rawPath) {
  final path = _patchRelativePath(rawPath);
  if (path == null) {
    return null;
  }
  if (path.startsWith('a/') || path.startsWith('b/')) {
    return path.substring(2);
  }
  return null;
}

String? _patchMetadataRelativePath(String line) {
  const prefixes = ['rename from ', 'rename to ', 'copy from ', 'copy to '];
  for (final prefix in prefixes) {
    if (line.startsWith(prefix)) {
      return _patchRelativePath(line.substring(prefix.length));
    }
  }
  return null;
}

String? _patchRelativePath(String rawPath) {
  final decodedPath = _decodeGitPath(rawPath.trimRight());
  if (decodedPath.isEmpty || decodedPath == '/dev/null') {
    return null;
  }
  return decodedPath.replaceAll('\\', '/');
}

String _decodeGitPath(String path) {
  if (path.length < 2 || !path.startsWith('"') || !path.endsWith('"')) {
    return path;
  }

  final content = path.substring(1, path.length - 1);
  final bytes = <int>[];
  for (var index = 0; index < content.length; index += 1) {
    final char = content[index];
    if (char != '\\') {
      bytes.addAll(utf8.encode(char));
      continue;
    }

    if (index + 1 >= content.length) {
      bytes.add('\\'.codeUnitAt(0));
      continue;
    }

    final next = content[index + 1];
    if (_isOctalDigit(next)) {
      var end = index + 1;
      while (end < content.length &&
          end < index + 4 &&
          _isOctalDigit(content[end])) {
        end += 1;
      }
      bytes.add(int.parse(content.substring(index + 1, end), radix: 8));
      index = end - 1;
      continue;
    }

    bytes.add(switch (next) {
      'a' => 0x07,
      'b' => 0x08,
      'f' => 0x0c,
      'n' => 0x0a,
      'r' => 0x0d,
      't' => 0x09,
      'v' => 0x0b,
      _ => next.codeUnitAt(0),
    });
    index += 1;
  }
  return utf8.decode(bytes);
}

bool _isOctalDigit(String value) {
  final codeUnit = value.codeUnitAt(0);
  return codeUnit >= 0x30 && codeUnit <= 0x37;
}

/// Rewrites temporary snapshot roots in `git diff --no-index` output.
String postProcessGitDiff({
  required String output,
  required String sourcePath,
  required String editPath,
}) {
  final oldPrefix = _gitDiffPathPrefix(sourcePath);
  final newPrefix = _gitDiffPathPrefix(editPath);
  final hasTrailingNewline = output.endsWith('\n');
  final lines = output.split('\n');
  if (hasTrailingNewline) {
    lines.removeLast();
  }

  final buffer = StringBuffer();
  for (final line in lines) {
    final processed = _shouldRewriteGitDiffLine(line)
        ? _stripGitDiffRootPrefixes(line, oldPrefix, newPrefix)
        : line;
    buffer
      ..write(processed)
      ..write('\n');
  }

  if (!hasTrailingNewline && buffer.length > 0) {
    final content = buffer.toString();
    return content.substring(0, content.length - 1);
  }
  return buffer.toString();
}

String _gitDiffPathPrefix(String path) {
  final normalized = gitArgumentPath(path);
  if (normalized.startsWith('/')) {
    return normalized.substring(1);
  }
  return normalized;
}

bool _shouldRewriteGitDiffLine(String line) {
  if (line.isEmpty) {
    return false;
  }

  final first = line.codeUnitAt(0);
  if (first == 0x20) {
    return false;
  }
  if (first == 0x2d && !line.startsWith('--- ')) {
    return false;
  }
  if (first == 0x2b && !line.startsWith('+++ ')) {
    return false;
  }
  return true;
}

String _stripGitDiffRootPrefixes(
  String line,
  String oldPrefix,
  String newPrefix,
) {
  var result = line;
  for (final side in const ['a', 'b']) {
    result = result.replaceAll('$side/$oldPrefix/', '$side/');
    result = result.replaceAll('$side/$newPrefix/', '$side/');
  }
  result = result.replaceAll('$oldPrefix/', '');
  result = result.replaceAll('$newPrefix/', '');
  return _stripMetadataLeadingSlash(result);
}

String _stripMetadataLeadingSlash(String line) {
  const prefixes = ['rename from ', 'rename to ', 'copy from ', 'copy to '];
  for (final prefix in prefixes) {
    if (line.startsWith('$prefix/')) {
      return '$prefix${line.substring(prefix.length + 1)}';
    }
    if (line.startsWith('$prefix"/')) {
      return '$prefix"${line.substring(prefix.length + 2)}';
    }
  }
  return line;
}
