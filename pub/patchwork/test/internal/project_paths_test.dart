import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:patchwork/src/internal/project_paths.dart';
import 'package:test/test.dart';

void main() {
  test('formats project paths relative to the project root', () {
    final root = Directory.systemTemp.createTempSync('patchwork_paths_');
    addTearDown(() => root.deleteSync(recursive: true));

    expect(relativeToProjectRoot(rootPath: root.path, path: root.path), '.');
    expect(
      relativeToProjectRoot(
        rootPath: root.path,
        path: p.join(root.path, 'nested', 'file.txt'),
      ),
      'nested/file.txt',
    );

    final outside = p.join(root.parent.path, 'outside.txt');
    expect(relativeToProjectRoot(rootPath: root.path, path: outside), outside);
  });
}
