import 'package:patchwork/src/pub/package_resolution.dart';
import 'package:patchwork/src/store/edit_session.dart';
import 'package:patchwork/src/target/target.dart';
import 'package:test/test.dart';

void main() {
  group('PubPatchSession', () {
    test('shell-quotes the edit path in the commit command', () {
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
        session.commitCommand,
        r"patchwork patch --commit '/tmp/work space/edit/it'\''s/analyzer'",
      );
    });
  });
}
