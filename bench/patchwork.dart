import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:hooks/hooks.dart';
import 'package:path/path.dart' as p;
import 'package:patchwork/src/apply/activation.dart';
import 'package:patchwork/src/edit/model.dart';
import 'package:patchwork/src/overlay/inspector.dart';
import 'package:patchwork/src/patch/package_tree.dart';
import 'package:patchwork/src/pub/source.dart';
import 'package:patchwork/src/pub/dependency_overrides.dart';
import 'package:patchwork/src/pub/overrides.dart';
import 'package:patchwork/src/state/applied_marker.dart';
import 'package:patchwork/src/state/applied_path_policy.dart';
import 'package:patchwork/src/state/dependency_override_state.dart';
import 'package:patchwork/src/state/path_layout.dart';
import 'package:patchwork/src/overlay/hook.dart' as overlay_hook;
import 'package:patchwork/src/patch/file.dart';
import 'package:patchwork/src/patchwork.dart';

Future<void> main(List<String> arguments) async {
  late final _Options options;
  try {
    options = _Options.parse(arguments);
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    stderr.write(_usage);
    exitCode = 64;
    return;
  }

  if (options.showHelp) {
    stdout.write(_usage);
    return;
  }

  final benchmarks = _benchmarks();
  final selected = options.caseName == null
      ? benchmarks
      : benchmarks
            .where((benchmark) => benchmark.group == options.caseName)
            .toList();
  if (selected.isEmpty) {
    stderr.writeln('No benchmarks match --case ${options.caseName}.');
    exitCode = 64;
    return;
  }

  final results = <_BenchmarkResult>[];
  for (final benchmark in selected) {
    if (!options.json) {
      stdout.writeln('Running ${benchmark.group}/${benchmark.name}...');
    }
    results.add(await benchmark.measure());
  }

  if (options.json) {
    stdout.writeln(
      const JsonEncoder.withIndent('  ').convert({
        'schemaVersion': 1,
        'benchmarks': [for (final result in results) result.toJson()],
      }),
    );
  } else {
    _printTable(results);
  }
}

