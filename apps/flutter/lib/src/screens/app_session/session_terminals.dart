part of '../app_session_screen.dart';

/// The connection and view that supplied a process id. A process id is never
/// portable across a reconnect or a different conversation.
typedef _TerminalTarget = ({
  String service,
  String thread,
  int load,
  int link,
  int access,
});

extension _SessionTerminals on _AppSessionState {
  _TerminalTarget? _terminalTarget() {
    final thread = _threadId;
    if (thread == null) return null;
    return (
      service: widget.serviceKey,
      thread: thread,
      load: _threadLoadGeneration,
      link: _linkEpoch,
      access: _externalWriterEpoch,
    );
  }

  bool _terminalTargetCurrent(_TerminalTarget target) =>
      mounted &&
      target == _terminalTarget() &&
      !_connectionLost &&
      !_reconnecting &&
      _caps.backgroundTerminals &&
      ref.read(bridgeApiProvider).appIsConnected(target.service);

  bool _canTerminateTerminal(_TerminalTarget target) =>
      _terminalTargetCurrent(target) &&
      !_externalWriterMode &&
      !_guardianReadOnly &&
      !_historySyncing &&
      !_showingCachedHistory;

  /// Read what the open conversation runs in the background. Only the latest
  /// read, for the conversation still shown, applies; a host that cannot say
  /// is not asked again until the connection or the conversation changes.
  Future<void> _loadTerminals() async {
    final target = _terminalTarget();
    if (target == null ||
        !_terminalTargetCurrent(target) ||
        _context.terminalsUnavailable) {
      return;
    }
    final read = ++_context.terminalsRead;
    try {
      final terminals = await ref
          .read(bridgeApiProvider)
          .appBackgroundTerminals(target.service, target.thread);
      if (!_terminalTargetCurrent(target) || read != _context.terminalsRead) {
        return;
      }
      if (target != _context.terminalsTarget ||
          !listEquals(terminals, _context.terminals)) {
        _updateState(() {
          _context.terminals = terminals;
          _context.terminalsTarget = target;
        });
      }
    } catch (_) {
      if (!_terminalTargetCurrent(target) || read != _context.terminalsRead) {
        return;
      }
      _updateState(() {
        _context.terminals = const [];
        _context.terminalsUnavailable = true;
      });
    }
  }

  /// A process's row, opening its details.
  _ContextRow _terminalRow(BackgroundTerminal terminal) => _ContextRow(
    key: Key('context-terminal-${terminal.processId}'),
    leading: const Icon(AppIcons.terminal_prompt, size: 16),
    label: terminal.command,
    onTap: switch (_context.terminalsTarget) {
      final target? => () => _showTerminal(terminal, target),
      null => null,
    },
  );

  /// The processes in a list of their own, on a phone.
  void _showTerminals() {
    final target = _context.terminalsTarget;
    if (target == null || !_terminalTargetCurrent(target)) return;
    final terminals = _context.terminals;
    unawaited(
      showAdaptivePanel<void>(
        context: context,
        insetTop: false,
        builder: (panel) {
          final l10n = AppLocalizations.of(panel);
          return Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    l10n.backgroundProcesses,
                    style: Theme.of(panel).textTheme.titleMedium,
                  ),
                ),
                for (final terminal in terminals)
                  _cardRow(
                    _ContextRow(
                      key: Key('context-terminal-${terminal.processId}'),
                      leading: const Icon(AppIcons.terminal_prompt, size: 16),
                      label: terminal.command,
                      onTap: () {
                        Navigator.of(panel).pop();
                        _showTerminal(terminal, target);
                      },
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// One process: its command, where it runs and what it uses, and the way to
  /// stop it for a view that writes this conversation.
  void _showTerminal(BackgroundTerminal terminal, _TerminalTarget target) {
    if (!_terminalTargetCurrent(target)) return;
    unawaited(
      showAdaptivePanel<void>(
        context: context,
        anchored: true,
        maxWidth: 380,
        insetTop: false,
        builder: (panel) {
          final l10n = AppLocalizations.of(panel);
          final theme = Theme.of(panel);
          final scheme = theme.colorScheme;
          final facts = <(String, String)>[
            (l10n.backgroundProcessFolder, terminal.cwd),
            if (terminal.osPid case final pid?) ('PID', '$pid'),
            if (terminal.cpuPercent case final cpu?)
              ('CPU', '${cpu.toStringAsFixed(1)}%'),
            if (terminal.rssKb case final rss?)
              (
                l10n.backgroundProcessMemory,
                '${(rss / 1024).toStringAsFixed(0)} MB',
              ),
          ];
          return Padding(
            key: const Key('background-process'),
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SelectableText(
                  terminal.command,
                  style: const TextStyle(
                    fontFamily: monoFontFamily,
                    fontFamilyFallback: monoCjkFallback,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 10),
                for (final (label, value) in facts)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          label,
                          style: TextStyle(
                            fontSize: 13,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: SelectableText(
                            value,
                            textAlign: TextAlign.end,
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                      ],
                    ),
                  ),
                if (_canTerminateTerminal(target))
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: OutlinedButton(
                        key: const Key('background-process-terminate'),
                        onPressed: () {
                          Navigator.of(panel).pop();
                          unawaited(_terminateTerminal(terminal, target));
                        },
                        child: Text(l10n.backgroundProcessTerminate),
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// Stop [terminal] after a confirm, reporting what came of it.
  Future<void> _terminateTerminal(
    BackgroundTerminal terminal,
    _TerminalTarget target,
  ) async {
    if (!_canTerminateTerminal(target)) return;
    final l10n = AppLocalizations.of(context);
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(l10n.backgroundProcessTerminateTitle),
        content: Text(terminal.command),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text(l10n.backgroundProcessTerminate),
          ),
        ],
      ),
    );
    if (ok != true || !_canTerminateTerminal(target)) return;
    try {
      final done = await ref
          .read(bridgeApiProvider)
          .appTerminateBackgroundTerminal(
            target.service,
            target.thread,
            terminal.processId,
          );
      if (!mounted || !_terminalTargetCurrent(target)) return;
      if (!done) showToastError(context, l10n.backgroundProcessGone);
    } catch (e) {
      if (mounted && _terminalTargetCurrent(target)) {
        showToastError(context, friendlyError(e));
      }
    }
    if (_terminalTargetCurrent(target)) unawaited(_loadTerminals());
  }
}
