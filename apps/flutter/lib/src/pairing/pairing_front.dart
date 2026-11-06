import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/app_icons.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/fonts.dart';
import 'package:pocox/src/pairing/pairing_platform.dart';
import 'package:pocox/src/pairing/pairing_session.dart';
import 'package:pocox/src/pairing/pairing_widgets.dart';
import 'package:pocox/src/providers.dart';
import 'package:pocox/src/theme.dart';
import 'package:pocox/src/widgets/app_toast.dart';

/// How often a first screen looks for a device that linked into this one, as
/// any foreground pairing page does.
const pairingPollInterval = Duration(seconds: 60);

/// The pairing paths at the top of sign-in: this device's code and getting
/// started on a computer, another device's code first on a phone, and restoring
/// a previous device. Preparing the code changes nothing but the device store:
/// no account, hosting or GitHub sign-in in progress is touched until the user
/// chooses Get started, Continue or a link.
class PairingFront extends ConsumerStatefulWidget {
  /// Creates the front, on [backend] or the configured one.
  const PairingFront({super.key, this.backend, this.extra});

  /// The backend the sign-in page's Advanced field names.
  final String? backend;

  /// What follows the pairing paths: GitHub's sign-ins and Advanced.
  final Widget? extra;

  @override
  ConsumerState<PairingFront> createState() => _PairingFrontState();
}