List<_Benchmark> _benchmarks() {
  return [
    _Benchmark(
      group: 'package-tree',
      name: 'sha256 small tree',
      iterations: 40,
      prepare: () {
        final fixture = _PackageTreeFixture.create(
          package: 'tree_small',
          files: 48,
          bytesPerFile: 512,
        );
        return _Prepared(
          run: () {
            final digest = const PackageTree().sha256Of(fixture.root.path);
            if (digest.isEmpty) {
              throw StateError('empty digest');
            }
          },
          cleanup: fixture.dispose,
        );
      },
    ),
    _Benchmark(
      group: 'package-tree',
      name: 'copy medium tree',
      iterations: 25,
      prepare: () {
        final fixture = _PackageTreeFixture.create(
          package: 'tree_medium',
          files: 160,
          bytesPerFile: 1024,
        );
        var runIndex = 0;
        return _Prepared(
          run: () {
            final output = Directory(
              p.join(fixture.scratch.path, 'copy_${runIndex++}'),
            );
            const PackageTree().copy(fixture.root.path, output.path);
          },
          cleanup: fixture.dispose,
        );
      },
    ),
    _Benchmark(
      group: 'patch-file',
      name: 'build multi-file patch',
      iterations: 18,
      prepare: () {
        final fixture = _PatchFileFixture.create(files: 80, changedFiles: 16);
        return _Prepared(
          run: () {
            final patch = const PatchFile().build(
              sourcePath: fixture.source.path,
              editPath: fixture.edit.path,
            );
            if (!patch.contains('diff --git')) {
              throw StateError('patch was not generated');
            }
          },
          cleanup: fixture.dispose,
        );
      },
    ),
    _Benchmark(
      group: 'patch-file',
      name: 'validate multi-file patch',
      iterations: 30,
      prepare: () {
        final fixture = _PatchFileFixture.create(files: 80, changedFiles: 16);
        final patch = const PatchFile().build(
          sourcePath: fixture.source.path,
          editPath: fixture.edit.path,
        );
        return _Prepared(
          run: () {
            const PatchFile().validate(
              sourcePath: fixture.source.path,
              patchContent: patch,
            );
          },
          cleanup: fixture.dispose,
        );
      },
    ),
    _Benchmark(
      group: 'patch-file',
      name: 'apply multi-file patch',
      iterations: 25,
      prepare: () {
        final fixture = _PatchFileFixture.create(files: 80, changedFiles: 16);
        final patch = const PatchFile().build(
          sourcePath: fixture.source.path,
          editPath: fixture.edit.path,
        );
        var runIndex = 0;
        return _Prepared(
          run: () {
            final output = Directory(
              p.join(fixture.scratch.path, 'apply_${runIndex++}'),
            )..createSync(recursive: true);
            const PackageTree().copy(fixture.source.path, output.path);
            const PatchFile().apply(
              packagePath: output.path,
              patchContent: patch,
            );
          },
          cleanup: fixture.dispose,
        );
      },
    ),
    _Benchmark(
      group: 'patchwork-workflow',
      name: 'patch commit apply undo',
      iterations: 12,
      freshFixture: true,
      prepare: () {
        final fixture = _PatchworkFixture.create(files: 72);
        return _Prepared(
          run: () {
            final patchwork = Patchwork.open(fixture.appRoot);
            patchwork.patch('greeter');
            fixture.editGreeter('Hello from benchmark');
            final write = patchwork.commit('greeter');
            if (write.status != PatchWriteStatus.written) {
              throw StateError('patch was not written');
            }
            patchwork.apply('greeter');
            patchwork.undo('greeter');
          },
          cleanup: fixture.dispose,
        );
      },
    ),
    _Benchmark(
      group: 'inventory',
      name: 'layout and marker scan',
      iterations: 80,
      prepare: () {
        final fixture = _InventoryFixture.create(packages: 120);
        return _Prepared(
          run: () {
            final layout = PathLayout(fixture.root.path);
            final edits = layout.editDirectories();
            final patches = layout.patchFiles();
            final applied = layout.appliedDirectories();
            final markers = AppliedMarkerStore(layout: layout).readAll();
            if (edits.length != 120 ||
                patches.length != 120 ||
                applied.length != 120 ||
                markers.length != 120) {
              throw StateError('inventory scan missed entries');
            }
          },
          cleanup: fixture.dispose,
        );
      },
    ),
    _Benchmark(
      group: 'activation',
      name: 'activate packages with existing markers',
      iterations: 12,
      freshFixture: true,
      prepare: () {
        final fixture = _ActivationFixture.create(
          existingPackages: 80,
          pendingPackages: 8,
        );
        return _Prepared(
          run: fixture.activatePending,
          cleanup: fixture.dispose,
        );
      },
    ),
    _Benchmark(
      group: 'inventory',
      name: 'patchwork inspect state',
      iterations: 45,
      prepare: () {
        final fixture = _InventoryFixture.create(packages: 80);
        return _Prepared(
          run: () {
            final state = Patchwork.open(fixture.root.path).inspect();
            if (state.packages.length != 80) {
              throw StateError('inspect missed packages');
            }
          },
          cleanup: fixture.dispose,
        );
      },
    ),
    _Benchmark(
      group: 'overlay',
      name: 'inspect multiple providers',
      iterations: 35,
      prepare: () {
        final fixture = _OverlayFixture.create(providers: 8);
        return _Prepared(
          run: () {
            final inspection = OverlayInspector(
              rootPath: fixture.root.path,
              layout: PathLayout(fixture.root.path),
            ).inspect();
            if (inspection.providers.length != 8 ||
                inspection.targets.single.contributions.length != 8) {
              throw StateError('overlay inspection missed providers');
            }
          },
          cleanup: fixture.dispose,
        );
      },
    ),
    _Benchmark(
      group: 'overlay',
      name: 'compose multiple providers',
      iterations: 14,
      prepare: () {
        final fixture = _OverlayFixture.create(providers: 4);
        return _Prepared(
          run: () async {
            final output = BuildOutputBuilder();
            await overlay_hook.applyPackageOverlaysFromPackageConfig(
              p.join(fixture.root.path, '.dart_tool', 'package_config.json'),
              output,
            );
            final generated = File(
              p.join(
                fixture.root.path,
                '.dart_tool',
                'patchwork',
                'greeter@0.1.0',
                'lib',
                'src',
                'file_3.dart',
              ),
            );
            if (!generated.readAsStringSync().contains('overlay_3')) {
              throw StateError('overlay output was not composed');
            }
          },
          cleanup: fixture.dispose,
        );
      },
    ),
  ];
}

