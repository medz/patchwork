import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'model.dart';

/// Inspects repository configuration that affects Patchwork workflows.
final class SetupInspector {
  /// Creates a setup inspector for a Patchwork project.
  const SetupInspector({
    required this.rootPath,
    required this.currentPackageRootPath,
  });

  /// The Patchwork state root.
  final String rootPath;

  /// The package root used by the current command.
  final String currentPackageRootPath;

  /// Returns read-only setup diagnostics.
  SetupReport inspect() {
    return SetupReport(
      checks: [
        ..._gitignoreChecks(),
        _hookCheck(),
        _ciCheck(),
        const SetupCheck(
          code: 'setup.no_committed_state_file',
          level: SetupCheckLevel.info,
          message:
              'Patchwork does not need a committed state file; patch files are the durable source of truth.',
        ),
      ],
    );
  }

  List<SetupCheck> _gitignoreChecks() {
    final gitignorePath = p.join(rootPath, '.gitignore');
    final rules = _GitignoreRules.read(gitignorePath);
    final checks = <SetupCheck>[];

    checks.add(
      _ignoredGeneratedPathCheck(
        rules,
        path: '.patchwork',
        code: 'setup.ignore_edit_state',
        okMessage: '.patchwork/ edit directories are ignored.',
        warningMessage: '.patchwork/ edit directories should stay uncommitted.',
        hint: 'Add .patchwork/ to .gitignore.',
        gitignorePath: gitignorePath,
      ),
    );
    checks.add(
      _ignoredGeneratedPathCheck(
        rules,
        path: p.posix.join('.dart_tool', 'patchwork'),
        code: 'setup.ignore_applied_output',
        okMessage: '.dart_tool/patchwork/ generated output is ignored.',
        warningMessage:
            '.dart_tool/patchwork/ generated output should stay uncommitted.',
        hint: 'Add .dart_tool/ or .dart_tool/patchwork/ to .gitignore.',
        gitignorePath: gitignorePath,
      ),
    );
    checks.add(
      _ignoredGeneratedPathCheck(
        rules,
        path: 'pubspec_overrides.yaml',
        code: 'setup.ignore_pubspec_overrides',
        okMessage: 'pubspec_overrides.yaml is ignored.',
        warningMessage:
            'pubspec_overrides.yaml is generated integration state and should stay uncommitted.',
        hint: 'Add pubspec_overrides.yaml to .gitignore.',
        gitignorePath: gitignorePath,
        directory: false,
      ),
    );

    const samplePatchFile = 'patches/example@0.0.0.patch';
    final patchesIgnored = rules.ignores(samplePatchFile, directory: false);
    checks.add(
      SetupCheck(
        code: 'setup.commit_patch_files',
        level: patchesIgnored ? SetupCheckLevel.warning : SetupCheckLevel.ok,
        message: patchesIgnored
            ? 'patches/*.patch is ignored, but Patchwork patch files should be committed.'
            : 'patches/*.patch remains commit-ready.',
        hint: patchesIgnored
            ? 'Remove ignore rules that hide patches/ or patches/*.patch.'
            : null,
        path: gitignorePath,
      ),
    );

    return checks;
  }

  SetupCheck _ignoredGeneratedPathCheck(
    _GitignoreRules rules, {
    required String path,
    required String code,
    required String okMessage,
    required String warningMessage,
    required String hint,
    required String gitignorePath,
    bool directory = true,
  }) {
    final ignored = rules.ignores(path, directory: directory);
    return SetupCheck(
      code: code,
      level: ignored ? SetupCheckLevel.ok : SetupCheckLevel.warning,
      message: ignored ? okMessage : warningMessage,
      hint: ignored ? null : hint,
      path: gitignorePath,
    );
  }

