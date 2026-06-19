import 'dart:io';

import 'package:path/path.dart' as p;
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
      await project.patchwork(['patch', 'greeter']);
      project.writeEdit('Hello from an app-local patch');
      await project.patchwork(['commit', 'greeter']);

      await project.patchwork(
        ['overlay', 'greeter', '--reason='],
        exitCodes: {64},
        stderrContains: 'expects a value',
      );
      await project.patchwork(
        ['overlay', 'greeter'],
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
      await project.patchwork(project.providerBRoot, ['patch', 'greeter']);
      project.writePrefixEdit(project.providerBRoot, 'Hello from workspace');
      await project.patchwork(project.providerBRoot, ['commit', 'greeter']);
      await project.patchwork(project.providerBRoot, ['overlay', 'greeter']);

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
    'transitive provider overlay is applied for an app that only depends on the provider',
    () async {
      final project = await OverlayProjectSandbox.create();
      addTearDown(project.dispose);

      await project.registerPrefixOverlay(
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

      await project.registerPrefixOverlay(
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

      await project.registerPrefixOverlay(
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

      await project.registerPrefixOverlay(project.providerBRoot, 'Hi');
      await project.registerPunctuationOverlay(project.providerCRoot, '?');
      await project.pubGet(project.appRoot);

      final result = await project.runApp();
      expect(result.stdout, contains('Hi, Patchwork?'));
      project.expectGreeterResolvedToAppliedOutput();
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

      await project.registerPrefixOverlay(
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

      await project.registerPrefixOverlay(project.providerBRoot, 'Hi');
      await project.registerPunctuationOverlay(project.providerCRoot, '?');
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

      await project.registerPrefixOverlay(project.providerBRoot, 'Hi');
      await project.registerPrefixOverlay(project.providerCRoot, 'Yo');
      await project.pubGet(project.appRoot);

      final result = await project.runApp(exitCodes: {1, 255});
      expect(result.stdout + result.stderr, contains('overlay.apply_failed'));
      expect(result.stdout + result.stderr, contains('provider_c'));
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
