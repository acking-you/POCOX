import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/desktop_theme.dart';
import 'package:pocket_codex/src/error_format.dart';
import 'package:pocket_codex/src/hosting/cancellable_delay.dart';
import 'package:pocket_codex/src/hosting/editor_block.dart';
import 'package:pocket_codex/src/providers.dart';
import 'package:pocket_codex/src/theme.dart';
import 'package:pocket_codex/src/widgets/action_row.dart';
import 'package:pocket_codex/src/widgets/app_toast.dart';
import 'package:pocket_codex/src/app_icons.dart';

/// The official Codex (ChatGPT) sign-in, in place.
///
/// Codex owns its login and writes `auth.json` itself. Each sign-in or
/// sign-out attempt runs on its own private, loopback-only Codex the bridge
/// starts for it ([BridgeApi.codexLocalSessionOpen]) with the official
/// route, the editor's codex binary and proxy — never on the relay, and with
/// no host required. An attempt owns its session: it is closed (awaited,
/// errors kept out of the zone) when the attempt ends, fails, times out, is
/// cancelled or this panel goes away, and a late answer of an older attempt
/// changes nothing and never closes or signs out a newer one.
///
/// Success is only the server's own completion of this attempt's login with
/// a ChatGPT account ([CodexAuthStatus.completed]); a credential already on
/// disk (an older `auth.json` or an API key) is shown as configured, never
/// as this sign-in having succeeded.
class OfficialLoginPanel extends ConsumerStatefulWidget {
  /// Creates the panel.
  const OfficialLoginPanel({
    super.key,
    required this.status,
    this.binary,
    this.proxy,
    this.onChanged,
    this.enabled = true,
    this.header,
  });

  /// What `CODEX_HOME` has on disk: a configured credential, not a verified
  /// sign-in.
  final CodexSetupStatus? status;

  /// The codex executable the sign-in should run (null: the saved codex,
  /// then `PATH`).
  final String? Function()? binary;

  /// The upstream proxy the sign-in's OAuth traffic should use.
  final String? Function()? proxy;

  /// Called after the sign-in state may have changed (signed in or out).
  final VoidCallback? onChanged;

  /// Whether the controls can be used.
  final bool enabled;

  /// What the sign-in control sits beside: the caller's own row (a title
  /// and description), in place of the sign-in state the panel shows by
  /// itself.
  final Widget? header;

  @override
  ConsumerState<OfficialLoginPanel> createState() => _OfficialLoginPanelState();
}

/// What a credential in `CODEX_HOME` signs in with, in words.
String codexSignedInLabel(AppLocalizations l10n, String? authMode) =>
    switch (authMode) {
      'chatgpt' || 'chatgptAuthTokens' => l10n.codexSignedInChatgpt,
      'apikey' => l10n.codexSignedInApiKey,
      _ => l10n.codexSignedIn,
    };

/// How many 2 s polls one sign-in waits (~5 minutes, codex's own window).
const _maxPolls = 150;

class _OfficialLoginPanelState extends ConsumerState<OfficialLoginPanel> {
  bool _busy = false;
  bool _polling = false;
  String? _error;
  String? _info;
  String? _deviceCode;
  String? _deviceUrl;
  // Moves on every new attempt, cancel and dispose; an older attempt stops.
  int _attempt = 0;
  // The session the current attempt owns, with that attempt's number.
  (int, String)? _owned;
  // The polling attempt's pending wait between two status reads: cut short
  // whenever that attempt ends.
  final _pollWait = CancellableDelay();

  // Read once: closing the session on dispose must not touch `ref`.
  late final BridgeApi _api;

  @override
  void initState() {
    super.initState();
    _api = ref.read(bridgeApiProvider);
  }

  @override
  void dispose() {
    _attempt++;
    _pollWait.stop();
    _release();
    super.dispose();
  }

