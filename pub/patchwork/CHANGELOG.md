# Changelog

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
- Added committed `patchwork.lock` metadata and `patches/pub/*.patch` files.
- Added generated `pubspec_overrides.yaml` support for applying patches through
  pub path overrides.
- Added end-to-end fixtures for the patch workflow.
