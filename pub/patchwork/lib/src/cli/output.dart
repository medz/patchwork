import 'dart:convert';
import 'dart:io' as io;

import '../error.dart';
import '../model.dart';
import '../patchwork.dart';

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
void printStatus(Patchwork patchwork, PatchworkState state, io.IOSink out) {
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
    }
    for (final problem in package.problems) {
      out.writeln('  problem: ${problem.message}');
      if (problem.hint != null) {
        out.writeln('    ${problem.hint}');
      }
    }
  }
}

/// Writes inspected state as a single JSON document.
void printStatusJson(Patchwork patchwork, PatchworkState state, io.IOSink out) {
  _printJson(out, {
    'packages': [
      for (final package in state.packages) _statusJson(patchwork, package),
    ],
    'needsApply': [
      for (final package in state.needsApply)
        {'package': package.package, 'version': package.version},
    ],
    'problems': [
      for (final package in state.packages)
        for (final problem in package.problems)
          {'package': package.package, ..._problemJson(problem)},
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
  io.IOSink out,
) {
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
    'needsPubGet': applied.isNotEmpty,
  });
}

/// Writes a `patchwork undo` result as a single JSON document.
void printUndoJson(Patchwork patchwork, UnappliedPatch result, io.IOSink out) {
  _printJson(out, {
    'command': 'undo',
    'result': {
      'package': result.package,
      'changed': result.changed,
      'path': result.path == null ? null : patchwork.relativePath(result.path!),
    },
    'needsPubGet': result.changed,
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

Map<String, Object?> _statusJson(Patchwork patchwork, PatchStatus package) {
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
    'problems': [for (final problem in package.problems) _problemJson(problem)],
  };
}

Map<String, Object?> _problemJson(PatchProblem problem) {
  return {
    'code': problem.code,
    'message': problem.message,
    'hint': problem.hint,
  };
}

void _printJson(io.IOSink out, Map<String, Object?> object) {
  out.writeln(jsonEncode(object));
}
