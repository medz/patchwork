import 'package:path/path.dart' as p;

import '../diagnostics/diagnostic.dart';
import '../pub/package_resolution.dart';
import '../store/edit_session.dart';
import '../target/target.dart';
import '../target/target_parser.dart';

final class ResolvedPubPatchTarget {
  const ResolvedPubPatchTarget({required this.package});

  final ResolvedPubPackage package;

  PubTarget get target {
    return PubTarget(name: package.name, versionConstraint: package.version);
  }

  String get manifestTarget => target.toString();
}

final class PubPatchTargetResolveResult {
  const PubPatchTargetResolveResult._({this.target, this.diagnostic});

  factory PubPatchTargetResolveResult.success(ResolvedPubPatchTarget target) {
    return PubPatchTargetResolveResult._(target: target);
  }

  factory PubPatchTargetResolveResult.failure(Diagnostic diagnostic) {
    return PubPatchTargetResolveResult._(diagnostic: diagnostic);
  }

  final ResolvedPubPatchTarget? target;
  final Diagnostic? diagnostic;

  bool get isSuccess => target != null;
}

final class PubPatchTargetResolver {
  const PubPatchTargetResolver({this.targetParser = const TargetParser()});

  final TargetParser targetParser;

  PubPatchTargetResolveResult resolve(
    PubResolution resolution,
    PubTarget target,
  ) {
    final packageResult = resolution.resolve(target);
    final packageDiagnostic = packageResult.diagnostic;
    if (packageDiagnostic != null) {
      return PubPatchTargetResolveResult.failure(packageDiagnostic);
    }

    final package = packageResult.package!;
    final unsupportedDiagnostic = _unsupportedPackageDiagnostic(package);
    if (unsupportedDiagnostic != null) {
      return PubPatchTargetResolveResult.failure(unsupportedDiagnostic);
    }

    return PubPatchTargetResolveResult.success(
      ResolvedPubPatchTarget(package: package),
    );
  }

  PubPatchTargetResolveResult resolveManifestTarget(
    PubResolution resolution,
    String manifestTarget,
  ) {
    final targetResult = targetParser.parsePubTarget(manifestTarget);
    final targetDiagnostic = targetResult.diagnostic;
    if (targetDiagnostic != null) {
      return PubPatchTargetResolveResult.failure(targetDiagnostic);
    }

    return resolve(resolution, targetResult.target!);
  }

  String? packageNameFromManifestTarget(String manifestTarget) {
    return targetParser.parsePubTarget(manifestTarget).target?.name;
  }

  Diagnostic? validateSession(
    PubResolution resolution,
    PubPatchSession session,
  ) {
    final sessionDiagnostic = _unsupportedPackageDiagnostic(session.package);
    if (sessionDiagnostic != null) {
      return sessionDiagnostic;
    }

    final targetResult = resolve(resolution, session.target);
    final targetDiagnostic = targetResult.diagnostic;
    if (targetDiagnostic != null) {
      return targetDiagnostic;
    }

    final package = targetResult.target!.package;
    if (!p.equals(package.rootPath, session.package.rootPath)) {
      return Diagnostic(
        code: 'pub.patch_session_stale',
        message:
            'Pub patch edit session no longer matches the current pub resolution.',
        hint: 'Restart the patch session for "${session.package.name}".',
        location: session.metadataPath,
      );
    }

    return null;
  }

  Diagnostic? _unsupportedPackageDiagnostic(ResolvedPubPackage package) {
    if (package.sourceKind != PubPackageSourceKind.root) {
      return null;
    }

    return Diagnostic(
      code: 'pub.patch_target_root_package',
      message: 'Cannot patch the current package as a dependency.',
      hint: 'Patch one of the packages resolved in pubspec.lock instead.',
      location: package.rootPath,
    );
  }
}
