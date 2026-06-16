# Patchwork Example: Local Greeter Patch

This example shows the pub MVP workflow with a small Dart app and a local pub
dependency named `greeter`.

The app starts by printing the dependency output:

```sh
cd examples/hello_patch/app
dart pub get
dart run bin/app.dart
```

Start a Patchwork edit session for the resolved pub package:

```sh
dart run patchwork patch greeter
```

Patchwork prints an edit directory similar to:

```text
.patchwork/greeter@0.1.0
```

Edit `lib/greeter.dart` inside that directory. For example:

```dart
String greeting(String name) {
  return 'Hello from a patch, $name!';
}
```

Commit the edit into a patch file:

```sh
dart run patchwork commit greeter
```

Apply committed patches and refresh pub resolution:

```sh
dart run patchwork apply
dart pub get
dart run bin/app.dart
dart run patchwork status
```

After the patch is applied, the app prints:

```text
Hello from a patch, Patchwork!
```

The generated Patchwork state lives under `.dart_tool/patchwork/` and
`pubspec_overrides.yaml`. The editable work-in-progress copy lives under
`.patchwork/`. The committed state for a real project is `patchwork.lock` plus
`patches/*.patch`.

This example uses a path dependency so it can run without a hosted package.
Patchwork still targets the package by pub package name (`greeter`); the
unsupported `path:` target syntax is not used.

Projects usually add Patchwork as a dev dependency and run it with
`dart run patchwork`. Global activation is optional.
