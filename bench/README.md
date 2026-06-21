# Patchwork Benchmarks

This directory contains repo-local performance baselines for Patchwork core
workflows. The runner is intentionally outside `package:test` so test reporter
work, test concurrency, and full workflow assertions do not pollute timings.

Run all benchmarks from the repository root:

```sh
dart bench/patchwork.dart
```

Print machine-readable JSON:

```sh
dart bench/patchwork.dart --json
```

Run one benchmark group:

```sh
dart bench/patchwork.dart --case package-tree
dart bench/patchwork.dart --case patch-file
dart bench/patchwork.dart --case patchwork-workflow
dart bench/patchwork.dart --case inventory
dart bench/patchwork.dart --case overlay
```

The fixtures write synthetic pub resolution files directly. They do not run
`dart pub get` inside measured loops. The goal is to track Patchwork production
path costs: package-tree hashing/copying, Git-backed patch operations, core
Patchwork workflows, marker and artifact inventory scans, and overlay
composition.

Treat these numbers as local baselines. CI can collect them on demand, but they
are not ordinary PR gates because runner hardware and filesystem cache state add
noise.
