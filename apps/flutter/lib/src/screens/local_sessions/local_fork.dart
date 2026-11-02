import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/error_format.dart';
import 'package:pocox/src/providers.dart';
import 'package:pocox/src/screens/local_sessions_screen.dart'
    show resolveSessionTarget;
import 'package:pocox/src/screens/session_source.dart';
import 'package:pocox/src/service_key.dart';
import 'package:pocox/src/widgets/app_toast.dart';
import 'package:pocox/src/widgets/fork_dialog.dart';

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
  final resolved = await resolveSessionTarget(ref, source, messenger, current);
  if (!resolved.ok || !context.mounted || !current()) return;
  final target = resolved.target;
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
