import 'dart:convert';
import 'dart:io' as io;

import '../error.dart';
import '../model.dart';
import '../patchwork.dart';
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

/// Writes a [PatchworkException] as a single JSON document.
void printErrorJson(io.IOSink out, PatchworkException error) {
  _printJson(out, {
    'error': {
      'code': error.code,
      'message': error.message,
      'hint': error.hint,
      'location': error.location,
    },
  });
}

/// Writes project patch state in the human-readable CLI format.
///
/// Paths are rendered relative to the Patchwork state root when possible so the
/// output can be copied between checkouts and compared in tests.
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
      out.writeln('  edit: ${patchwork.relativePath(package.editPath)}');
    }
    if (package.hasPatch) {
      out.writeln('  patch: ${patchwork.relativePath(package.patchPath)}');
    }
    if (package.appliedPath != null) {
      out.writeln('  applied: ${patchwork.relativePath(package.appliedPath!)}');
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

/// Writes inspected state as a single JSON document.
void printStatusJson(
  Patchwork patchwork,
  PatchworkState state,
  io.IOSink out, {
  bool explain = false,
}) {
  _printJson(out, {
    'packages': [
      for (final package in state.packages)
        _statusJson(patchwork, package, explain: explain),
    ],
    'needsApply': [
      for (final package in state.needsApply)
        {
          'package': package.package,
          'version': package.version,
          if (explain) 'suggestedActions': [_actionJson(applyAction(package))],
        },
    ],
    'problems': [
      for (final package in state.packages)
        for (final problem in package.problems)
          {
            'package': package.package,
            ..._problemJson(problem),
            if (explain)
              'suggestedActions': [
                for (final action in remediationActions(package, problem))
                  _actionJson(action),
              ],
          },
    ],
  });
}

/// Writes a `patchwork patch` result as a single JSON document.
void printPatchJson(Patchwork patchwork, PreparedEdit edit, io.IOSink out) {
  _printJson(out, {
    'command': 'patch',
    'edit': {
      'package': edit.package,
      'version': edit.version,
      'path': patchwork.relativePath(edit.path),
      'sourcePath': patchwork.relativePath(edit.sourcePath),
      'continuedFromPatchPath': edit.continuedFromPatchPath == null
          ? null
          : patchwork.relativePath(edit.continuedFromPatchPath!),
    },
  });
}

/// Writes a `patchwork commit` result as a single JSON document.
void printCommitJson(
  Patchwork patchwork,
  List<PatchWrite> writes,
  io.IOSink out,
) {
  _printJson(out, {
    'command': 'commit',
    'writes': [
      for (final write in writes)
        {
          'package': write.package,
          'version': write.version,
          'status': write.status.name,
          'editPath': patchwork.relativePath(write.editPath),
          'patchPath': patchwork.relativePath(write.patchPath),
        },
    ],
  });
}

/// Writes a `patchwork apply` result as a single JSON document.
void printApplyJson(
  Patchwork patchwork,
  List<AppliedPatch> applied,
  io.IOSink out, {
  required bool pubGetRan,
  required bool needsPubGet,
}) {
  _printJson(out, {
    'command': 'apply',
    'applied': [
      for (final patch in applied)
        {
          'package': patch.package,
          'version': patch.version,
          'path': patchwork.relativePath(patch.path),
          'patchPath': patchwork.relativePath(patch.patchPath),
        },
    ],
    'pubGetRan': pubGetRan,
    'needsPubGet': needsPubGet,
  });
}

/// Writes a `patchwork undo` result as a single JSON document.
void printUndoJson(
  Patchwork patchwork,
  UnappliedPatch result,
  io.IOSink out, {
  required bool pubGetRan,
  required bool needsPubGet,
}) {
  _printJson(out, {
    'command': 'undo',
    'result': {
      'package': result.package,
      'changed': result.changed,
      'path': result.path == null ? null : patchwork.relativePath(result.path!),
    },
    'pubGetRan': pubGetRan,
    'needsPubGet': needsPubGet,
  });
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
    out.writeln('No patchwork artifacts to ${result.command}.');
    return;
  }

  final verb = result.dryRun ? 'Would remove' : 'Removed';
  for (final change in result.changes) {
    out.writeln(
      '$verb ${_cleanupKindLabel(change.kind)} '
      '${patchwork.relativePath(change.path)}.',
    );
  }
  if (pubGetRan) {
    out.writeln('Ran dart pub get.');
  } else if (needsPubGet) {
    out.writeln('Run dart pub get.');
  }
}

/// Writes a cleanup command result as a single JSON document.
void printCleanupJson(
  Patchwork patchwork,
  CleanupResult result,
  io.IOSink out, {
  required bool pubGetRan,
  required bool needsPubGet,
}) {
  _printJson(out, {
    'command': result.command,
    'dryRun': result.dryRun,
    'force': result.force,
    'changes': [
      for (final change in result.changes)
        {
          'kind': change.kind.name,
          'package': change.package,
          'version': change.version,
          'path': patchwork.relativePath(change.path),
        },
    ],
    'pubGetRan': pubGetRan,
    'needsPubGet': needsPubGet,
  });
}

/// Writes a `patchwork overlay` result as a single JSON document.
void printOverlayJson(
  Patchwork patchwork,
  RegisteredOverlay overlay,
  io.IOSink out,
) {
  _printJson(out, {
    'command': 'overlay',
    'overlay': {
      'package': overlay.package,
      'version': overlay.version,
      'sha256': overlay.sha256,
      'patchPath': overlay.patchPath,
      'manifestPath': patchwork.relativePath(overlay.manifestPath),
      'reason': overlay.reason,
    },
  });
}

Map<String, Object?> _statusJson(
  Patchwork patchwork,
  PatchStatus package, {
  required bool explain,
}) {
  return {
    'package': package.package,
    'version': package.version,
    'editPath': patchwork.relativePath(package.editPath),
    'patchPath': patchwork.relativePath(package.patchPath),
    'appliedPath': package.appliedPath == null
        ? null
        : patchwork.relativePath(package.appliedPath!),
    'hasOpenEdit': package.hasOpenEdit,
    'hasPatch': package.hasPatch,
    'needsApply': package.needsApply,
    'problems': [
      for (final problem in package.problems)
        {
          ..._problemJson(problem),
          if (explain)
            'suggestedActions': [
              for (final action in remediationActions(package, problem))
                _actionJson(action),
            ],
        },
    ],
  };
}

Map<String, Object?> _problemJson(PatchProblem problem) {
  return {
    'code': problem.code,
    'message': problem.message,
    'hint': problem.hint,
  };
}

Map<String, Object?> _actionJson(SuggestedAction action) {
  return {
    if (action.command != null) 'command': action.command,
    'description': action.description,
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

void _printJson(io.IOSink out, Map<String, Object?> object) {
  out.writeln(jsonEncode(object));
}
