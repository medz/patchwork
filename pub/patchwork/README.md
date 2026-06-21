# Patchwork

[![pub package](https://img.shields.io/pub/v/patchwork.svg)](https://pub.dev/packages/patchwork)
[![CI](https://github.com/medz/patchwork/actions/workflows/ci.yml/badge.svg)](https://github.com/medz/patchwork/actions/workflows/ci.yml)
[![license](https://img.shields.io/github/license/medz/patchwork.svg)](https://github.com/medz/patchwork/blob/main/LICENSE)

Patchwork keeps Dart pub dependency fixes in reviewable patch files without
editing your shared `.pub-cache`.

Use it when you need a local dependency fix that should survive fresh
checkouts, code review, and CI. Patchwork copies a resolved dependency into
`.patchwork/<pkg>@<version>/`, commits the edit as
`patches/<pkg>@<version>.patch`, and materializes the patch through generated
pub path overrides.

## Why Patchwork

Manual `.pub-cache` edits are fast, but they are local to one machine and easy
to lose. Patchwork keeps the durable part of the change in your project so the
same patch can be reviewed, committed, and applied by teammates or CI.

Patchwork is a good fit for small dependency fixes while you wait for an
upstream release. Prefer a fork or vendored dependency when the change is large,
long-lived, security-sensitive, or needs its own release process.

## Install

Add Patchwork as a dev dependency in the project that owns the patch files.

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

Global activation is optional for interactive use, but recommended for scripts,
editors, and agents that use `--json` and need clean stdout:

```sh
dart pub global activate patchwork
patchwork status --json
```

## Workflow

Run Patchwork from the Dart package or workspace you want to patch.

```sh
dart pub get
dart run patchwork doctor
dart run patchwork patch collection
```

Edit the directory printed by `patchwork patch`, then commit it:

```sh
dart run patchwork commit collection
```

Apply committed patches:

```sh
dart run patchwork apply
dart run patchwork status
```

After a successful apply, Patchwork refreshes pub resolution through the
generated overrides before the command exits.

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

## Package-Provided Overlays

Packages can also publish narrowly scoped patch contributions for their own
dependencies. This is for package authors who know that their package needs a
temporary fix in a dependency, while downstream applications should only depend
on the package and run normally.

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
  -
    package: "collection"
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
currently resolved package version and source `sha256`, and composes all
matching patch contributions into one generated output at
`.dart_tool/patchwork/<pkg>@<version>/`.

If multiple dependency packages provide overlays for the same target package,
Patchwork applies provider overlays in deterministic order by provider package
name and patch path. If the root application also owns a committed patch for
that same target, the root patch is applied last. Conflicting patches fail the
build with a deterministic diagnostic; Patchwork reports the conflict instead
of trying to merge it.

To inspect overlay discovery without mutating generated package output:

```sh
dart run patchwork overlay inspect
dart run patchwork overlay inspect --json
```

Inspection reports provider manifests, matched and skipped entries, root patch
contribution, deduplication, compose order, and conflict sources.

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

## What To Commit

Commit these files in projects that use Patchwork:

- `patches/*.patch`

Patch files are the committed source of truth for your dependency patches.

## State Model

Patchwork uses three project-local locations:

- `.patchwork/<pkg>@<version>/` is the editable work-in-progress copy.
- `patches/<pkg>@<version>.patch` is the committed reviewable patch file.
- `.dart_tool/patchwork/<pkg>@<version>/` is generated by `patchwork apply` and
  wired into pub through `pubspec_overrides.yaml`.

Open edit directories contain hidden session metadata under
`.patchwork/<pkg>@<version>/.patchwork/`. Patchwork uses that baseline snapshot
to commit edits even if pub resolution changes while the edit is open.
Generated output contains a hidden ownership marker so Patchwork can refresh or
delete only output it created.

Patchwork derives historical and stale patch inventory from safe
`patches/<pkg>@<version>.patch` filenames. Older patch files remain visible to
`status` and `doctor` until you carry them forward or remove them.

## What Stays Generated

Do not commit Patchwork's generated integration state:

- `.patchwork/`
- `.dart_tool/patchwork/`
- `pubspec_overrides.yaml`

`patchwork apply` never mutates the primary `pubspec.yaml`; it writes
`pubspec_overrides.yaml` so pub resolves patched packages through generated path
overrides. `pubspec_overrides.yaml` is shared with other tools and local
workflow, so Patchwork only manages its own patch override entries.

## Commands

| Command | Description |
| --- | --- |
| `patchwork patch <pkg> [--continue [version]] [--force] [--json]` | Create a source-based edit. |
| `patchwork commit [pkg] [--json]` | Commit open edits into patch files. |
| `patchwork overlay add <pkg> [--reason <text>] [--json]` | Register a committed patch in `patchwork.yaml`. |
| `patchwork overlay inspect [--json]` | Inspect provider overlays and composition diagnostics. |
| `patchwork apply [pkg] [--no-pub-get] [--json]` | Apply committed patches and refresh pub resolution. |
| `patchwork undo <pkg> [--no-pub-get] [--json]` | Remove one applied patch and refresh pub resolution. |
| `patchwork remove <pkg> [version] [--dry-run] [--force] [--no-pub-get] [--json]` | Remove selected Patchwork artifacts safely. |
| `patchwork prune [--dry-run] [--force] [--no-pub-get] [--json]` | Remove stale patch files and unreferenced generated output. |
| `patchwork status [--json]` | Show patch and override state. |
| `patchwork doctor [--setup] [--explain] [--json]` | Check local readiness, setup recommendations, and optional remediation actions. |

Packages are plain pub package names selected by the current pub resolution.
Patchwork rejects target syntax such as `pub:collection`, `collection@1.19.1`,
`path:collection`, git URLs, filesystem paths, the current project package, and
workspace member packages.

Use `--json` when a script, editor, or agent needs structured Patchwork state
instead of human-readable text:

```sh
patchwork status --json
```

JSON mode prints one JSON object on stdout and keeps the normal exit-code
rules. It is diagnostic output that mirrors Patchwork's current product model,
not a fixed public schema. Fields may evolve as commands and state concepts
change.

Patchwork and usage failures use an `error` object with a clear `code`. Problem
entries also expose codes and hints so tools can decide the next action without
parsing prose. Path fields use the same values the command would show in human
output, such as `.patchwork/collection@1.19.1` and
`patches/collection@1.19.1.patch`.

Use `patchwork doctor --explain` when you want remediation guidance attached to
each diagnostic. In JSON mode, `doctor --explain --json` includes diagnostic
`suggestedActions`; those actions are current CLI guidance, not a fixed
compatibility schema.

Use `patchwork doctor --setup` to validate repository setup without mutating
files. It checks that generated Patchwork state stays ignored, committed patch
files remain visible to Git, hook setup is complete when `hook/build.dart`
exists, and CI uses the high-level `patchwork apply` or `patchwork doctor`
commands. A typical `.gitignore` should include:

```gitignore
.patchwork/
.dart_tool/
pubspec_overrides.yaml
```

Do not ignore `patches/` or `patches/*.patch`; those files are Patchwork's
reviewable durable state.

State JSON is derived from committed patch files, open edit-session metadata,
generated applied markers, pub resolution, and `pubspec_overrides.yaml`. It
does not imply a committed Patchwork state file.

Prefer the standalone `patchwork` executable for JSON automation. `dart run`
may print Dart build-hook progress before the Patchwork process starts when a
package in the dependency graph provides a hook.

Use `--no-pub-get` with commands that change generated overrides only when a
script needs to separate Patchwork's filesystem changes from pub resolution
refresh. Normal interactive usage should let Patchwork run `dart pub get`.

## Migrating From Cache Patches

If you currently use a cache patch tool or manual `.pub-cache` edits, restore a
clean dependency copy before creating a Patchwork edit. Patchwork should diff
from the original dependency source, not from a package that already has local
cache edits applied.

Patchwork does not import other patch formats yet. Recreate the dependency edit
with `patchwork patch <package>`, then commit it with
`patchwork commit <package>`.

## Carrying Patches Across Upgrades

When an upstream release may contain your fix, undo the generated override
before upgrading so pub resolves the real dependency source:

```sh
dart run patchwork undo collection
dart pub upgrade collection
dart pub get
```

If the upstream release contains the fix, create a fresh edit from that source
and commit it unchanged. The older patch file remains in `patches/` until you
remove it intentionally:

```sh
dart run patchwork patch collection
dart run patchwork commit collection
dart run patchwork remove collection 1.19.0
```

If the upstream release does not contain the fix, explicitly continue from the
older patch file:

```sh
dart run patchwork patch collection --continue 1.19.0
dart run patchwork commit collection
dart run patchwork apply collection
```

Use `patchwork prune --dry-run` to inspect stale patch files and unreferenced
generated output before cleanup. `prune` only removes generated output when a
valid Patchwork marker proves ownership and no active override points at it.

## CI Check

Run Patchwork in CI after dependencies are installed:

```sh
dart run patchwork apply
dart run patchwork status
dart test
```

Run `dart run patchwork doctor --setup` when you want CI to verify repository
configuration. Use plain `patchwork apply` in CI so Patchwork refreshes
`pubspec_overrides.yaml` and pub resolution together. Reserve `--no-pub-get` for
low-level scripts that run `dart pub get` themselves.

Use `patchwork doctor` when CI should fail on missing, stale, or unapplied
patch state. Use `patchwork doctor --explain` when CI logs should include the
next repair action for each diagnostic.

## Example

The repository contains a runnable example under `examples/hello_patch`. The
package-level `example/README.md` links to that walkthrough for pub.dev.
