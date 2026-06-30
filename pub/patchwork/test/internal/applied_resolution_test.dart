import 'dart:io';

import 'package:patchwork/src/applied_marker.dart';
import 'package:patchwork/src/internal/applied_path_policy.dart';
import 'package:patchwork/src/internal/applied_resolution.dart';
import 'package:patchwork/src/internal/path_layout.dart';
import 'package:patchwork/src/model.dart';
import 'package:patchwork/src/pub/package_resolution.dart';
import 'package:test/test.dart';

void main() {
  test('detects pub resolutions that point at Patchwork applied output', () {
    final root = Directory.systemTemp.createTempSync(
      'patchwork_applied_resolution_',
    );
    addTearDown(() => root.deleteSync(recursive: true));

    final layout = PathLayout(root.path);
    final store = AppliedMarkerStore(layout: layout);
    final policy = AppliedPathPolicy(
      rootPath: root.path,
      layout: layout,
      protectedRootPaths: {root.path},
    );

    expect(
      _resolves(
        rootPath: root.path,
        appliedPaths: policy,
        store: store,
        layout: layout,
        resolvedRootPath: layout.appliedPath('greeter', '0.1.0'),
      ),
      isFalse,
    );

    store.write(_marker(layout));

    expect(
      _resolves(
        rootPath: root.path,
        appliedPaths: policy,
        store: store,
        layout: layout,
        resolvedRootPath: layout.appliedPath('greeter', '0.1.0'),
      ),
      isTrue,
    );
    expect(
      _resolves(
        rootPath: root.path,
        appliedPaths: policy,
        store: store,
        layout: layout,
        resolvedRootPath: layout.editPath('greeter', '0.1.0'),
      ),
      isFalse,
    );
  });
}

bool _resolves({
  required String rootPath,
  required AppliedPathPolicy appliedPaths,
  required AppliedMarkerStore store,
  required PathLayout layout,
  required String resolvedRootPath,
}) {
  return resolvesToPatchworkAppliedPath(
    rootPath: rootPath,
    appliedPaths: appliedPaths,
    appliedMarkerStore: store,
    package: 'greeter',
    version: '0.1.0',
    resolved: ResolvedPubPackage(
      version: '0.1.0',
      rootPath: resolvedRootPath,
      source: const PackageSource(type: 'path', sha256: 'source-sha'),
    ),
  );
}

AppliedMarker _marker(PathLayout layout) {
  return AppliedMarker(
    package: 'greeter',
    version: '0.1.0',
    patchSha256: 'patch-sha',
    path: layout.relativeAppliedPath('greeter', '0.1.0'),
    source: null,
  );
}
