import 'dart:async';

import 'package:file_selector_platform_interface/file_selector_platform_interface.dart'
    as fsel;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/widgets/folder_tree_picker.dart';

import 'fake_bridge_api.dart';
import 'support/screen_harness.dart';

const _service = 'pcx:dev:acp:claude';

class _DirectoryPicker extends FakeFileSelector {
  Completer<String?> result = Completer<String?>();
  int calls = 0;

  @override
  Future<String?> getDirectoryPath({
    String? initialDirectory,
    String? confirmButtonText,
  }) {
    calls++;
    return result.future;
  }
}

Future<void> _open(
  WidgetTester t,
  FakeBridgeApi api, {
  String? initialPath,
}) async {
  await t.pumpWidget(
    host(
      Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showFolderPicker(
              context,
              serviceKey: _service,
              initialPath: initialPath,
            ),
            child: const Text('open'),
          ),
        ),
      ),
      api,
    ),
  );
  await t.tap(find.text('open'));
  await t.pumpAndSettle();
}

void main() {
  for (final (root, target, parent, child) in [
    ('/', '/work/app', '/work', '/work/app/src'),
    ('/work/', '/work/app', '/work', '/work/app/src'),
    (r'D:\', r'D:\work\app', r'D:\work', r'D:\work\app\src'),
    (r'D:\work\', r'D:\work\app', r'D:\work', r'D:\work\app\src'),
  ]) {
    testWidgets('initial path inside root $root preserves breadcrumbs', (
      t,
    ) async {
      final api = FakeBridgeApi();
      api.projectConfigs[_service] = ProjectConfig(projectRoots: [root]);
      api.dirTree[target] = [HostDirEntry(name: 'src', path: child)];
      api.dirTree[parent] = [HostDirEntry(name: 'app', path: target)];
      await _open(t, api, initialPath: target);
      expect(find.byKey(Key('folder-row-$child')), findsOneWidget);
      await t.tap(find.byKey(const Key('folder-up-btn')));
      await t.pumpAndSettle();
      expect(find.byKey(Key('folder-row-$target')), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  }

  testWidgets(
    'native chooser is single-flight, reports errors and retries',
    (t) async {
      final previous = fsel.FileSelectorPlatform.instance;
      final picker = _DirectoryPicker();
      fsel.FileSelectorPlatform.instance = picker;
      addTearDown(() => fsel.FileSelectorPlatform.instance = previous);
      await _open(t, FakeBridgeApi()..hostIsLocal = true);
      await t.tap(find.byKey(const Key('folder-local-btn')));
      await t.pump();
      expect(
        t
            .widget<IconButton>(find.byKey(const Key('folder-local-btn')))
            .onPressed,
        isNull,
      );
      await t.tap(find.byKey(const Key('folder-local-start')));
      await t.pump();
      expect(picker.calls, 1);
      picker.result.completeError(StateError('Folder chooser unavailable'));
      await t.pumpAndSettle();
      expect(find.textContaining('Folder chooser unavailable'), findsOneWidget);
      picker.result = Completer<String?>();
      await t.tap(find.byKey(const Key('folder-local-btn')));
      await t.pump();
      expect(picker.calls, 2);
      // Closing the picker while its native dialog is pending must not pop
      // another route or set state on the disposed picker.
      await t.pumpWidget(const SizedBox.shrink());
      picker.result.complete('/chosen');
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );
}
