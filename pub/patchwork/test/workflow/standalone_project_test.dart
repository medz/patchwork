@Tags(['full'])
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'project_sandbox.dart';

void main() {
  test(
    'patches, applies, continues, and forces a standalone project dependency',
    () async {
      final project = await ProjectSandbox.standalone();
      addTearDown(project.dispose);

      await project.pubGet();
      await project.application(['doctor'], stdoutContains: 'No patchwork');

      await project.application(['patch', 'greeter']);
      project.writeEdit('Hello from a standalone patch');
      await project.application(['commit']);
      await project.application(['apply']);
      await project.application(
        ['patch', 'greeter'],
        exitCodes: {1},
        stderrContains: 'already has an applied Patchwork patch',
      );
      await project.application(
        ['carry', 'greeter'],
        exitCodes: {1},
        stderrContains: 'already has an applied Patchwork patch',
      );
      await project.application([
        'doctor',
      ], stdoutContains: 'applied: .dart_tool/patchwork/greeter@0.1.0');
      await project.application([
        'status',
      ], stdoutContains: 'applied: .dart_tool/patchwork/greeter@0.1.0');
      await project.application([
        'apply',
      ], stdoutContains: 'No patches need apply.');
      await project.runApp('Hello from a standalone patch, Patchwork!');

      await project.application(['undo', 'greeter']);
      await project.application(
        ['doctor'],
        exitCodes: {1},
        stdoutContains: 'action: patchwork apply greeter',
      );
      await project.runApp('Hello, Patchwork!');

      await project.application(['patch', '--continue', 'greeter']);
      expect(
        project.editFile.readAsStringSync(),
        contains('Hello from a standalone patch'),
      );
      await project.application(['patch', 'greeter']);
      expect(project.editFile.readAsStringSync(), contains('Hello, \$name!'));
      await project.application(['patch', 'greeter', '--continue']);
      expect(
        project.editFile.readAsStringSync(),
        contains('Hello from a standalone patch'),
      );
      await project.application(['commit', 'greeter']);

      project.writeManualOverride();
      await project.application(
        ['apply', 'greeter'],
        exitCodes: {1},
        stderrContains: 'already has a dependency override',
      );
      expect(
        project.overrideFile.readAsStringSync(),
        contains('manual_greeter'),
      );
      expect(project.appliedDirectory.existsSync(), isFalse);
      await project.application(
        ['doctor'],
        exitCodes: {1},
        stdoutContains: 'already has a dependency override',
      );
      await project.application([
        'status',
      ], stdoutContains: 'already has a dependency override');

      project.overrideFile.deleteSync();
      await project.pubGet();
      await project.application(['patch', 'greeter']);
      await project.application(['patch', 'greeter']);
      expect(project.editFile.readAsStringSync(), contains('Hello, \$name!'));
      project.editFile.writeAsStringSync('dirty edit\n');
      await project.application(
        ['patch', 'greeter'],
        exitCodes: {1},
        stderrContains: 'uncommitted changes',
      );
      await project.application(
        ['patch', 'greeter', '--force', '--continue', '9.9.9'],
        exitCodes: {1},
        stderrContains: 'Patch file does not exist',
      );
      expect(project.editFile.readAsStringSync(), 'dirty edit\n');
      await project.application(['patch', 'greeter', '--force']);
      expect(project.editFile.readAsStringSync(), contains('Hello, \$name!'));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'can continue an old version patch after the dependency version changes',
    () async {
      final project = await ProjectSandbox.standalone();
      addTearDown(project.dispose);

      await project.pubGet();
      await project.application(['patch', 'greeter']);
      project.writeEdit('Hello from a carried patch');
      await project.application(['commit', 'greeter']);

      project.updateGreeterPackage(
        version: '0.1.1',
        greeting: 'Hello, \$name!',
      );
      await project.pubGet();

      await project.application(['patch', 'greeter', '--continue', '0.1.0']);
      expect(
        project.editFileFor('0.1.1').readAsStringSync(),
        contains('Hello from a carried patch'),
      );
      project.editDirectoryFor('0.1.1').deleteSync(recursive: true);
      await project.application(
        ['doctor'],
        exitCodes: {1},
        stdoutContains: 'targets "greeter@0.1.0"',
      );

      await project.application(['patch', 'greeter', '--continue', '0.1.0']);
      expect(
        project.editFileFor('0.1.1').readAsStringSync(),
        contains('Hello from a carried patch'),
      );
      project.editDirectoryFor('0.1.1').deleteSync(recursive: true);

      File(
        p.join(project.stateRoot, 'patches', 'greeter@0.1.0.patch'),
      ).writeAsStringSync('tampered\n');
      await project.application(
        ['patch', 'greeter', '--continue', '0.1.0'],
        exitCodes: {1},
        stderrContains: 'Could not apply patch',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'carries a unique stale patch into the current standalone dependency edit',
    () async {
      final project = await ProjectSandbox.standalone();
      addTearDown(project.dispose);

      await project.pubGet();
      await project.application(['patch', 'greeter']);
      project.writeEdit('Hello from a carried command patch');
      await project.application(['commit', 'greeter']);

      project.updateGreeterPackage(
        version: '0.1.1',
        greeting: 'Hello, \$name!',
      );
      await project.pubGet();

      final result = await project.applicationResult(['carry', 'greeter']);
      expect(result.stdout, contains('Created carry edit'));
      expect(result.stdout, contains('Applied patches/greeter@0.1.0.patch'));
      expect(
        result.stdout,
        contains('Review the edit and run patchwork commit greeter.'),
      );
      expect(
        project.editFileFor('0.1.1').readAsStringSync(),
        contains('Hello from a carried command patch'),
      );
      expect(project.editManifestFor('0.1.1').existsSync(), isTrue);
      expect(
        File(
          p.join(
            project.editDirectoryFor('0.1.1').path,
            '.patchwork',
            'source',
            'lib',
            'greeter.dart',
          ),
        ).readAsStringSync(),
        contains('Hello, \$name!'),
      );

      await project.application([
        'commit',
        'greeter',
      ], stdoutContains: 'Wrote patches/greeter@0.1.1.patch.');
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'requires --from when multiple standalone stale patches exist',
    () async {
      final project = await ProjectSandbox.standalone();
      addTearDown(project.dispose);

      project.writeResolution();
      project.writeGreeterPatch('Hello from the first stale patch');
      project.writeGreeterPatch(
        'Hello from the second stale patch',
        version: '0.1.1',
      );
      project.updateGreeterPackage(
        version: '0.1.2',
        greeting: 'Hello, \$name!',
      );
      project.writeResolution(greeterVersion: '0.1.2');

      final ambiguous = await project.applicationResult(
        ['carry', 'greeter'],
        exitCodes: {1},
      );
      expect(ambiguous.stderr, contains('More than one stale patch'));
      expect(ambiguous.stderr, contains('Pass --from with one of:'));
      expect(ambiguous.stderr, contains('0.1.0'));
      expect(ambiguous.stderr, contains('0.1.1'));

      await project.application(['carry', 'greeter', '--from', '0.1.1']);
      expect(
        project.editFileFor('0.1.2').readAsStringSync(),
        contains('Hello from the second stale patch'),
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'leaves a repairable edit when carry cannot apply the stale patch',
    () async {
      final project = await ProjectSandbox.standalone();
      addTearDown(project.dispose);

      project.writeResolution();
      project.writeGreeterPatch('Hello from a broken stale patch');
      project.updateGreeterPackage(
        version: '0.1.1',
        greeting: 'Hello, \$name!',
      );
      project.writeResolution(greeterVersion: '0.1.1');
      File(
        p.join(project.stateRoot, 'patches', 'greeter@0.1.0.patch'),
      ).writeAsStringSync('tampered\n');

      final result = await project.applicationResult(
        ['carry', 'greeter'],
        exitCodes: {1},
      );
      expect(result.stderr, contains('Could not apply patch'));
      expect(result.stderr, contains('.patchwork/greeter@0.1.1'));
      expect(result.stderr, contains('patchwork commit greeter'));
      expect(project.editDirectoryFor('0.1.1').existsSync(), isTrue);
      expect(project.editManifestFor('0.1.1').existsSync(), isTrue);
      expect(
        project.editFileFor('0.1.1').readAsStringSync(),
        contains('Hello, \$name!'),
      );
      expect(
        File(
          p.join(project.stateRoot, 'patches', 'greeter@0.1.1.patch'),
        ).existsSync(),
        isFalse,
      );
      expect(project.appliedDirectoryFor('0.1.1').existsSync(), isFalse);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'partial carry fails when git cannot produce reject repair material',
    () async {
      final project = await ProjectSandbox.standalone();
      addTearDown(project.dispose);

      project.writeResolution();
      project.writeGreeterPatch('Hello from a broken stale patch');
      project.updateGreeterPackage(
        version: '0.1.1',
        greeting: 'Hello, \$name!',
      );
      project.writeResolution(greeterVersion: '0.1.1');
      File(
        p.join(project.stateRoot, 'patches', 'greeter@0.1.0.patch'),
      ).writeAsStringSync('tampered\n');

      final result = await project.applicationResult(
        ['carry', 'greeter', '--partial'],
        exitCodes: {1},
      );
      expect(result.stderr, contains('Could not apply patch'));
      expect(result.stderr, contains('No valid patches in input'));
      expect(project.editDirectoryFor('0.1.1').existsSync(), isFalse);
      expect(project.appliedDirectoryFor('0.1.1').existsSync(), isFalse);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'partially carries applicable hunks into a repairable edit',
    () async {
      final project = await ProjectSandbox.standalone();
      addTearDown(project.dispose);

      File(
        p.join(project.greeterRoot, 'lib', 'extra.dart'),
      ).writeAsStringSync("const extra = 'old';\n");
      File(
        p.join(project.greeterRoot, 'lib', 'greeter.dart.rej'),
      ).writeAsStringSync('existing reject-suffixed source file\n');
      File(
        p.join(project.greeterRoot, 'lib', 'quote"name.dart'),
      ).writeAsStringSync("const quoted = 'old';\n");
      File(
        p.join(project.greeterRoot, 'lib', 'quote"name.dart.rej'),
      ).writeAsStringSync('existing quoted reject source file\n');
      File(
        p.join(project.greeterRoot, 'lib', 'mode.dart'),
      ).writeAsStringSync("const mode = 'old';\n");
      final executableReject = File(
        p.join(project.greeterRoot, 'lib', 'mode.dart.rej'),
      )..writeAsStringSync('existing executable reject source file\n');
      _chmod(executableReject.path, '755');
      File(
        p.join(project.greeterRoot, 'lib', 'link.dart'),
      ).writeAsStringSync("const link = 'old';\n");
      File(
        p.join(project.greeterRoot, 'lib', 'link-target.txt'),
      ).writeAsStringSync('existing symlink target\n');
      Link(
        p.join(project.greeterRoot, 'lib', 'link.dart.rej'),
      ).createSync('link-target.txt');
      project.writeResolution();
      final stalePatch = File(
        p.join(project.stateRoot, 'patches', 'greeter@0.1.0.patch'),
      );
      stalePatch.parent.createSync(recursive: true);
      stalePatch.writeAsStringSync(r'''
diff --git a/lib/extra.dart b/lib/extra.dart
--- a/lib/extra.dart
+++ b/lib/extra.dart
@@ -1 +1 @@
-const extra = 'old';
+const extra = 'carried';
diff --git a/lib/notes.rej b/lib/notes.rej
new file mode 100644
--- /dev/null
+++ b/lib/notes.rej
@@ -0,0 +1 @@
+legitimate reject-suffixed source file
diff --git a/lib/greeter.dart b/lib/greeter.dart
--- a/lib/greeter.dart
+++ b/lib/greeter.dart
@@ -1,3 +1,3 @@
 String greeting(String name) {
-  return 'Hello, $name!';
+  return 'Hello from partial stale patch, $name!';
 }
diff --git a/lib/quote"name.dart b/lib/quote"name.dart
--- a/lib/quote"name.dart
+++ b/lib/quote"name.dart
@@ -1 +1 @@
-const quoted = 'old';
+const quoted = 'carried';
diff --git a/lib/mode.dart b/lib/mode.dart
--- a/lib/mode.dart
+++ b/lib/mode.dart
@@ -1 +1 @@
-const mode = 'old';
+const mode = 'carried';
diff --git a/lib/link.dart b/lib/link.dart
--- a/lib/link.dart
+++ b/lib/link.dart
@@ -1 +1 @@
-const link = 'old';
+const link = 'carried';
''');

      project.updateGreeterPackage(
        version: '0.1.1',
        greeting: 'Hello from upstream, \$name!',
      );
      File(
        p.join(project.greeterRoot, 'lib', 'quote"name.dart'),
      ).writeAsStringSync("const quoted = 'upstream';\n");
      File(
        p.join(project.greeterRoot, 'lib', 'mode.dart'),
      ).writeAsStringSync("const mode = 'upstream';\n");
      File(
        p.join(project.greeterRoot, 'lib', 'link.dart'),
      ).writeAsStringSync("const link = 'upstream';\n");
      project.writeResolution(greeterVersion: '0.1.1');

      final result = await project.applicationResult([
        'carry',
        'greeter',
        '--partial',
      ]);
      expect(result.stdout, contains('Created partial carry edit'));
      expect(
        result.stdout,
        contains(
          'Wrote conflict log .patchwork/greeter@0.1.1/.patchwork/partial-repair.log.',
        ),
      );
      expect(
        result.stdout,
        contains('Moved rejects under .patchwork/rejects/.'),
      );
      expect(
        project.editFileFor('0.1.1').readAsStringSync(),
        contains('Hello from upstream, \$name!'),
      );
      expect(
        File(
          p.join(project.editDirectoryFor('0.1.1').path, 'lib', 'extra.dart'),
        ).readAsStringSync(),
        contains("const extra = 'carried';"),
      );
      expect(
        File(
          p.join(project.editDirectoryFor('0.1.1').path, 'lib', 'notes.rej'),
        ).readAsStringSync(),
        contains('legitimate reject-suffixed source file'),
      );
      expect(
        File(
          p.join(
            project.editDirectoryFor('0.1.1').path,
            'lib',
            'greeter.dart.rej',
          ),
        ).readAsStringSync(),
        'existing reject-suffixed source file\n',
      );
      expect(
        File(
          p.join(
            project.editDirectoryFor('0.1.1').path,
            'lib',
            'quote"name.dart',
          ),
        ).readAsStringSync(),
        "const quoted = 'upstream';\n",
      );
      expect(
        File(
          p.join(
            project.editDirectoryFor('0.1.1').path,
            'lib',
            'quote"name.dart.rej',
          ),
        ).readAsStringSync(),
        'existing quoted reject source file\n',
      );
      final restoredExecutableReject = File(
        p.join(project.editDirectoryFor('0.1.1').path, 'lib', 'mode.dart.rej'),
      );
      expect(
        restoredExecutableReject.readAsStringSync(),
        'existing executable reject source file\n',
      );
      if (!Platform.isWindows) {
        expect(_permissionBits(restoredExecutableReject), 0x1ed);
      }
      expect(
        Link(
          p.join(
            project.editDirectoryFor('0.1.1').path,
            'lib',
            'link.dart.rej',
          ),
        ).targetSync(),
        'link-target.txt',
      );

      final repairLog = File(
        p.join(
          project.editDirectoryFor('0.1.1').path,
          '.patchwork',
          'partial-repair.log',
        ),
      );
      expect(repairLog.existsSync(), isTrue);
      final logContent = repairLog.readAsStringSync();
      expect(logContent, contains('patch: patches/greeter@0.1.0.patch'));
      expect(logContent, contains('gitExitCode: 1'));
      expect(logContent, contains('- .patchwork/rejects/lib/greeter.dart.rej'));
      expect(
        logContent,
        contains('- .patchwork/rejects/lib/quote"name.dart.rej'),
      );
      expect(logContent, contains('- .patchwork/rejects/lib/mode.dart.rej'));
      expect(logContent, contains('- .patchwork/rejects/lib/link.dart.rej'));
      expect(logContent, isNot(contains(project.root.path)));
      expect(
        File(
          p.join(
            project.editDirectoryFor('0.1.1').path,
            '.patchwork',
            'rejects',
            'lib',
            'greeter.dart.rej',
          ),
        ).readAsStringSync(),
        contains('Hello from partial stale patch'),
      );
      expect(
        File(
          p.join(
            project.editDirectoryFor('0.1.1').path,
            '.patchwork',
            'rejects',
            'lib',
            'quote"name.dart.rej',
          ),
        ).readAsStringSync(),
        contains("const quoted = 'carried';"),
      );
      expect(
        File(
          p.join(
            project.editDirectoryFor('0.1.1').path,
            '.patchwork',
            'rejects',
            'lib',
            'mode.dart.rej',
          ),
        ).readAsStringSync(),
        contains("const mode = 'carried';"),
      );
      expect(
        File(
          p.join(
            project.editDirectoryFor('0.1.1').path,
            '.patchwork',
            'rejects',
            'lib',
            'link.dart.rej',
          ),
        ).readAsStringSync(),
        contains("const link = 'carried';"),
      );
      expect(
        File(
          p.join(
            project.editDirectoryFor('0.1.1').path,
            '.patchwork',
            'rejects',
            'lib',
            'notes.rej',
          ),
        ).existsSync(),
        isFalse,
      );
      expect(
        File(
          p.join(project.stateRoot, 'patches', 'greeter@0.1.1.patch'),
        ).existsSync(),
        isFalse,
      );
      expect(project.appliedDirectoryFor('0.1.1').existsSync(), isFalse);

      project.editFileFor('0.1.1').writeAsStringSync('''
String greeting(String name) {
  return 'Hello from partial stale patch, \$name!';
}
''');
      File(
        p.join(
          project.editDirectoryFor('0.1.1').path,
          'lib',
          'quote"name.dart',
        ),
      ).writeAsStringSync("const quoted = 'carried';\n");
      File(
        p.join(project.editDirectoryFor('0.1.1').path, 'lib', 'link.dart'),
      ).writeAsStringSync("const link = 'carried';\n");
      File(
        p.join(project.editDirectoryFor('0.1.1').path, 'lib', 'mode.dart'),
      ).writeAsStringSync("const mode = 'carried';\n");
      await project.application([
        'commit',
        'greeter',
      ], stdoutContains: 'Wrote patches/greeter@0.1.1.patch.');
      final committedPatch = File(
        p.join(project.stateRoot, 'patches', 'greeter@0.1.1.patch'),
      ).readAsStringSync();
      expect(committedPatch, contains('lib/extra.dart'));
      expect(committedPatch, contains('lib/notes.rej'));
      expect(committedPatch, contains('quote\\"name.dart'));
      expect(committedPatch, contains('lib/link.dart'));
      expect(committedPatch, contains('lib/mode.dart'));
      expect(committedPatch, contains('Hello from partial stale patch'));
      expect(committedPatch, isNot(contains('partial-repair.log')));
      expect(committedPatch, isNot(contains('greeter.dart.rej')));
      expect(committedPatch, isNot(contains('link.dart.rej')));
      expect(committedPatch, isNot(contains('mode.dart.rej')));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'can continue a same-version patch after the dependency source changes',
    () async {
      final project = await ProjectSandbox.standalone();
      addTearDown(project.dispose);

      await project.pubGet();
      await project.application(['patch', 'greeter']);
      project.writeEdit('Hello from a same-version patch');
      await project.application(['commit', 'greeter']);

      File(
        p.join(project.greeterRoot, 'lib', 'upstream.dart'),
      ).writeAsStringSync("const upstream = 'changed';\n");
      await project.pubGet();

      await project.application(['patch', 'greeter']);
      expect(
        File(
          p.join(
            project.editDirectoryFor('0.1.0').path,
            'lib',
            'upstream.dart',
          ),
        ).existsSync(),
        isTrue,
      );
      project.editDirectoryFor('0.1.0').deleteSync(recursive: true);

      await project.application(['patch', 'greeter', '--continue', '0.1.0']);
      expect(
        project.editFileFor('0.1.0').readAsStringSync(),
        contains('Hello from a same-version patch'),
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'commit removes an unchanged edit without leaving a package record',
    () async {
      final project = await ProjectSandbox.standalone();
      addTearDown(project.dispose);

      await project.pubGet();
      await project.application(['patch', 'greeter']);
      await project.application([
        'commit',
        'greeter',
      ], stdoutContains: 'has no changes');

      expect(project.editDirectoryFor('0.1.0').existsSync(), isFalse);
      await project.application(['doctor'], stdoutContains: 'No patchwork');
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'commit leaves stale patch files when upstream contains the fix',
    () async {
      final project = await ProjectSandbox.standalone();
      addTearDown(project.dispose);

      await project.pubGet();
      await project.application(['patch', 'greeter']);
      project.writeEdit('Hello from upstream');
      await project.application(['commit', 'greeter']);
      final oldPatch = File(
        p.join(project.stateRoot, 'patches', 'greeter@0.1.0.patch'),
      );
      expect(oldPatch.existsSync(), isTrue);

      project.updateGreeterPackage(
        version: '0.1.1',
        greeting: 'Hello from upstream, \$name!',
      );
      await project.pubGet();
      await project.application(['patch', 'greeter']);
      await project.application([
        'commit',
        'greeter',
      ], stdoutContains: 'has no changes');

      expect(oldPatch.existsSync(), isTrue);
      await project.application(
        ['doctor'],
        exitCodes: {1},
        stdoutContains: 'targets "greeter@0.1.0"',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

void _chmod(String path, String mode) {
  if (Platform.isWindows) {
    return;
  }

  final result = Process.runSync('chmod', [mode, path]);
  if (result.exitCode != 0) {
    fail('${result.stderr}${result.stdout}');
  }
}

int _permissionBits(File file) => file.statSync().mode & 0x1ff;
