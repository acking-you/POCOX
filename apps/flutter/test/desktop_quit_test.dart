import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocox/src/desktop_tray.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const window = MethodChannel('window_manager');
  const tray = MethodChannel('tray_manager');
  late List<String> calls;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    calls = [];
    messenger.setMockMethodCallHandler(window, (call) async {
      calls.add('window.${call.method}');
      return call.method == 'isMinimized' ? false : null;
    });
    messenger.setMockMethodCallHandler(tray, (call) async {
      calls.add('tray.${call.method}');
      return null;
    });
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(window, null);
    messenger.setMockMethodCallHandler(tray, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test(
    'quit hides immediately and joins cleanup before destroying resources',
    () async {
      final started = Completer<void>();
      final cleanup = Completer<void>();
      var stops = 0;
      final controller = DesktopTray.forTesting(() {
        stops++;
        started.complete();
        return cleanup.future;
      });
      final quitting = controller.quit();
      expect(identical(controller.quit(), quitting), isTrue);
      await started.future;
      expect(calls, ['window.hide']);
      expect(controller.quitStatus.value?.stopping, isTrue);
      expect(stops, 1);

      cleanup.complete();
      await quitting;
      expect(calls, [
        'window.hide',
        'tray.destroy',
        'window.setPreventClose',
        'window.destroy',
      ]);
      expect(controller.quitStatus.value, isNull);
    },
  );

  test('failed cleanup restores the window and a later quit retries', () async {
    var stops = 0;
    final controller = DesktopTray.forTesting(() async {
      if (++stops == 1) {
        throw StateError('owned process still running');
      }
    });
    await controller.quit();
    expect(
      calls,
      containsAllInOrder(['window.hide', 'window.show', 'window.focus']),
    );
    expect(calls, isNot(contains('window.destroy')));
    expect(calls, isNot(contains('tray.destroy')));
    expect(
      controller.quitStatus.value?.error,
      contains('owned process still running'),
    );
    calls.clear();
    await controller.quit();
    expect(stops, 2);
    expect(calls.last, 'window.destroy');
    expect(controller.quitStatus.value, isNull);
  });

  test('a window dismissal failure still stops hosting and exits', () async {
    messenger.setMockMethodCallHandler(window, (call) async {
      if (call.method == 'hide') {
        throw PlatformException(code: 'window-unavailable');
      }
      calls.add('window.${call.method}');
      return null;
    });
    var stopped = false;
    await DesktopTray.forTesting(() async => stopped = true).quit();
    expect(stopped, isTrue);
    expect(calls.last, 'window.destroy');
  });
}
