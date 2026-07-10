/// Opt-in helpers for using Patchwork from Dart build hooks.
///
/// This library intentionally does not define a `hook/build.dart` entrypoint.
/// User projects should call these helpers from their own
/// `build(args, callback)` body so Patchwork can compose with any other hook
/// work in that package.
library;

import 'dart:io';

import 'package:hooks/hooks.dart';

import 'src/error.dart';
import 'src/hooks/errors.dart';
import 'src/state/path_layout.dart';
import 'src/apply/model.dart';
import 'src/inspection/model.dart';
import 'src/patchwork.dart';
import 'src/pub/workspace.dart';
export 'patchwork.dart' show AppliedPatch;

/// Applies every committed Patchwork patch from a build hook callback.
///
/// The helper registers Patchwork state and pub resolution files as hook
/// dependencies, applies any committed patches that need generated output, and
/// runs `dart pub get` when pub resolution must be refreshed before the current
/// build continues.
Future<List<AppliedPatch>> applyAll(
  BuildInput input,
  BuildOutputBuilder output,
) {
  return wrapPatchworkHookErrors(() => _apply(input, output, package: null));
}

/// Applies the committed Patchwork patch for [package] from a build hook.
///
/// If the package is already applied and pub resolution already points at the
/// generated Patchwork output, this is a no-op. Other Patchwork safety failures
/// are surfaced as build failures.
Future<List<AppliedPatch>> apply(
  BuildInput input,
  BuildOutputBuilder output, {
  required String package,
}) {
  return wrapPatchworkHookErrors(() => _apply(input, output, package: package));
}

Future<List<AppliedPatch>> _apply(
  BuildInput input,
  BuildOutputBuilder output, {
  required String? package,
}) async {
  final packageRoot = Directory.fromUri(input.packageRoot).path;
  final workspace = const PubWorkspaceLocator().locate(packageRoot);
  final layout = PathLayout(workspace.rootPath);
  _declareDependencies(output, workspace: workspace, layout: layout);

  final patchwork = Patchwork.open(packageRoot);
  final applied = package == null
      ? patchwork.applyAll()
      : _applyPackage(patchwork, package);
  final state = patchwork.inspect();
  if (applied.isNotEmpty || _pubGetRequired(state, package: package)) {
    await _runPubGet(workspace.rootPath);
  }
  return applied;
}

List<AppliedPatch> _applyPackage(Patchwork patchwork, String package) {
  try {
    return [patchwork.apply(package)];
  } on PatchworkException catch (error) {
    if (error.code == 'applied.pub_get_required') {
      return const [];
    }
    rethrow;
  }
}

void _declareDependencies(
  BuildOutputBuilder output, {
  required PubWorkspace workspace,
  required PathLayout layout,
}) {
  final files = {
    workspace.packageConfigPath,
    workspace.lockfilePath,
    workspace.packageGraphPath,
    _join(workspace.rootPath, 'pubspec.yaml'),
    _join(workspace.currentPackageRootPath, 'pubspec.yaml'),
    _join(workspace.rootPath, 'pubspec_overrides.yaml'),
    ...layout.patchFiles().map((patch) => patch.path),
  };
  output.dependencies.addAll(files.map((path) => File(path).absolute.uri));

  final directories = {
    layout.patchesRootPath,
    layout.appliedRootPath,
    layout.editRootPath,
  };
  output.dependencies.addAll({
    for (final path in directories)
      _existingDirectoryDependency(path).absolute.uri,
  });
}

bool _pubGetRequired(PatchworkState state, {required String? package}) {
  for (final status in state.packages) {
    if (package != null && status.package != package) {
      continue;
    }
    if (status.problems.any(
      (problem) => problem.code == 'applied.pub_get_required',
    )) {
      return true;
    }
  }
  return false;
}

Future<void> _runPubGet(String rootPath) async {
  final result = await Process.run(Platform.resolvedExecutable, [
    'pub',
    'get',
  ], workingDirectory: rootPath);
  if (result.exitCode == 0) {
    return;
  }

  final stdout = '${result.stdout}'.trim();
  final stderr = '${result.stderr}'.trim();
  final details = [
    if (stdout.isNotEmpty) stdout,
    if (stderr.isNotEmpty) stderr,
  ].join('\n');
  throw InfraError(
    message: [
      'dart pub get failed while refreshing Patchwork hook output.',
      if (details.isNotEmpty) details,
    ].join('\n'),
  );
}

String _join(String part1, String part2) {
  return Directory(part1).uri.resolve(part2).toFilePath();
}

Directory _existingDirectoryDependency(String path) {
  // Dart hooks cannot track a missing directory; track the nearest existing
  // parent so creating Patchwork state still invalidates the hook cache.
  var directory = Directory(path);
  if (directory.existsSync()) {
    return directory;
  }
  while (true) {
    final parent = directory.parent;
    if (parent.path == directory.path || parent.existsSync()) {
      return parent;
    }
    directory = parent;
  }
}
