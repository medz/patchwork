# Patchwork

Patchwork keeps Dart pub dependency fixes in reviewable patch files without
editing your shared `.pub-cache`.

Use it when you need a local dependency fix that should survive fresh
checkouts, code review, and CI. Patchwork copies a resolved dependency into an
editable workspace, commits the edit as `patches/pub/*.patch`, and materializes
the patch through generated pub path overrides.

## Why Patchwork

Manual `.pub-cache` edits are fast, but they are local to one machine and easy
to lose. Patchwork keeps the durable part of the change in your project so the
same patch can be reviewed, committed, and applied by teammates or CI.

Patchwork is a good fit for small dependency fixes while you wait for an
upstream release. Prefer a fork or vendored dependency when the change is large,
long-lived, security-sensitive, or needs its own release process.

## Install

Add Patchwork as a dev dependency in the project that owns the patch files.

After the package is published:

```sh
dart pub add dev:patchwork
```

For repository development or unpublished testing:

```yaml
dev_dependencies:
  patchwork:
    path: ../path/to/patchwork/pub/patchwork
```

Run commands with `dart run`:

```sh
dart run patchwork --help
```

Global activation is optional for users who prefer a standalone executable.

## Workflow

Run Patchwork from the Dart package or workspace you want to patch.

```sh
dart pub get
dart run patchwork doctor
dart run patchwork patch collection
```

Edit the directory printed by `patchwork patch`, then commit it:

```sh
dart run patchwork patch --commit collection
```

Apply committed patches:

```sh
dart run patchwork apply
dart pub get
dart run patchwork status
```

After a successful apply, Patchwork prints the `dart pub get` next step so pub
refreshes dependency resolution through the generated overrides.

## What To Commit

Commit these files in projects that use Patchwork:

- `patchwork.lock`
- `patches/pub/*.patch`

These files are the reviewable source of truth for your dependency patches.

## What Stays Generated

Do not commit Patchwork's generated integration state:

- `.dart_tool/patchwork/`
- `pubspec_overrides.yaml`

`patchwork apply` never mutates the primary `pubspec.yaml`; it writes
`pubspec_overrides.yaml` so pub resolves patched packages through generated path
overrides. `pubspec_overrides.yaml` is shared with other tools and local
workflow, so Patchwork only manages its own patch override entries.

## Commands

```text
patchwork patch <target>              Create an editable patch session.
patchwork patch --commit <target|dir> Commit an edit session into a patch.
patchwork apply [target]              Apply committed pub patches.
patchwork status                      Show patch and generated override state.
patchwork doctor                      Check local readiness.
```

Targets default to pub package names. `collection` and `pub:collection` refer
to the same target.

## Current Limits

Patchwork 0.1.x focuses on pub packages resolved from `pubspec.lock`. It does
not support:

- `sdk:` targets such as `sdk:flutter`
- explicit `path:` target syntax
- git dependency target syntax
- hooks or automatic `dart pub get`
- `patchwork run`
- undo commands

## Migrating From Cache Patches

If you currently use a cache patch tool or manual `.pub-cache` edits, restore a
clean dependency copy before starting a Patchwork session. Patchwork should
diff from the original dependency source, not from a package that already has
local cache edits applied.

Patchwork does not import other patch formats yet. Recreate the dependency edit
with `patchwork patch <package>`, then commit it with
`patchwork patch --commit <package>`.

## CI Check

Run Patchwork in CI after dependencies are installed:

```sh
dart run patchwork apply
dart pub get
dart run patchwork status
dart test
```

`patchwork status` exits non-zero when committed patches are missing, stale, or
not applied through the generated overrides.

## Example

The repository contains a runnable example under `examples/hello_patch`. The
package-level `example/README.md` links to that walkthrough for pub.dev.
