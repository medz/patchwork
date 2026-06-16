import 'dart:io';

Future<void> main() async {
  final guard = _QualityGuard(Directory.current.path);
  guard.checkTrackedFiles();
  guard.checkFacadeBoundary();
  guard.checkDocumentationText();
  await guard.run('dart', ['pub', 'get']);
  await guard.run('dart', [
    'format',
    '--output=none',
    '--set-exit-if-changed',
    'pub/patchwork/bin',
    'pub/patchwork/lib',
    'pub/patchwork/test',
    'examples/hello_patch',
  ]);
  await guard.run('dart', ['analyze'], workingDirectory: 'pub/patchwork');
  await guard.run('dart', ['test'], workingDirectory: 'pub/patchwork');
  await guard.run('dart', [
    'pub',
    'publish',
    '--dry-run',
  ], workingDirectory: 'pub/patchwork');
  await guard.runExampleSmoke();
}

final class _QualityGuard {
  const _QualityGuard(this.rootPath);

  final String rootPath;

  void checkTrackedFiles() {
    final tracked = _gitLsFiles();
    const forbiddenTrackedPaths = [
      'docs/v0.2-programmable-model.zh.md',
      'pub/patchwork/lib/src/app/',
      'pub/patchwork/lib/src/diagnostics/',
      'pub/patchwork/lib/src/session/',
      'pub/patchwork/lib/src/store/',
      'pub/patchwork/lib/src/target/',
      'pub/patchwork/test/app/',
      'pub/patchwork/test/store/',
      'pub/patchwork/test/target/',
    ];

    for (final path in tracked) {
      for (final forbidden in forbiddenTrackedPaths) {
        if (path == forbidden || path.startsWith(forbidden)) {
          throw StateError('Forbidden tracked path: $path');
        }
      }
    }

    const localDesignDoc = 'docs/v0.2-programmable-model.zh.md';
    if (File(_path(localDesignDoc)).existsSync()) {
      final ignored = Process.runSync('git', [
        'check-ignore',
        '-q',
        localDesignDoc,
      ], workingDirectory: rootPath);
      if (ignored.exitCode != 0) {
        throw StateError('$localDesignDoc must stay ignored and untracked.');
      }
    }

    final exampleReadmeType = FileSystemEntity.typeSync(
      _path('pub/patchwork/example/README.md'),
      followLinks: false,
    );
    if (exampleReadmeType == FileSystemEntityType.link) {
      throw StateError(
        'pub/patchwork/example/README.md must not be a symlink.',
      );
    }
  }

  void checkDocumentationText() {
    const scannedFiles = [
      'AGENTS.md',
      'README.md',
      'examples/README.md',
      'pub/patchwork/README.md',
      'pub/patchwork/example/README.md',
    ];
    const forbiddenSnippets = [
      'patch --commit',
      'patches/pub',
      '.dart_tool/patchwork/edit',
      '.dart_tool/patchwork/store',
      '.dart_tool/patchwork/baseline',
      'MVP',
      'edit session',
      'Patchwork session',
    ];

    for (final relativePath in scannedFiles) {
      final content = File(_path(relativePath)).readAsStringSync();
      for (final snippet in forbiddenSnippets) {
        if (content.contains(snippet)) {
          throw StateError('$relativePath contains legacy text: $snippet');
        }
      }
    }
  }

  void checkFacadeBoundary() {
    final facade = File(
      _path('pub/patchwork/lib/src/patchwork.dart'),
    ).readAsStringSync();
    const forbiddenFacadeFields = [
      'final String rootPath;',
      'final PathLayout layout;',
      'final PubResolutionReader pubResolutionReader;',
      'final PatchworkLockStore lockStore;',
      'final PackageTree packageTree;',
      'final PatchFile patchFile;',
      'final PubspecOverrides pubspecOverrides;',
    ];
    for (final field in forbiddenFacadeFields) {
      if (facade.contains(field)) {
        throw StateError('Patchwork facade exposes internal field: $field');
      }
    }
    final forbiddenFacadeGetters = [
      RegExp(r'\bPathLayout\s+get\s+[A-Za-z]'),
      RegExp(r'\bPatchworkLockStore\s+get\s+[A-Za-z]'),
      RegExp(r'\bPackageTree\s+get\s+[A-Za-z]'),
      RegExp(r'\bPatchFile\s+get\s+[A-Za-z]'),
      RegExp(r'\bPubspecOverrides\s+get\s+[A-Za-z]'),
      RegExp(r'\bPubResolutionReader\s+get\s+[A-Za-z]'),
    ];
    for (final pattern in forbiddenFacadeGetters) {
      if (pattern.hasMatch(facade)) {
        throw StateError('Patchwork facade exposes an internal getter.');
      }
    }

    final publicExports = File(
      _path('pub/patchwork/lib/patchwork.dart'),
    ).readAsStringSync();
    const forbiddenExports = [
      'src/internal/',
      'src/lock/',
      'src/patch/',
      'src/pub/',
    ];
    for (final export in forbiddenExports) {
      if (publicExports.contains(export)) {
        throw StateError('Public API exports internal module: $export');
      }
    }
  }

