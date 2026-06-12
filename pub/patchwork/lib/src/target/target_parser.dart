import '../diagnostics/diagnostic.dart';
import 'target.dart';

final class TargetParseResult {
  const TargetParseResult._({this.target, this.diagnostic});

  factory TargetParseResult.success(PubTarget target) {
    return TargetParseResult._(target: target);
  }

  factory TargetParseResult.failure(Diagnostic diagnostic) {
    return TargetParseResult._(diagnostic: diagnostic);
  }

  final PubTarget? target;
  final Diagnostic? diagnostic;

  bool get isSuccess => target != null;
}

final class TargetParser {
  const TargetParser();

  static final RegExp _packageNamePattern = RegExp(r'^[a-z_][a-z0-9_]*$');

  TargetParseResult parsePubTarget(String value) {
    final input = value.trim();

    if (input.isEmpty) {
      return TargetParseResult.failure(
        const Diagnostic(
          code: 'target.empty',
          message: 'Expected a target.',
          hint: 'Use a pub package target such as analyzer or pub:analyzer.',
        ),
      );
    }

    final separatorIndex = input.indexOf(':');
    var packageRef = input;

    if (separatorIndex != -1) {
      final kind = input.substring(0, separatorIndex);
      packageRef = input.substring(separatorIndex + 1);

      if (kind != 'pub') {
        return TargetParseResult.failure(
          Diagnostic(
            code: 'target.unsupportedKind',
            message: 'Target kind "$kind" is not supported by the pub MVP.',
            hint: 'Use a pub package target such as analyzer or pub:analyzer.',
          ),
        );
      }
    }

    return _parsePackageRef(packageRef);
  }

  TargetParseResult _parsePackageRef(String packageRef) {
    if (packageRef.isEmpty) {
      return TargetParseResult.failure(
        const Diagnostic(
          code: 'target.missingPackage',
          message: 'Expected a pub package name.',
          hint: 'Use a target such as analyzer or pub:analyzer.',
        ),
      );
    }

    final atIndex = packageRef.indexOf('@');
    final name = atIndex == -1 ? packageRef : packageRef.substring(0, atIndex);
    final versionConstraint = atIndex == -1
        ? null
        : packageRef.substring(atIndex + 1);

    if (!_packageNamePattern.hasMatch(name)) {
      return TargetParseResult.failure(
        Diagnostic(
          code: 'target.invalidPackageName',
          message: 'Invalid pub package name "$name".',
          hint: 'Package names must use lowercase letters, numbers, and "_".',
        ),
      );
    }

    if (versionConstraint != null && versionConstraint.isEmpty) {
      return TargetParseResult.failure(
        Diagnostic(
          code: 'target.invalidVersionConstraint',
          message: 'Invalid version constraint in "$packageRef".',
          hint: 'Use a target such as analyzer@7.4.0.',
        ),
      );
    }

    return TargetParseResult.success(
      PubTarget(name: name, versionConstraint: versionConstraint),
    );
  }
}
