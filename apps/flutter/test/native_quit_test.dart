import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocox/src/native_quit.dart';

const _channel = MethodChannel('pocox/app_quit');

/// Delivers a native `quit` to the Dart handler, as the gate does.
Future<void> _nativeQuit() async {
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        _channel.name,
        const StandardMethodCodec().encodeMethodCall(const MethodCall('quit')),
        (_) {},
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<String> calls;

  void mockNative({bool pending = false}) {
    calls = [];
    messenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call.method);
      return call.method == 'ready' ? pending : null;
    });
  }

  tearDown(() => messenger.setMockMethodCallHandler(_channel, null));

  test('a quit requested before Dart was ready runs once attached', () async {
    mockNative(pending: true);
    var quits = 0;
    await NativeQuitChannel(onQuit: () async => quits++).attach();
    expect(calls, ['ready']);
    expect(quits, 1);
  });

  test('no pending quit runs nothing until native asks', () async {
    mockNative();
    var quits = 0;
    await NativeQuitChannel(onQuit: () async => quits++).attach();
    expect(quits, 0);
    await _nativeQuit();
    await _nativeQuit();
    // Each native request reaches the quit; joining is the quit's job.
    expect(quits, 2);
    expect(calls, ['ready']);
  });

  test('termination is allowed only when the caller says so', () async {
    mockNative();
    final quit = NativeQuitChannel(onQuit: () async {});
    await quit.attach();
    expect(calls, isNot(contains('allowTerminate')));
    await quit.allowTerminate();
    expect(calls, ['ready', 'allowTerminate']);
  });

  test('a missing native gate is not an error', () async {
    var quits = 0;
    final quit = NativeQuitChannel(onQuit: () async => quits++);
    await quit.attach();
    await quit.allowTerminate();
    expect(quits, 0);
  });
}
