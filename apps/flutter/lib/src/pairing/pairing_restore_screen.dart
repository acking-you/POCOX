import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/app_icons.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/fonts.dart';
import 'package:pocox/src/pairing/pairing_page.dart';
import 'package:pocox/src/pairing/pairing_platform.dart';
import 'package:pocox/src/pairing/pairing_session.dart';
import 'package:pocox/src/pairing/pairing_widgets.dart';
import 'package:pocox/src/providers.dart';
import 'package:pocox/src/widgets/app_toast.dart';
import 'package:pocox/src/widgets/field_help.dart';

enum _Step { start, pick, asking, approved }

/// Restore a previous device: a code from any device of its group and the
/// pick of which one this is, or a linked device's approval. Nothing changes
/// until the user has seen the group's devices and said they are theirs;
/// continuing as new stays open throughout. A device that only asked shows a
/// check number and no device names.
class PairingRestoreScreen extends ConsumerStatefulWidget {
  /// Creates the page. [retake] ends the old device's access at once and
  /// changes its code, for when someone else may have it.
  const PairingRestoreScreen({super.key, this.retake = false, this.backend});

  /// Whether this takes a device back rather than continuing it.
  final bool retake;

  /// The backend of the page that opened this one; null is the configured
  /// one.
  final String? backend;

  @override
  ConsumerState<PairingRestoreScreen> createState() => _PairingRestoreState();
}

class _PairingRestoreState extends ConsumerState<PairingRestoreScreen> {
  final _entry = TextEditingController();
  _Step _step = _Step.start;
  PairingPreview? _preview;
  PairingRestoreRequest? _request;

  /// The device picked, or the empty string for adding as a new one.
  String? _picked;
  String? _error;
  bool _busy = false;
  Timer? _poll;
  var _wait = const Duration(seconds: 5);

  String? get _backend => widget.backend;
  BridgeApi get _api => ref.read(bridgeApiProvider);

  @override
  void initState() {
    super.initState();
    _entry.addListener(() => setState(() => _error = null));
  }

  @override
  void dispose() {
    _poll?.cancel();
    _entry.dispose();
    super.dispose();
  }

