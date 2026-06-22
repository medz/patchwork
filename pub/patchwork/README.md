# Patchwork

[![pub package](https://img.shields.io/pub/v/patchwork.svg)](https://pub.dev/packages/patchwork)
[![CI](https://github.com/medz/patchwork/actions/workflows/ci.yml/badge.svg)](https://github.com/medz/patchwork/actions/workflows/ci.yml)
[![license](https://img.shields.io/github/license/medz/patchwork.svg)](https://github.com/medz/patchwork/blob/main/LICENSE)

Patch a Dart pub dependency without forking it or editing your shared
`.pub-cache`.

Patchwork is for the space between a fragile local cache edit and a long-lived
fork: make a small fix to a resolved dependency, commit the fix as a reviewable
patch file, and let Patchwork regenerate local path overrides wherever the
project runs.

> No fork. No cache edits. A normal patch file your team can review and reapply.

## Choose The Workflow

Start here: decide who owns the patch file.

| If this is true                             | Use                                                   |
| ------------------------------------------- | ----------------------------------------------------- |
| App/workspace needs the patch while it runs | [Root Project Patches](#root-project-patches)         |
| Published package ships fix downstream      | [Package-Provided Patches](#package-provided-patches) |

Workflow outcomes:

- Root project: add Patchwork under `dev_dependencies`, run `patch` ->
  `commit` -> `apply`, and commit `patches/<pkg>@<version>.patch`.
- Package-provided: add Patchwork under `dependencies`, run `patch` ->
  `commit` -> review the patch file -> `overlay add`, and commit
  `patchwork.yaml` plus `patches/<pkg>@<version>.patch`.

If you are unsure, choose Root Project Patches. Use Package-Provided Patches
only when a published package must carry a direct runtime dependency fix for
downstream applications.

Use one workflow for one patch. The two workflows install Patchwork differently
and commit different files.

After choosing an owner, a root project can also use
[Automatic Apply Hooks](#automatic-apply-hooks) to apply committed patches before
runs or tests. Hooks are an activation helper, not a third patch owner.

Both workflows should finish with the matching [CI](#ci) checks.
Agents and scripts should follow
[For Agents And Scripts](#for-agents-and-scripts) before mutating a project.

Patchwork regenerates applied package output and pub override wiring from
committed files. Edit directories are disposable workspaces.

## Quick Start: Root Project Patch

This is the default path when the current app or workspace owns the dependency
fix.
Replace `collection` with a package selected by the current pub resolution,
including direct or transitive dependencies.

```sh
dart pub add dev:patchwork
dart pub get
dart run patchwork doctor
dart run patchwork patch collection
# edit .patchwork/collection@<version>/
dart run patchwork commit collection
dart run patchwork apply collection
```

Commit the patch file when it exists:

```text
patches/collection@<version>.patch
```

Then run the [Test with committed patches](#test-with-committed-patches) CI
sequence.

Published packages that need to ship a direct runtime dependency patch to
downstream applications should use
[Package-Provided Patches](#package-provided-patches) instead.

## Why Patchwork

Manual `.pub-cache` edits are fast, but they are local to one machine and easy
to lose. Patchwork keeps the durable part of the change in your project so the
same dependency fix can be reviewed, committed, and applied by teammates or CI.

Patchwork is a good fit for small dependency fixes while you wait for an
upstream release. Prefer a fork or vendored dependency when the change is large,
long-lived, security-sensitive, or needs its own release process.

## Root Project Patches

Run Patchwork from the Dart package or workspace that owns the patch files.
Add Patchwork as a dev dependency:

```sh
dart pub add dev:patchwork
```

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

Use the resolved package name, such as `collection`.

The dependency can be hosted, path, or git; the command target is still only
the package name. SDK packages are not patch targets.
The target must be selected by the current pub resolution, have lockfile
metadata, and appear in `.dart_tool/package_config.json`. It can be a direct or
transitive dependency.

### Commit the edit

Edit files inside `.patchwork/collection@<version>/`, then commit the edit into
a patch file:

```sh
dart run patchwork commit collection
```

The patch file is written under `patches/` and should be committed to version
control. If `patchwork commit` reports no changes, there is no patch file to
commit.

Commit the root-owned patch file when it exists:

- `patches/<pkg>@<version>.patch`

Do not commit local working or generated state:

- `.patchwork/`
- `.dart_tool/patchwork/`
- `pubspec_overrides.yaml`

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

## Package-Provided Patches

Use this when you publish a Dart package and the package needs to ship a narrow
patch for one of its direct runtime dependencies. Downstream applications
should only depend on your package and run normally; they should not copy your
patch file or add their own Patchwork dependency just to consume your patch.
Because your package depends on Patchwork normally, downstream applications
receive Patchwork's hook through your package's dependency graph.

Treat `patchwork overlay add` as the registration step, not a separate
workflow. A package-provided patch is a reviewed patch file carried by a
published package for one direct runtime dependency.

Before creating a package-provided patch, these facts must be true:

- The current package is the package that will publish `patchwork.yaml`.
- The target package is listed under that package's `dependencies`, not only
  `dev_dependencies`. Downstream composition can only use package-provided
  patches for runtime dependencies; dev-only, transitive, or unrelated targets
  fail during `overlay inspect` or hook execution.
- The package that provides the patch depends on Patchwork as a regular
  dependency, not a dev dependency, so Patchwork's build hook is present in
  downstream dependency graphs.

```sh
dart pub add patchwork
```

Create the dependency patch from the package that provides it:

```sh
dart pub get
dart run patchwork doctor
dart run patchwork patch collection
# edit .patchwork/collection@<version>/
dart run patchwork commit collection
```

If `patchwork commit` reports no changes, stop here; there is no
package-provided patch to register.

### Review the patch file

A package-provided patch file is published with your package and applied in
downstream applications as generated runtime source. This review step prevents
accidentally shipping upstream test suites or unrelated package maintenance as
part of your downstream runtime patch. Review
`patches/collection@<version>.patch` before registering it:

- Include the target package source files required for the runtime fix.
- Do not include upstream package tests, examples, docs, or unrelated cleanup
  unless those files are required at runtime.
- Keep upstream test changes for an upstream pull request or temporary local
  verification, not for the package-provided patch file.
- Add a regression test in the providing package when the behavior is observable
  through that package.

If the patch file contains files that should not ship downstream, fix the edit
directory and run `patchwork commit` again before `overlay add`.

Nothing is registered automatically. After reviewing the patch file, register
the package-provided patch:

```sh
dart run patchwork overlay add collection --reason "Fix parser crash used here."
```

`patchwork overlay add` records the reviewed patch in `patchwork.yaml`:

```yaml
overlays:
  - package: "collection"
    version: "1.19.1"
    sha256: "<source-tree-sha>"
    patch: "patches/collection@1.19.1.patch"
    reason: "Fix parser crash used here."
```

Commit these package-owned files:

- `patchwork.yaml`
- `patches/<pkg>@<version>.patch`

Do not commit local working or generated state:

- `.patchwork/`
- `.dart_tool/patchwork/`
- `pubspec_overrides.yaml`

When an application depends on the providing package, Patchwork's package hook
scans dependency packages for `patchwork.yaml`, selects entries matching the
currently resolved package version and source `sha256`, and composes matching
patch files into generated output at
`.dart_tool/patchwork/<pkg>@<version>/`.

If multiple dependency packages provide patches for the same target package,
Patchwork applies package-provided patches in deterministic order by providing
package name and patch path. If the root application also owns a committed
patch for that same target, the root patch is applied last. Duplicate patch
content is deduplicated, and conflicting patches fail with deterministic
diagnostics.

Inspect package-provided patch discovery without mutating generated package
output:

```sh
dart run patchwork overlay inspect
```

Inspection reports package manifests, matched and skipped entries, root patch
contributions, deduplication, compose order, and conflict sources. For
machine-readable inspection, use JSON mode through the standalone executable as
described in [For Agents And Scripts](#for-agents-and-scripts).

For release validation, use a temporary downstream app; see
[Downstream smoke for package-provided patches](#downstream-smoke-for-package-provided-patches).

If the providing package's own tests rely on the patched behavior, also use the
[Test with committed patches](#test-with-committed-patches) CI sequence.

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

These helpers are for root-owned patches committed by the application or
workspace. Published packages that ship patch files for their direct runtime
dependencies should use package-provided patches instead.

## How It Works

Patch files are the committed source of patched package content. A
package-provided patch also commits `patchwork.yaml` to declare that content to
downstream applications.

Committed state:

- `patches/<pkg>@<version>.patch`: the reviewable patch file.
- `patchwork.yaml`: package-provided patch declarations, only for packages that
  publish patches for downstream applications.

Local edit state:

- `.patchwork/<pkg>@<version>/`: the editable work-in-progress copy created by
  `patchwork patch`.
- `.patchwork/<pkg>@<version>/.patchwork/`: edit-session metadata and baseline
  snapshots used by `patchwork commit`.

Generated apply state:

- `.dart_tool/patchwork/<pkg>@<version>/`: generated package output created by
  `patchwork apply`.
- `pubspec_overrides.yaml`: generated pub wiring that points selected packages
  at applied output.

Patchwork does not use a committed edit-session or apply-state file. Historical
and stale patch inventory is derived from safe
`patches/<pkg>@<version>.patch` filenames. Generated output contains ownership
markers so Patchwork can refresh or delete only directories it created.

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

If the upstream release still needs your fix, carry the older patch file onto
the currently resolved source:

```sh
dart run patchwork carry collection --from 1.19.0
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
then try `patchwork carry <pkg> --from <oldVersion>` to carry the older patch
onto the current source. Use `--partial` when you want Patchwork to keep
applicable hunks and write reject details for manual repair. If the older patch
no longer applies cleanly, create a fresh edit with `patchwork patch <pkg>` and
port the relevant changes manually from the stale patch file.

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

Use the CI path that matches the patch owner:

- Root project: run [Test with committed patches](#test-with-committed-patches).
- Package-provided: run
  [Downstream smoke](#downstream-smoke-for-package-provided-patches). Also run
  [Test with committed patches](#test-with-committed-patches) when the
  providing package's own checks need patched behavior.

A fresh checkout should not depend on `.dart_tool/patchwork/` or
`pubspec_overrides.yaml` already being present. CI should recreate generated
state from committed Patchwork files before running checks that need patched
behavior.

### Test with committed patches

Use this whenever the current package itself needs patched dependency behavior
while running analysis or tests. It applies to root project patches, and also
to packages that provide patches while testing themselves:

```sh
dart pub get
dart run patchwork apply
dart run patchwork doctor
dart analyze
dart test
```

Use `patchwork doctor` when CI should fail on missing, stale, or unapplied patch
state. Use `patchwork doctor --explain` when CI logs should include the next
repair action for each diagnostic. Use `patchwork doctor --setup` when CI
should verify repository configuration.

Reserve `--no-pub-get` for low-level scripts that intentionally separate
Patchwork filesystem changes from pub resolution refresh. Normal interactive
and CI usage should let Patchwork run `dart pub get`.

### Publish dry-run

Run the publish dry-run in the same job if that matches your package release
checks:

```sh
dart pub publish --dry-run
```

`patchwork.yaml` and `patches/<pkg>@<version>.patch` are committed package
files. `.dart_tool/patchwork/` and `pubspec_overrides.yaml` are local generated
state, not package contents that downstream consumers resolve from.

### Downstream smoke for package-provided patches

A package that provides patches is still the root package during its own CI.
Its `patchwork.yaml` is meant for downstream applications, so the providing
package does not discover itself as a package-provided patch source.

Keep one downstream smoke test when the package-provided patch is part of the
release contract. This proves the providing package is discovered from a
consumer dependency graph, which the providing package's own tests cannot
prove. Create a temporary app that depends on the providing package and, only
if the test imports target APIs directly, the patched target package. Then run
`dart run patchwork overlay inspect` and a focused behavior check in that app.

A minimal CI smoke can use a temporary app. Replace the package name, path, and
final behavior command:

```sh
tmp_dir="$(mktemp -d)"
dart create -t console --no-pub "$tmp_dir/app"
cd "$tmp_dir/app"
dart pub add "your_package@{path: /absolute/path/to/providing/package}"
# Only if the smoke imports patched target APIs directly:
# dart pub add target_package
dart pub get
dart run patchwork overlay inspect
# Replace with the focused behavior check for your package.
dart run bin/app.dart
```

The downstream app does not need a direct Patchwork dependency just to run
`dart run patchwork`; the providing package brings Patchwork into the
dependency graph.

Prefer a providing-package behavior check when the patched behavior is
observable through the providing package.

## For Agents And Scripts

Follow this checklist before mutating a project.

Before changing files:

- Choose exactly one patch owner from
  [Choose The Workflow](#choose-the-workflow). Do not infer ownership from the
  first command that happens to work.
- Run or verify `dart pub get`, then read `pubspec.yaml`, `pubspec.lock`,
  `.dart_tool/package_config.json`, and, for package-provided patches,
  `.dart_tool/package_graph.json` before choosing a target version.
- For root project patches, verify the target package is selected by the
  current pub resolution and has lockfile metadata. It can be direct or
  transitive.
- For package-provided patches, verify the target package and `patchwork` are
  both under the providing package's `dependencies`, not `dev_dependencies`,
  before running `patchwork patch` or `overlay add`.
- If any required dependency relationship or pub resolution file is missing,
  stop and report the missing fact instead of guessing a workflow.
- Use dependency names such as `collection`; do not pass `pub:collection`,
  `collection@1.19.1`, `package:collection/collection.dart`, paths, git URLs,
  or workspace package names. For path or git dependencies, still pass only the
  dependency key from `pubspec.yaml`.
- List expected commit artifacts before mutating: root project patches commit
  `patches/<pkg>@<version>.patch` when a patch file is produced;
  package-provided patches commit both `patchwork.yaml` and
  `patches/<pkg>@<version>.patch` after a reviewed patch file exists.
- Also list state that must remain uncommitted: `.patchwork/`,
  `.dart_tool/patchwork/`, and `pubspec_overrides.yaml`.

While patching:

- Follow the selected owner workflow's command sequence. Do not keep probing
  global executables, sibling checkouts, or unrelated local tool state to decide
  how Patchwork should be installed in the current project.
- If `patchwork commit` reports no changes, stop the patch workflow. Do not run
  `overlay add`, create `patchwork.yaml`, or claim a patch artifact exists.
- After `patchwork commit`, inspect the patch file itself. For package-provided
  patches, follow [Review the patch file](#review-the-patch-file) before running
  `overlay add`. Do not ship upstream package tests, examples, docs, or
  unrelated cleanup in a package-provided runtime patch.

Before finishing:

- Report which [CI](#ci) path applies.
- If the repository has CI configuration, update it to run the selected CI
  path. If no CI file exists, say that explicitly.
- Run `git status` and compare changed files with the expected commit
  artifacts and intentional CI/docs changes.
- For package-provided patches, update CI when the providing package's tests
  rely on patched dependency behavior, and validate published behavior with a
  temporary downstream app that depends on the providing package. Add the
  patched target package there only when the smoke test imports target APIs
  directly.

Use `--json` when a script, editor, or agent needs structured Patchwork state
instead of human-readable text:

```sh
patchwork status --json
patchwork doctor --explain --json
patchwork overlay inspect --json
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

Global activation is optional for interactive use, but useful for scripts,
editors, and agents that need clean JSON output:

```sh
dart pub global activate patchwork
patchwork status --json
```

## Command Reference

Use these commands as `dart run patchwork ...` from a project, or as
`patchwork ...` after global activation.

Create and update patches:

- `patchwork patch <pkg> [--continue [version]] [--force] [--json]`: create a
  source-based edit.
- `patchwork carry <pkg> [--from version] [--partial] [--json]`: carry a stale
  patch into a current-version edit.
- `patchwork commit [pkg] [--json]`: commit open edits into patch files.

Activate patches:

- `patchwork apply [pkg] [--no-pub-get] [--json]`: apply committed patches and
  refresh pub resolution.
- `patchwork undo <pkg> [--no-pub-get] [--json]`: remove one applied patch and
  refresh pub resolution.

Maintain state:

- `patchwork remove <pkg> [version] [--dry-run] [--force] [--no-pub-get] [--json]`:
  remove selected Patchwork artifacts safely.
- `patchwork prune [--dry-run] [--force] [--no-pub-get] [--json]`: remove stale
  patch files and unreferenced generated output.

Inspect and troubleshoot:

- `patchwork status [--json]`: show patch and override state.
- `patchwork doctor [--setup] [--explain] [--json]`: check local readiness,
  setup recommendations, and optional remediation actions.

Package-provided patches:

- `patchwork overlay add <pkg> [--reason <text>] [--json]`: register a
  package-provided patch in `patchwork.yaml`.
- `patchwork overlay inspect [--json]`: inspect package-provided patches and
  composition diagnostics.

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

## Runnable Example

The repository contains a runnable example under `examples/hello_patch`. The
package-level `example/README.md` links to that walkthrough for pub.dev.

## Contributing

When developing Patchwork itself from a local checkout, use a path dependency in
the test project that exercises the local package:

```yaml
dev_dependencies:
  patchwork:
    path: ../path/to/patchwork/pub/patchwork
```

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
