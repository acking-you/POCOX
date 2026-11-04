import 'package:flutter/material.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/widgets/app_dialog.dart';

/// Says what a fork is before one is created: a new conversation, its boundary,
/// and that the working folder stays shared.
class ForkDialog extends StatelessWidget {
  /// Creates the confirmation.
  const ForkDialog({
    super.key,
    required this.throughTurn,
    required this.running,
  });

  /// The fork stops at a chosen turn rather than the latest saved state.
  final bool throughTurn;

  /// A turn is running in the source, so a latest fork freezes it.
  final bool running;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final paragraphs = [
      l10n.forkDialogBody,
      if (throughTurn) l10n.forkDialogThroughTurn,
      if (running && !throughTurn) l10n.forkDialogRunning,
      l10n.forkDialogFiles,
    ];
    return AlertDialog(
      key: const Key('fork-dialog'),
      // Its paragraphs outgrow a small phone at large text.
      scrollable: true,
      title: Text(throughTurn ? l10n.forkThroughTurn : l10n.forkConversation),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (index, text) in paragraphs.indexed)
            Padding(
              padding: EdgeInsets.only(top: index == 0 ? 0 : 10),
              child: Text(text),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          key: const Key('fork-confirm'),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(l10n.forkConfirm),
        ),
      ],
    );
  }
}

/// Ask before forking; false when dismissed.
Future<bool> confirmFork(
  BuildContext context, {
  bool throughTurn = false,
  bool running = false,
}) async =>
    await showAppDialog<bool>(
      context: context,
      builder: (_) => ForkDialog(throughTurn: throughTurn, running: running),
    ) ??
    false;

/// What to say about a created fork.
String forkCreatedMessage(AppLocalizations l10n, ThreadForkResult fork) =>
    fork.lastTurnInterrupted ? l10n.forkCreatedInterrupted : l10n.forkCreated;

/// Carry the source's per-thread settings the host keeps for this app over to
/// [fork]. The server restores what it tracks itself; plan mode, for one, lives
/// only here, and a fork must not silently leave it. Best effort: a slow or
/// unreachable host keeps the fork on what the server reports.
Future<void> copyForkSettings(
  BridgeApi api,
  String serviceKey, {
  required String source,
  required String fork,
}) async {
  const limit = Duration(seconds: 5);
  try {
    final config = await api
        .metaThreadConfigGet(serviceKey, source)
        .timeout(limit);
    await api.metaThreadConfigSet(serviceKey, fork, config).timeout(limit);
  } catch (_) {
    // The fork exists either way, and opening it must not wait on this.
  }
}
