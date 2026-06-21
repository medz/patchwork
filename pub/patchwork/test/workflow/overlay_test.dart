@Tags(['full'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:patchwork/src/cli/application.dart';
import 'package:test/test.dart';

import 'overlay_project_sandbox.dart';
import 'project_sandbox.dart';

void main() {
  test(
    'overlay command requires patchwork as a regular dependency',
    () async {
      final project = await ProjectSandbox.standalone();
      addTearDown(project.dispose);

      await project.pubGet();
      await project.application(['patch', 'greeter']);
      project.writeEdit('Hello from an app-local patch');
      await project.application(['commit', 'greeter']);

      await project.application(
        ['overlay', 'add', 'greeter', '--reason='],
        exitCodes: {64},
        stderrContains: 'expects a value',
      );
      await project.application(
        ['overlay', 'add', 'greeter'],
        exitCodes: {1},
        stderrContains: 'must depend on patchwork',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'overlay command writes package-provided patchwork.yaml entries',
    () async {
      final project = await OverlayProjectSandbox.create();
      addTearDown(project.dispose);

      await project.registerPrefixOverlay(
        project.providerBRoot,
        'Hello from provider B',
        reason: 'Fix greeting used by provider_b.',
      );

      final manifest = project.manifestFor(project.providerBRoot);
      expect(manifest.existsSync(), isTrue);
      expect(
        manifest.readAsStringSync(),
        allOf([
          contains('overlays:'),
          contains('package: "greeter"'),
          contains('version: "0.1.0"'),
          contains('sha256:'),
          contains('patch: "patches/greeter@0.1.0.patch"'),
          contains('reason: "Fix greeting used by provider_b."'),
        ]),
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'workspace provider overlays copy committed patches into the member package',
    () async {
      final project = await OverlayProjectSandbox.providerWorkspace();
      addTearDown(project.dispose);

      await project.pubGet(project.providerBRoot);
      await project.application(project.providerBRoot, ['patch', 'greeter']);
      project.writePrefixEdit(project.providerBRoot, 'Hello from workspace');
      await project.application(project.providerBRoot, ['commit', 'greeter']);
      // Compatibility for the original `patchwork overlay <pkg>` command.
      await project.application(project.providerBRoot, ['overlay', 'greeter']);

      expect(
        File(
          p.join(project.providerBRoot, 'patches', 'greeter@0.1.0.patch'),
        ).existsSync(),
        isTrue,
      );
      expect(
        project.manifestFor(project.providerBRoot).readAsStringSync(),
        contains('patch: "patches/greeter@0.1.0.patch"'),
      );
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );

  test(
    'overlay inspect reports matched providers and root deduplication',
    () async {
      final project = await OverlayProjectSandbox.create(
        appDependsOnGreeter: true,
      );
      addTearDown(project.dispose);

      project.writePrefixOverlay(project.providerBRoot, 'Hi');
      project.writeRootPrefixPatch('Hi');
      await project.pubGet(project.appRoot);

      final result = await _runApplication(project.appRoot, [
        'overlay',
        'inspect',
        '--json',
      ]);

      expect(result.exitCode, 0);
      final decoded = jsonDecode(result.stdout) as Map<String, Object?>;
      expect(decoded['command'], 'overlay.inspect');
      final providers = decoded['providers'] as List<Object?>;
      expect(providers, hasLength(1));
      final provider = providers.single as Map<String, Object?>;
      expect(provider['package'], 'provider_b');
      final entries = provider['entries'] as List<Object?>;
      expect(entries, hasLength(1));
      expect((entries.single as Map<String, Object?>)['status'], 'matched');

      final targets = decoded['targets'] as List<Object?>;
      expect(targets, hasLength(1));
      final target = targets.single as Map<String, Object?>;
      expect(target['package'], 'greeter');
      final contributions = target['contributions'] as List<Object?>;
      expect(contributions, hasLength(2));
      expect(
        contributions.map((entry) {
          return (entry as Map<String, Object?>)['provider'];
        }),
        ['provider_b', '<root>'],
      );
      expect(
        (contributions.last as Map<String, Object?>)['status'],
        'deduplicated',
      );
      expect(target['conflict'], isNull);
      project.expectGreeterResolvedToSource();
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test(
    'transitive provider overlay is applied for an app that only depends on the provider',
    () async {
      final project = await OverlayProjectSandbox.create();
      addTearDown(project.dispose);

      project.writePrefixOverlay(
        project.providerBRoot,
        'Hello from provider B overlay',
      );
      await project.pubGet(project.appRoot);

      final result = await project.runApp();
      expect(
        result.stdout,
        contains('Hello from provider B overlay, Patchwork!'),
      );
      project.expectGreeterResolvedToAppliedOutput();

      final inspect = await _runApplication(project.appRoot, [
        'overlay',
        'inspect',
        '--json',
      ]);
      expect(inspect.exitCode, 0);
      final decoded = jsonDecode(inspect.stdout) as Map<String, Object?>;
      final targets = decoded['targets'] as List<Object?>;
      final target = targets.single as Map<String, Object?>;
      expect(target['sourcePath'], contains('packages/greeter'));
      expect(target['conflict'], isNull);
      project.expectGreeterResolvedToAppliedOutput();
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );

  test(
    'new provider manifests are picked up without another app pub get',
    () async {
      final project = await OverlayProjectSandbox.create();
      addTearDown(project.dispose);

      await project.pubGet(project.appRoot);
      final plain = await project.runApp();
      expect(plain.stdout, contains('Hello, Patchwork!'));
      project.expectGreeterResolvedToSource();

      project.writePrefixOverlay(
        project.providerBRoot,
        'Hello after manifest creation',
      );

      final patched = await project.runApp();
      expect(
        patched.stdout,
        contains('Hello after manifest creation, Patchwork!'),
      );
      project.expectGreeterResolvedToAppliedOutput();
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test(
    'removing provider overlays restores the base package config',
    () async {
      final project = await OverlayProjectSandbox.create();
      addTearDown(project.dispose);

      project.writePrefixOverlay(
        project.providerBRoot,
        'Hello from provider B overlay',
      );
      await project.pubGet(project.appRoot);

      final patched = await project.runApp();
      expect(
        patched.stdout,
        contains('Hello from provider B overlay, Patchwork!'),
      );
      project.expectGreeterResolvedToAppliedOutput();

      project
          .manifestFor(project.providerBRoot)
          .writeAsStringSync('overlays: []\n');
      final restored = await project.runApp();
      expect(restored.stdout, contains('Hello, Patchwork!'));
      project.expectGreeterResolvedToSource();
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );

  test(
    'multiple provider overlays compose into one generated package output',
    () async {
      final project = await OverlayProjectSandbox.create(
        appDependsOnProviderC: true,
      );
      addTearDown(project.dispose);

      project.writePrefixOverlay(project.providerBRoot, 'Hi');
      project.writePunctuationOverlay(project.providerCRoot, '?');
      await project.pubGet(project.appRoot);

      final result = await project.runApp();
      expect(result.stdout, contains('Hi, Patchwork?'));
      project.expectGreeterResolvedToAppliedOutput();
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test(
    'duplicate provider overlays compose once',
    () async {
      final project = await OverlayProjectSandbox.create(
        appDependsOnProviderC: true,
      );
      addTearDown(project.dispose);

      project.writePrefixOverlay(project.providerBRoot, 'Hi');
      project.writePrefixOverlay(project.providerCRoot, 'Hi');
      await project.pubGet(project.appRoot);

      final result = await project.runApp();
      expect(result.stdout, contains('Hi, Patchwork!'));
      project.expectGreeterResolvedToAppliedOutput();

      final inspect = await _runApplication(project.appRoot, [
        'overlay',
        'inspect',
        '--json',
      ]);
      expect(inspect.exitCode, 0);
      final decoded = jsonDecode(inspect.stdout) as Map<String, Object?>;
      final targets = decoded['targets'] as List<Object?>;
      final target = targets.single as Map<String, Object?>;
      final contributions = target['contributions'] as List<Object?>;
      expect(
        contributions.map((entry) {
          return (entry as Map<String, Object?>)['status'];
        }),
        ['active', 'deduplicated'],
      );
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test(
    'workspace provider manifests are applied when the app depends on them',
    () async {
      final project = await OverlayProjectSandbox.create(
        appIsWorkspaceMember: true,
        providerBIsWorkspaceMember: true,
      );
      addTearDown(project.dispose);

      project.writePrefixOverlay(
        project.providerBRoot,
        'Hello from workspace provider',
      );
      await project.pubGet(project.appRoot);

      final result = await project.runApp();
      expect(
        result.stdout,
        contains('Hello from workspace provider, Patchwork!'),
      );
      project.expectGreeterResolvedToAppliedOutput();
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test(
    'workspace member apps compose provider overlays into one generated output',
    () async {
      final project = await OverlayProjectSandbox.create(
        appDependsOnProviderC: true,
        appIsWorkspaceMember: true,
      );
      addTearDown(project.dispose);

      project.writePrefixOverlay(project.providerBRoot, 'Hi');
      project.writePunctuationOverlay(project.providerCRoot, '?');
      await project.pubGet(project.appRoot);

      final result = await project.runApp();
      expect(result.stdout, contains('Hi, Patchwork?'));
      project.expectGreeterResolvedToAppliedOutput();
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test(
    'conflicting provider overlays fail with deterministic diagnostics',
    () async {
      final project = await OverlayProjectSandbox.create(
        appDependsOnProviderC: true,
      );
      addTearDown(project.dispose);

      project.writePrefixOverlay(project.providerBRoot, 'Hi');
      project.writePrefixOverlay(project.providerCRoot, 'Yo');
      await project.pubGet(project.appRoot);

      final result = await project.runApp(exitCodes: {1, 255});
      expect(result.stdout + result.stderr, contains('overlay.apply_failed'));
      expect(result.stdout + result.stderr, contains('provider_c'));
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

Future<_ApplicationResult> _runApplication(
  String workingDirectory,
  List<String> arguments,
) async {
  final root = Directory.systemTemp.createTempSync('patchwork_overlay_cli_');
  final stdoutFile = File(p.join(root.path, 'stdout.txt'));
  final stderrFile = File(p.join(root.path, 'stderr.txt'));
  final stdout = stdoutFile.openWrite();
  final stderr = stderrFile.openWrite();
  var stdoutClosed = false;
  var stderrClosed = false;
  try {
    final exitCode = await Application(
      stdout: stdout,
      stderr: stderr,
      workingDirectory: workingDirectory,
    ).run(arguments);
    await stdout.close();
    stdoutClosed = true;
    await stderr.close();
    stderrClosed = true;
    return _ApplicationResult(
      exitCode: exitCode,
      stdout: stdoutFile.readAsStringSync(),
      stderr: stderrFile.readAsStringSync(),
    );
  } finally {
    if (!stdoutClosed) {
      await stdout.close();
    }
    if (!stderrClosed) {
      await stderr.close();
    }
    root.deleteSync(recursive: true);
  }
}

final class _ApplicationResult {
  const _ApplicationResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
}
