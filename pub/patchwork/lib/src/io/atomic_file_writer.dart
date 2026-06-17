import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Moves a completed temporary file into its final destination.
///
/// Tests inject this callback to simulate write failures without depending on
/// platform-specific filesystem behavior.
typedef AtomicFileRename =
    void Function(String sourcePath, String destinationPath);

/// Writes files through a temporary sibling followed by a rename.
///
/// The temporary file is created in the destination directory so the final
/// rename stays on the same filesystem. Failed writes try to delete the
/// temporary file before rethrowing the original error.
final class AtomicFileWriter {
  /// Creates an atomic writer with an injectable rename operation.
  const AtomicFileWriter({this.renameFile = _renameFile});

  /// The operation used to move a completed temporary file into place.
  final AtomicFileRename renameFile;

  /// Writes [content] to [path] using [encoding].
  void writeString(String path, String content, {Encoding encoding = utf8}) {
    writeBytes(path, encoding.encode(content));
  }

  /// Writes [bytes] to [path].
  void writeBytes(String path, List<int> bytes) {
    final destinationFile = File(path);
    destinationFile.parent.createSync(recursive: true);
    final tempFile = File(
      p.join(
        destinationFile.parent.path,
        '.${p.basename(path)}.$pid.'
        '${DateTime.now().microsecondsSinceEpoch}.tmp',
      ),
    );

    try {
      tempFile.writeAsBytesSync(bytes, flush: true);
      renameFile(tempFile.path, path);
    } catch (_) {
      _deleteTempFile(tempFile);
      rethrow;
    }
  }
}

/// Writes a UTF-8 string file atomically.
void writeStringFileAtomically(String path, String content) {
  const AtomicFileWriter().writeString(path, content);
}

/// Writes a byte file atomically.
void writeBytesFileAtomically(String path, List<int> bytes) {
  const AtomicFileWriter().writeBytes(path, bytes);
}

void _renameFile(String sourcePath, String destinationPath) {
  File(sourcePath).renameSync(destinationPath);
}

void _deleteTempFile(File tempFile) {
  try {
    if (tempFile.existsSync()) {
      tempFile.deleteSync();
    }
  } on FileSystemException {
    // Preserve the original write or rename failure.
  }
}
