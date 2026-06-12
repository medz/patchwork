import 'package:patchwork/src/cli/command_intent.dart';
import 'package:patchwork/src/cli/command_runner.dart';
import 'package:test/test.dart';

void main() {
  group('PatchworkCommandParser', () {
    const parser = PatchworkCommandParser();

    test('parses patch with a bare pub target', () {
      final intent = _parseSuccess<PatchIntent>(parser, ['patch', 'analyzer']);

      expect(intent.isCommit, isFalse);
      expect(intent.target.toString(), 'pub:analyzer');
    });

    test('parses patch with a package version constraint', () {
      final intent = _parseSuccess<PatchIntent>(parser, [
        'patch',
        'analyzer@7.4.0',
      ]);

      expect(intent.isCommit, isFalse);
      expect(intent.target.toString(), 'pub:analyzer@7.4.0');
    });

    test('parses patch with an explicit pub target', () {
      final intent = _parseSuccess<PatchIntent>(parser, [
        'patch',
        'pub:analyzer',
      ]);

      expect(intent.target.toString(), 'pub:analyzer');
    });

    test('rejects unsupported sdk targets', () {
      final result = parser.parse(['patch', 'sdk:flutter']);

      expect(result.isSuccess, isFalse);
      expect(result.diagnostic?.code, 'target.unsupported_kind');
      expect(result.diagnostic?.message, contains('sdk'));
    });

    test('parses patch commit with a pub target', () {
      final intent = _parseSuccess<PatchIntent>(parser, [
        'patch',
        '--commit',
        'analyzer',
      ]);

      expect(intent.isCommit, isTrue);
      expect(intent.commitSubject, isA<PatchCommitTarget>());
      expect(intent.commitSubject.toString(), 'pub:analyzer');
    });

    test('parses patch commit with an edit directory', () {
      final intent = _parseSuccess<PatchIntent>(parser, [
        'patch',
        '--commit',
        '.dart_tool/patchwork/sessions/analyzer',
      ]);

      expect(intent.isCommit, isTrue);
      expect(intent.commitSubject, isA<PatchCommitDirectory>());
      expect(
        intent.commitSubject.toString(),
        '.dart_tool/patchwork/sessions/analyzer',
      );
    });

    test('parses patch commit with a Windows edit directory', () {
      const editPaths = [
        r'C:\repo\.dart_tool\patchwork\edit\pub\analyzer@7.4.0',
        r'c:\repo\.dart_tool\patchwork\edit\pub\analyzer@7.4.0',
        r'.\.dart_tool\patchwork\edit\pub\analyzer@7.4.0',
      ];

      for (final editPath in editPaths) {
        final intent = _parseSuccess<PatchIntent>(parser, [
          'patch',
          '--commit',
          editPath,
        ]);

        expect(intent.isCommit, isTrue);
        expect(intent.commitSubject, isA<PatchCommitDirectory>());
        expect(intent.commitSubject.toString(), editPath);
      }
    });

    test(
      'rejects path targets before treating commit subjects as directories',
      () {
        final result = parser.parse([
          'patch',
          '--commit',
          'path:../local_package',
        ]);

        expect(result.isSuccess, isFalse);
        expect(result.diagnostic?.code, 'target.unsupported_kind');
        expect(result.diagnostic?.message, contains('path'));
      },
    );

    test('parses apply without a target', () {
      final intent = _parseSuccess<ApplyIntent>(parser, ['apply']);

      expect(intent.target, isNull);
    });

    test('parses apply with a target', () {
      final intent = _parseSuccess<ApplyIntent>(parser, ['apply', 'analyzer']);

      expect(intent.target.toString(), 'pub:analyzer');
    });

    test('parses status and doctor', () {
      expect(
        _parseSuccess<StatusIntent>(parser, ['status']),
        isA<StatusIntent>(),
      );
      expect(
        _parseSuccess<DoctorIntent>(parser, ['doctor']),
        isA<DoctorIntent>(),
      );
    });

    test('parses top-level help', () {
      final intent = _parseSuccess<HelpIntent>(parser, ['--help']);

      expect(intent.command, isNull);
    });

    test('parses command help', () {
      final intent = _parseSuccess<HelpIntent>(parser, ['patch', '--help']);

      expect(intent.command, 'patch');
    });

    test('rejects unknown commands', () {
      final result = parser.parse(['unknown']);

      expect(result.isSuccess, isFalse);
      expect(result.diagnostic?.code, 'usage.unknown_command');
    });

    test('rejects missing patch target', () {
      final result = parser.parse(['patch']);

      expect(result.isSuccess, isFalse);
      expect(result.diagnostic?.code, 'usage.missing_target');
    });

    test('rejects extra status arguments', () {
      final result = parser.parse(['status', 'one', 'two']);

      expect(result.isSuccess, isFalse);
      expect(result.diagnostic?.code, 'usage.too_many_arguments');
    });
  });
}

T _parseSuccess<T extends CommandIntent>(
  PatchworkCommandParser parser,
  List<String> arguments,
) {
  final result = parser.parse(arguments);

  expect(result.diagnostic, isNull);
  expect(result.intent, isA<T>());

  return result.intent! as T;
}
