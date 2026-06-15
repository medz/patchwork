import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

typedef AtomicFileRename =
    void Function(String sourcePath, String destinationPath);

final class AtomicFileWriter {
  const AtomicFileWriter({this.renameFile = _renameFile});

  final AtomicFileRename renameFile;

  void writeString(String path, String content, {Encoding encoding = utf8}) {
    writeBytes(path, encoding.encode(content));
  }

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

void writeStringFileAtomically(String path, String content) {
  const AtomicFileWriter().writeString(path, content);
}

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
