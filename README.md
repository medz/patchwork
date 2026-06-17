# Patchwork

[![CI](https://github.com/medz/patchwork/actions/workflows/ci.yml/badge.svg)](https://github.com/medz/patchwork/actions/workflows/ci.yml)
[![pub package](https://img.shields.io/pub/v/patchwork.svg?label=patchwork)](https://pub.dev/packages/patchwork)
[![license](https://img.shields.io/github/license/medz/patchwork.svg)](https://github.com/medz/patchwork/blob/main/LICENSE)

Patchwork is a patch manager for Dart pub dependencies. It creates a fresh
editable copy of a resolved dependency, commits the edit as a versioned patch
file, and applies committed patches through generated
`pubspec_overrides.yaml` path overrides.

## Repository Layout

```text
pub/patchwork/       Publishable Dart package
examples/            Runnable examples
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

The example demonstrates the 0.2 patch flow against a small app and a local pub
dependency:

```sh
cd examples/hello_patch/app
dart pub get
dart run patchwork doctor
dart run patchwork patch greeter
dart run patchwork commit greeter
dart run patchwork apply greeter
dart pub get
```

See `examples/README.md` for the complete walkthrough.

## Project State

Patchwork commits portable state to:

- `patchwork.lock`
- `patches/*.patch`

It generates local state in:

- `.patchwork/`
- `.dart_tool/patchwork/`
- `pubspec_overrides.yaml`

Generated state should be reproducible from the committed lockfile and patch
files.
