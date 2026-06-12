import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:patchwork/src/cli/command_runner.dart';
import 'package:patchwork/src/diagnostics/exit_code.dart';
import 'package:patchwork/src/store/patchwork_manifest.dart';
import 'package:test/test.dart';

void main() {
  group('pub patch workflow end-to-end', () {
    late _PubPatchWorkflowFixture fixture;

    setUp(() {
      fixture = _PubPatchWorkflowFixture.create();
    });

    tearDown(() {
      fixture.dispose();
    });

    test('patches a direct dependency by bare name', () {
      expect(fixture.runApp(), 'original');
      final originalPubspec = fixture.appPubspec.readAsStringSync();

      fixture.patchAndCommit('sample_dep', message: 'patched');
      final apply = fixture.runPatchwork(['apply']);
      _expectPatchworkSuccess(apply);
      expect(fixture.appPubspec.readAsStringSync(), originalPubspec);
      expect(fixture.appOverrides.existsSync(), isTrue);

      fixture.runPubGet();

      expect(fixture.runApp(), 'patched');
      final status = fixture.runPatchwork(['status']);
      _expectPatchworkSuccess(status);
      expect(status.stdout, contains('pub:sample_dep@1.2.3 [clean]'));
    });

    test('patches a direct dependency by name and version', () {
      fixture.patchAndCommit('sample_dep@1.2.3', message: 'version target');

      final apply = fixture.runPatchwork(['apply']);
      _expectPatchworkSuccess(apply);
      fixture.runPubGet();

      expect(fixture.runApp(), 'version target');
    });

    test('rejects unknown packages', () {
      final result = fixture.runPatchwork(['patch', 'missing_dep']);

      expect(result.exitCode, PatchworkExitCode.failure);
      expect(result.stdout, isEmpty);
      expect(result.stderr, contains('Package "missing_dep"'));
    });

    test('rejects unsupported target prefixes', () {
      final result = fixture.runPatchwork(['patch', 'sdk:flutter']);

      expect(result.exitCode, PatchworkExitCode.failure);
      expect(result.stdout, isEmpty);
      expect(result.stderr, contains('Target kind "sdk" is not supported'));
    });

    test('commits no changes as a clean no-op', () {
      final patch = fixture.runPatchwork(['patch', 'sample_dep']);
      _expectPatchworkSuccess(patch);

      final commit = fixture.runPatchwork(['patch', '--commit', 'sample_dep']);

      _expectPatchworkSuccess(commit);
      expect(commit.stdout, 'No changes to commit.\n');
      expect(fixture.patchFile.existsSync(), isFalse);
      expect(fixture.manifestFile.existsSync(), isFalse);
    });

    test('generates portable patch files without fixture paths', () {
      fixture.patchAndCommit('sample_dep', message: 'portable');

      final content = fixture.patchFile.readAsStringSync();
      expect(content, contains('diff --git a/lib/sample_dep.dart'));
      expect(content, isNot(contains(fixture.rootPath)));
      expect(content, isNot(contains(fixture.appPath)));
      expect(content, isNot(contains(fixture.dependencyPath)));
      expect(content, isNot(contains('.pub-cache')));
    });

    test('rebuilds the generated store when the patch hash changes', () {
      fixture.patchAndCommit('sample_dep', message: 'first');
      final firstApply = fixture.runPatchwork(['apply']);
      _expectPatchworkSuccess(firstApply);
      final firstStorePath = _appliedStorePath(firstApply);
      fixture.runPubGet();
      expect(fixture.runApp(), 'first');

      fixture.writeEditMessage('second');
      final commit = fixture.runPatchwork(['patch', '--commit', 'sample_dep']);
      _expectPatchworkSuccess(commit);
      final secondApply = fixture.runPatchwork(['apply']);
      _expectPatchworkSuccess(secondApply);
      final secondStorePath = _appliedStorePath(secondApply);
      fixture.runPubGet();

      expect(secondStorePath, isNot(firstStorePath));
      expect(
        File(
          p.join(secondStorePath, 'lib', 'sample_dep.dart'),
        ).readAsStringSync(),
        "String sampleMessage() => 'second';\n",
      );
      expect(fixture.runApp(), 'second');
    });

    test('reports missing patch files clearly', () {
      fixture.patchAndCommit('sample_dep', message: 'missing file');
      fixture.patchFile.deleteSync();

      final status = fixture.runPatchwork(['status']);

      expect(status.exitCode, PatchworkExitCode.failure);
      expect(status.stderr, isEmpty);
      expect(status.stdout, contains('pub:sample_dep@1.2.3 [missing]'));
      expect(status.stdout, contains('(missing)'));
    });

    test('bad patches fail without corrupting generated state', () {
      final patch = fixture.runPatchwork(['patch', 'sample_dep']);
      _expectPatchworkSuccess(patch);
      fixture.writeEditMessage('edit survives');
      fixture.patchFile.parent.createSync(recursive: true);
      fixture.patchFile.writeAsStringSync('not a valid patch\n');
      const manifestStore = PatchworkManifestStore();
      manifestStore.upsertPatch(
        workspaceRootPath: fixture.appPath,
        entry: PatchworkManifestPatch(
          target: 'pub:sample_dep@1.2.3',
          path: 'patches/pub/sample_dep@1.2.3.patch',
          hash: manifestStore.hashFile(fixture.patchFile.path),
        ),
      );

      final apply = fixture.runPatchwork(['apply']);

      expect(apply.exitCode, PatchworkExitCode.failure);
      expect(
        apply.stderr,
        contains('Could not apply patch to the generated package copy'),
      );
      expect(fixture.storeRoot.existsSync(), isFalse);
      expect(
        fixture.baselineLib.readAsStringSync(),
        "String sampleMessage() => 'original';\n",
      );
      expect(
        fixture.editLib.readAsStringSync(),
        "String sampleMessage() => 'edit survives';\n",
      );
      expect(fixture.appOverrides.existsSync(), isFalse);
    });
  });
}

