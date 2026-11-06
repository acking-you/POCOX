import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/desktop_theme.dart';
import 'package:pocox/src/error_format.dart';
import 'package:pocox/src/fonts.dart';
import 'package:pocox/src/pairing/pairing_front.dart';
import 'package:pocox/src/pairing/pairing_other_ways.dart';
import 'package:pocox/src/pairing/pairing_session.dart';
import 'package:pocox/src/providers.dart';
import 'package:pocox/src/web_authenticator.dart';
import 'package:pocox/src/widgets/app_toast.dart';
import 'package:pocox/src/widgets/brand_logo.dart';
import 'package:pocox/src/widgets/links.dart';
import 'package:pocox/src/widgets/window_title_bar.dart';
import 'package:pocox/src/app_icons.dart';

/// Default first-run experience. Pairing leads, with at most three actions on
/// the page; GitHub's two sign-ins and the self-hosted path sit under "Other
/// ways to sign in". A GitHub user whose session expired gets GitHub's
/// sign-ins on the page instead, and pairing under Other ways.
class AccountOnboardingScreen extends ConsumerStatefulWidget {
  /// Default constructor.
  const AccountOnboardingScreen({super.key, this.sessionExpired = false});

  /// Whether this sign-in was opened because a saved session cannot renew.
  final bool sessionExpired;

  @override
  ConsumerState<AccountOnboardingScreen> createState() =>
      _AccountOnboardingState();
}

class _AccountOnboardingState extends ConsumerState<AccountOnboardingScreen> {
  DeviceCode? _device;
  String? _error;

  /// A sign-in under way, as a listenable too: Other ways' panel, a route of
  /// its own, follows it while open.
  final _busyNow = ValueNotifier(false);
  bool get _busy => _busyNow.value;
  set _busy(bool value) => _busyNow.value = value;

  /// An expired GitHub session's user chose a pairing code instead.
  bool _pairingInstead = false;
  final _backend = TextEditingController();

  @override
  void dispose() {
    _busyNow.dispose();
    _backend.dispose();
    super.dispose();
  }

