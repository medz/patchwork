# Patchwork

Patchwork manages dependency patches for Dart projects. The current pub MVP
keeps dependency edits in reviewable patch files: edit a resolved package,
commit the edit, then reapply it through pub path overrides.

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

## Commands

```text
patchwork patch <target>              Create an editable patch session.
patchwork patch --commit <target|dir> Commit an edit session into a patch.
patchwork apply [target]              Apply committed pub patches.
patchwork status                      Show patch and generated override state.
patchwork doctor                      Check local readiness.
```

Targets default to pub package names. `collection` and `pub:collection` refer
to the same target. The pub MVP does not support `sdk:` targets, `path:` target
syntax, hooks, `patchwork run`, or undo commands.

## Project Files

Commit these files in projects that use Patchwork:

- `patchwork.lock`
- `patches/pub/*.patch`

Patchwork generates these files and directories locally:

- `.dart_tool/patchwork/`
- `pubspec_overrides.yaml`

`patchwork apply` never mutates the primary `pubspec.yaml`; it writes
`pubspec_overrides.yaml` so pub resolves patched packages through generated path
overrides.

## Example

The repository contains a runnable example under `examples/hello_patch`. The
package-level `example/README.md` links to that walkthrough for pub.dev.