final class _Options {
  const _Options({this.caseName, required this.json, required this.showHelp});

  final String? caseName;
  final bool json;
  final bool showHelp;

  static _Options parse(List<String> arguments) {
    String? caseName;
    var json = false;
    var showHelp = false;
    for (var index = 0; index < arguments.length; index += 1) {
      final argument = arguments[index];
      switch (argument) {
        case '--json':
          json = true;
        case '--help' || '-h':
          showHelp = true;
        case '--case':
          if (index + 1 >= arguments.length) {
            throw const FormatException('--case expects a value.');
          }
          caseName = arguments[++index];
        default:
          if (argument.startsWith('--case=')) {
            caseName = argument.substring('--case='.length);
          } else {
            throw FormatException('Unknown option: $argument');
          }
      }
    }
    return _Options(caseName: caseName, json: json, showHelp: showHelp);
  }
}

const _usage = '''
Usage: dart bench/patchwork.dart [options]

Options:
  --case <name>  Run one benchmark group.
  --json         Print machine-readable JSON.
  -h, --help     Print this help.
''';

final class _Benchmark {
  const _Benchmark({
    required this.group,
    required this.name,
    required this.iterations,
    this.freshFixture = false,
    required this.prepare,
  });

  final String group;
  final String name;
  final int iterations;
  final bool freshFixture;
  final _Prepared Function() prepare;

  Future<_BenchmarkResult> measure() async {
    final samples = <int>[];
    if (freshFixture) {
      for (var index = 0; index < iterations + 2; index += 1) {
        final prepared = prepare();
        try {
          samples.addAll(await _measureRun(prepared, collect: index >= 2));
        } finally {
          prepared.cleanup();
        }
      }
    } else {
      final prepared = prepare();
      try {
        for (var index = 0; index < iterations + 2; index += 1) {
          samples.addAll(await _measureRun(prepared, collect: index >= 2));
        }
      } finally {
        prepared.cleanup();
      }
    }
    samples.sort();
    return _BenchmarkResult(
      group: group,
      name: name,
      iterations: iterations,
      medianMicros: samples[samples.length ~/ 2],
      minMicros: samples.first,
      maxMicros: samples.last,
    );
  }

  Future<List<int>> _measureRun(
    _Prepared prepared, {
    required bool collect,
  }) async {
    final stopwatch = Stopwatch()..start();
    await prepared.run();
    stopwatch.stop();
    return collect ? [stopwatch.elapsedMicroseconds] : const [];
  }
}

final class _Prepared {
  const _Prepared({required this.run, required this.cleanup});

  final FutureOr<void> Function() run;
  final void Function() cleanup;
}

final class _BenchmarkResult {
  const _BenchmarkResult({
    required this.group,
    required this.name,
    required this.iterations,
    required this.medianMicros,
    required this.minMicros,
    required this.maxMicros,
  });

  final String group;
  final String name;
  final int iterations;
  final int medianMicros;
  final int minMicros;
  final int maxMicros;

