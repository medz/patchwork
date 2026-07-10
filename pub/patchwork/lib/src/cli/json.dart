import 'dart:convert';
import 'dart:io' as io;

import 'package:path/path.dart' as p;

import '../apply/model.dart';
import '../cleanup/model.dart';
import '../edit/model.dart';
import '../error.dart';
import '../inspection/model.dart';
import '../overlay/model.dart';
import '../patchwork.dart';
import 'path.dart';
import 'remediation.dart';

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

/// Writes setup checks as a single JSON document.
void printSetupJson(Patchwork patchwork, SetupReport report, io.IOSink out) {
  _printJson(out, {
    'setupChecks': [
      for (final check in report.checks) _setupCheckJson(patchwork, check),
    ],
    'hasWarnings': report.hasWarnings,
  });
}

/// Writes a `patchwork patch` result as a single JSON document.
void printPatchJson(Patchwork patchwork, PreparedEdit edit, io.IOSink out) {
  printEditJson(patchwork, edit, out, command: 'patch');
}

/// Writes an edit-producing command result as a single JSON document.
void printEditJson(
  Patchwork patchwork,
  PreparedEdit edit,
  io.IOSink out, {
  required String command,
}) {
  _printJson(out, {
    'command': command,
    'edit': {
      'package': edit.package,
      'version': edit.version,
      'path': patchwork.displayPath(edit.path),
      'sourcePath': patchwork.displayPath(edit.sourcePath),
      'continuedFromPatchPath': edit.continuedFromPatchPath == null
          ? null
          : patchwork.displayPath(edit.continuedFromPatchPath!),
      if (edit.partialRepairLogPath != null)
        'partialRepairLogPath': patchwork.displayPath(
          edit.partialRepairLogPath!,
        ),
      if (edit.partialRejectPaths.isNotEmpty)
        'partialRejectPaths': edit.partialRejectPaths,
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
          'editPath': patchwork.displayPath(write.editPath),
          'patchPath': patchwork.displayPath(write.patchPath),
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
          'path': patchwork.displayPath(patch.path),
          'patchPath': patchwork.displayPath(patch.patchPath),
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
      'path': result.path == null ? null : patchwork.displayPath(result.path!),
    },
    'pubGetRan': pubGetRan,
    'needsPubGet': needsPubGet,
  });
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
    'command': result.command.name,
    'dryRun': result.dryRun,
    'force': result.force,
    'changes': [
      for (final change in result.changes)
        {
          'kind': change.kind.name,
          'package': change.package,
          'version': change.version,
          'path': patchwork.displayPath(change.path),
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
      'manifestPath': patchwork.displayPath(overlay.manifestPath),
      'reason': overlay.reason,
    },
  });
}

/// Writes read-only package-provided overlay diagnostics as JSON.
void printOverlayInspectionJson(
  Patchwork patchwork,
  OverlayInspection inspection,
  io.IOSink out,
) {
  _printJson(out, {
    'command': 'overlay.inspect',
    'providers': [
      for (final provider in inspection.providers)
        {
          'package': provider.package,
          'rootPath': _displayPath(patchwork, provider.rootPath),
          'manifestPath': _displayPath(patchwork, provider.manifestPath),
          'entries': [
            for (final entry in provider.entries)
              {
                'package': entry.package,
                'version': entry.version,
                'sha256': entry.sha256,
                'patchPath': _displayPath(patchwork, entry.patchPath),
                'reason': entry.reason,
                'status': entry.status.name,
                'skipReason': entry.skipReason,
                'resolvedVersion': entry.resolvedVersion,
                'resolvedSha256': entry.resolvedSha256,
              },
          ],
        },
    ],
    'targets': [
      for (final target in inspection.targets)
        {
          'package': target.package,
          'version': target.version,
          'sha256': target.sha256,
          'sourcePath': _displayPath(patchwork, target.sourcePath),
          'contributions': [
            for (final contribution in target.contributions)
              {
                'provider': contribution.provider,
                'patchPath': _displayPath(patchwork, contribution.patchPath),
                'sha256': contribution.sha256,
                'status': contribution.status.name,
              },
          ],
          'conflict': target.conflict == null
              ? null
              : {
                  'provider': target.conflict!.provider,
                  'patchPath': _displayPath(
                    patchwork,
                    target.conflict!.patchPath,
                  ),
                  'message': target.conflict!.message,
                },
        },
    ],
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
    'editPath': patchwork.displayPath(package.editPath),
    'patchPath': patchwork.displayPath(package.patchPath),
    'appliedPath': package.appliedPath == null
        ? null
        : patchwork.displayPath(package.appliedPath!),
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

String _displayPath(Patchwork patchwork, String path) {
  return p.isAbsolute(path) ? patchwork.displayPath(path) : path;
}

Map<String, Object?> _problemJson(PatchProblem problem) {
  return {
    'code': problem.code,
    'message': problem.message,
    'hint': problem.hint,
    if (problem.remediationVersion != null)
      'remediationVersion': problem.remediationVersion,
    if (problem.remediationCanContinuePatch)
      'remediationCanContinuePatch': true,
    if (problem.remediationRequiresUndoFirst)
      'remediationRequiresUndoFirst': true,
    if (problem.remediationRequiresOverrideCleanup)
      'remediationRequiresOverrideCleanup': true,
    if (problem.remediationRequiresManualCleanup)
      'remediationRequiresManualCleanup': true,
  };
}

Map<String, Object?> _actionJson(SuggestedAction action) {
  return {
    if (action.command != null) 'command': action.command,
    'description': action.description,
  };
}

Map<String, Object?> _setupCheckJson(Patchwork patchwork, SetupCheck check) {
  return {
    'code': check.code,
    'level': check.level.name,
    'message': check.message,
    'hint': check.hint,
    'path': check.path == null ? null : patchwork.displayPath(check.path!),
  };
}

void _printJson(io.IOSink out, Map<String, Object?> object) {
  out.writeln(jsonEncode(object));
}
