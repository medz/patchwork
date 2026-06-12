import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:patchwork/src/cli/command_runner.dart';
import 'package:patchwork/src/diagnostics/exit_code.dart';
import 'package:patchwork/src/store/patchwork_manifest.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

const _dartProcessTimeout = Duration(seconds: 30);
const _timeoutExitCode = -999;

void main() {
  group('pub patch workflow end-to-end', () {
    late _PubPatchWorkflowFixture fixture;

    setUp(() async {
      fixture = await _PubPatchWorkflowFixture.create();
    });

    tearDown(() {
      fixture.dispose();
    });

    test('patches a direct dependency by bare name', () async {
      expect(await fixture.runApp(), 'original');
      final originalPubspec = fixture.appPubspec.readAsStringSync();

      fixture.patchAndCommit('sample_dep', message: 'patched');
      final apply = fixture.runPatchwork(['apply']);
      _expectPatchworkSuccess(apply);
      expect(fixture.appPubspec.readAsStringSync(), originalPubspec);
      expect(fixture.appOverrides.existsSync(), isTrue);

      await fixture.runPubGet();

      expect(await fixture.runApp(), 'patched');
      final status = fixture.runPatchwork(['status']);
      _expectPatchworkSuccess(status);
      expect(status.stdout, contains('pub:sample_dep@1.2.3 [clean]'));
    });

    test('patches a direct dependency by name and version', () async {
      fixture.patchAndCommit('sample_dep@1.2.3', message: 'version target');

      final apply = fixture.runPatchwork(['apply']);
      _expectPatchworkSuccess(apply);
      await fixture.runPubGet();

      expect(await fixture.runApp(), 'version target');
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
      final normalizedContent = content.replaceAll('\\', '/');
      expect(content, contains('diff --git a/lib/sample_dep.dart'));
      expect(normalizedContent, isNot(contains(_asPosix(fixture.rootPath))));
      expect(normalizedContent, isNot(contains(_asPosix(fixture.appPath))));
      expect(
        normalizedContent,
        isNot(contains(_asPosix(fixture.dependencyPath))),
      );
      expect(content, isNot(contains('.pub-cache')));
    });

    test('rebuilds the generated store when the patch hash changes', () async {
      fixture.patchAndCommit('sample_dep', message: 'first');
      final firstApply = fixture.runPatchwork(['apply']);
      _expectPatchworkSuccess(firstApply);
      final firstStorePath = _appliedStorePath(firstApply);
      await fixture.runPubGet();
      expect(await fixture.runApp(), 'first');

      fixture.writeEditMessage('second');
      final commit = fixture.runPatchwork(['patch', '--commit', 'sample_dep']);
      _expectPatchworkSuccess(commit);
      final secondApply = fixture.runPatchwork(['apply']);
      _expectPatchworkSuccess(secondApply);
      final secondStorePath = _appliedStorePath(secondApply);
      await fixture.runPubGet();

      expect(secondStorePath, isNot(firstStorePath));
      expect(
        File(
          p.join(secondStorePath, 'lib', 'sample_dep.dart'),
        ).readAsStringSync(),
        "String sampleMessage() => 'second';\n",
      );
      expect(await fixture.runApp(), 'second');
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

String _asPosix(String path) {
  return p.posix.normalize(path.replaceAll('\\', '/'));
}

String _readPatchworkSdkConstraint() {
  final pubspec = _patchworkPubspecFile();
  final decoded = loadYaml(pubspec.readAsStringSync());
  if (decoded is YamlMap) {
    final environment = decoded['environment'];
    if (environment is YamlMap) {
      final sdk = environment['sdk'];
      if (sdk is String) {
        return sdk;
      }
    }
  }

  throw StateError('Could not read the patchwork SDK constraint.');
}

File _patchworkPubspecFile() {
  final currentDirectory = Directory.current.path;
  final candidates = [
    p.join(currentDirectory, 'pub', 'patchwork', 'pubspec.yaml'),
    p.join(currentDirectory, 'pubspec.yaml'),
  ];
  for (final candidate in candidates) {
    final file = File(candidate);
    if (!file.existsSync()) {
      continue;
    }
    final decoded = loadYaml(file.readAsStringSync());
    if (decoded is YamlMap && decoded['name'] == 'patchwork') {
      return file;
    }
  }

  throw StateError('Could not find the patchwork pubspec.yaml.');
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

  static Future<_PubPatchWorkflowFixture> create() async {
    final root = Directory.systemTemp.createTempSync('patchwork_pub_e2e_');
    final fixture = _PubPatchWorkflowFixture._(root);
    fixture.writeProject();
    await fixture.runPubGet();
    return fixture;
  }

  void dispose() {
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  }

  void writeProject() {
    final sdkConstraint = _readPatchworkSdkConstraint();
    Directory(p.join(dependencyPath, 'lib')).createSync(recursive: true);
    File(p.join(dependencyPath, 'pubspec.yaml')).writeAsStringSync('''
name: sample_dep
version: 1.2.3

environment:
  sdk: $sdkConstraint
''');
    File(
      p.join(dependencyPath, 'lib', 'sample_dep.dart'),
    ).writeAsStringSync("String sampleMessage() => 'original';\n");

    Directory(p.join(appPath, 'bin')).createSync(recursive: true);
    appPubspec.writeAsStringSync('''
name: app
publish_to: none

environment:
  sdk: $sdkConstraint

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

  Future<void> runPubGet() async {
    final result = await _runDart(['pub', 'get']);
    expect(result.exitCode, 0, reason: result.combinedOutput);
  }

  Future<String> runApp() async {
    final result = await _runDart(['run', 'bin/app.dart']);
    expect(result.exitCode, 0, reason: result.combinedOutput);
    return result.stdout.trim();
  }

  Future<_DartRunResult> _runDart(List<String> arguments) async {
    final process = await Process.start(
      'dart',
      arguments,
      workingDirectory: appPath,
    );
    final stdout = process.stdout.transform(systemEncoding.decoder).join();
    final stderr = process.stderr.transform(systemEncoding.decoder).join();
    final exitCode = await process.exitCode.timeout(
      _dartProcessTimeout,
      onTimeout: () {
        process.kill();
        return _timeoutExitCode;
      },
    );
    final result = _DartRunResult(
      exitCode: exitCode,
      stdout: await stdout,
      stderr: await stderr,
    );
    if (exitCode == _timeoutExitCode) {
      fail(
        'dart ${arguments.join(' ')} timed out after '
        '${_dartProcessTimeout.inSeconds} seconds.\n${result.combinedOutput}',
      );
    }
    return result;
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

final class _DartRunResult {
  const _DartRunResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;

  String get combinedOutput => '$stdout$stderr';
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
