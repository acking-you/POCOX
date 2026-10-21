import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;
import 'package:image/image.dart' as image;
import 'package:pocox/src/bridge_api_rust.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/image_attachments.dart';
import 'package:pocox/src/rust/frb_generated.dart';
import 'package:pocox/src/rust/api/bridge/attachments.dart' as native;
import 'support/native_diff_fixture.dart';

void main() {
  final library = Platform.environment['POCOX_NATIVE_TEST_LIB'];
  test(
    'native admission, history, images and review cross the real bridge',
    () async {
      await RustLib.init(externalLibrary: ExternalLibrary.open(library!));
      const api = RustBridgeApi();
      final control = api.composerCreate();
      control.apply(ComposerAction.enqueue, id: 7);
      final lease = control.beginSend();
      control.apply(ComposerAction.beginQueued, id: 7);
      control.apply(ComposerAction.unknown, id: 7);
      control.finishSend(lease);
      control.apply(ComposerAction.resume);
      expect(
        () => control.apply(ComposerAction.beginQueued, id: 7),
        throwsA(anything),
      );
      control.apply(ComposerAction.retryUnknown, id: 7);
      control.apply(ComposerAction.beginQueued, id: 7);
      control.apply(ComposerAction.accept, id: 7);
      expect(control.state.queue, isEmpty);

      final order = await api.historyMerge(
        ['tail'],
        ['turn'],
        ['first', 'tail', 'last'],
        ['turn', 'turn', 'turn'],
        ['turn'],
        false,
      );
      expect(order, [1, 0, 3]);
      final index = await api.reviewIndex([
        diffFixture('中文.dart'),
        diffFixture('中文.dart', added: ['a', 'b']),
      ]);
      expect(index.files.single.sections, [(0, 0), (1, 0)]);
      expect((index.added, index.removed), (3, 2));

      final bytes = image.encodePng(image.Image(width: 6, height: 4));
      final prepared = await processImageNative(bytes);
      expect(
        (prepared.width, prepared.height, prepared.mime),
        (6, 4, 'image/png'),
      );
      expect(prepared.bytes, bytes);
      expect(decodeImageDataUrl(prepared.dataUrl), bytes);

      final dir = await Directory.systemTemp.createTemp('pocox-native-test-');
      try {
        final path = '${dir.path}/picked.txt';
        await File(path).writeAsString('picked by the user');
        final handles = [
          for (var i = 0; i < 4; i++)
            await native.attachmentReadFile(path: path),
        ];
        await expectLater(
          native.attachmentReadFile(path: path),
          throwsA(anything),
        );
        for (final handle in handles) {
          handle.dispose();
        }
        final next = await native.attachmentReadFile(path: path);
        next.dispose();
      } finally {
        await dir.delete(recursive: true);
      }
    },
    skip: library == null
        ? 'set POCOX_NATIVE_TEST_LIB to the freshly built bridge'
        : false,
  );
}