  SetupCheck _hookCheck() {
    final hookPath = p.join(currentPackageRootPath, 'hook', 'build.dart');
    final hookFile = File(hookPath);
    if (!hookFile.existsSync()) {
      return SetupCheck(
        code: 'setup.hook_optional',
        level: SetupCheckLevel.info,
        message:
            'No hook/build.dart file is configured; Patchwork hooks are optional.',
        hint:
            'Use a hook when you want Patchwork patches to apply automatically during Dart hook runs.',
        path: hookPath,
      );
    }

    final pubspecPath = p.join(currentPackageRootPath, 'pubspec.yaml');
    final dependencyNames = _dependencyNames(pubspecPath);
    final hookSource = hookFile.readAsStringSync();
    final packageName = _packageName(pubspecPath);
    final isPackageProvidedPatchworkHook =
        packageName == 'patchwork' &&
        hookSource.contains('package:patchwork/src/overlay_hook.dart');

    if (isPackageProvidedPatchworkHook) {
      final missing = [
        if (!dependencyNames.contains('hooks')) 'hooks',
        if (!hookSource.contains('package:hooks/hooks.dart'))
          'package:hooks/hooks.dart import',
      ];
      if (missing.isEmpty) {
        return SetupCheck(
          code: 'setup.hook_config',
          level: SetupCheckLevel.ok,
          message:
              'hook/build.dart is configured for package-provided Patchwork overlays.',
          path: hookPath,
        );
      }
      return SetupCheck(
        code: 'setup.hook_config',
        level: SetupCheckLevel.warning,
        message:
            'hook/build.dart exists but its package-provided Patchwork hook setup looks incomplete.',
        hint: 'Add ${missing.join(', ')} for the hook workflow.',
        path: hookPath,
      );
    }

    final missing = [
      if (!dependencyNames.contains('hooks')) 'hooks',
      if (!dependencyNames.contains('patchwork')) 'patchwork',
    ];
    if (!hookSource.contains('package:hooks/hooks.dart')) {
      missing.add('package:hooks/hooks.dart import');
    }
    if (!hookSource.contains('package:patchwork/hooks.dart')) {
      missing.add('package:patchwork/hooks.dart import');
    }

    if (missing.isNotEmpty) {
      return SetupCheck(
        code: 'setup.hook_config',
        level: SetupCheckLevel.warning,
        message:
            'hook/build.dart exists but its Patchwork hook setup looks incomplete.',
        hint: 'Add ${missing.join(', ')} for the hook workflow.',
        path: hookPath,
      );
    }

    return SetupCheck(
      code: 'setup.hook_config',
      level: SetupCheckLevel.ok,
      message: 'hook/build.dart is configured for Patchwork hooks.',
      path: hookPath,
    );
  }

  SetupCheck _ciCheck() {
    final workflowRoot = Directory(p.join(rootPath, '.github', 'workflows'));
    if (!workflowRoot.existsSync()) {
      return SetupCheck(
        code: 'setup.ci_optional',
        level: SetupCheckLevel.info,
        message: 'No GitHub Actions workflow directory was found.',
        hint:
            'In CI, run dart run patchwork apply or dart run patchwork doctor after dart pub get.',
        path: workflowRoot.path,
      );
    }

    final workflowFiles =
        workflowRoot.listSync(followLinks: false).whereType<File>().where((
          file,
        ) {
          final extension = p.extension(file.path);
          return extension == '.yml' || extension == '.yaml';
        }).toList()..sort((left, right) => left.path.compareTo(right.path));
    if (workflowFiles.isEmpty) {
      return SetupCheck(
        code: 'setup.ci_optional',
        level: SetupCheckLevel.info,
        message: 'No GitHub Actions workflow files were found.',
        hint:
            'In CI, run dart run patchwork apply or dart run patchwork doctor after dart pub get.',
        path: workflowRoot.path,
      );
    }

    final combined = workflowFiles
        .map((file) => file.readAsStringSync())
        .join('\n');
    if (RegExp(r'patchwork\s+apply[^\n]*--no-pub-get').hasMatch(combined)) {
      return SetupCheck(
        code: 'setup.ci_apply_pub_get',
        level: SetupCheckLevel.warning,
        message:
            'CI runs patchwork apply with --no-pub-get, which skips the high-level activation refresh.',
        hint:
            'Use dart run patchwork apply in CI; reserve --no-pub-get for low-level scripts that run dart pub get themselves.',
        path: workflowRoot.path,
      );
    }

    if (RegExp(r'patchwork\s+(apply|doctor)\b').hasMatch(combined)) {
      return SetupCheck(
        code: 'setup.ci_patchwork_check',
        level: SetupCheckLevel.ok,
        message: 'CI includes a Patchwork apply or doctor check.',
        path: workflowRoot.path,
      );
    }

    return SetupCheck(
      code: 'setup.ci_patchwork_check',
      level: SetupCheckLevel.info,
      message: 'CI does not appear to run Patchwork checks.',
      hint:
          'After dart pub get, add dart run patchwork apply or dart run patchwork doctor before tests.',
      path: workflowRoot.path,
    );
  }

