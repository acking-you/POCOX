import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/app_icons.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/fonts.dart';
import 'package:pocox/src/pairing/pairing_other_ways.dart';
import 'package:pocox/src/pairing/pairing_platform.dart';
import 'package:pocox/src/pairing/pairing_session.dart';
import 'package:pocox/src/pairing/pairing_widgets.dart';
import 'package:pocox/src/providers.dart';
import 'package:pocox/src/theme.dart';
import 'package:pocox/src/widgets/app_toast.dart';

/// How often a first screen looks for a device that linked into this one, as
/// any foreground pairing page does.
const pairingPollInterval = Duration(seconds: 60);

/// Sign-in's pairing page: this device's code and getting started on a
/// computer, another device's code first on a phone, then "Other ways to sign
/// in" for restoring a previous device and [otherWays]. Preparing the code
/// changes nothing but the device store: no account, hosting or GitHub sign-in
/// in progress is touched until the user chooses Get started, Continue or a
/// link.
class PairingFront extends ConsumerStatefulWidget {
  /// Creates the front, on [backend] or the configured one.
  const PairingFront({
    super.key,
    this.backend,
    this.otherWays = const [],
    this.advanced,
    this.enabled = true,
  });

  /// The backend the sign-in page's Advanced field names.
  final String? backend;

  /// The sign-in page's own other ways (GitHub's), after Restore.
  final List<PairingOtherWay> otherWays;

  /// The self-hosted settings under Advanced.
  final WidgetBuilder? advanced;

  /// Whether its actions can act now: not while another sign-in on the page
  /// is under way, which would otherwise race this one.
  final bool enabled;

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

  /// Which [_load] may still write: a backend change starts another.
  int _generation = 0;

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
    if (old.backend == widget.backend) return;
    // Another backend is another identity: nothing of this one may act.
    setState(() {
      _code = null;
      _status = null;
      _session = null;
      _others = const [];
      _offline = false;
      _unavailable = null;
      _loading = true;
    });
    unawaited(_load());
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

  /// Read where this device stands and prepare its code, on every poll and
  /// resume too, so a removal or a replaced identity shows here. Offline
  /// keeps the page usable; the next poll asks again. Only the latest call
  /// writes.
  Future<void> _load() async {
    final generation = ++_generation;
    bool stale() => !mounted || generation != _generation;
    final api = _api;
    final backend = widget.backend;
    await settleQuietly(api, backend: backend);
    if (stale()) return;
    try {
      final status = await api.pairingStatus(backend: backend);
      if (!mounted || generation != _generation) return;
      setState(() {
        _status = status;
        _session = status.session;
        _offline = false;
        _unavailable = null;
      });
      explainFailedOperations(context, status.failed);
      if (const {'superseded', 'unknown', 'pending'}.contains(status.state)) {
        return;
      }
      final prepared = await api.pairingPrepare(backend: backend);
      if (stale()) return;
      setState(() {
        _code = prepared.code;
        _session = prepared.session;
      });
      await _refreshGroup(generation);
    } catch (error) {
      if (stale()) return;
      setState(() => _noteFailure(error));
    } finally {
      if (!stale()) setState(() => _loading = false);
    }
  }

  void _noteFailure(Object error) {
    final l10n = AppLocalizations.of(context);
    if (error is PairingFailure &&
        const {
          'relay_capacity',
          'pairing_disabled',
          'pairing_client_upgrade_required',
          'rate_limited',
        }.contains(error.code)) {
      // Each says what is wrong, or how long to wait, better than Offline.
      _unavailable = pairingErrorText(l10n, error);
      _offline = false;
    } else {
      _offline = true;
    }
  }

  void _refresh() => unawaited(_load());

  /// Who has linked into this device while its first screen was open.
  Future<void> _refreshGroup(int generation) async {
    try {
      final page = await _api.pairingDevices(backend: widget.backend);
      if (!mounted || generation != _generation) return;
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
      if (!mounted) return;
      if (followTransitionPending(context, error, backend: widget.backend)) {
        return;
      }
      showToastError(context, pairingErrorText(l10n, error));
      // A refusal about this identity changes what the page should offer.
      if (error is PairingFailure &&
          const {
            'device_superseded',
            'device_unknown',
            'grace_restricted',
            'transition_pending',
            'signed_out',
          }.contains(error.code)) {
        await _load();
      }
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
        context.push('/pair/restore', extra: (true, widget.backend));
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
    context.push('/pair/join', extra: (code ?? _entry.text, widget.backend));
  }

  /// Whether this device may recover another identity: only one read in full
  /// that has nothing to lose, not set up, alone and not removed.
  bool get _restorable {
    final status = _status;
    final session = _session;
    return status != null &&
        session != null &&
        !const {
          'superseded',
          'unknown',
          'pending',
          'removed',
        }.contains(status.state) &&
        !session.activated &&
        _others.isEmpty &&
        !_offline &&
        _unavailable == null;
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
    final idle = widget.enabled && !_busy;
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
            onPressed: idle ? () => _startOver(takeBack: true) : null,
            style: pairingCta,
            child: Text(l10n.pairingTakeBack),
          ),
          const SizedBox(height: 10),
        ],
        OutlinedButton(
          key: const Key('pairing-start-over'),
          onPressed: idle ? () => _startOver(takeBack: false) : null,
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
      final ready = _code != null && idle;
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
            onPressed: idle ? () => _openJoin('') : null,
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
            enabled: idle,
            onScan: nativeDeviceStore ? _scan : null,
            onSubmitted: (_) {
              if (idle && pairingCodeComplete(_entry.text)) _openJoin();
            },
          ),
          const SizedBox(height: 12),
          FilledButton(
            key: const Key('pairing-next'),
            onPressed: pairingCodeComplete(_entry.text) && idle
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
          if (!activated && !joined && placeholder != null) ...[
            const SizedBox(height: 8),
            Text(
              placeholder,
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ]);
      }
    }
    if (_busy || (_loading && _status == null)) {
      children.addAll(const [SizedBox(height: 12), PairingSpinner()]);
    }
    final ways = [
      if (_restorable)
        PairingOtherWay(
          key: const Key('pairing-restore'),
          icon: AppIcons.history,
          label: l10n.pairingRestore,
          // Read again on the tap: the panel may have stayed open while
          // another device linked into this one.
          onSelected: () {
            if (_restorable) {
              context.push('/pair/restore', extra: (false, widget.backend));
            }
          },
        ),
      ...widget.otherWays,
    ];
    if (ways.isNotEmpty || widget.advanced != null) {
      children.addAll([
        const SizedBox(height: 6),
        PairingOtherWaysButton(
          enabled: idle,
          advanced: widget.advanced,
          ways: ways,
        ),
      ]);
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }
}
