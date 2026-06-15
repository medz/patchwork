import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:patchwork/src/io/atomic_file_writer.dart';
import 'package:test/test.dart';

void main() {
  group('AtomicFileWriter', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('patchwork atomic writer ');
    });

    tearDown(() {
      if (root.existsSync()) {
        root.deleteSync(recursive: true);
      }
    });

    test('writes content through a same-directory temp file', () {
      final targetPath = p.join(root.path, 'nested', 'target.txt');

      const AtomicFileWriter().writeString(targetPath, 'new content\n');

      expect(File(targetPath).readAsStringSync(), 'new content\n');
    });

    test(
      'preserves the target and deletes the temp file when rename fails',
      () {
        final targetPath = p.join(root.path, 'target.txt');
        File(targetPath).writeAsStringSync('old content\n');
        late String tempPath;
        final writer = AtomicFileWriter(
          renameFile: (sourcePath, destinationPath) {
            tempPath = sourcePath;
            expect(destinationPath, targetPath);
            expect(p.dirname(sourcePath), p.dirname(targetPath));
            throw FileSystemException('rename failed', destinationPath);
          },
        );

        expect(
          () => writer.writeString(targetPath, 'new content\n'),
          throwsA(isA<FileSystemException>()),
        );

        expect(File(targetPath).readAsStringSync(), 'old content\n');
        expect(File(tempPath).existsSync(), isFalse);
      },
    );
  });
}
