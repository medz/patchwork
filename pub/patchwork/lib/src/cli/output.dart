import 'dart:io' as io;

import 'package:path/path.dart' as p;

import '../cleanup/model.dart';
import '../error.dart';
import '../inspection/model.dart';
import '../overlay/model.dart';
import '../patchwork.dart';
import 'path.dart';
import 'remediation.dart';

/// Writes a [PatchworkException] in the human-readable CLI format.
///
/// The stable error code is intentionally not printed in normal CLI output; it
/// remains available to tests and library callers through the exception object.
void printError(io.IOSink err, PatchworkException error) {
  err.writeln('error: ${error.message}');
  if (error.hint != null && error.hint!.isNotEmpty) {
    err.writeln(error.hint);
  }
  if (error.location != null && error.location!.isNotEmpty) {
    err.writeln(error.location);
  }
}

/// Writes project patch state in the human-readable CLI format.
void printStatus(
  Patchwork patchwork,
  PatchworkState state,
  io.IOSink out, {
  bool explain = false,
}) {
  if (state.packages.isEmpty) {
    out.writeln('No patchwork packages.');
    return;
  }

  for (final package in state.packages) {
    out.writeln('${package.package}@${package.version}');
    if (package.hasOpenEdit) {
      out.writeln('  edit: ${patchwork.displayPath(package.editPath)}');
    }
    if (package.hasPatch) {
      out.writeln('  patch: ${patchwork.displayPath(package.patchPath)}');
    }
    if (package.appliedPath != null) {
      out.writeln('  applied: ${patchwork.displayPath(package.appliedPath!)}');
    }
    if (package.needsApply) {
      out.writeln('  action: patchwork apply ${package.package}');
      if (explain) {
        _printSuggestedActions(out, [applyAction(package)]);
      }
    }
    for (final problem in package.problems) {
      out.writeln('  problem: ${problem.message}');
      if (problem.hint != null) {
        out.writeln('    ${problem.hint}');
      }
      if (explain) {
        _printSuggestedActions(out, remediationActions(package, problem));
      }
    }
  }
}

/// Writes setup checks in the human-readable CLI format.
void printSetup(Patchwork patchwork, SetupReport report, io.IOSink out) {
  out.writeln('Setup checks:');
  for (final check in report.checks) {
    out.writeln('${_setupCheckPrefix(check.level)} ${check.message}');
    if (check.path != null) {
      out.writeln('  path: ${patchwork.displayPath(check.path!)}');
    }
    if (check.hint != null) {
      out.writeln('  ${check.hint}');
    }
  }
}

/// Writes a cleanup command result in the human-readable CLI format.
void printCleanup(
  Patchwork patchwork,
  CleanupResult result,
  io.IOSink out, {
  required bool pubGetRan,
  required bool needsPubGet,
}) {
  if (result.changes.isEmpty) {
    out.writeln('No patchwork artifacts to ${result.command.name}.');
    return;
  }

  final verb = result.dryRun ? 'Would remove' : 'Removed';
  for (final change in result.changes) {
    out.writeln(
      '$verb ${_cleanupKindLabel(change.kind)} '
      '${patchwork.displayPath(change.path)}.',
    );
  }
  if (pubGetRan) {
    out.writeln('Ran dart pub get.');
  } else if (needsPubGet) {
    out.writeln('Run dart pub get.');
  }
}

/// Writes read-only package-provided overlay diagnostics.
void printOverlayInspection(
  Patchwork patchwork,
  OverlayInspection inspection,
  io.IOSink out,
) {
  out.writeln('Overlay inspection');

  if (inspection.providers.isEmpty) {
    out.writeln('No package-provided overlays found.');
  } else {
    out.writeln('Providers:');
    for (final provider in inspection.providers) {
      out.writeln(
        '  ${provider.package}: ${_displayPath(patchwork, provider.manifestPath)}',
      );
      if (provider.entries.isEmpty) {
        out.writeln('    no overlay entries');
        continue;
      }
      for (final entry in provider.entries) {
        final status = switch (entry.status) {
          OverlayEntryStatus.matched => 'matched',
          OverlayEntryStatus.skipped => 'skipped: ${entry.skipReason}',
          OverlayEntryStatus.failed => 'failed: ${entry.skipReason}',
        };
        out.writeln('    ${entry.package}@${entry.version} $status');
        out.writeln('      patch: ${_displayPath(patchwork, entry.patchPath)}');
        if (entry.resolvedVersion != null) {
          out.writeln(
            '      resolved: ${entry.resolvedVersion} ${entry.resolvedSha256}',
          );
        }
      }
    }
  }

  if (inspection.targets.isEmpty) {
    out.writeln('No matching overlay targets.');
    return;
  }

  out.writeln('Targets:');
  for (final target in inspection.targets) {
    out.writeln('  ${target.package}@${target.version}');
    out.writeln('    source: ${target.sha256}');
    out.writeln('    path: ${_displayPath(patchwork, target.sourcePath)}');
    out.writeln('    compose order:');
    for (final contribution in target.contributions) {
      final suffix =
          contribution.status == OverlayContributionStatus.deduplicated
          ? ' (deduplicated)'
          : '';
      out.writeln(
        '      ${contribution.provider}: '
        '${_displayPath(patchwork, contribution.patchPath)}$suffix',
      );
    }
    final conflict = target.conflict;
    if (conflict != null) {
      out.writeln(
        '    conflict: ${conflict.provider} '
        '${_displayPath(patchwork, conflict.patchPath)}',
      );
      out.writeln('      ${conflict.message.replaceAll('\n', '\n      ')}');
    }
  }
}

String _displayPath(Patchwork patchwork, String path) {
  return p.isAbsolute(path) ? patchwork.displayPath(path) : path;
}

String _setupCheckPrefix(SetupCheckLevel level) {
  return switch (level) {
    SetupCheckLevel.ok => 'ok:',
    SetupCheckLevel.warning => 'warning:',
    SetupCheckLevel.info => 'info:',
  };
}

void _printSuggestedActions(io.IOSink out, List<SuggestedAction> actions) {
  if (actions.isEmpty) {
    return;
  }
  out.writeln('  remediation:');
  for (final action in actions) {
    if (action.command == null) {
      out.writeln('    - ${action.description}');
      continue;
    }
    out.writeln('    - ${action.command}');
    out.writeln('      ${action.description}');
  }
}

String _cleanupKindLabel(CleanupChangeKind kind) {
  return switch (kind) {
    CleanupChangeKind.patchFile => 'patch file',
    CleanupChangeKind.editDirectory => 'edit directory',
    CleanupChangeKind.appliedDirectory => 'applied directory',
    CleanupChangeKind.pubspecOverride => 'pubspec override',
  };
}
