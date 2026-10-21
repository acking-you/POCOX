import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/app_icons.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/desktop_theme.dart';
import 'package:pocox/src/error_format.dart';
import 'package:pocox/src/hosting/cancellable_delay.dart';
import 'package:pocox/src/hosting/editor_block.dart';
import 'package:pocox/src/providers.dart';
import 'package:pocox/src/theme.dart';
import 'package:pocox/src/widgets/action_row.dart';

/// Grok Build's own sign-in, in place: the "Grok account" model service.
///
/// Grok owns its sign-in and stores it in its home itself. Status, sign-in
/// and sign-out each run on a private, short-lived `grok` the bridge starts
/// with the Grok-account route ([BridgeApi.grokAccountStatus]); no host is
/// needed. A sign-in is Grok's device flow: the page to confirm its code is
/// opened in the browser, and the attempt ends when Grok reports it signed
/// in, or when it is cancelled or this panel goes away. A late answer of an
/// older attempt changes nothing.
class GrokLoginPanel extends ConsumerStatefulWidget {
  /// Creates the panel.
  const GrokLoginPanel({super.key, this.program, this.enabled = true});

  /// The `grok` executable the editor chose (null: the installed one).
  final String? Function()? program;

  /// Whether the controls can be used.
  final bool enabled;

  @override
  ConsumerState<GrokLoginPanel> createState() => _GrokLoginPanelState();
}

class _GrokLoginPanelState extends ConsumerState<GrokLoginPanel> {
  GrokAccount? _account;
  bool _busy = false;
  String? _error;
  String? _attempt;
  GrokSignIn? _signIn;
  bool _opened = false;
  // Moves on every status read, new attempt, cancel and dispose.
  int _seq = 0;
  final _pollWait = CancellableDelay();

  late final BridgeApi _api;

  @override
  void initState() {
    super.initState();
    _api = ref.read(bridgeApiProvider);
    unawaited(_refresh());
  }

  @override
  void dispose() {
    _seq++;
    _pollWait.stop();
    final attempt = _attempt;
    if (attempt != null) {
      unawaited(_api.grokSignInCancel(attempt).catchError((_) {}));
    }
    super.dispose();
  }

