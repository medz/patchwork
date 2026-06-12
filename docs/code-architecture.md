# Patchwork Code Architecture

This document defines the MVP architecture for `pub/patchwork`. It is the
implementation contract for #4 through #11 and should be updated intentionally
when the implementation proves that a boundary is wrong.

## MVP Scope

The first Patchwork version supports pub package patches only. It must cover
target parsing, pub package resolution, edit sessions, patch commits,
`patchwork.lock`, generated path overrides, `status`, `doctor`, and end-to-end
fixtures.

The MVP does not include `sdk:flutter`, `sdk:dart`, hooks integration,
`patchwork run -- <command>`, Flutter current element patches, or release
publishing polish.

## Package Layout

```text
pub/patchwork/
  bin/
    patchwork.dart
  lib/
    patchwork.dart
    src/
      cli/
        command_runner.dart
        commands/
          apply_command.dart
          doctor_command.dart
          patch_command.dart
          status_command.dart
      app/
        apply_patches.dart
        commit_patch_session.dart
        read_status.dart
        run_doctor.dart
        start_patch_session.dart
      target/
        target.dart
        target_parser.dart
      pub/
        package_resolution.dart
        pub_workspace.dart
      store/
        edit_session.dart
        patchwork_store.dart
      manifest/
        patchwork_manifest.dart
        patchwork_manifest_codec.dart
      patch/
        patch_file.dart
        patch_hash.dart
        patch_tool.dart
      diagnostics/
        diagnostic.dart
        exit_code.dart
      io/
        file_system.dart
        process_runner.dart
  test/
    cli/
    fixtures/
    target/
    pub/
    store/
    manifest/
    patch/
```

`bin/patchwork.dart` wires the real file system, process runner, command
runner, and output streams. It should not contain command behavior.

`lib/patchwork.dart` is the public library entrypoint. For the MVP it should
stay small and export only stable API that is useful outside the CLI.

Everything under `lib/src/` is implementation detail. Tests may import `src`
libraries when they are testing module boundaries directly.

## Layer Rules

The CLI layer parses arguments, selects commands, formats output, and maps typed
diagnostics to exit codes. Command classes call application use cases instead of
performing package resolution, file writes, diff generation, or manifest edits
directly.

The application layer owns workflows:

- `start_patch_session` creates a baseline and editable package copy.
- `commit_patch_session` turns edits into a validated patch and manifest entry.
- `apply_patches` materializes generated path overrides.
- `read_status` reports session, manifest, hash, and apply state.
- `run_doctor` checks local tool and workspace readiness.

Domain modules are narrow:

- `target` parses strings such as `foo` and `pub:foo`. A missing prefix means
  `pub:` for the MVP. Parsing must be pure and unit-testable.
- `pub` reads the current pub workspace and resolves package names to immutable
  package metadata.
- `store` owns `.dart_tool/patchwork/` paths, baselines, editable copies, and
  session metadata.
- `manifest` owns `patchwork.lock` models and stable YAML read/write behavior.
- `patch` owns diff creation, patch apply validation, and content hashes.
- `io` contains side-effect adapters for files, processes, clocks, and
  environment access.
- `diagnostics` defines typed errors, hints, and exit code mapping.

Pure modules must not read files, spawn processes, use global mutable state, or
write to stdout/stderr. Root paths, clocks, process runners, and environment
access must be passed in from the application or IO boundary.

## State Ownership

Committed project state:

- `patchwork.lock`
- patch files under `patches/pub/`
- source, tests, fixtures, and documentation

Internal generated state:

- `.dart_tool/patchwork/sessions/`
- `.dart_tool/patchwork/baselines/`
- `.dart_tool/patchwork/tmp/`
- `.dart_tool/patchwork/cache/`

The only generated integration output allowed outside `.dart_tool/patchwork/`
is `pubspec_overrides.yaml`, written by `patchwork apply` so pub can resolve
patched packages through path overrides. Patchwork must never mutate the
project's primary `pubspec.yaml` to apply patches.

Generated output must be reproducible from committed state. A command may delete
and recreate generated Patchwork output, but it must not delete unrelated
ignored files.

## Manifest Rules

`patchwork.lock` is the committed source of truth for applied patches. Its
writer must produce stable ordering and formatting so repeated commands do not
create noisy diffs.

A patch commit must validate that the generated patch applies to a fresh
baseline before updating `patchwork.lock`. Hash metadata must describe the patch
content that was validated, not an editable working copy.

Manifest writes are all-or-nothing from the caller's perspective. A failed patch
commit must not leave a manifest entry pointing at a missing or invalid patch
file.

## Diagnostics

Expected failures use typed diagnostics instead of ad hoc string exceptions. A
diagnostic includes a stable code, severity, message, optional hint, and optional
location.

CLI exit codes:

- `0`: success
- `1`: valid command, expected user-facing failure
- `2`: usage error or invalid arguments
- `70`: unexpected internal failure

The CLI may render friendly text, but tests should assert diagnostic codes and
exit codes at module boundaries.

## Testing Bar

Each implementation issue should add tests at the boundary it introduces:

- #4: command parsing, command selection, usage errors, and exit code mapping.
- #5: target parsing and pub workspace/package resolution fixtures.
- #6: store layout, session creation, idempotency, and missing target handling.
- #7: diff creation, apply validation, hash stability, and failed commit safety.
- #8: manifest model validation and stable YAML round trips.
- #9: generated `pubspec_overrides.yaml`, idempotent apply, and no primary
  `pubspec.yaml` mutation.
- #10: `status` and `doctor` diagnostics for clean, dirty, missing, and stale
  states.
- #11: end-to-end CLI fixtures covering the MVP flow from `patchwork patch` to
  `patchwork status`.

Tests should prefer small fixtures over large golden directories. Golden text is
acceptable for CLI help and stable file output when it protects a user-facing
contract.

## Review Checklist

Before merging implementation work, verify that:

- command handlers stay thin;
- side effects go through `io`, `store`, `pub`, `manifest`, or `patch`;
- target parsing remains pure;
- generated state is isolated and reproducible;
- committed state is limited to the manifest and patch files;
- diagnostics are typed and testable;
- tests cover the boundary introduced by the issue;
- out-of-scope SDK and hook features remain out of the pub MVP.