void _expectPatchworkSuccess(_PatchworkRunResult result) {
  expect(
    result.exitCode,
    PatchworkExitCode.success,
    reason: result.combinedOutput,
  );
  expect(result.stderr, isEmpty);
}

String _appliedStorePath(_PatchworkRunResult result) {
  final match = RegExp(
    r'Applied pub:sample_dep@1\.2\.3: (.+)$',
    multiLine: true,
  ).firstMatch(result.stdout);
  expect(match, isNotNull, reason: result.stdout);
  return match!.group(1)!.trim();
}

final class _PubPatchWorkflowFixture {
  _PubPatchWorkflowFixture._(this.root);

  final Directory root;
  final PatchworkCommandRunner runner = const PatchworkCommandRunner();

  String get rootPath => p.normalize(root.path);

  String get appPath => p.join(rootPath, 'app');

  String get dependencyPath => p.join(rootPath, 'packages', 'sample_dep');

  File get appPubspec => File(p.join(appPath, 'pubspec.yaml'));

  File get appOverrides => File(p.join(appPath, 'pubspec_overrides.yaml'));

  File get manifestFile => File(p.join(appPath, 'patchwork.lock'));

  File get patchFile {
    return File(p.join(appPath, 'patches', 'pub', 'sample_dep@1.2.3.patch'));
  }

  Directory get storeRoot {
    return Directory(p.join(appPath, '.dart_tool', 'patchwork', 'store'));
  }

  File get editLib {
    return File(
      p.join(
        appPath,
        '.dart_tool',
        'patchwork',
        'edit',
        'pub',
        'sample_dep@1.2.3',
        'lib',
        'sample_dep.dart',
      ),
    );
  }

  File get baselineLib {
    return File(
      p.join(
        appPath,
        '.dart_tool',
        'patchwork',
        'baseline',
        'pub',
        'sample_dep@1.2.3',
        'lib',
        'sample_dep.dart',
      ),
    );
  }

  static _PubPatchWorkflowFixture create() {
    final root = Directory.systemTemp.createTempSync('patchwork_pub_e2e_');
    final fixture = _PubPatchWorkflowFixture._(root);
    fixture.writeProject();
    fixture.runPubGet();
    return fixture;
  }

  void dispose() {
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  }

  void writeProject() {
    Directory(p.join(dependencyPath, 'lib')).createSync(recursive: true);
    File(p.join(dependencyPath, 'pubspec.yaml')).writeAsStringSync('''
name: sample_dep
version: 1.2.3

environment:
  sdk: ^3.12.0
''');
    File(
      p.join(dependencyPath, 'lib', 'sample_dep.dart'),
    ).writeAsStringSync("String sampleMessage() => 'original';\n");

    Directory(p.join(appPath, 'bin')).createSync(recursive: true);
    appPubspec.writeAsStringSync('''
name: app
publish_to: none

environment:
  sdk: ^3.12.0

dependencies:
  sample_dep:
    path: ../packages/sample_dep
''');
    File(p.join(appPath, 'bin', 'app.dart')).writeAsStringSync('''
import 'package:sample_dep/sample_dep.dart';

void main() {
  print(sampleMessage());
}
''');
  }

  void runPubGet() {
    final result = Process.runSync('dart', [
      'pub',
      'get',
    ], workingDirectory: appPath);
    expect(result.exitCode, 0, reason: '${result.stderr}${result.stdout}');
  }

  String runApp() {
    final result = Process.runSync('dart', [
      'run',
      'bin/app.dart',
    ], workingDirectory: appPath);
    expect(result.exitCode, 0, reason: '${result.stderr}${result.stdout}');
    return '${result.stdout}'.trim();
  }

  _PatchworkRunResult runPatchwork(List<String> arguments) {
    final stdout = StringBuffer();
    final stderr = StringBuffer();
    final exitCode = runner.run(
      arguments,
      stdout: stdout,
      stderr: stderr,
      currentDirectory: appPath,
    );
    return _PatchworkRunResult(
      exitCode: exitCode,
      stdout: stdout.toString(),
      stderr: stderr.toString(),
    );
  }

  void patchAndCommit(String target, {required String message}) {
    final patch = runPatchwork(['patch', target]);
    _expectPatchworkSuccess(patch);
    writeEditMessage(message);

    final commit = runPatchwork(['patch', '--commit', target]);
    _expectPatchworkSuccess(commit);
    expect(commit.stdout, contains('Patch file:'));
  }

  void writeEditMessage(String message) {
    editLib.writeAsStringSync("String sampleMessage() => '$message';\n");
  }
}

final class _PatchworkRunResult {
  const _PatchworkRunResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;

  String get combinedOutput => '$stdout$stderr';
}
