part of '../app_session_screen.dart';

extension _SessionSetup on _AppSessionState {
  /// Whether THIS machine's codex (the local host behind [widget.serviceKey])
  /// still needs setup — no login AND no custom provider — so a model turn
  /// can't succeed. Only ever true for a LOCAL host; a remote host's codex
  /// config is the remote owner's concern, not ours to detect. Pass
  /// `watch: true` from `build` (so it rebuilds when the status resolves),
  /// `watch: false` from callbacks.
  bool _codexNeedsSetup({required bool watch}) {
    // Only a Codex app-server uses Codex's login. Native OpenCode (its own
    // sign-ins) and ACP agents never depend on it, whatever else they share
    // with Codex (local session history, for one).
    if (_caps.engine != 'codex') return false;
    final host = _localHost(watch: watch);
    if (host == null || !host.isCodex) return false;
    // Launched with its own provider, the host does not use Codex's own
    // setup at all.
    if (host.configSource == 'custom') return false;
    final status = watch
        ? ref.watch(codexSetupStatusProvider)
        : ref.read(codexSetupStatusProvider);
    return status.valueOrNull?.needsSetup ?? false;
  }

  /// This conversation's host when it is one of this device's own hosts.
  AppServeStatus? _localHost({required bool watch}) {
    final locals = watch
        ? ref.watch(localServeListProvider)
        : ref.read(localServeListProvider);
    return (locals.valueOrNull ?? const <AppServeStatus>[])
        .where((h) => h.appServiceKey == widget.serviceKey)
        .firstOrNull;
  }

  /// Open this host's model service in the hosting editor (sign-in or a
  /// custom provider for exactly this host), or the Codex setup page where
  /// this device cannot host. Nothing is saved or restarted by opening it;
  /// the status is re-read on return so the banner / send-guard clear once
  /// the host can make model calls.
  void _openCodexSetup() {
    final host = _localHost(watch: false);
    final Future<Object?> opened = host != null && isDesktop
        ? showHostingEditor(context, existing: host)
        : context.push('/setup/codex');
    opened.then((_) {
      if (!mounted) return;
      ref
        ..invalidate(codexSetupStatusProvider)
        ..invalidate(localServeListProvider);
    });
  }

  /// A warning strip under the app bar when the local codex isn't configured —
  /// a persistent, tappable pointer to the setup wizard.
  PreferredSizeWidget _codexSetupBar(AppLocalizations l10n) {
    final scheme = Theme.of(context).colorScheme;
    return PreferredSize(
      preferredSize: const Size.fromHeight(46),
      child: Material(
        color: scheme.errorContainer,
        child: InkWell(
          mouseCursor: clickable,
          onTap: _openCodexSetup,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
            child: Row(
              children: [
                Icon(
                  Icons.warning_amber_rounded,
                  size: 18,
                  color: scheme.onErrorContainer,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l10n.codexChatNeedsSetup,
                    key: const Key('codex-chat-needs-setup'),
                    style: TextStyle(
                      color: scheme.onErrorContainer,
                      fontSize: 13,
                    ),
                  ),
                ),
                TextButton(
                  key: const Key('codex-chat-setup-btn'),
                  onPressed: _openCodexSetup,
                  child: Text(l10n.hostSectionModel),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