  String? _packageName(String pubspecPath) {
    final decoded = _readPubspec(pubspecPath);
    final name = decoded?['name'];
    return name is String ? name : null;
  }

  Set<String> _dependencyNames(String pubspecPath) {
    final decoded = _readPubspec(pubspecPath);
    if (decoded == null) {
      return const {};
    }
    return {
      ..._yamlMapKeys(decoded['dependencies']),
      ..._yamlMapKeys(decoded['dev_dependencies']),
    };
  }

  YamlMap? _readPubspec(String pubspecPath) {
    final pubspec = File(pubspecPath);
    if (!pubspec.existsSync()) {
      return null;
    }
    Object? decoded;
    try {
      decoded = loadYaml(pubspec.readAsStringSync());
    } on YamlException {
      return null;
    } on FileSystemException {
      return null;
    }
    if (decoded is! YamlMap) {
      return null;
    }
    return decoded;
  }

  Set<String> _yamlMapKeys(Object? value) {
    if (value is! YamlMap) {
      return const {};
    }
    return {
      for (final key in value.keys)
        if (key is String) key,
    };
  }
}

final class _GitignoreRules {
  const _GitignoreRules(this.rules);

  final List<_GitignoreRule> rules;

  static _GitignoreRules read(String path) {
    final file = File(path);
    if (!file.existsSync()) {
      return const _GitignoreRules([]);
    }
    final rules = <_GitignoreRule>[];
    for (final rawLine in file.readAsLinesSync()) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#')) {
        continue;
      }
      final negated = line.startsWith('!');
      final pattern = (negated ? line.substring(1) : line).trim();
      if (pattern.isEmpty) {
        continue;
      }
      rules.add(_GitignoreRule(pattern: pattern, negated: negated));
    }
    return _GitignoreRules(rules);
  }

  bool ignores(String path, {required bool directory}) {
    var ignored = false;
    final normalized = p.posix.joinAll(p.split(path));
    for (final rule in rules) {
      if (rule.matches(normalized, directory: directory)) {
        ignored = !rule.negated;
      }
    }
    return ignored;
  }
}

final class _GitignoreRule {
  const _GitignoreRule({required this.pattern, required this.negated});

  final String pattern;
  final bool negated;

  bool matches(String path, {required bool directory}) {
    var normalizedPattern = pattern;
    if (normalizedPattern.startsWith('/')) {
      normalizedPattern = normalizedPattern.substring(1);
    }
    normalizedPattern = p.posix.joinAll(p.split(normalizedPattern));
    final directoryOnly = normalizedPattern.endsWith('/');
    if (directoryOnly) {
      normalizedPattern = normalizedPattern.substring(
        0,
        normalizedPattern.length - 1,
      );
    }
    if (directoryOnly && !directory) {
      return false;
    }
    if (normalizedPattern.isEmpty) {
      return false;
    }

    if (normalizedPattern.contains('/')) {
      return _matchesPathPattern(normalizedPattern, path) ||
          path.startsWith('$normalizedPattern/');
    }

    final segments = path.split('/');
    return segments.any(
          (segment) => _matchesPathPattern(normalizedPattern, segment),
        ) ||
        path.startsWith('$normalizedPattern/');
  }

  bool _matchesPathPattern(String pattern, String value) {
    if (!pattern.contains('*')) {
      return pattern == value;
    }
    final source = RegExp.escape(pattern).replaceAll(r'\*', r'[^/]*');
    final regex = RegExp('^$source\$');
    return regex.hasMatch(value);
  }
}
