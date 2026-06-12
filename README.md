# Patchwork

Patchwork is a patch management tool for Dart projects.
The current MVP focuses on pub packages: create an editable copy of a resolved
dependency, commit the edit as a patch file, and apply committed patches through
generated `pubspec_overrides.yaml` path overrides.

## Repository Layout

```text
pub/patchwork/       Dart package implementation
docs/                Architecture notes for the pub MVP
examples/            Workspace-level runnable examples
.github/             CI and repository metadata
```

## Package

The publishable package lives in `pub/patchwork`.

```sh
cd pub/patchwork
dart pub get
dart analyze
dart test
dart pub publish --dry-run
```

## Example

The workspace example demonstrates the MVP flow against a small app and a local
pub dependency:

```sh
cd examples/hello_patch/app
dart pub get
dart run patchwork doctor
dart run patchwork patch greeter
```

See `examples/README.md` for the complete walkthrough.

## Project State

Patchwork commits portable state to:

- `patchwork.lock`
- `patches/pub/*.patch`

It generates local state in:

- `.dart_tool/patchwork/`
- `pubspec_overrides.yaml`

Generated state should be reproducible from the committed lockfile and patch
files.
