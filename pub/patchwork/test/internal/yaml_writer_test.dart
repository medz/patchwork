import 'package:patchwork/src/internal/yaml_writer.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  test('round-trips map list items with nested list and empty map values', () {
    final yaml = formatYamlMap({
      'items': [
        {
          'name': 'foo',
          'tags': ['stable', 'patched'],
          'empty': <String, Object?>{},
        },
      ],
    });

    final decoded = loadYaml(yaml);

    expect(decoded, isA<YamlMap>());
    final items = (decoded as YamlMap)['items'] as YamlList;
    final item = items.single as YamlMap;
    expect(item['name'], 'foo');
    expect(item['tags'], ['stable', 'patched']);
    expect(item['empty'], isA<YamlMap>());
  });
}
