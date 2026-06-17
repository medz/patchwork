import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:patchwork/src/internal/package_tree.dart';
import 'package:test/test.dart';

void main() {
  test(
    'hash includes file modes',
    () {
      final root = Directory.systemTemp.createTempSync('patchwork_tree_');
      addTearDown(() => root.deleteSync(recursive: true));

      final script = File(p.join(root.path, 'tool.dart'))
        ..writeAsStringSync('void main() {}\n');
      Process.runSync('chmod', ['644', script.path]);
      final plainHash = const PackageTree().sha256Of(root.path);

      Process.runSync('chmod', ['755', script.path]);
      final executableHash = const PackageTree().sha256Of(root.path);

      expect(executableHash, isNot(plainHash));
    },
    skip: Platform.isWindows ? 'POSIX file mode test.' : false,
  );
}