  Map<String, Object?> toJson() {
    return {
      'group': group,
      'name': name,
      'iterations': iterations,
      'medianMicros': medianMicros,
      'minMicros': minMicros,
      'maxMicros': maxMicros,
    };
  }
}

void _printTable(List<_BenchmarkResult> results) {
  stdout.writeln('');
  stdout.writeln('| group | benchmark | iterations | median | min | max |');
  stdout.writeln('| --- | --- | ---: | ---: | ---: | ---: |');
  for (final result in results) {
    stdout.writeln(
      '| ${result.group} | ${result.name} | ${result.iterations} | '
      '${_formatMicros(result.medianMicros)} | '
      '${_formatMicros(result.minMicros)} | '
      '${_formatMicros(result.maxMicros)} |',
    );
  }
}

String _formatMicros(int micros) {
  if (micros < 1000) {
    return '${micros}us';
  }
  final millis = micros / 1000;
  if (millis < 1000) {
    return '${millis.toStringAsFixed(2)}ms';
  }
  return '${(millis / 1000).toStringAsFixed(2)}s';
}

final class _PackageTreeFixture {
  const _PackageTreeFixture({required this.root, required this.scratch});

  final Directory root;
  final Directory scratch;

  static _PackageTreeFixture create({
    required String package,
    required int files,
    required int bytesPerFile,
  }) {
    final temp = Directory.systemTemp.createTempSync('patchwork_bench_tree_');
    final root = Directory(p.join(temp.path, package));
    _writePackageTree(root.path, package, files, bytesPerFile);
    return _PackageTreeFixture(
      root: root,
      scratch: Directory(p.join(temp.path, 'scratch'))..createSync(),
    );
  }

  void dispose() {
    final tempRoot = root.parent;
    if (tempRoot.existsSync()) {
      tempRoot.deleteSync(recursive: true);
    }
  }
}

final class _PatchFileFixture {
  const _PatchFileFixture({
    required this.root,
    required this.source,
    required this.edit,
    required this.scratch,
  });

  final Directory root;
  final Directory source;
  final Directory edit;
  final Directory scratch;

  static _PatchFileFixture create({
    required int files,
    required int changedFiles,
  }) {
    final root = Directory.systemTemp.createTempSync('patchwork_bench_patch_');
    final source = Directory(p.join(root.path, 'source'));
    final edit = Directory(p.join(root.path, 'edit'));
    _writePackageTree(source.path, 'greeter', files, 768);
    const PackageTree().copy(source.path, edit.path);
    for (var index = 0; index < changedFiles; index += 1) {
      final file = File(p.join(edit.path, 'lib', 'src', 'file_$index.dart'));
      file.writeAsStringSync('${file.readAsStringSync()}\n// changed $index\n');
    }
    return _PatchFileFixture(
      root: root,
      source: source,
      edit: edit,
      scratch: Directory(p.join(root.path, 'scratch'))..createSync(),
    );
  }

  void dispose() {
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  }
}

final class _PatchworkFixture {
  const _PatchworkFixture({
    required this.root,
    required this.appRoot,
    required this.greeterRoot,
  });

  final Directory root;
  final String appRoot;
  final String greeterRoot;

  static _PatchworkFixture create({required int files}) {
    final root = Directory.systemTemp.createTempSync(
      'patchwork_bench_workflow_',
    );
    final appRoot = p.join(root.path, 'app');
    final greeterRoot = p.join(root.path, 'packages', 'greeter');
    _writeAppPackage(appRoot, greeterPath: '../packages/greeter');
    _writePackageTree(greeterRoot, 'greeter', files, 512);
    _writePubResolution(
      rootPath: appRoot,
      rootPackage: 'bench_app',
      dependencies: {'greeter': greeterRoot},
    );
    return _PatchworkFixture(
      root: root,
      appRoot: appRoot,
      greeterRoot: greeterRoot,
    );
  }

