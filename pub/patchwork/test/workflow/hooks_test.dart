@Tags(['full'])
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'project_sandbox.dart';

void main() {
  test(
    'package overlay hook no-op does not force an immediate rerun',
    () async {
      final project = await ProjectSandbox.standalone();
      addTearDown(project.dispose);

      await project.pubGet();

      final result = await project.patchworkResult(['status']);
      expect(result.stdout, contains('No patchwork packages.'));
      expect(result.stdout, isNot(contains('File modified during build')));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'auto-applies committed patches before running a standalone project',
    () async {
      final project = await ProjectSandbox.standalone();
      addTearDown(project.dispose);

      await project.writeAutoApplyAllHook();
      await project.pubGet();
      project.writeGreeterPatch('Hello from a standalone hook patch');

      await project.runApp('Hello from a standalone hook patch, Patchwork!');
      project.expectPackageResolvedTo('greeter', project.appliedDirectory.path);

      final packageConfig = File(
        p.join(project.stateRoot, '.dart_tool', 'package_config.json'),
      );
      final modified = packageConfig.lastModifiedSync();
      await _waitForDistinctTimestamp(packageConfig);
      await project.runApp('Hello from a standalone hook patch, Patchwork!');
      expect(packageConfig.lastModifiedSync(), modified);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'auto-applies committed patches before running a workspace member',
    () async {
      final project = await ProjectSandbox.workspace();
      addTearDown(project.dispose);

      await project.writeAutoApplyAllHook();
      await project.pubGet();
      project.writeGreeterPatch('Hello from a workspace hook patch');

      await project.runApp('Hello from a workspace hook patch, Patchwork!');
      project.expectPackageResolvedTo('greeter', project.appliedDirectory.path);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'auto-applies one selected package from a build hook',
    () async {
      final project = await ProjectSandbox.standalone();
      addTearDown(project.dispose);

      await project.writeAutoApplyGreeterHook();
      await project.pubGet();
      project.writeGreeterPatch('Hello from a single hook patch');

      await project.runApp('Hello from a single hook patch, Patchwork!');
      project.expectPackageResolvedTo('greeter', project.appliedDirectory.path);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

Future<void> _waitForDistinctTimestamp(File file) async {
  final suffix = DateTime.now().microsecondsSinceEpoch;
  final probe = File(
    p.join(file.parent.path, '.patchwork_timestamp_probe_${pid}_$suffix'),
  );
  try {
    probe.writeAsStringSync('0');
    final initial = probe.lastModifiedSync();
    for (var attempt = 0; attempt < 60; attempt += 1) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      probe.writeAsStringSync('$attempt');
      if (probe.lastModifiedSync() != initial) {
        return;
      }
    }
  } finally {
    if (probe.existsSync()) {
      probe.deleteSync();
    }
  }
}