  String? get _program {
    final value = widget.program?.call()?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  Future<void> _refresh() async {
    final seq = ++_seq;
    setState(() => _error = null);
    try {
      final account = await _api.grokAccountStatus(program: _program);
      if (!mounted || seq != _seq) return;
      setState(() => _account = account);
    } catch (e) {
      if (!mounted || seq != _seq) return;
      setState(() => _error = friendlyError(e));
    }
  }

  Future<void> _start() async {
    final seq = ++_seq;
    setState(() {
      _busy = true;
      _error = null;
      _signIn = null;
      _opened = false;
    });
    try {
      final attempt = await _api.grokSignInStart(program: _program);
      if (!mounted || seq != _seq) {
        unawaited(_api.grokSignInCancel(attempt).catchError((_) {}));
        return;
      }
      _attempt = attempt;
      await _poll(seq, attempt);
    } catch (e) {
      if (mounted && seq == _seq) setState(() => _error = friendlyError(e));
    } finally {
      if (mounted && seq == _seq) setState(() => _busy = false);
    }
  }

  Future<void> _poll(int seq, String attempt) async {
    while (mounted && seq == _seq) {
      final state = _api.grokSignInState(attempt);
      setState(() => _signIn = state);
      if (state.url case final url? when !_opened) {
        _opened = true;
        unawaited(launchUrl(Uri.parse(url)));
      }
      if (state.ended) {
        _attempt = null;
        if (state.phase == 'failed') {
          setState(() => _error = state.error);
        } else if (state.phase == 'signed_in') {
          setState(() => _signIn = null);
          await _refresh();
        }
        return;
      }
      if (!await _pollWait.wait(const Duration(seconds: 1))) return;
    }
  }

  Future<void> _cancel() async {
    final attempt = _attempt;
    _seq++;
    _pollWait.stop();
    setState(() {
      _attempt = null;
      _signIn = null;
      _busy = false;
    });
    if (attempt != null) {
      try {
        await _api.grokSignInCancel(attempt);
      } catch (_) {
        // The bridge stops the private grok on quit anyway.
      }
    }
  }

  Future<void> _signOut() async {
    final seq = ++_seq;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final account = await _api.grokSignOut(program: _program);
      if (mounted && seq == _seq) setState(() => _account = account);
    } catch (e) {
      if (mounted && seq == _seq) setState(() => _error = friendlyError(e));
    } finally {
      if (mounted && seq == _seq) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final account = _account;
    final enabled = widget.enabled && !_busy;
    final waiting = _signIn != null && !_signIn!.ended;
    final Widget lead = switch (account) {
      null when _error == null => const SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 1.8),
      ),
      null => const SizedBox.shrink(),
      GrokAccount(signedIn: true) => Row(
        children: [
          Icon(
            AppIcons.check_circle_outline,
            size: 18,
            color: successColor(scheme),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              account.account
                  ? (account.email == null
                        ? l10n.grokSignedIn
                        : l10n.grokSignedInAs(account.email!))
                  : l10n.grokApiKeyInUse,
              key: const Key('grok-login-done'),
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
      _ => Text(
        l10n.grokNotSignedIn,
        key: const Key('grok-login-none'),
        style: TextStyle(color: cautionColor(scheme)),
      ),
    };
    final Widget action;
    if (account?.signedIn == true) {
      action = OutlinedButton(
        key: const Key('grok-logout-btn'),
        onPressed: enabled ? _signOut : null,
        child: Text(l10n.accountSignOut),
      );
    } else {
      action = Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Tooltip(
            message: l10n.grokOfficialNote,
            child: FilledButton.icon(
              key: const Key('grok-login-btn'),
              onPressed: (!enabled || waiting || account == null)
                  ? null
                  : _start,
              icon: waiting || _busy
                  ? const SizedBox(
                      width: 15,
                      height: 15,
                      child: CircularProgressIndicator(strokeWidth: 1.8),
                    )
                  : const Icon(AppIcons.open_in_new, size: 18),
              label: Text(
                waiting ? l10n.codexSetupLoginWaiting : l10n.grokSignIn,
              ),
            ),
          ),
          if (waiting)
            TextButton(
              key: const Key('grok-login-cancel'),
              onPressed: _cancel,
              child: Text(l10n.cancel),
            ),
        ],
      );
    }
    final children = <Widget>[ActionRow(lead: lead, action: action)];
    if (_signIn case GrokSignIn(url: final url?, :final code) when waiting) {
      children
        ..add(const SizedBox(height: 12))
        ..add(_codePanel(l10n, theme, url, code));
    }
    if (_error case final error?) {
      children
        ..add(const SizedBox(height: 8))
        ..add(
          EditorNote(
            error,
            key: const Key('grok-login-error'),
            color: scheme.error,
            action: TextButton(onPressed: _refresh, child: Text(l10n.retry)),
          ),
        );
    }
    return Column(
      key: const Key('grok-login-panel'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }

  /// The device code to confirm, with the way back to its page.
  Widget _codePanel(
    AppLocalizations l10n,
    ThemeData theme,
    String url,
    String? code,
  ) {
    final scheme = theme.colorScheme;
    return Container(
      key: const Key('grok-login-code'),
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
          if (code != null) ...[
            const SizedBox(height: 4),
            SelectableText(
              code,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w600,
                letterSpacing: 2,
              ),
            ),
          ],
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              TextButton.icon(
                key: const Key('grok-login-open'),
                onPressed: () => launchUrl(Uri.parse(url)),
                icon: const Icon(AppIcons.open_in_new, size: 16),
                label: Text(l10n.grokOpenSignInPage),
              ),
              TextButton.icon(
                onPressed: () => Clipboard.setData(ClipboardData(text: url)),
                icon: const Icon(AppIcons.copy, size: 16),
                label: Text(l10n.copy),
                style: TextButton.styleFrom(
                  foregroundColor: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
