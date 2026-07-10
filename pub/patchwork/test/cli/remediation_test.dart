import 'package:patchwork/src/cli/remediation.dart';
import 'package:patchwork/src/inspection/model.dart';
import 'package:test/test.dart';

void main() {
  test('does not suggest apply repair actions without a patch file', () {
    final status = _status(hasPatch: false);
    const codes = [
      'applied.output_missing',
      'applied.patch_stale',
      'applied.source_stale',
      'applied.override_missing',
    ];

    for (final code in codes) {
      final actions = remediationActions(
        status,
        PatchProblem(
          code: code,
          message: 'Applied state cannot be repaired with apply.',
          remediationRequiresUndoFirst: true,
        ),
      );
      expect(
        _commands(actions),
        isNot(contains('patchwork apply greeter')),
        reason: code,
      );
    }

    final outputMissing = remediationActions(
      status,
      const PatchProblem(
        code: 'applied.output_missing',
        message: 'Applied marker exists, but output is missing.',
      ),
    );
    expect(_commands(outputMissing), orderedEquals([null]));
    expect(
      outputMissing.single.description,
      contains('committed patch file is gone'),
    );

    final overrideMissing = remediationActions(
      status,
      const PatchProblem(
        code: 'applied.override_missing',
        message: 'Applied override is missing.',
        remediationRequiresUndoFirst: true,
      ),
    );
    expect(
      _commands(overrideMissing),
      orderedEquals(['patchwork undo greeter', 'dart pub get']),
    );
  });

  test('keeps apply repair actions when a patch file exists', () {
    final status = _status(hasPatch: true);

    final outputMissing = remediationActions(
      status,
      const PatchProblem(
        code: 'applied.output_missing',
        message: 'Applied marker exists, but output is missing.',
      ),
    );
    expect(
      _commands(outputMissing),
      orderedEquals(['patchwork apply greeter']),
    );

    final overrideMissing = remediationActions(
      status,
      const PatchProblem(
        code: 'applied.override_missing',
        message: 'Applied override is missing.',
        remediationRequiresUndoFirst: true,
      ),
    );
    expect(
      _commands(overrideMissing),
      orderedEquals([
        'patchwork undo greeter',
        'dart pub get',
        'patchwork apply greeter',
      ]),
    );
  });
}

PatchStatus _status({required bool hasPatch}) {
  return PatchStatus(
    package: 'greeter',
    version: '0.1.0',
    editPath: '.patchwork/greeter@0.1.0',
    patchPath: 'patches/greeter@0.1.0.patch',
    appliedPath: '.dart_tool/patchwork/greeter@0.1.0',
    hasOpenEdit: false,
    hasPatch: hasPatch,
    needsApply: false,
  );
}

List<String?> _commands(List<SuggestedAction> actions) {
  return actions.map((action) => action.command).toList();
}
