import 'package:patchwork/src/pub/package_resolution.dart';
import 'package:patchwork/src/store/edit_session.dart';
import 'package:patchwork/src/target/target.dart';
import 'package:test/test.dart';

void main() {
  group('PubPatchSession', () {
    test('shell-quotes the edit path for POSIX shells', () {
      const session = PubPatchSession(
        target: PubTarget(name: 'analyzer', versionConstraint: '7.4.0'),
        package: ResolvedPubPackage(
          name: 'analyzer',
          version: '7.4.0',
          sourceKind: PubPackageSourceKind.hosted,
          dependencyKind: PubPackageDependencyKind.directMain,
          rootPath: '/cache/analyzer',
          packageUri: 'lib/',
        ),
        baselinePath: '/tmp/workspace/baseline/analyzer',
        editPath: "/tmp/work space/edit/it's/analyzer",
        metadataPath: '/tmp/workspace/session/analyzer.json',
      );

      expect(
        session.commitCommandFor(CommandShell.posix),
        r"patchwork patch --commit '/tmp/work space/edit/it'\''s/analyzer'",
      );
    });

    test('shell-quotes the edit path for Windows shells', () {
      const session = PubPatchSession(
        target: PubTarget(name: 'analyzer', versionConstraint: '7.4.0'),
        package: ResolvedPubPackage(
          name: 'analyzer',
          version: '7.4.0',
          sourceKind: PubPackageSourceKind.hosted,
          dependencyKind: PubPackageDependencyKind.directMain,
          rootPath: r'C:\cache\analyzer',
          packageUri: 'lib/',
        ),
        baselinePath: r'C:\workspace\baseline\analyzer',
        editPath: r'C:\work space\edit\analyzer "quoted"',
        metadataPath: r'C:\workspace\session\analyzer.json',
      );

      expect(
        session.commitCommandFor(CommandShell.windows),
        r'patchwork patch --commit "C:\work space\edit\analyzer \"quoted\""',
      );
    });
  });
}