  void editGreeter(String message) {
    File(
      p.join(appRoot, '.patchwork', 'greeter@0.1.0', 'lib', 'greeter.dart'),
    ).writeAsStringSync('''
String greeting(String name) {
  return '$message, \$name!';
}
''');
  }

  void dispose() {
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  }
}

final class _InventoryFixture {
  const _InventoryFixture(this.root);

  final Directory root;

  static _InventoryFixture create({required int packages}) {
    final root = Directory.systemTemp.createTempSync(
      'patchwork_bench_inventory_',
    );
    _writeAppPackage(
      root.path,
      package: 'inventory_app',
      greeterPath: 'packages/package_0',
    );
    final dependencyRoots = <String, String>{};
    final layout = PathLayout(root.path);
    for (var index = 0; index < packages; index += 1) {
      final package = 'package_$index';
      final version = '0.1.0';
      final packageRoot = p.join(root.path, 'packages', package);
      dependencyRoots[package] = packageRoot;
      _writePackageTree(packageRoot, package, 6, 128);
      File(layout.patchPath(package, version))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(_prefixPatch(package, 'inventory_$index'));
      final edit = Directory(layout.editPath(package, version))
        ..createSync(recursive: true);
      File(p.join(edit.path, 'pubspec.yaml')).writeAsStringSync('''
name: $package
version: $version
publish_to: none
environment:
  sdk: ^3.12.0
''');
      final applied = Directory(layout.appliedPath(package, version));
      _writePackageTree(applied.path, package, 4, 128);
      AppliedMarkerStore(layout: layout).write(
        AppliedMarker(
          package: package,
          version: version,
          patchSha256: 'sha-$index',
          path: layout.relativeAppliedPath(package, version),
          source: PackageSource(
            type: 'path',
            sha256: 'source-$index',
            fields: const {},
          ),
        ),
      );
    }
    _writePubResolution(
      rootPath: root.path,
      rootPackage: 'inventory_app',
      dependencies: dependencyRoots,
    );
    return _InventoryFixture(root);
  }

  void dispose() {
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  }
}

final class _ActivationFixture {
  const _ActivationFixture({
    required this.root,
    required this.layout,
    required this.markerStore,
    required this.pendingPackages,
  });

  final Directory root;
  final PathLayout layout;
  final AppliedMarkerStore markerStore;
  final List<String> pendingPackages;

  static _ActivationFixture create({
    required int existingPackages,
    required int pendingPackages,
  }) {
    final root = Directory.systemTemp.createTempSync(
      'patchwork_bench_activation_',
    );
    _writeAppPackage(
      root.path,
      package: 'activation_app',
      greeterPath: 'packages/greeter',
    );
    final layout = PathLayout(root.path);
    final markerStore = AppliedMarkerStore(layout: layout);
    for (var index = 0; index < existingPackages; index += 1) {
      final package = 'existing_$index';
      const version = '0.1.0';
      Directory(
        layout.appliedPath(package, version),
      ).createSync(recursive: true);
      markerStore.write(
        AppliedMarker(
          package: package,
          version: version,
          patchSha256: 'patch-$index',
          path: layout.relativeAppliedPath(package, version),
          source: PackageSource(
            type: 'path',
            sha256: 'source-$index',
            fields: const {},
          ),
        ),
      );
    }
    final pending = [
      for (var index = 0; index < pendingPackages; index += 1) 'pending_$index',
    ];
    for (final package in pending) {
      Directory(
        layout.appliedPath(package, '0.1.0'),
      ).createSync(recursive: true);
    }
    return _ActivationFixture(
      root: root,
      layout: layout,
      markerStore: markerStore,
      pendingPackages: pending,
    );
  }

