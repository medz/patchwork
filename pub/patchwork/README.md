# Patchwork

[![pub package](https://img.shields.io/pub/v/patchwork.svg)](https://pub.dev/packages/patchwork)
[![CI](https://github.com/medz/patchwork/actions/workflows/ci.yml/badge.svg)](https://github.com/medz/patchwork/actions/workflows/ci.yml)
[![license](https://img.shields.io/github/license/medz/patchwork.svg)](https://github.com/medz/patchwork/blob/main/LICENSE)

Patchwork keeps Dart pub dependency fixes in reviewable patch files without
editing your shared `.pub-cache`.

Use it when you need a local dependency fix that should survive fresh
checkouts, code review, and CI. Patchwork copies a resolved dependency into an
editable project-local directory, commits the edit as
`patches/<pkg>@<version>.patch`, and applies committed patches through
generated pub path overrides.

## TL;DR

Add Patchwork to the project that owns the patch files:

```sh
dart pub add dev:patchwork
```

Create, commit, and activate a dependency patch:

```sh
dart pub get
dart run patchwork patch collection
# edit .patchwork/collection@<version>/
dart run patchwork commit collection
dart run patchwork apply collection
```

Commit the generated patch file:

```text
patches/collection@<version>.patch
```

Do not commit Patchwork's local working or generated state:

```text
.patchwork/
.dart_tool/patchwork/
pubspec_overrides.yaml
```

## Why Patchwork

Manual `.pub-cache` edits are fast, but they are local to one machine and easy
to lose. Patchwork keeps the durable part of the change in your project so the
same dependency fix can be reviewed, committed, and applied by teammates or CI.

Patchwork is a good fit for small dependency fixes while you wait for an
upstream release. Prefer a fork or vendored dependency when the change is large,
long-lived, security-sensitive, or needs its own release process.

## How It Works

Patchwork has one committed source of truth: patch files.

| Path                                     | Purpose                                                                         |
| ---------------------------------------- | ------------------------------------------------------------------------------- |
| `patches/<pkg>@<version>.patch`          | The committed, reviewable patch file.                                           |
| `.patchwork/<pkg>@<version>/`            | The editable work-in-progress copy created by `patchwork patch`.                |
| `.patchwork/<pkg>@<version>/.patchwork/` | Hidden edit-session metadata and baseline snapshots used by `patchwork commit`. |
| `.dart_tool/patchwork/<pkg>@<version>/`  | Generated applied output created by `patchwork apply`.                          |
| `pubspec_overrides.yaml`                 | Generated pub wiring that points selected packages at applied output.           |

Patchwork does not use a committed Patchwork state file. Historical and stale
patch inventory is derived from safe `patches/<pkg>@<version>.patch`
filenames. Generated output contains ownership markers so Patchwork can refresh
or delete only directories it created.

## Install

For a normal project:

```sh
dart pub add dev:patchwork
```

For local repository development:

```yaml
dev_dependencies:
  patchwork:
    path: ../path/to/patchwork/pub/patchwork
```

Run commands with `dart run`:

```sh
dart run patchwork --help
```

Global activation is optional for interactive use, but useful for scripts,
editors, and agents that need JSON output without `dart run` hook progress on
stdout:

```sh
dart pub global activate patchwork
patchwork status --json
```

## Basic Workflow

Run Patchwork from the Dart package or workspace that owns the patch files.

### Create a patch

```sh
dart pub get
dart run patchwork doctor
dart run patchwork patch collection
```

`patchwork patch` creates a fresh edit directory for the package selected by
the current pub resolution:

```text
.patchwork/collection@<version>/
```

Patchwork targets plain pub package names. It rejects target syntax such as
`pub:collection`, `collection@1.19.1`, `path:collection`, git URLs,
filesystem paths, the current project package, and workspace member packages.

### Commit the edit

Edit files inside `.patchwork/collection@<version>/`, then commit the edit into
a patch file:

```sh
dart run patchwork commit collection
```

The patch file is written under `patches/` and should be committed to version
control.

### Apply committed patches

```sh
dart run patchwork apply
dart run patchwork status
```

`patchwork apply` writes generated output under `.dart_tool/patchwork/`, updates
Patchwork-owned entries in `pubspec_overrides.yaml`, and refreshes pub
resolution before the command exits.

### Deactivate a patch

```sh
dart run patchwork undo collection
```

`undo` removes Patchwork's generated activation state for one package and
refreshes pub resolution. It does not delete the committed patch file.

## Common Tasks

### Apply patches after checkout

After cloning a project that already has committed patch files:

```sh
dart pub get
dart run patchwork apply
dart run patchwork doctor
```

`apply` is the complete activation command. It recreates generated package
output and pub override wiring from committed patch files and the current pub
resolution.

### Upgrade a patched dependency

When an upstream release may contain your fix, first remove generated override
state so pub resolves the real dependency source:

```sh
dart run patchwork undo collection
dart pub upgrade collection
dart pub get
```

If the upstream release already contains the fix, remove the stale patch when
you are ready:

```sh
dart run patchwork remove collection 1.19.0 --dry-run
dart run patchwork remove collection 1.19.0
```

If the upstream release still needs your fix, continue from the older patch
file onto the currently resolved source:

```sh
dart run patchwork patch collection --continue 1.19.0
# inspect and adjust .patchwork/collection@<newVersion>/
dart run patchwork commit collection
dart run patchwork apply collection
```

### Repair a patch that no longer applies

Start with diagnostics:

```sh
dart run patchwork doctor --explain
```

For upgrade-related conflicts, use `patchwork undo`, upgrade the dependency,
then try `patchwork patch <pkg> --continue <oldVersion>` to carry the older
patch onto the current source. If the older patch no longer applies cleanly,
create a fresh edit with `patchwork patch <pkg>` and port the relevant changes
manually from the stale patch file.

Patchwork keeps normal apply behavior atomic: a failed apply does not replace
the committed patch file or pretend the generated output is healthy.

### Remove stale state

Use `remove` for a selected package or version:

```sh
dart run patchwork remove collection 1.19.0 --dry-run
dart run patchwork remove collection 1.19.0
```

Use `prune` to inspect stale patch files and unreferenced generated output:

```sh
dart run patchwork prune --dry-run
```

`prune` only removes generated output when a valid Patchwork marker proves
ownership and no active override points at it.

### Troubleshoot local setup

Use `doctor --setup` to validate repository setup without mutating files:

```sh
dart run patchwork doctor --setup
```

It checks that generated Patchwork state stays ignored, committed patch files
remain visible to Git, hook setup is complete when `hook/build.dart` exists,
and CI uses high-level Patchwork commands such as `apply` or `doctor`.

A typical `.gitignore` should include:

```gitignore
.patchwork/
.dart_tool/
pubspec_overrides.yaml
```

Do not ignore `patches/` or `patches/*.patch`; those files are Patchwork's
reviewable durable state.

## CI

Run Patchwork after dependencies are installed and before tests:

```sh
dart pub get
dart run patchwork apply
dart run patchwork doctor
dart test --exclude-tags=full
dart test --tags=full --concurrency=1
```

Use `patchwork doctor` when CI should fail on missing, stale, or unapplied patch
state. Use `patchwork doctor --explain` when CI logs should include the next
repair action for each diagnostic. Use `patchwork doctor --setup` when CI
should verify repository configuration.

Reserve `--no-pub-get` for low-level scripts that intentionally separate
Patchwork filesystem changes from pub resolution refresh. Normal interactive
and CI usage should let Patchwork run `dart pub get`.

Patchwork's own test suite has two lanes. The fast lane covers unit and focused
behavior tests without creating downstream Dart projects:

```sh
dart test --exclude-tags=full
```

The full lane covers real pub, hook, CLI, and generated-output workflows. Run it
before release, and keep concurrency low on developer machines:

```sh
dart test --tags=full --concurrency=1
```

## Automatic Apply Hooks

User projects can opt in to automatic apply with Dart build hooks. Add both
Patchwork and the hooks API as dev dependencies:

```sh
dart pub add dev:patchwork dev:hooks
```

Then create `hook/build.dart` in the application or workspace member that owns
the patch workflow:

```dart
import 'package:hooks/hooks.dart';
import 'package:patchwork/hooks.dart' as patchwork;

Future<void> main(List<String> args) async {
  await build(args, (input, output) async {
    await patchwork.applyAll(input, output);
  });
}
```

The first `dart run`, `dart test`, or build after a patch is committed applies
the generated output and runs `dart pub get` when pub resolution needs to be
refreshed. No-op hook runs do not call `dart pub get`.

To apply only one package:

```dart
await patchwork.apply(input, output, package: 'collection');
```

These helpers are for user-owned patches committed by the application or
workspace. Dependency packages that publish their own patch contributions should
use package-provided overlays instead.

## Provider Overlays

Provider overlays are an advanced package-author workflow. Use them when a
package needs to publish a narrowly scoped patch contribution for one of its own
dependencies, while downstream applications should only depend on the provider
package and run normally.

The provider package must depend on Patchwork as a regular dependency, not a
dev dependency, so Patchwork's build hook is present in downstream dependency
graphs:

```sh
dart pub add patchwork
```

Create and commit the dependency patch from the provider package:

```sh
dart run patchwork patch collection
# edit .patchwork/collection@<version>/
dart run patchwork commit collection
dart run patchwork overlay add collection --reason "Fix parser crash used here."
```

`patchwork overlay add` creates or updates `patchwork.yaml`:

```yaml
overlays:
  - package: "collection"
    version: "1.19.1"
    sha256: "<source-tree-sha>"
    patch: "patches/collection@1.19.1.patch"
    reason: "Fix parser crash used here."
```

Commit these provider-owned files:

- `patchwork.yaml`
- `patches/<pkg>@<version>.patch`

When an application depends on the provider package, Patchwork's package hook
scans dependency packages for `patchwork.yaml`, selects overlays matching the
currently resolved package version and source `sha256`, and composes matching
patch contributions into generated output at
`.dart_tool/patchwork/<pkg>@<version>/`.

If multiple dependency packages provide overlays for the same target package,
Patchwork applies provider overlays in deterministic order by provider package
name and patch path. If the root application also owns a committed patch for
that same target, the root patch is applied last. Duplicate patch content is
deduplicated, and conflicting patches fail with deterministic diagnostics.

Inspect overlay discovery without mutating generated package output:

```sh
dart run patchwork overlay inspect
dart run patchwork overlay inspect --json
```

Inspection reports provider manifests, matched and skipped entries, root patch
contributions, deduplication, compose order, and conflict sources.

## Automation And JSON

Use `--json` when a script, editor, or agent needs structured Patchwork state
instead of human-readable text:

```sh
patchwork status --json
patchwork doctor --explain --json
```

JSON mode prints one JSON object on stdout and keeps normal exit-code rules.
Patchwork and usage failures use an `error` object with a clear `code`. Problem
entries expose codes and hints so tools can decide the next action without
parsing prose. In JSON mode, `doctor --explain --json` includes diagnostic
`suggestedActions`.

State JSON is derived from committed patch files, open edit-session metadata,
generated applied markers, pub resolution, and `pubspec_overrides.yaml`. It does
not imply a committed Patchwork state file.

The JSON output mirrors Patchwork's current product model. It is not a fixed
public schema, and fields may evolve as commands and state concepts change.

Prefer the standalone `patchwork` executable for JSON automation. `dart run`
may print Dart build-hook progress before the Patchwork process starts when a
package in the dependency graph provides a hook.

## Command Reference

| Command                                                                          | Description                                                                     |
| -------------------------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| `patchwork patch <pkg> [--continue [version]] [--force] [--json]`                | Create a source-based edit.                                                     |
| `patchwork commit [pkg] [--json]`                                                | Commit open edits into patch files.                                             |
| `patchwork apply [pkg] [--no-pub-get] [--json]`                                  | Apply committed patches and refresh pub resolution.                             |
| `patchwork undo <pkg> [--no-pub-get] [--json]`                                   | Remove one applied patch and refresh pub resolution.                            |
| `patchwork remove <pkg> [version] [--dry-run] [--force] [--no-pub-get] [--json]` | Remove selected Patchwork artifacts safely.                                     |
| `patchwork prune [--dry-run] [--force] [--no-pub-get] [--json]`                  | Remove stale patch files and unreferenced generated output.                     |
| `patchwork status [--json]`                                                      | Show patch and override state.                                                  |
| `patchwork doctor [--setup] [--explain] [--json]`                                | Check local readiness, setup recommendations, and optional remediation actions. |
| `patchwork overlay add <pkg> [--reason <text>] [--json]`                         | Register a committed provider patch in `patchwork.yaml`.                        |
| `patchwork overlay inspect [--json]`                                             | Inspect provider overlays and composition diagnostics.                          |

## Library API

The CLI uses the same API that hooks or other Dart tooling can call:

```dart
import 'dart:io';

import 'package:patchwork/patchwork.dart';

Future<void> main() async {
  final patchwork = await Patchwork.open(Directory.current);

  await patchwork.patch('collection');
  await patchwork.commit('collection');
  await patchwork.apply('collection');
  await patchwork.undo('collection');

  final state = await patchwork.inspect();
  stdout.writeln('${state.packages.length} patchwork packages');
}
```

Use `PatchRef.version('1.19.0')` with `patch` when carrying an older patch onto
a newer dependency source.

## Migration And Limits

If you currently use a cache patch tool or manual `.pub-cache` edits, restore a
clean dependency copy before creating a Patchwork edit. Patchwork should diff
from the original dependency source, not from a package that already has local
cache edits applied.

Patchwork does not import other patch formats yet. Recreate the dependency edit
with `patchwork patch <package>`, then commit it with
`patchwork commit <package>`.

Patchwork is intentionally optimized for small, reviewable dependency fixes.
Use a fork, vendored dependency, or upstream contribution for broad feature
work, long-lived divergence, or changes that need their own release process.

## Example

The repository contains a runnable example under `examples/hello_patch`. The
package-level `example/README.md` links to that walkthrough for pub.dev.
