import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:patchwork/src/patch/patch_file.dart';
import 'package:test/test.dart';

void main() {
  group('PatchFileBuilder', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('patchwork patch file ');
    });

    tearDown(() {
      if (root.existsSync()) {
        root.deleteSync(recursive: true);
      }
    });

    test('builds and validates a unified patch', () {
      final baselinePath = p.join(root.path, 'baseline');
      final editPath = p.join(root.path, 'edit');
      Directory(p.join(baselinePath, 'lib')).createSync(recursive: true);
      Directory(p.join(editPath, 'lib')).createSync(recursive: true);
      File(
        p.join(baselinePath, 'lib', 'file.dart'),
      ).writeAsStringSync('String value = "old";\n');
      File(
        p.join(editPath, 'lib', 'file.dart'),
      ).writeAsStringSync('String value = "new";\n');

      final buildResult = const PatchFileBuilder().build(
        baselinePath: baselinePath,
        editPath: editPath,
      );

      expect(buildResult.diagnostic, isNull);
      expect(buildResult.hasChanges, isTrue);
      expect(buildResult.content, contains('--- a/lib/file.dart'));
      expect(buildResult.content, contains('+++ b/lib/file.dart'));

      final validationResult = const PatchValidator().validate(
        baselinePath: baselinePath,
        patchContent: buildResult.content!,
      );
      expect(validationResult.diagnostic, isNull);
    });
  });

  group('PatchValidator', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('patchwork patch validate ');
    });

    tearDown(() {
      if (root.existsSync()) {
        root.deleteSync(recursive: true);
      }
    });

    test('rejects a patch that cannot apply to the baseline', () {
      File(p.join(root.path, 'file.dart')).writeAsStringSync('old\n');

      final result = const PatchValidator().validate(
        baselinePath: root.path,
        patchContent: '''
--- a/file.dart
+++ b/file.dart
@@ -1 +1 @@
-missing
+new
''',
      );

      expect(result.diagnostic?.code, 'patch.validation_failed');
    });
  });
}