class _PairingFrontState extends ConsumerState<PairingFront>
    with WidgetsBindingObserver {
  final _entry = TextEditingController();
  PairingStatus? _status;
  PairingCode? _code;
  PairingSession? _session;
  List<PairingDevice> _others = const [];
  String? _unavailable;
  bool _offline = false;
  bool _loading = true;
  bool _busy = false;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _entry.addListener(() => setState(() {}));
    unawaited(_load());
    _poll = Timer.periodic(pairingPollInterval, (_) => _refresh());
  }

  @override
  void didUpdateWidget(PairingFront old) {
    super.didUpdateWidget(old);
    if (old.backend != widget.backend) unawaited(_load());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    _entry.dispose();
    super.dispose();
  }

  BridgeApi get _api => ref.read(bridgeApiProvider);

  /// Read where this device stands and prepare its code. Offline keeps the
  /// page usable; the next poll asks again.
  Future<void> _load() async {
    final api = _api;
    final backend = widget.backend;
    await settleQuietly(api, backend: backend);
    try {
      final status = await api.pairingStatus(backend: backend);
      if (!mounted) return;
      setState(() {
        _status = status;
        _session = status.session;
        _offline = false;
        _unavailable = null;
      });
      if (const {'superseded', 'unknown', 'pending'}.contains(status.state)) {
        return;
      }
      final prepared = await api.pairingPrepare(backend: backend);
      if (!mounted) return;
      setState(() {
        _code = prepared.code;
        _session = prepared.session;
      });
      await _refreshGroup();
    } catch (error) {
      if (!mounted) return;
      setState(() => _noteFailure(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _noteFailure(Object error) {
    final l10n = AppLocalizations.of(context);
    if (error is PairingFailure &&
        const {
          'relay_capacity',
          'pairing_disabled',
          'pairing_client_upgrade_required',
        }.contains(error.code)) {
      _unavailable = pairingErrorText(l10n, error);
    } else {
      _offline = true;
    }
  }

  void _refresh() {
    if (_code == null || _offline || _unavailable != null) {
      unawaited(_load());
    } else {
      unawaited(_refreshGroup());
    }
  }

  /// Who has linked into this device while its first screen was open.
  Future<void> _refreshGroup() async {
    try {
      final page = await _api.pairingDevices(backend: widget.backend);
      if (!mounted) return;
      setState(
        () => _others = [
          for (final device in page.devices)
            if (!device.isSelf) device,
        ],
      );
    } catch (_) {
      // The code still works; who joined shows on the next try.
    }
  }

  /// Get started or Continue: the user's explicit choice to use this device's
  /// identity here, the moment its hint is read.
  Future<void> _activate() async {
    final l10n = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      final hint = await pairingHardwareHint();
      await _api.pairingActivate(hint: hint, backend: widget.backend);
      if (!mounted) return;
      showToastOk(context, l10n.pairingReady);
      await landAfterSignIn(context, ref);
    } catch (error) {
      if (mounted) showToastError(context, pairingErrorText(l10n, error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// A superseded or unknown identity's way forward: discard it for a new
  /// inactive device, then recover one or carry on.
  Future<void> _startOver({required bool takeBack}) async {
    final l10n = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      await _api.pairingStartOver(backend: widget.backend);
      if (!mounted) return;
      if (takeBack) {
        context.push('/pair/restore', extra: true);
      }
      await _load();
    } catch (error) {
      if (mounted) showToastError(context, pairingErrorText(l10n, error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _checkPending() async {
    setState(() => _loading = true);
    await _load();
  }

  Future<void> _scan() async {
    final code = await context.push<String>('/pair/scan');
    if (code != null && mounted) _openJoin(code);
  }

  void _openJoin([String? code]) {
    context.push('/pair/join', extra: code ?? _entry.text);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final status = _status;
    final state = status?.state;
    final activated = _session?.activated ?? false;
    final removed = state == 'removed';
    final joined = _others.isNotEmpty;
    final restorable = !activated && !joined && !removed;
    final children = <Widget>[];

    if (state == 'superseded' || state == 'unknown') {
      final deadline = status?.graceDeadline;
      children.addAll([
        PairingBanner(
          key: const Key('pairing-superseded'),
          icon: AppIcons.gpp_bad_outlined,
          title: state == 'superseded'
              ? l10n.pairingSupersededTitle
              : l10n.pairingUnknownTitle,
          body: state == 'superseded'
              ? (deadline == null
                    ? l10n.pairingSupersededBodyNow
                    : l10n.pairingSupersededBody(
                        TimeOfDay.fromDateTime(
                          DateTime.fromMillisecondsSinceEpoch(deadline * 1000),
                        ).format(context),
                      ))
              : l10n.pairingUnknownBody,
        ),
        const SizedBox(height: 16),
        if (state == 'superseded') ...[
          FilledButton(
            key: const Key('pairing-take-back'),
            onPressed: _busy ? null : () => _startOver(takeBack: true),
            style: pairingCta,
            child: Text(l10n.pairingTakeBack),
          ),
          const SizedBox(height: 10),
        ],
        OutlinedButton(
          key: const Key('pairing-start-over'),
          onPressed: _busy ? null : () => _startOver(takeBack: false),
          style: pairingCta,
          child: Text(l10n.pairingStartOver),
        ),
      ]);
    } else if (state == 'pending') {
      children.addAll([
        PairingBanner(
          key: const Key('pairing-pending'),
          icon: AppIcons.hourglass_empty,
          urgent: false,
          title: l10n.pairingPendingTitle,
          body: l10n.pairingPendingBody,
        ),
        const SizedBox(height: 16),
        OutlinedButton(
          onPressed: _loading ? null : _checkPending,
          style: pairingCta,
          child: Text(l10n.pairingCheckStatus),
        ),
      ]);
    } else {
      if (removed) {
        children.addAll([
          PairingBanner(
            key: const Key('pairing-removed'),
            icon: AppIcons.link_off_outlined,
            title: l10n.pairingRemovedTitle,
            body: l10n.pairingRemovedBody,
          ),
          const SizedBox(height: 16),
        ]);
      }
      final primary = removed
          ? l10n.pairingContinueAlone
          : activated || joined
          ? l10n.pairingContinue
          : l10n.pairingGetStarted;
      final placeholder =
          _unavailable ?? (_offline ? l10n.pairingOfflineBody : null);
      final badge = _unavailable != null
          ? PairingPill(l10n.pairingUnavailable)
          : _offline
          ? PairingPill(l10n.pairingOffline)
          : joined
          ? PairingPill(
              // One peer is the device that just linked with this code; more
              // is a group this device already belongs to.
              _others.length == 1
                  ? l10n.pairingJoined(_others.first.name)
                  : l10n.pairingLinkedCount(_others.length + 1),
              tone: successColor(scheme),
            )
          : null;
      final ready = _code != null && !_busy;
      if (isDesktop) {
        children.addAll([
          PairingCodeCard(
            code: _code,
            qr: true,
            badge: badge,
            placeholder: placeholder,
          ),
          const SizedBox(height: 12),
          FilledButton(
            key: const Key('pairing-get-started'),
            onPressed: ready ? _activate : null,
            style: pairingCta,
            child: Text(primary),
          ),
          const SizedBox(height: 10),
          OutlinedButton(
            key: const Key('pairing-enter-code'),
            onPressed: _busy ? null : () => _openJoin(''),
            style: pairingCta,
            child: Text(l10n.pairingEnterOther),
          ),
        ]);
      } else {
        if (joined || activated) {
          children.addAll([
            PairingCodeCard(
              code: _code,
              badge: badge,
              placeholder: placeholder,
            ),
            const SizedBox(height: 12),
          ]);
        }
        children.addAll([
          PairingCodeField(
            controller: _entry,
            onScan: nativeDeviceStore ? _scan : null,
            onSubmitted: (_) {
              if (pairingCodeComplete(_entry.text)) _openJoin();
            },
          ),
          const SizedBox(height: 12),
          FilledButton(
            key: const Key('pairing-next'),
            onPressed: pairingCodeComplete(_entry.text) && !_busy
                ? _openJoin
                : null,
            style: pairingCta,
            child: Text(l10n.pairingNext),
          ),
          const SizedBox(height: 10),
          OutlinedButton(
            key: const Key('pairing-get-started'),
            onPressed: ready ? _activate : null,
            style: pairingCta,
            child: Text(
              removed || activated || joined
                  ? primary
                  : l10n.pairingFirstDevice,
            ),
          ),
          if (!activated && !joined && _unavailable != null) ...[
            const SizedBox(height: 8),
            Text(
              _unavailable!,
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ]);
      }
      if (restorable) {
        children.addAll([
          const SizedBox(height: 4),
          TextButton(
            key: const Key('pairing-restore'),
            onPressed: _busy ? null : () => context.push('/pair/restore'),
            child: Text(l10n.pairingRestore),
          ),
        ]);
      }
    }
    if (_busy || (_loading && _status == null)) {
      children.addAll(const [SizedBox(height: 12), PairingSpinner()]);
    }
    final extra = widget.extra;
    if (extra != null) {
      children.addAll([
        const SizedBox(height: 14),
        const PairingOr(),
        const SizedBox(height: 14),
        extra,
      ]);
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }
}
