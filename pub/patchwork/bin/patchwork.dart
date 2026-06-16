import 'dart:io';

import 'package:patchwork/src/cli/application.dart';

Future<void> main(List<String> arguments) async {
  final app = Application();
  exitCode = await app.run(arguments);
}
