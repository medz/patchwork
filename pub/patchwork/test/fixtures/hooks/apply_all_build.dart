import 'package:hooks/hooks.dart';
import 'package:patchwork/hooks.dart' as patchwork;

Future<void> main(List<String> args) async {
  await build(args, (input, output) async {
    await patchwork.applyAll(input, output);
  });
}