  String? _text(String? Function()? read) {
    final value = read?.call()?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  bool _current(int attempt) => mounted && attempt == _attempt;

  /// Wait one poll interval for [attempt]: `false` when it ended meanwhile
  /// (a new attempt, cancel or dispose stopped the wait).
  Future<bool> _pollDelay(int attempt) async =>
      await _pollWait.wait(const Duration(seconds: 2)) && _current(attempt);

  /// Close [session]; a failure is not the user's to see (the bridge stops
  /// the private codex on quit anyway).
  Future<void> _closeSession(String session) async {
    try {
      await _api.codexLocalSessionClose(session);
    } catch (_) {}
  }

  /// Close the owned session, if any (for whichever attempt owns it).
  void _release() {
    final owned = _owned;
    _owned = null;
    if (owned != null) unawaited(_closeSession(owned.$2));
  }

  /// Close [session] of [attempt], and forget it only when that attempt
  /// still owns it.
  Future<void> _end(int attempt, String session) async {
    if (_owned case (final a, final s) when a == attempt && s == session) {
      _owned = null;
    }
    await _closeSession(session);
  }

  Future<void> _signIn(AppLocalizations l10n) async {
    final attempt = ++_attempt;
    _pollWait.stop();
    _release();
    setState(() {
      _busy = true;
      _error = null;
      _info = null;
      _deviceCode = null;
      _deviceUrl = null;
    });
    String? session;
    try {
      session = await _api.codexLocalSessionOpen(
        binary: _text(widget.binary),
        proxy: _text(widget.proxy),
      );
      if (!_current(attempt)) {
        await _closeSession(session);
        return;
      }
      _owned = (attempt, session);
      final start = await _api.codexLocalLoginStart(session);
      if (!_current(attempt)) return;
      final device = start.mode == 'device';
      final url = device ? start.verificationUrl : start.authUrl;
      if (url != null && url.isNotEmpty) {
        await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      }
      if (!_current(attempt)) return;
      setState(() {
        _busy = false;
        _polling = true;
        _deviceCode = device ? start.userCode : null;
        _deviceUrl = device ? start.verificationUrl : null;
        _info = device
            ? l10n.codexSetupDeviceOpened
            : l10n.codexSetupLoginOpened;
      });
      await _poll(l10n, attempt, session, start.loginId);
    } catch (e) {
      if (session != null) await _end(attempt, session);
      if (!_current(attempt)) return;
      setState(() {
        _busy = false;
        _polling = false;
        _error = friendlyError(e);
      });
    }
  }

  /// Poll until this attempt's login completes (bounded). A failed refresh
  /// stays visible and the next poll retries it.
  Future<void> _poll(
    AppLocalizations l10n,
    int attempt,
    String session,
    String loginId,
  ) async {
    for (var i = 0; i < _maxPolls; i++) {
      if (!await _pollDelay(attempt) || !_polling) return;
      CodexAuthStatus status;
      try {
        status = await _api.codexLocalAuthStatus(session, loginId: loginId);
      } catch (e) {
        if (!_current(attempt)) return;
        setState(() => _error = l10n.hostLoginRefreshFailed(friendlyError(e)));
        continue;
      }
      if (!_current(attempt)) return;
      final completed = status.completed;
      if (completed == null) {
        if (_error != null) setState(() => _error = null);
        continue;
      }
      await _end(attempt, session);
      if (!_current(attempt)) return;
      final official = completed && status.method == 'chatgpt';
      setState(() {
        _polling = false;
        _deviceCode = null;
        _deviceUrl = null;
        _info = official ? l10n.codexSetupLoginSuccess : null;
        _error = official
            ? null
            : completed
            ? l10n.hostLoginNotOfficial
            : l10n.hostLoginFailed(status.error ?? '');
      });
      widget.onChanged?.call();
      return;
    }
    if (!_current(attempt)) return;
    try {
      await _api.codexLocalLoginCancel(session, loginId);
    } catch (_) {}
    await _end(attempt, session);
    if (!_current(attempt)) return;
    setState(() {
      _polling = false;
      _error = l10n.codexSetupLoginTimeout;
    });
  }

  /// Stop waiting for the browser and close this attempt's sign-in.
  void _cancel() {
    _attempt++;
    _pollWait.stop();
    _release();
    setState(() {
      _polling = false;
      _busy = false;
      _info = null;
      _error = null;
      _deviceCode = null;
      _deviceUrl = null;
    });
  }

  Future<void> _signOut() async {
    final attempt = ++_attempt;
    _pollWait.stop();
    _release();
    setState(() {
      _busy = true;
      _error = null;
      _info = null;
    });
    String? session;
    try {
      session = await _api.codexLocalSessionOpen(
        binary: _text(widget.binary),
        proxy: _text(widget.proxy),
      );
      if (!_current(attempt)) return;
      _owned = (attempt, session);
      await _api.codexLocalLogout(session);
      if (_current(attempt)) widget.onChanged?.call();
    } catch (e) {
      if (_current(attempt)) setState(() => _error = friendlyError(e));
    } finally {
      if (session != null) await _end(attempt, session);
      if (_current(attempt)) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final status = widget.status;
    final enabled = widget.enabled && !_busy;
    final signedIn = status?.hasAuth == true;
    final Widget action;
    if (signedIn) {
      action = OutlinedButton(
        key: const Key('codex-logout-btn'),
        onPressed: enabled ? _signOut : null,
        child: Text(l10n.accountSignOut),
      );
    } else {
      action = Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          // Where the sign-in runs is the button's tooltip.
          Tooltip(
            message: l10n.hostOfficialNote,
            child: FilledButton.icon(
              key: const Key('codex-login-chatgpt'),
              onPressed: (!enabled || _polling) ? null : () => _signIn(l10n),
              icon: _polling || _busy
                  ? const SizedBox(
                      width: 15,
                      height: 15,
                      child: CircularProgressIndicator(strokeWidth: 1.8),
                    )
                  : const Icon(AppIcons.open_in_new, size: 18),
              label: Text(
                _polling
                    ? l10n.codexSetupLoginWaiting
                    : l10n.codexSetupLoginButton,
              ),
            ),
          ),
          if (_polling)
            TextButton(
              key: const Key('codex-login-cancel'),
              onPressed: _cancel,
              child: Text(l10n.cancel),
            ),
        ],
      );
    }
    final lead =
        widget.header ??
        (signedIn
            ? Row(
                children: [
                  Icon(
                    AppIcons.check_circle_outline,
                    size: 18,
                    color: successColor(scheme),
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      // A credential on disk, not a verified sign-in.
                      codexSignedInLabel(l10n, status!.authMode),
                      key: const Key('codex-login-done'),
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  ),
                ],
              )
            : null);
    final children = <Widget>[
      if (lead == null)
        Align(alignment: AlignmentDirectional.centerStart, child: action)
      else
        ActionRow(lead: lead, action: action),
    ];
    if (_deviceCode case final code? when code.isNotEmpty) {
      children
        ..add(const SizedBox(height: 12))
        ..add(_devicePanel(l10n, theme, code));
    }
    for (final (key, message, color) in [
      if (_info != null)
        (const Key('codex-login-info'), _info!, successColor(scheme)),
      if (_error != null)
        (const Key('codex-login-error'), _error!, scheme.error),
    ]) {
      children
        ..add(const SizedBox(height: 8))
        ..add(EditorNote(message, key: key, color: color));
    }
    return Column(
      key: const Key('official-login-panel'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }

  /// The one-time code for the device flow (codex could not bind its local
  /// callback port), with the way back to the verification page.
  Widget _devicePanel(AppLocalizations l10n, ThemeData theme, String code) {
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(kPanelRadius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.codexSetupDeviceCodeLabel,
            style: theme.textTheme.labelMedium,
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: SelectableText(
                  code,
                  key: const Key('codex-device-code'),
                  style: theme.textTheme.headlineSmall?.copyWith(
                    letterSpacing: 3,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              IconButton(
                key: const Key('codex-device-code-copy'),
                tooltip: l10n.accountCopyCode,
                icon: const Icon(AppIcons.copy, size: 20),
                onPressed: () async {
                  final messenger = ToastMessenger.of(context);
                  await Clipboard.setData(ClipboardData(text: code));
                  messenger.ok(l10n.copied);
                },
              ),
            ],
          ),
          if (_deviceUrl case final url? when url.isNotEmpty)
            TextButton.icon(
              onPressed: () => launchUrl(
                Uri.parse(url),
                mode: LaunchMode.externalApplication,
              ),
              icon: const Icon(AppIcons.open_in_new, size: 16),
              label: Text(l10n.codexSetupDeviceReopen),
            ),
        ],
      ),
    );
  }
}