  void activatePending() {
    const overrides = PubspecOverrides();
    final activation = AppliedPatchActivation(
      rootPath: root.path,
      appliedPaths: AppliedPathPolicy(
        rootPath: root.path,
        layout: layout,
        protectedRootPaths: {root.path},
      ),
      appliedMarkerStore: markerStore,
      pubspecOverrides: overrides,
      packageTree: const PackageTree(),
      readOverrideState: () => DependencyOverrideState.read(
        rootPath: root.path,
        overrideRootPaths: {root.path},
        pubspecOverrides: overrides,
        pubspecDependencyOverrides: const PubspecDependencyOverrides(),
      ),
      invalidAppliedPathMessage: 'invalid applied path',
    );
    for (final package in pendingPackages) {
      activation.activate(
        package: package,
        version: '0.1.0',
        patchSha256: '$package-patch',
        path: layout.relativeAppliedPath(package, '0.1.0'),
        source: PackageSource(
          type: 'path',
          sha256: '$package-source',
          fields: const {},
        ),
      );
    }
  }

  void dispose() {
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  }
}

final class _OverlayFixture {
  const _OverlayFixture({required this.root});

  final Directory root;

  static _OverlayFixture create({required int providers}) {
    final root = Directory.systemTemp.createTempSync(
      'patchwork_bench_overlay_',
    );
    final greeterRoot = p.join(root.path, 'packages', 'greeter');
    _writePackageTree(greeterRoot, 'greeter', 32, 256);
    _writeAppPackage(
      root.path,
      package: 'overlay_app',
      greeterPath: 'packages/greeter',
    );

    final dependencies = <String, String>{'greeter': greeterRoot};
    final graphDependencies = <String, List<String>>{
      'overlay_app': [
        'greeter',
        for (var index = 0; index < providers; index += 1) 'provider_$index',
      ],
      'greeter': const [],
    };
    final greeterSha = const PackageTree().sha256Of(greeterRoot);
    for (var index = 0; index < providers; index += 1) {
      final provider = 'provider_$index';
      final providerRoot = p.join(root.path, 'packages', provider);
      dependencies[provider] = providerRoot;
      graphDependencies[provider] = const ['greeter'];
      _writeProviderPackage(providerRoot, provider, greeterPath: '../greeter');
      _writeOverlay(
        providerRoot,
        patch: _srcFilePatch(index, 'overlay_$index'),
        sha256: greeterSha,
      );
    }
    _writePubResolution(
      rootPath: root.path,
      rootPackage: 'overlay_app',
      dependencies: dependencies,
      graphDependencies: graphDependencies,
    );
    return _OverlayFixture(root: root);
  }

  void dispose() {
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  }
}

void _writePackageTree(
  String rootPath,
  String package,
  int files,
  int bytesPerFile,
) {
  Directory(p.join(rootPath, 'lib', 'src')).createSync(recursive: true);
  File(p.join(rootPath, 'pubspec.yaml')).writeAsStringSync('''
name: $package
version: 0.1.0
publish_to: none
environment:
  sdk: ^3.12.0
''');
  File(p.join(rootPath, 'lib', '$package.dart')).writeAsStringSync(
    'String greeting(String name) {\n'
    "  return 'Hello, \$name!';\n"
    '}\n',
  );
  for (var index = 0; index < files; index += 1) {
    final payload = _payload(index, bytesPerFile);
    File(p.join(rootPath, 'lib', 'src', 'file_$index.dart')).writeAsStringSync(
      'String value$index() {\n'
      '  return ${jsonEncode(payload)};\n'
      '}\n',
    );
  }
  Directory(p.join(rootPath, '.dart_tool')).createSync(recursive: true);
  File(p.join(rootPath, '.dart_tool', 'ignored.txt')).writeAsStringSync('x');
}

String _payload(int index, int bytes) {
  final seed = 'payload-$index-';
  final buffer = StringBuffer();
  while (buffer.length < bytes) {
    buffer.write(seed);
  }
  return buffer.toString().substring(0, bytes);
}

