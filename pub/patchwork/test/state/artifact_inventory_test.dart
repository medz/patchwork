import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:patchwork/src/state/artifact_inventory.dart';
import 'package:patchwork/src/state/path_layout.dart';
import 'package:test/test.dart';

void main() {
  test('groups Patchwork artifacts by package and version', () {
    final root = Directory.systemTemp.createTempSync('patchwork_inventory_');
    addTearDown(() => root.deleteSync(recursive: true));

    final layout = PathLayout(root.path);
    Directory(layout.editPath('greeter', '0.1.0')).createSync(recursive: true);
    Directory(layout.editPath('alpha', '1.0.0')).createSync(recursive: true);
    Directory(
      p.join(layout.editRootPath, 'scratch'),
    ).createSync(recursive: true);
    File(layout.patchPath('greeter', '0.1.1'))
      ..createSync(recursive: true)
      ..writeAsStringSync('patch');
    File(p.join(layout.patchesRootPath, 'note.txt'))
      ..createSync(recursive: true)
      ..writeAsStringSync('ignored');
    Directory(
      layout.appliedPath('greeter', '0.1.2'),
    ).createSync(recursive: true);

    final inventory = PatchworkArtifactInventory.read(layout);

    expect(inventory.packages, ['alpha', 'greeter']);
    expect(inventory.openEditPackages, ['alpha', 'greeter']);
    expect(inventory.editsFor('greeter').map((entry) => entry.version), [
      '0.1.0',
    ]);
    expect(inventory.patchesFor('greeter').map((entry) => entry.version), [
      '0.1.1',
    ]);
    expect(inventory.appliedFor('greeter').map((entry) => entry.version), [
      '0.1.2',
    ]);
    expect(inventory.versionsFor('greeter'), {'0.1.0', '0.1.1', '0.1.2'});
    expect(inventory.edit('greeter', '0.1.0')?.path, isNotNull);
    expect(inventory.edit('greeter', 'missing'), isNull);
  });

  test('ignores unsafe patch and applied artifact identities', () {
    final root = Directory.systemTemp.createTempSync('patchwork_inventory_');
    addTearDown(() => root.deleteSync(recursive: true));

    final layout = PathLayout(root.path);
    File(layout.patchPath('greeter', '0.1.0'))
      ..createSync(recursive: true)
      ..writeAsStringSync('patch');
    File(p.join(layout.patchesRootPath, 'bad-name@0.1.0.patch'))
      ..createSync(recursive: true)
      ..writeAsStringSync('ignored');
    File(p.join(layout.patchesRootPath, 'greeter@..patch'))
      ..createSync(recursive: true)
      ..writeAsStringSync('ignored');

    Directory(
      layout.appliedPath('greeter', '0.1.0'),
    ).createSync(recursive: true);
    Directory(
      p.join(layout.appliedRootPath, 'bad-name@0.1.0'),
    ).createSync(recursive: true);
    Directory(
      p.join(layout.appliedRootPath, 'greeter@..'),
    ).createSync(recursive: true);

    final inventory = PatchworkArtifactInventory.read(layout);

    expect(inventory.patchesFor('greeter').map((entry) => entry.version), [
      '0.1.0',
    ]);
    expect(inventory.appliedFor('greeter').map((entry) => entry.version), [
      '0.1.0',
    ]);
    expect(inventory.packages, ['greeter']);
  });
}
