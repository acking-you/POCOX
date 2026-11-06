import 'dart:async';
import 'dart:io';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:pocox/src/bridge_api.dart';

/// The native half of the pairing device store and hardware hint, behind one
/// channel (`DeviceStoreChannel` on iOS and Android). Desktops keep the store
/// in Rust and read their own hardware, so none of this runs there.
const _channel = MethodChannel('pocox/device_store');

/// Whether this platform keeps the device store natively.
bool get nativeDeviceStore => !kIsWeb && (Platform.isIOS || Platform.isAndroid);

/// Install the native device store for this engine's run. Call once per
/// engine, before any other pairing call: a new Android engine replaces an
/// adapter the destroyed one left unanswered. A failure leaves pairing
/// refusing every call, which is safer than a store the platform backs up.
Future<void> installPairingStore(BridgeApi api) async {
  if (!nativeDeviceStore) return;
  try {
    final lockDir = await _channel.invokeMethod<String>('lockDir');
    if (lockDir == null) return;
    await api.pairingInstallNativeStore(
      lockDir: lockDir,
      read: _read,
      write: _write,
    );
  } catch (error) {
    debugPrint('pairing device store not installed: ${error.runtimeType}');
  }
}

/// Never throws: Rust turns a Dart exception here into a panic.
Future<NativeStoreAnswer> _read(String slot) async {
  try {
    final answer = await _channel.invokeMapMethod<String, Object?>('read', {
      'slot': slot,
    });
    return NativeStoreAnswer(
      value: answer?['value'] as String?,
      error: answer == null
          ? 'the device store gave no answer'
          : answer['error'] as String?,
    );
  } catch (error) {
    return NativeStoreAnswer(
      error: 'the device store failed: ${error.runtimeType}',
    );
  }
}

/// Null once the record is durable; otherwise why not. Never throws.
Future<String?> _write(String slot, String value) async {
  try {
    return await _channel.invokeMethod<String?>('write', {
      'slot': slot,
      'value': value,
    });
  } catch (error) {
    return 'the device store failed: ${error.runtimeType}';
  }
}

/// This phone's hardware identifier for the one action the user just
/// confirmed, or null where there is none (iOS, Android 7 and older) and on a
/// desktop, where Rust reads its own.
Future<NativeHardwareHint?> pairingHardwareHint() async {
  if (kIsWeb || !Platform.isAndroid) return null;
  try {
    final id = await _channel.invokeMethod<String>('hardwareId');
    if (id == null || id.isEmpty) return null;
    return NativeHardwareHint(source: 'android_id', rawId: id);
  } catch (_) {
    return null;
  }
}

/// Pairing invitations opened from outside the app: `pocox://pair?c=<code>`.
/// Each becomes the code to preview, and only that; anything else, an OAuth
/// callback included, is ignored and never logged, since it may carry a code.
class PairingInvitations {
  PairingInvitations._();

  static StreamSubscription<Uri>? _links;

  /// Start listening, handing each invitation's code to [onCode]. Covers the
  /// link that launched the app too.
  static void listen(BridgeApi api, void Function(String code) onCode) {
    if (kIsWeb || _links != null) return;
    if (!(Platform.isIOS || Platform.isAndroid || Platform.isMacOS)) return;
    try {
      _links = AppLinks().uriLinkStream.listen((uri) {
        final code = api.pairingParseInvitation(uri.toString());
        if (code != null) onCode(code);
      }, onError: (Object _) {});
    } on MissingPluginException {
      // Widget tests and platforms without the plugin take no links.
    }
  }
}
