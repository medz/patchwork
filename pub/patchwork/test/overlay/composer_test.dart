import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:patchwork/src/error.dart';
import 'package:patchwork/src/overlay/composer.dart';
import 'package:patchwork/src/overlay/rules.dart';
import 'package:patchwork/src/state/path_layout.dart';
import 'package:test/test.dart';

void main() {
  test('reports overlay patches that become unreadable before composition', () {
    final root = Directory.systemTemp.createTempSync('patchwork_composer_');
    addTearDown(() => root.deleteSync(recursive: true));
    final sourcePath = p.join(root.path, 'source');
    File(p.join(sourcePath, 'lib', 'greeter.dart'))
      ..createSync(recursive: true)
      ..writeAsStringSync('String greeting = "hello";\n');
    final patch = File(p.join(root.path, 'provider.patch'))
      ..writeAsStringSync('patch');
    final contribution = OverlayContribution(
      provider: 'provider',
      patchPath: patch.path,
    );
    patch.deleteSync();
    final target = OverlayComposition(
      package: 'greeter',
      version: '0.1.0',
      sourceSha256: 'source-sha',
      sourcePath: sourcePath,
    )..contributions.add(contribution);

    expect(
      () => const OverlayComposer().compose(
        target,
        layout: PathLayout(root.path),
      ),
      throwsA(
        isA<PatchworkException>().having(
          (error) => error.code,
          'code',
          'overlay.patch_unreadable',
        ),
      ),
    );
  });
}
