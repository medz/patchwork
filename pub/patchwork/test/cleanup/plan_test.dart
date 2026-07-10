import 'package:patchwork/src/cleanup/model.dart';
import 'package:patchwork/src/cleanup/plan.dart';
import 'package:test/test.dart';

void main() {
  test('keeps shared override-file changes for each package', () {
    final builder = CleanupPlanBuilder(
      command: CleanupCommand.prune,
      dryRun: true,
      force: true,
    );
    for (final package in ['alpha', 'beta']) {
      builder.addChange(
        CleanupChange(
          kind: CleanupChangeKind.pubspecOverride,
          package: package,
          version: '0.1.0',
          path: '/workspace/pubspec_overrides.yaml',
        ),
      );
    }

    final changes = builder.build().result.changes;

    expect(changes, hasLength(2));
    expect(changes.map((change) => change.package), ['alpha', 'beta']);
  });
}
