# Changelog

## Unreleased

## 0.6.2 - 2026-06-30

- Split Patchwork state planning into dedicated edit, apply, cleanup, and undo
  planner components while keeping command execution behavior stable.
- Made explicit `patchwork apply <pkg>` validate committed patch content before
  materializing generated output, matching apply-all validation.
- Tightened artifact identity parsing and kept carry override-conflict hints
  tied to the actual `patchwork carry` command.

## 0.6.1 - 2026-06-25

- Lowered the minimum Dart SDK to `3.10.0` while keeping Patchwork's
  package-provided build hook and overlay behavior intact.
- Added CI coverage for Dart `3.10.0`, Dart stable, Flutter `3.38.2`, and
  Flutter stable dependency resolution.
- Refined README positioning around package-provided patches and project-owned
  patch workflows.

## 0.6.0 - 2026-06-23

- Added root-owned `patchwork patch` and `patchwork carry` support for
  transitive packages selected by the current pub resolution, while keeping
  package-provided overlays direct-only.
- Switched Patchwork-owned YAML writes for `patchwork.yaml` and
  `pubspec_overrides.yaml` to parser-backed `yaml_edit` updates.
- Refreshed README guidance for package-provided patches and hook workflows.

## 0.5.0 - 2026-06-21

- Added `patchwork carry <pkg> [--from version]` to carry stale patch files into
  current-version edit sessions for dependency upgrades.
- Removed `patchwork.lock` from root patch workflows. Patch files are now the
  committed patch truth; edit sessions keep hidden baselines under `.patchwork/`
  and applied output keeps generated ownership markers under `.dart_tool/`.
- Made CLI `apply` and `undo` refresh pub resolution by default, with
  `--no-pub-get` for scripts that need the lower-level filesystem step.
- Added `patchwork remove` and `patchwork prune` for safe cleanup of stale patch
  files, open edit directories, and Patchwork-owned generated state.
- Added doctor setup checks and explain-mode remediation details for project
  setup, generated state, and next-step guidance.
- Added overlay inspection for provider manifests, matched contributions,
  deduplication, and conflict diagnostics.
- Reduced build hook no-op noise when overlay manifests are absent.
- Split Patchwork internals around edit preparation, patch commits, applied
  output materialization/activation, dependency override state, status
  inspection, and overlay publishing.
- Reorganized README guidance around task-oriented workflows, generated state,
  CI, hooks, and provider overlays.

## 0.4.0 - 2026-06-20

- Added package-provided overlays through `patchwork.yaml`, the
  `patchwork overlay <pkg>` command, and Patchwork's built-in `hook/build.dart`
  for composing matching dependency patch contributions in downstream apps.
- Added opt-in Dart build hook helpers through `package:patchwork/hooks.dart`
  for automatically applying committed patches from user-owned `hook/build.dart`
  files.

## 0.3.0 - 2026-06-18

- Added `--json` output for `patch`, `commit`, `apply`, `undo`, `status`, and
  `doctor`.
- Rejected same-package `dependency_overrides` from project `pubspec.yaml`
  files before `patch` or `apply` mutates Patchwork state.
- Derived historical patch inventory from durable `patches/*.patch` files while
  keeping current patch ownership in `patchwork.lock`.

## 0.2.0 - 2026-06-17

- Rebuilt Patchwork around a library-first programmable model with CLI commands
  as thin adapters.
- Replaced patch sessions, baselines, stores, manifests, and target syntax with
  the v0.2 paths: `.patchwork/<pkg>@<version>/`,
  `patches/<pkg>@<version>.patch`, and
  `.dart_tool/patchwork/<pkg>@<version>/`.
- Added `patchwork commit [pkg]` and removed `patchwork patch --commit`.
- Added `patchwork undo <pkg>` for safe removal of lock-owned
  `pubspec_overrides.yaml` entries and generated applied directories.
- Added `patchwork patch <pkg> [--continue [version]]` for explicit patch
  carry-forward across dependency upgrades.
- Reworked `patchwork.lock` into a v2 lockfile with source `sha256`,
  `patch.commit-sha256`, and `applied.patch-sha256` records.
- Added patch history `commit-sha256` records so `--continue <version>` can
  safely reuse older patch files after a dependency upgrade.
- Removed obsolete historical patch files when an unchanged fresh edit proves
  the upgraded dependency source already contains the fix.
- Added source records for hosted, custom hosted, path, and git dependencies.

## 0.1.1 - 2026-06-15

- Added clearer `dart pub get` next-step guidance after successful
  `patchwork apply`.
- Hardened project-visible writes for `patchwork.lock`, committed patch files,
  and `pubspec_overrides.yaml`.
- Added CI release gates for `dart pub publish --dry-run` and an example smoke
  test from a clean archive copy.
- Updated the package README to position Patchwork as reviewable Dart pub
  dependency patches without `.pub-cache` edits.
- Rejected root packages as patch targets to avoid confusing self-patches.

## 0.1.0 - 2026-06-13

- Added the pub package Patchwork MVP.
- Added `patch`, `patch --commit`, `apply`, `status`, and `doctor` commands.
- Added committed `patchwork.lock` metadata and `patches/*.patch` files.
- Added generated `pubspec_overrides.yaml` support for applying patches through
  pub path overrides.
- Added end-to-end fixtures for the patch workflow.