  Future<void> runExampleSmoke() async {
    final appPath = _path('examples/hello_patch/app');
    _deleteIfExists('$appPath/.dart_tool');
    _deleteIfExists('$appPath/.patchwork');
    _deleteIfExists('$appPath/patches');
    _deleteIfExists('$appPath/pubspec.lock');
    _deleteIfExists('$appPath/pubspec_overrides.yaml');
    _deleteIfExists('$appPath/patchwork.lock');

    await run('dart', ['pub', 'get'], workingDirectory: appPath);
    await run('dart', [
      'run',
      'patchwork',
      'doctor',
    ], workingDirectory: appPath);
    await run('dart', [
      'run',
      'patchwork',
      'patch',
      'greeter',
    ], workingDirectory: appPath);

    File(
      '$appPath/.patchwork/greeter@0.1.0/lib/greeter.dart',
    ).writeAsStringSync('''
String greeting(String name) {
  return 'Hello from a patch, \$name!';
}
''');

    await run('dart', [
      'run',
      'patchwork',
      'commit',
      'greeter',
    ], workingDirectory: appPath);
    await run('dart', [
      'run',
      'patchwork',
      'apply',
      'greeter',
    ], workingDirectory: appPath);
    await run('dart', ['pub', 'get'], workingDirectory: appPath);
    await run('dart', ['analyze'], workingDirectory: appPath);
    await run('dart', [
      'run',
      'patchwork',
      'doctor',
    ], workingDirectory: appPath);
    final app = await run('dart', [
      'run',
      'bin/app.dart',
    ], workingDirectory: appPath);
    if (!app.stdout.contains('Hello from a patch, Patchwork!')) {
      throw StateError('Example app did not use the applied patch.');
    }

    _deleteIfExists('$appPath/.dart_tool');
    _deleteIfExists('$appPath/.patchwork');
    _deleteIfExists('$appPath/patches');
    _deleteIfExists('$appPath/pubspec.lock');
    _deleteIfExists('$appPath/pubspec_overrides.yaml');
    _deleteIfExists('$appPath/patchwork.lock');
  }

  Future<_RunResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) async {
    final cwd = workingDirectory == null ? rootPath : _path(workingDirectory);
    stdout.writeln('\$ ${[executable, ...arguments].join(' ')}');
    final result = await Process.run(
      executable,
      arguments,
      workingDirectory: cwd,
    );
    if (result.stdout.toString().isNotEmpty) {
      stdout.write(result.stdout);
    }
    if (result.stderr.toString().isNotEmpty) {
      stderr.write(result.stderr);
    }
    if (result.exitCode != 0) {
      throw StateError(
        'Command failed with exit code ${result.exitCode}: '
        '${[executable, ...arguments].join(' ')}',
      );
    }
    return _RunResult(
      stdout: result.stdout.toString(),
      stderr: result.stderr.toString(),
    );
  }

  List<String> _gitLsFiles() {
    final result = Process.runSync('git', [
      'ls-files',
    ], workingDirectory: rootPath);
    if (result.exitCode != 0) {
      throw StateError('git ls-files failed: ${result.stderr}');
    }
    return result.stdout
        .toString()
        .split('\n')
        .where((line) => line.isNotEmpty)
        .toList();
  }

  String _path(String path) {
    if (path.startsWith('/')) {
      return path;
    }
    return '$rootPath/$path';
  }

  void _deleteIfExists(String path) {
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    switch (type) {
      case FileSystemEntityType.directory:
        Directory(path).deleteSync(recursive: true);
      case FileSystemEntityType.file:
      case FileSystemEntityType.link:
        File(path).deleteSync();
      case FileSystemEntityType.notFound:
      case FileSystemEntityType.pipe:
      case FileSystemEntityType.unixDomainSock:
        break;
    }
  }
}

final class _RunResult {
  const _RunResult({required this.stdout, required this.stderr});

  final String stdout;
  final String stderr;
}