void _writeAppPackage(
  String rootPath, {
  String package = 'bench_app',
  required String greeterPath,
}) {
  Directory(p.join(rootPath, 'lib')).createSync(recursive: true);
  File(p.join(rootPath, 'pubspec.yaml')).writeAsStringSync('''
name: $package
publish_to: none
environment:
  sdk: ^3.12.0
dependencies:
  greeter:
    path: $greeterPath
''');
  File(p.join(rootPath, 'lib', 'bench_app.dart')).writeAsStringSync('''
import 'package:greeter/greeter.dart';

String runGreeting() => greeting('Patchwork');
''');
}

void _writeProviderPackage(
  String rootPath,
  String package, {
  required String greeterPath,
}) {
  Directory(p.join(rootPath, 'lib')).createSync(recursive: true);
  File(p.join(rootPath, 'pubspec.yaml')).writeAsStringSync('''
name: $package
version: 0.1.0
publish_to: none
environment:
  sdk: ^3.12.0
dependencies:
  greeter:
    path: $greeterPath
''');
  File(p.join(rootPath, 'lib', '$package.dart')).writeAsStringSync('''
import 'package:greeter/greeter.dart';

String providerGreeting(String name) => greeting(name);
''');
}

void _writeOverlay(
  String providerRoot, {
  required String patch,
  required String sha256,
}) {
  File(p.join(providerRoot, 'patches', 'greeter@0.1.0.patch'))
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(patch);
  File(p.join(providerRoot, 'patchwork.yaml')).writeAsStringSync('''
overlays:
  - package: "greeter"
    version: "0.1.0"
    sha256: "$sha256"
    patch: "patches/greeter@0.1.0.patch"
''');
}

void _writePubResolution({
  required String rootPath,
  required String rootPackage,
  required Map<String, String> dependencies,
  Map<String, List<String>>? graphDependencies,
}) {
  final dartTool = Directory(p.join(rootPath, '.dart_tool'))
    ..createSync(recursive: true);
  final packages = {rootPackage: rootPath, ...dependencies};
  File(p.join(dartTool.path, 'package_config.json')).writeAsStringSync(
    '${jsonEncode({
      'configVersion': 2,
      'packages': [
        for (final entry in packages.entries) {'name': entry.key, 'rootUri': Directory(entry.value).absolute.uri.toString(), 'packageUri': 'lib/'},
      ],
    })}\n',
  );
  final graph =
      graphDependencies ??
      {
        rootPackage: dependencies.keys.toList(),
        for (final package in dependencies.keys) package: <String>[],
      };
  File(p.join(dartTool.path, 'package_graph.json')).writeAsStringSync(
    '${jsonEncode({
      'roots': [rootPackage],
      'packages': [
        for (final entry in graph.entries) {'name': entry.key, 'dependencies': entry.value},
      ],
    })}\n',
  );
  File(p.join(rootPath, 'pubspec.lock')).writeAsStringSync('''
packages:
${dependencies.entries.map((entry) => '''  ${entry.key}:
    dependency: "direct main"
    description:
      path: ${p.relative(entry.value, from: rootPath)}
      relative: true
    source: path
    version: "0.1.0"
''').join()}sdks:
  dart: ">=3.12.0 <4.0.0"
''');
}

String _prefixPatch(String package, String prefix) {
  return 'diff --git a/lib/$package.dart b/lib/$package.dart\n'
      '--- a/lib/$package.dart\n'
      '+++ b/lib/$package.dart\n'
      '@@ -1,3 +1,3 @@\n'
      ' String greeting(String name) {\n'
      "-  return 'Hello, \$name!';\n"
      "+  return '$prefix, \$name!';\n"
      ' }\n';
}

String _srcFilePatch(int index, String marker) {
  return 'diff --git a/lib/src/file_$index.dart b/lib/src/file_$index.dart\n'
      '--- a/lib/src/file_$index.dart\n'
      '+++ b/lib/src/file_$index.dart\n'
      '@@ -1,3 +1,3 @@\n'
      ' String value$index() {\n'
      '-  return ${jsonEncode(_payload(index, 256))};\n'
      '+  return ${jsonEncode(marker)};\n'
      ' }\n';
}
