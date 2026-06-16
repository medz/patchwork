# Repository Guidelines

## Project Structure & Module Organization

Patchwork is a Dart workspace. The root `pubspec.yaml` defines the workspace and shared development dependencies. The publishable package lives in `pub/patchwork`, with the executable in `bin/patchwork.dart`, public exports in `lib/patchwork.dart`, and implementation code under `lib/src/` by domain (`cli`, `pub`, `patch`, `lock`, `internal`, and related helpers). Tests live in `pub/patchwork/test` and mirror those domains, with end-to-end coverage in `test/e2e`. Runnable smoke examples are under `examples/hello_patch`.

## Build, Test, and Development Commands

Install package dependencies before local work:

```sh
dart pub get
cd pub/patchwork && dart pub get
cd examples/hello_patch/app && dart pub get
```

Run the CI-style checks from the repository root unless noted:

```sh
dart tool/quality_guard.dart
```

## Coding Style & Naming Conventions

Use standard Dart formatting; do not hand-align code that `dart format` will rewrite. The project includes `package:lints/recommended.yaml`, so prefer idiomatic Dart, explicit small types, and clear error paths. Name test files with `_test.dart`. Keep new source files grouped by feature under the existing `lib/src/<domain>/` folders rather than adding broad utility modules.

## Testing Guidelines

The test suite uses `package:test`. Add focused unit tests beside the affected domain, and use `test/e2e` for full patch workflow behavior. There is no separate coverage threshold, but lockfile, source resolution, patch-file, override safety, status/doctor, and CLI behavior should be covered when changed. If a change touches workspace resolution or the example flow, run `dart tool/quality_guard.dart` before treating the change as ready.

## Commit & Pull Request Guidelines

Recent history follows conventional commits such as `feat:`, `fix:`, `docs:`, and `chore:`. Keep commits scoped and include issue or PR references when relevant, for example `fix: reject root pub patch targets (#38)`. PRs should describe the behavior change, list validation commands run, link related issues, and call out publish or example-flow implications.

## Patchwork State & Configuration

Patchwork commits durable patch state in consumer projects as `patchwork.lock` plus `patches/<pkg>@<version>.patch`. Editable work lives in `.patchwork/<pkg>@<version>/`. Generated apply output lives in `.dart_tool/patchwork/<pkg>@<version>/`, and `pubspec_overrides.yaml` should stay uncommitted. In this repository, example patch artifacts are ignored so the walkthrough can be rerun cleanly. The local design scratch file `docs/v0.2-programmable-model.zh.md` must remain ignored and untracked.
