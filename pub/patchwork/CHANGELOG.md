# Changelog

## Unreleased

- Removed `patchwork.lock` from root patch workflows. Patch files are now the
  committed patch truth; edit sessions keep hidden baselines under `.patchwork/`
  and applied output keeps generated ownership markers under `.dart_tool/`.
- Made CLI `apply` and `undo` refresh pub resolution by default, with
  `--no-pub-get` for scripts that need the lower-level filesystem step.
- Added `patchwork remove` and `patchwork prune` for safe cleanup of stale patch
  files, open edit directories, and Patchwork-owned generated state.
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
