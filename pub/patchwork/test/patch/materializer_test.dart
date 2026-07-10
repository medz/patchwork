import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:patchwork/src/patch/materializer.dart';
import 'package:patchwork/src/patch/package_tree.dart';
import 'package:test/test.dart';

void main() {
  test('installs a transformed package copy and replaces old output', () {
    final root = Directory.systemTemp.createTempSync('patchwork_materializer_');
    addTearDown(() => root.deleteSync(recursive: true));

    final sourcePath = p.join(root.path, 'source');
    final outputPath = p.join(root.path, 'output', 'greeter@0.1.0');
    File(p.join(sourcePath, 'lib', 'greeter.dart'))
      ..createSync(recursive: true)
      ..writeAsStringSync('before');
    File(p.join(outputPath, 'stale.txt'))
      ..createSync(recursive: true)
      ..writeAsStringSync('stale');

    const PackageMaterializer(packageTree: PackageTree()).materialize(
      identity: 'greeter@0.1.0',
      sourcePath: sourcePath,
      outputPath: outputPath,
      transform: (packagePath) {
        File(
          p.join(packagePath, 'lib', 'greeter.dart'),
        ).writeAsStringSync('after');
      },
    );

    expect(
      File(p.join(sourcePath, 'lib', 'greeter.dart')).readAsStringSync(),
      'before',
    );
    expect(
      File(p.join(outputPath, 'lib', 'greeter.dart')).readAsStringSync(),
      'after',
    );
    expect(File(p.join(outputPath, 'stale.txt')).existsSync(), isFalse);
    expect(_temporaryDirectories(outputPath), isEmpty);
  });

  test('keeps existing output and removes the temporary copy on failure', () {
    final root = Directory.systemTemp.createTempSync('patchwork_materializer_');
    addTearDown(() => root.deleteSync(recursive: true));

    final sourcePath = p.join(root.path, 'source');
    final outputPath = p.join(root.path, 'output', 'greeter@0.1.0');
    File(p.join(sourcePath, 'lib', 'greeter.dart'))
      ..createSync(recursive: true)
      ..writeAsStringSync('source');
    File(p.join(outputPath, 'current.txt'))
      ..createSync(recursive: true)
      ..writeAsStringSync('current');

    expect(
      () => const PackageMaterializer(packageTree: PackageTree()).materialize(
        identity: 'greeter@0.1.0',
        sourcePath: sourcePath,
        outputPath: outputPath,
        transform: (_) => throw StateError('failed transform'),
      ),
      throwsStateError,
    );

    expect(
      File(p.join(outputPath, 'current.txt')).readAsStringSync(),
      'current',
    );
    expect(_temporaryDirectories(outputPath), isEmpty);
  });

  test('restores existing output when the install rename fails', () {
    final root = Directory.systemTemp.createTempSync('patchwork_materializer_');
    addTearDown(() => root.deleteSync(recursive: true));

    final sourcePath = p.join(root.path, 'source');
    final outputPath = p.join(root.path, 'output', 'greeter@0.1.0');
    File(p.join(sourcePath, 'lib', 'greeter.dart'))
      ..createSync(recursive: true)
      ..writeAsStringSync('next');
    File(p.join(outputPath, 'current.txt'))
      ..createSync(recursive: true)
      ..writeAsStringSync('current');
    var renames = 0;
    final materializer = PackageMaterializer(
      packageTree: const PackageTree(),
      renameDirectory: (source, destination) {
        renames += 1;
        if (renames == 2) {
          throw FileSystemException('install failed', source);
        }
        Directory(source).renameSync(destination);
      },
    );

    expect(
      () => materializer.materialize(
        identity: 'greeter@0.1.0',
        sourcePath: sourcePath,
        outputPath: outputPath,
        transform: (_) {},
      ),
      throwsA(isA<FileSystemException>()),
    );

    expect(
      File(p.join(outputPath, 'current.txt')).readAsStringSync(),
      'current',
    );
    expect(
      File(p.join(outputPath, 'lib', 'greeter.dart')).existsSync(),
      isFalse,
    );
    expect(_temporaryDirectories(outputPath), isEmpty);
  });
}

List<FileSystemEntity> _temporaryDirectories(String outputPath) {
  final parent = Directory(p.dirname(outputPath));
  return parent
      .listSync(followLinks: false)
      .where(
        (entity) =>
            p.basename(entity.path).startsWith('.${p.basename(outputPath)}.'),
      )
      .toList();
}
