import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/error_format.dart';
import 'package:pocox/src/providers.dart';
import 'package:pocox/src/screens/app_session_screen.dart' show appLocalPort;
import 'package:pocox/src/screens/local_sessions_screen.dart'
    show resolveSessionTarget;
import 'package:pocox/src/screens/session_source.dart';
import 'package:pocox/src/service_key.dart';
import 'package:pocox/src/widgets/app_toast.dart';
import 'package:pocox/src/widgets/fork_dialog.dart';

/// A connected app-server this app runs on this device, which is what serves a
/// session read from this device's disk. A connected service elsewhere never
/// qualifies: the thread does not exist there.
Future<String?> _thisDeviceHost(WidgetRef ref) async {
  final bridge = ref.read(bridgeApiProvider);
  final hosts = bridge.localServices().where((s) => s.kind == 'app').toList();
  for (final host in hosts) {
    if (bridge.appIsConnected(host.key)) return host.key;
  }
  for (final host in hosts) {
    try {
      await bridge.appConnect(host.key, appLocalPort);
      return host.key;
    } catch (_) {
      // Stopping or not answering: try the next one this device runs.
    }
  }
  return null;
}

/// Branch a session seen in the browser or viewer into a new conversation on
/// the host serving it, then open that. The source is only read, so this works
/// while another client holds it or is running a turn there, and [running] says
/// which of those the viewer last saw.
Future<void> forkLocalSession(
  BuildContext context,
  WidgetRef ref, {
  required String threadId,
  String? cwd,
  required bool running,
  SessionSource source = const SessionSource.local(),
  bool Function()? isCurrent,
}) async {
  bool current() => context.mounted && (isCurrent?.call() ?? true);
  if (source.isNative || !current()) return;
  final l10n = AppLocalizations.of(context);
  final messenger = ToastMessenger.of(context);
  final String? target;
  if (source.isRemote) {
    final resolved = await resolveSessionTarget(
      ref,
      source,
      messenger,
      current,
    );
    if (!resolved.ok) return;
    target = resolved.target;
  } else {
    target = await _thisDeviceHost(ref);
  }
  if (!context.mounted || !current()) return;
  if (target == null) {
    messenger.error(l10n.forkNoLocalHost);
    return;
  }
  if (!await confirmFork(context, running: running) || !current()) return;
  final bridge = ref.read(bridgeApiProvider);
  final ThreadForkResult result;
  try {
    result = await bridge.appThreadFork(target, threadId);
  } catch (e) {
    messenger.error('${l10n.forkFailed}: ${friendlyError(e)}');
    return;
  }
  final thread = result.thread;
  if (thread == null) {
    messenger.error(l10n.forkOutcomeUnknown);
    return;
  }
  await copyForkSettings(bridge, target, source: threadId, fork: thread.id);
  messenger.notice(forkCreatedMessage(l10n, result));
  if (!context.mounted || !current()) return;
  context.push(
    conversationRoute(
      target,
      thread.id,
      cwd: thread.cwd.isEmpty ? cwd : thread.cwd,
    ),
  );
}
