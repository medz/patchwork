import 'package:hooks/hooks.dart';
import 'package:patchwork/src/overlay_hook.dart' as patchwork;

Future<void> main(List<String> args) async {
  await build(args, patchwork.applyPackageOverlays);
}
