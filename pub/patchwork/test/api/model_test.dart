import 'package:patchwork/patchwork.dart';
import 'package:test/test.dart';

void main() {
  test('public result collections are defensive immutable snapshots', () {
    final rejects = <String>['reject.patch'];
    final edit = PreparedEdit(
      package: 'greeter',
      version: '0.1.0',
      path: '.patchwork/greeter@0.1.0',
      sourcePath: 'packages/greeter',
      partialRejectPaths: rejects,
    );
    rejects.add('late.patch');
    expect(edit.partialRejectPaths, ['reject.patch']);
    expect(
      () => edit.partialRejectPaths.add('blocked.patch'),
      throwsUnsupportedError,
    );

    final problems = <PatchProblem>[
      const PatchProblem(code: 'test.problem', message: 'problem'),
    ];
    final status = PatchStatus(
      package: 'greeter',
      version: '0.1.0',
      editPath: '.patchwork/greeter@0.1.0',
      patchPath: 'patches/greeter@0.1.0.patch',
      appliedPath: null,
      hasOpenEdit: false,
      hasPatch: true,
      needsApply: true,
      problems: problems,
    );
    final packages = <PatchStatus>[status];
    final state = PatchworkState(packages: packages);
    problems.clear();
    packages.clear();
    expect(state.packages.single.problems, hasLength(1));
    expect(() => state.packages.clear(), throwsUnsupportedError);

    final checks = <SetupCheck>[
      const SetupCheck(
        code: 'setup.ok',
        level: SetupCheckLevel.ok,
        message: 'ok',
      ),
    ];
    final setup = SetupReport(checks: checks);
    checks.clear();
    expect(setup.checks, hasLength(1));

    final entries = <OverlayEntryInspection>[];
    final provider = OverlayProviderInspection(
      package: 'provider',
      rootPath: 'packages/provider',
      manifestPath: 'packages/provider/patchwork.yaml',
      entries: entries,
    );
    final providers = <OverlayProviderInspection>[provider];
    final targets = <OverlayTargetInspection>[];
    final overlays = OverlayInspection(providers: providers, targets: targets);
    providers.clear();
    entries.add(
      const OverlayEntryInspection(
        package: 'greeter',
        version: '0.1.0',
        sha256: 'sha',
        patchPath: 'patches/greeter.patch',
        status: OverlayEntryStatus.matched,
      ),
    );
    targets.add(
      OverlayTargetInspection(
        package: 'greeter',
        version: '0.1.0',
        sha256: 'sha',
        sourcePath: 'packages/greeter',
        contributions: const [],
      ),
    );
    expect(overlays.providers, hasLength(1));
    expect(overlays.providers.single.entries, isEmpty);
    expect(overlays.targets, isEmpty);
  });

  test('cleanup results expose a typed command and immutable changes', () {
    final changes = <CleanupChange>[
      const CleanupChange(
        kind: CleanupChangeKind.patchFile,
        package: 'greeter',
        version: '0.1.0',
        path: 'patches/greeter@0.1.0.patch',
      ),
    ];
    final result = CleanupResult(
      command: CleanupCommand.remove,
      dryRun: false,
      force: false,
      changes: changes,
    );
    changes.clear();

    expect(result.command, CleanupCommand.remove);
    expect(result.changes, hasLength(1));
    expect(() => result.changes.clear(), throwsUnsupportedError);
  });

  test('apply results expose immutable changes and pub refresh state', () {
    final applied = <AppliedPatch>[
      const AppliedPatch(
        package: 'greeter',
        version: '0.1.0',
        path: '.dart_tool/patchwork/greeter@0.1.0',
        patchPath: 'patches/greeter@0.1.0.patch',
      ),
    ];
    final result = ApplyResult(applied: applied, needsPubGet: true);
    applied.clear();

    expect(result.changed, isTrue);
    expect(result.needsPubGet, isTrue);
    expect(result.applied, hasLength(1));
    expect(() => result.applied.clear(), throwsUnsupportedError);
  });
}