  void _asNew() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/onboarding');
    }
  }

  Future<void> _run(Future<void> Function() work) async {
    final l10n = AppLocalizations.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await work();
    } catch (error) {
      if (mounted) setState(() => _error = pairingErrorText(l10n, error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// A ticket-carrying change refused: another change under way opens its
  /// page; a group that changed since its preview is shown again, picking
  /// anew. True when handled.
  bool _followRefusal(Object error) {
    if (followTransitionPending(context, error, backend: _backend)) return true;
    if (error is PairingFailure && error.code == 'preview_stale') {
      showToast(context, AppLocalizations.of(context).pairingErrStale);
      setState(() => _picked = null);
      // After the refused change's own busy state has cleared.
      unawaited(Future(_lookUp));
      return true;
    }
    return false;
  }

  Future<void> _lookUp() => _run(() async {
    final preview = await _api.pairingPreview(_entry.text, backend: _backend);
    if (!mounted) return;
    _poll?.cancel();
    setState(() {
      _preview = preview;
      _picked = null;
      _step = _Step.pick;
    });
  });

  Future<void> _scan() async {
    final code = await context.push<String>('/pair/scan');
    if (code == null || !mounted) return;
    _entry.text = code;
    await _lookUp();
  }

  Future<void> _ask() => _run(() async {
    final hint = await pairingHardwareHint();
    final request = await _api.pairingRestoreRequest(
      hint: hint,
      backend: _backend,
    );
    if (!mounted) return;
    setState(() {
      _request = request;
      _step = _Step.asking;
    });
    _schedulePoll();
  });

  void _schedulePoll() {
    _poll?.cancel();
    _poll = Timer(_wait, _pollRequest);
    final next = _wait * 2;
    _wait = next > pairingPendingMaxWait ? pairingPendingMaxWait : next;
  }

  Future<void> _pollRequest() async {
    final request = _request;
    if (request == null || _step != _Step.asking) return;
    final l10n = AppLocalizations.of(context);
    try {
      final latest = await _api.pairingRestorePoll(
        request.requestId,
        backend: _backend,
      );
      if (!mounted || _step != _Step.asking) return;
      switch (latest.status) {
        case 'approved':
          setState(() {
            _request = latest;
            _step = _Step.approved;
          });
          return;
        case 'pending':
          break;
        default:
          showToast(context, switch (latest.status) {
            'denied' => l10n.pairingRestoreDenied,
            'expired' => l10n.pairingRestoreExpired,
            _ => l10n.pairingErrStale,
          });
          setState(() => _step = _Step.start);
          return;
      }
    } catch (_) {
      // Asked again after the next wait.
    }
    if (mounted) _schedulePoll();
  }

  Future<void> _restore({String? requestId}) async {
    final l10n = AppLocalizations.of(context);
    final preview = _preview;
    final picked = _picked;
    if (requestId == null && preview != null && picked != null) {
      final device = preview.devices.where((d) => d.id == picked).firstOrNull;
      if (device != null && pairingActiveToday(device.lastActiveDay)) {
        final yes = await confirmPairing(
          context,
          title: l10n.pairingActiveTodayTitle(device.name),
          body: l10n.pairingActiveTodayBody,
          yes: l10n.pairingRestoreYes,
          danger: true,
        );
        if (!yes || !mounted) return;
      }
    }
    await _run(() async {
      final hint = await pairingHardwareHint();
      final PairingOperation operation;
      try {
        operation = await _api.pairingRestoreConfirm(
          ticket: requestId == null ? preview?.ticket : null,
          targetDeviceId: requestId == null ? picked : null,
          requestId: requestId,
          retake: widget.retake,
          hint: hint,
          backend: _backend,
        );
      } catch (error) {
        if (mounted && _followRefusal(error)) return;
        rethrow;
      }
      if (!mounted) return;
      if (operation.status == 'completed') {
        showToastOk(context, l10n.pairingRestored);
      }
      await followPairingOperation(context, ref, operation, backend: _backend);
    });
  }

  /// Not one of the group's devices: join the group as a new one with the
  /// same preview.
  Future<void> _linkAsNew() => _run(() async {
    final preview = _preview!;
    final hint = await pairingHardwareHint();
    final PairingOperation operation;
    try {
      operation = await _api.pairingLink(
        ticket: preview.ticket,
        leaveCurrent: false,
        hint: hint,
        backend: _backend,
      );
    } catch (error) {
      if (mounted && _followRefusal(error)) return;
      rethrow;
    }
    if (!mounted) return;
    await followPairingOperation(context, ref, operation, backend: _backend);
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final title = widget.retake ? l10n.pairingTakeBack : l10n.pairingRestore;
    return switch (_step) {
      _Step.start => _start(l10n, title),
      _Step.pick => _pick(l10n, title),
      _Step.asking => _asking(l10n, title),
      _Step.approved => _approved(l10n, title),
    };
  }

  Widget _codeEntry(AppLocalizations l10n) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      PairingCodeField(
        controller: _entry,
        label: l10n.pairingGroupCode,
        // A failed lookup says so wherever the code was typed.
        error: _step == _Step.start || _step == _Step.asking ? _error : null,
        enabled: !_busy,
        onScan: nativeDeviceStore ? _scan : null,
        onSubmitted: (_) {
          if (pairingCodeComplete(_entry.text)) _lookUp();
        },
      ),
      const SizedBox(height: 12),
      FilledButton(
        key: const Key('pairing-restore-next'),
        onPressed: pairingCodeComplete(_entry.text) && !_busy ? _lookUp : null,
        style: pairingCta,
        child: Text(l10n.pairingNext),
      ),
    ],
  );

  Widget _start(AppLocalizations l10n, String title) => PairingPageFrame(
    title: title,
    busy: _busy,
    logo: true,
    children: [
      PairingHeading(l10n.pairingRestoreQuestion, center: true),
      if (widget.retake) ...[
        const SizedBox(height: 14),
        PairingBanner(
          icon: AppIcons.gpp_bad_outlined,
          urgent: false,
          title: l10n.pairingTakeBack,
          body: l10n.pairingTakeBackBody,
        ),
      ],
      const SizedBox(height: 20),
      _codeEntry(l10n),
      const SizedBox(height: 14),
      const PairingOr(),
      const SizedBox(height: 14),
      OutlinedButton(
        key: const Key('pairing-ask'),
        onPressed: _busy ? null : _ask,
        style: pairingCta,
        child: Text(l10n.pairingAsk),
      ),
      const SizedBox(height: 6),
      TextButton(
        key: const Key('pairing-as-new'),
        onPressed: _busy ? null : _asNew,
        child: Text(l10n.pairingAsNew),
      ),
      if (_busy) ...const [SizedBox(height: 12), PairingSpinner()],
    ],
  );

  Widget _pick(AppLocalizations l10n, String title) {
    final preview = _preview!;
    final rows = <Widget>[
      for (final device in preview.devices)
        PairingDeviceRow(
          key: Key('pairing-pick-${device.id}'),
          name: device.name,
          icon: pairingDeviceIcon(null),
          line: pairingLastActive(l10n, device.lastActiveDay),
          selected: _picked == device.id,
          onTap: _busy ? null : () => setState(() => _picked = device.id),
        ),
      if (!widget.retake)
        PairingDeviceRow(
          key: const Key('pairing-pick-new'),
          name: l10n.pairingAddAsNew,
          icon: AppIcons.add,
          selected: _picked == '',
          onTap: _busy ? null : () => setState(() => _picked = ''),
        ),
    ];
    final picked = _picked;
    final actions = [
      FilledButton(
        key: const Key('pairing-restore-confirm'),
        onPressed: picked == null || _busy
            ? null
            : picked.isEmpty
            ? _linkAsNew
            : () => _restore(),
        style: pairingCta,
        child: Text(
          picked != null && picked.isEmpty
              ? l10n.pairingLink
              : l10n.pairingRestoreThis,
        ),
      ),
      const SizedBox(height: 8),
      TextButton(
        onPressed: _busy ? null : () => setState(() => _step = _Step.start),
        child: Text(l10n.cancel),
      ),
    ];
    return PairingPageFrame(
      title: title,
      busy: _busy,
      onBack: () => setState(() => _step = _Step.start),
      footer: isDesktop ? null : actions,
      children: [
        PairingHeading(l10n.pairingWhichDevice),
        const SizedBox(height: 14),
        PairingPlate(rows),
        if (_error != null) ...[
          const SizedBox(height: 10),
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        if (_busy) ...const [SizedBox(height: 12), PairingSpinner()],
        if (isDesktop) ...[const SizedBox(height: 24), ...actions],
      ],
    );
  }

  Widget _asking(AppLocalizations l10n, String title) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return PairingPageFrame(
      title: title,
      busy: _busy,
      logo: true,
      onBack: () {
        _poll?.cancel();
        setState(() => _step = _Step.start);
      },
      children: [
        PairingHeading(
          l10n.pairingWaitingTitle,
          center: true,
          info: InfoTip(l10n.pairingWaitingInfo),
        ),
        const SizedBox(height: 16),
        DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: scheme.outline),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Column(
              children: [
                Text(
                  l10n.pairingCheckNumber,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  _request?.matchingId ?? '····',
                  key: const Key('pairing-check-number'),
                  style: pairingMono(context, 24, tracking: 4),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        const PairingOr(),
        const SizedBox(height: 14),
        _codeEntry(l10n),
        const SizedBox(height: 6),
        TextButton(onPressed: _asNew, child: Text(l10n.pairingAsNew)),
      ],
    );
  }

  Widget _approved(AppLocalizations l10n, String title) {
    final request = _request!;
    final actions = [
      FilledButton(
        key: const Key('pairing-approved-restore'),
        onPressed: _busy ? null : () => _restore(requestId: request.requestId),
        style: pairingCta,
        child: Text(l10n.pairingRestoreThis),
      ),
      const SizedBox(height: 8),
      TextButton(
        key: const Key('pairing-not-mine'),
        onPressed: _busy ? null : _asNew,
        child: Text(l10n.pairingNotMine),
      ),
    ];
    return PairingPageFrame(
      title: l10n.pairingConfirmRestore,
      busy: _busy,
      onBack: _asNew,
      footer: isDesktop ? null : actions,
      children: [
        PairingHeading(l10n.pairingYourDevices),
        const SizedBox(height: 14),
        PairingPlate([
          for (final device in request.devices)
            PairingDeviceRow(
              name: device.name,
              icon: pairingDeviceIcon(null),
              line: device.id == request.targetDeviceId
                  ? l10n.pairingSameDevice
                  : pairingLastActive(l10n, device.lastActiveDay),
            ),
        ]),
        if (_error != null) ...[
          const SizedBox(height: 10),
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        if (_busy) ...const [SizedBox(height: 12), PairingSpinner()],
        if (isDesktop) ...[const SizedBox(height: 24), ...actions],
      ],
    );
  }
}
