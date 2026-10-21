import 'dart:async';

import 'package:flutter/services.dart';

/// Dart side of the macOS native-quit handshake (`NativeQuitGate` in
/// `macos/Runner/AppDelegate.swift`).
///
/// AppKit's quit paths (Cmd+Q, the application menu, the Dock) are cancelled
/// natively and delivered here as `quit`; [onQuit] then runs the same cleanup
/// as the tray's Quit. A quit requested before [attach] is held natively and
/// returned by `ready`. The process exits only after [allowTerminate].
class NativeQuitChannel {
  /// Binds [onQuit] to [channel].
  NativeQuitChannel({
    required this.onQuit,
    this.channel = const MethodChannel('pocox/app_quit'),
  });

  /// Runs (or joins) the app's quit.
  final Future<void> Function() onQuit;

  /// The channel shared with the native gate.
  final MethodChannel channel;

  /// Starts listening and runs a quit that arrived before; the native side
  /// keeps a later quit until this has been called.
  Future<void> attach() async {
    channel.setMethodCallHandler((call) async {
      if (call.method != 'quit') {
        throw MissingPluginException('unknown method ${call.method}');
      }
      // Answer at once: the cleanup reports through the quit status, and
      // the native side only needs to know the request was received.
      unawaited(onQuit());
      return null;
    });
    final bool pending;
    try {
      pending = await channel.invokeMethod<bool>('ready') ?? false;
    } on MissingPluginException {
      // No native gate: native quits are not intercepted at all.
      return;
    }
    if (pending) unawaited(onQuit());
  }

  /// Lets the next native terminate exit; called once cleanup succeeded,
  /// immediately before the app terminates itself.
  Future<void> allowTerminate() async {
    try {
      await channel.invokeMethod<void>('allowTerminate');
    } on MissingPluginException {
      // No native gate, so nothing would hold the terminate back.
    }
  }
}