  /// The convenient default: open a browser, let GitHub authorize, and come back
  /// automatically. The backend brokers GitHub's authorization-code flow; we only
  /// ever hold a one-time exchange code (+ a PKCE verifier the backend never sees).
  Future<void> _startWeb() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final api = ref.read(bridgeApiProvider);
    final authenticator = ref.read(webAuthenticatorProvider);
    final l10n = AppLocalizations.of(context);
    String? failure;
    try {
      final cb = webAuthCallback();
      final start = await api.accountWebLoginStart(
        redirectUri: cb.redirectUri,
        backend: _backendOverride,
      );
      final result = await authenticator.authenticate(
        url: start.authorizeUrl,
        callbackUrlScheme: cb.callbackScheme,
      );
      final params = Uri.parse(result).queryParameters;
      final err = params['error'];
      final code = params['exchange_code'];
      if (err != null && err.isNotEmpty) {
        failure = err == 'access_denied'
            ? l10n.accountDenied
            : l10n.accountWebFailed;
      } else if (params['state'] != start.state ||
          code == null ||
          code.isEmpty) {
        // A mismatched state or missing code means the redirect wasn't ours.
        failure = l10n.accountWebFailed;
      } else {
        final user = await api.accountWebLoginExchange(
          exchangeCode: code,
          codeVerifier: start.codeVerifier,
          backend: start.backend,
        );
        _showSignedIn(user.login);
        await _goAfterSignIn();
        return;
      }
    } on PlatformException catch (e) {
      // The browser hand-off didn't come back. CANCELED is the user dismissing
      // the tab — on Android that is also what a GitHub page that won't load
      // looks like, since a Custom Tab has no timeout of its own. Either way the
      // remedy is the same, and it is the one thing that still works when the
      // in-app browser can't reach GitHub: the device code, which goes through
      // the backend.
      failure = e.code == 'CANCELED'
          ? l10n.accountWebTrouble
          : friendlyError(e);
    } catch (e) {
      // Includes the desktop loopback listener giving up (see the timeout in
      // web_authenticator.dart) and a redirect that never arrived because the
      // browser opened a profile that isn't signed in. Lead with the remedy, but
      // keep the cause: a raw transport error is what makes a real bug
      // diagnosable when someone reports it. An account backend older than the
      // app refuses the app's return link before any browser opens; only a
      // backend update fixes that, so say so instead.
      final cause = friendlyError(e);
      failure = cause.contains('redirect_uri is not allowed')
          ? l10n.accountRedirectRejected
          : '${l10n.accountWebTrouble}\n\n$cause';
    }
    if (mounted) {
      setState(() {
        _error = failure;
        _busy = false;
      });
    }
  }

  /// Fallback for environments without a usable browser hand-off: show a code to
  /// type at github.com/login/device, then poll until authorized.
  Future<void> _startDevice() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final api = ref.read(bridgeApiProvider);
    try {
      final device = await api.accountLoginStart(backend: _backendOverride);
      if (!mounted) return;
      setState(() {
        _device = device;
        _busy = false;
      });
      unawaited(_poll(device));
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = friendlyError(e);
          _busy = false;
        });
      }
    }
  }

  /// The backend typed under "Advanced" (a self-deployed one); null keeps
  /// the built-in default (lb7666.top).
  String? get _backendOverride {
    final typed = _backend.text.trim();
    return typed.isEmpty ? null : typed;
  }

  /// End the device flow on [error], dropping its code.
  void _stopPolling(String error) {
    if (!mounted) return;
    setState(() {
      _device = null;
      _error = error;
    });
  }

  Future<void> _poll(DeviceCode device) async {
    final api = ref.read(bridgeApiProvider);
    final interval = Duration(
      seconds: device.intervalSecs < 1 ? 5 : device.intervalSecs,
    );
    // Client-side expiry: stop once the device code's lifetime elapses even if
    // the backend never answers, so the spinner can't spin forever.
    final deadline = DateTime.now().add(
      Duration(seconds: device.expiresInSecs < 1 ? 900 : device.expiresInSecs),
    );
    var delay = interval;
    while (mounted && identical(_device, device)) {
      await Future<void>.delayed(delay);
      if (!mounted || !identical(_device, device)) return;
      if (DateTime.now().isAfter(deadline)) {
        _stopPolling(AppLocalizations.of(context).accountCodeExpired);
        return;
      }
      // Resolve l10n fresh each iteration so a locale change mid-poll shows the
      // terminal message in the current language.
      final l10n = AppLocalizations.of(context);
      // An authorized poll persists account mode before returning. Don't let
      // the user switch to relay setup while that write may still happen.
      setState(() => _busy = true);
      try {
        final poll = await api.accountLoginPoll(
          device.pollHandle,
          device.backend,
        );
        if (!mounted) return;
        switch (poll.status) {
          case 'authorized':
            setState(() => _device = null);
            _showSignedIn(poll.login);
            await _goAfterSignIn();
            return;
          case 'slow_down':
            delay = interval + const Duration(seconds: 5);
          case 'expired':
            _stopPolling(l10n.accountCodeExpired);
            return;
          case 'denied':
            _stopPolling(l10n.accountDenied);
            return;
          default: // pending / unknown: keep polling at the base interval
            delay = interval;
        }
      } catch (_) {
        // Transient network error: keep polling at the base interval.
        delay = interval;
      } finally {
        if (mounted) setState(() => _busy = false);
      }
    }
  }

  void _openSelfHost() {
    // Welcome stays mounted under setup. Drop the pending device code so a
    // sleeping poll can't sign in from behind the setup page. Return to the
    // compact sign-in view while retaining any typed backend address.
    setState(() => _device = null);
    final uri = GoRouterState.of(context).uri;
    context.go(uri.replace(path: '/onboarding/self-host').toString());
  }

  /// Land the signed-in user: the welcome guide the first time on this device,
  /// the chat every later time.
  Future<void> _goAfterSignIn() => landAfterSignIn(context, ref);

  /// Confirm a successful sign-in. Raised on the app-level ScaffoldMessenger, so
  /// it survives the immediate `context.go('/')`.
  void _showSignedIn(String? login) {
    if (!mounted) return;
    final l10n = AppLocalizations.of(context);
    showToastOk(
      context,
      (login != null && login.isNotEmpty)
          ? l10n.accountSignedInAs(login)
          : l10n.accountSignedIn,
    );
  }

  /// The backend pairing works on: the Advanced field's, once the user is done
  /// typing it, else the configured one.
  String? _pairingBackend;

  void _applyPairingBackend() {
    // Blur can arrive while the panel's route unmounts: change state after.
    Future(() {
      if (!mounted) return;
      final typed = _backend.text.trim();
      final backend = typed.isEmpty ? null : typed;
      if (backend == _pairingBackend) return;
      ref.read(pairingBackendProvider.notifier).state = backend;
      setState(() => _pairingBackend = backend);
    });
  }

  /// GitHub's two sign-ins, in the order the platform prefers: a phone's
  /// browser hands back to the app in fewest steps, while a desktop's redirect
  /// often lands in another browser profile, and the device code has no
  /// redirect at all.
  List<PairingOtherWay> _gitHubWays(AppLocalizations l10n) {
    final device = PairingOtherWay(
      key: const Key('account-device-code'),
      icon: AppIcons.pin_outlined,
      label: l10n.accountUseDeviceCode,
      onSelected: _startDevice,
    );
    final web = PairingOtherWay(
      key: const Key('account-sign-in-web'),
      icon: AppIcons.open_in_new,
      label: l10n.accountSignInButton,
      onSelected: _startWeb,
    );
    return prefersDeviceCodeLogin ? [device, web] : [web, device];
  }

  /// GitHub's sign-ins as the page's own actions, for a user whose GitHub
  /// session expired: the preferred one filled, the other outlined.
  List<Widget> _gitHubButtons(AppLocalizations l10n) {
    final ways = _gitHubWays(l10n);
    return [
      FilledButton(
        key: ways.first.key,
        onPressed: _busy ? null : ways.first.onSelected,
        style: _ctaStyle,
        child: Text(ways.first.label),
      ),
      const SizedBox(height: 10),
      OutlinedButton(
        key: ways.last.key,
        onPressed: _busy ? null : ways.last.onSelected,
        style: _ctaStyle,
        child: Text(ways.last.label),
      ),
    ];
  }

  /// Advanced, inside Other ways: a self-deployed backend, which pairing and
  /// GitHub then both use, or the self-hosted relay instead.
  Widget _advancedSettings(BuildContext panel) {
    final l10n = AppLocalizations.of(panel);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Focus(
          onFocusChange: (focused) {
            if (!focused) _applyPairingBackend();
          },
          child: TextField(
            key: const Key('account-backend'),
            controller: _backend,
            enabled: _device == null,
            keyboardType: TextInputType.url,
            autocorrect: false,
            onSubmitted: (_) => _applyPairingBackend(),
            decoration: InputDecoration(
              labelText: l10n.accountBackendHint,
              isDense: true,
            ),
          ),
        ),
        const SizedBox(height: 6),
        // An authorized poll may still be writing the account: no relay
        // setup until it has answered.
        ValueListenableBuilder<bool>(
          valueListenable: _busyNow,
          builder: (_, busy, _) => TextButton(
            key: const Key('account-self-host'),
            onPressed: busy
                ? null
                : () {
                    Navigator.of(panel).pop();
                    _openSelfHost();
                  },
            child: Text(l10n.accountAdvancedSelfHost),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final device = _device;
    // A GitHub user whose session expired comes back to GitHub first.
    final gitHubFirst = widget.sessionExpired && !_pairingInstead;
    return Scaffold(
      appBar: WindowTitleBar(title: Text(l10n.accountSignInTitle)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Center(child: BrandLogo(size: 64)),
                const SizedBox(height: 20),
                BrandHeadline(
                  l10n.accountWelcomeHeadline,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 32),
                if (gitHubFirst) ...[
                  DecoratedBox(
                    key: const Key('account-session-expired'),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.errorContainer,
                      borderRadius: BorderRadius.circular(kControlRadius),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            AppIcons.lock_clock_outlined,
                            size: 20,
                            color: theme.colorScheme.onErrorContainer,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  l10n.accountSessionExpiredTitle,
                                  style: theme.textTheme.titleSmall?.copyWith(
                                    color: theme.colorScheme.onErrorContainer,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  l10n.accountSessionExpiredMessage,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onErrorContainer,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                if (_error != null) ...[
                  Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                  const SizedBox(height: 16),
                ],
                if (device == null && gitHubFirst) ...[
                  ..._gitHubButtons(l10n),
                  if (_busy) ...const [SizedBox(height: 12), _Spinner()],
                  const SizedBox(height: 6),
                  PairingOtherWaysButton(
                    enabled: !_busy,
                    advanced: _advancedSettings,
                    ways: [
                      PairingOtherWay(
                        key: const Key('account-use-pairing'),
                        icon: AppIcons.devices_outlined,
                        label: l10n.pairingUseInstead,
                        onSelected: () =>
                            setState(() => _pairingInstead = true),
                      ),
                    ],
                  ),
                ] else if (device == null) ...[
                  // Pairing leads: no account needed. GitHub's sign-ins and
                  // the self-hosted path wait under Other ways.
                  PairingFront(
                    backend: _pairingBackend,
                    otherWays: _gitHubWays(l10n),
                    advanced: _advancedSettings,
                    otherWaysEnabled: !_busy,
                  ),
                  if (_busy) ...const [SizedBox(height: 12), _Spinner()],
                ] else ...[
                  // Three ordered steps, because the code alone doesn't say what
                  // to do with it: take the code, enter it at GitHub, come back.
                  _Step(
                    number: 1,
                    caption: l10n.accountEnterCode,
                    child: _DeviceCodeCard(code: device.userCode),
                  ),
                  const SizedBox(height: 14),
                  _Step(
                    number: 2,
                    child: FilledButton.icon(
                      key: const Key('account-open-github'),
                      onPressed: () =>
                          openWebUrl(context, device.verificationUri),
                      icon: const Icon(AppIcons.open_in_new, size: 18),
                      label: Text(l10n.accountOpenGitHub),
                    ),
                  ),
                  const SizedBox(height: 14),
                  _Step(
                    number: 3,
                    child: Row(
                      children: [
                        const SizedBox(
                          width: 15,
                          height: 15,
                          child: CircularProgressIndicator(strokeWidth: 1.8),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            l10n.accountWaiting,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                  // Waiting on GitHub: only the self-hosted way out remains.
                  PairingOtherWaysButton(
                    ways: const [],
                    advanced: _advancedSettings,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The sign-in actions are the page's whole purpose: full-size pills on
/// every platform, not the denser desktop button.
const _ctaStyle = ButtonStyle(
  minimumSize: WidgetStatePropertyAll(Size.fromHeight(46)),
);

/// One numbered step of the device-code flow.
///
/// The number is what makes the three read as an order rather than three
/// unrelated controls; [caption] explains a step whose content can't speak for
/// itself (the bare code), and is omitted where the control already says it.
class _Step extends StatelessWidget {
  const _Step({required this.number, required this.child, this.caption});

  final int number;
  final Widget child;
  final String? caption;

  /// A 20px disc, the same tinted-glyph treatment the capability rows use, with
  /// its content indented to clear it.
  static const double _discSize = 20;
  static const double _discGap = 10;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: _discSize,
          height: _discSize,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: scheme.primaryContainer,
            shape: BoxShape.circle,
          ),
          child: Text(
            '$number',
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: scheme.onPrimaryContainer,
            ),
          ),
        ),
        const SizedBox(width: _discGap),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (caption != null) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 1, bottom: 7),
                  child: Text(
                    caption!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
              child,
            ],
          ),
        ),
      ],
    );
  }
}

/// The device code, as one tap target that copies it.
///
/// Copying is the whole point of showing the code, so the card itself is the
/// button rather than hanging a separate control underneath — and it confirms,
/// because a silent clipboard write leaves the user unsure whether to retype the
/// code by hand. Monospace with the digits spaced out, since the next thing that
/// happens is a human transcribing it into another window.
class _DeviceCodeCard extends StatelessWidget {
  const _DeviceCodeCard({required this.code});

  final String code;

  static const double _codeSize = 25;
  static const double _codeTracking = 4;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: l10n.accountCopyCode,
      child: Material(
        color: scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(kPanelRadius),
        child: InkWell(
          key: const Key('account-code-copy'),
          mouseCursor: clickable,
          borderRadius: BorderRadius.circular(kPanelRadius),
          onTap: () {
            Clipboard.setData(ClipboardData(text: code));
            showToastOk(context, l10n.copied);
          },
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(kPanelRadius),
              border: Border.all(color: scheme.outline),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    code,
                    style: TextStyle(
                      fontFamily: monoFontFamily,
                      fontFamilyFallback: monoCjkFallback,
                      fontSize: _codeSize,
                      letterSpacing: _codeTracking,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurface,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  AppIcons.copy_outlined,
                  size: 18,
                  color: scheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A sign-in under way.
class _Spinner extends StatelessWidget {
  const _Spinner();

  @override
  Widget build(BuildContext context) => const Center(
    child: SizedBox(
      width: 18,
      height: 18,
      child: CircularProgressIndicator(strokeWidth: 2),
    ),
  );
}
