import 'package:hooks/hooks.dart';
import 'package:patchwork/hooks.dart' as patchwork;

Future<void> main(List<String> args) async {
  await build(args, (input, output) async {
    patchwork.apply(input, output, package: 'greeter');
  });
}
