import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:patchwork/src/io/atomic_file_writer.dart';
import 'package:patchwork/src/pub/pubspec_overrides.dart';
import 'package:test/test.dart';

void main() {
  group('PubspecOverridesStore', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('patchwork overrides ');
    });

    tearDown(() {
      if (root.existsSync()) {
        root.deleteSync(recursive: true);
      }
    });

    test('keeps existing overrides when atomic rename fails', () {
      final overridesPath = p.join(root.path, 'pubspec_overrides.yaml');
      const existingContent = '''
dependency_overrides:
  local_tool:
    path: ../local_tool
''';
      File(overridesPath).writeAsStringSync(existingContent);
      late String tempPath;
      final store = PubspecOverridesStore(
        fileWriter: AtomicFileWriter(
          renameFile: (sourcePath, destinationPath) {
            tempPath = sourcePath;
            expect(destinationPath, overridesPath);
            throw FileSystemException('rename failed', destinationPath);
          },
        ),
      );

      expect(
        () => store.updateDependencyOverrides(
          workspaceRootPath: root.path,
          dependencyOverridePaths: const {
            'analyzer':
                '.dart_tool/patchwork/store/pub/analyzer@7.4.0_patch_hash=abc',
          },
        ),
        throwsA(isA<FileSystemException>()),
      );

      expect(File(overridesPath).readAsStringSync(), existingContent);
      expect(File(tempPath).existsSync(), isFalse);
    });
  });
}
