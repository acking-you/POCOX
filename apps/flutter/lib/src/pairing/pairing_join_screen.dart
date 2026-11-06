import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/fonts.dart';
import 'package:pocox/src/pairing/pairing_page.dart';
import 'package:pocox/src/pairing/pairing_platform.dart';
import 'package:pocox/src/pairing/pairing_session.dart';
import 'package:pocox/src/pairing/pairing_widgets.dart';
import 'package:pocox/src/providers.dart';
import 'package:pocox/src/widgets/app_toast.dart';

/// Link this device to another device's group: a code typed, scanned or
/// opened from a link, then the group's devices, then the user's yes. A link
/// never happens without that preview, and leaving current peers, a GitHub
/// sign-in or a self-hosted relay is asked about first.
class PairingJoinScreen extends ConsumerStatefulWidget {
  /// Creates the page, previewing [code] at once when there is one.
  const PairingJoinScreen({super.key, this.code, this.backend});

  /// A code from the first screen, a scan or a `pocox://pair` link.
  final String? code;

  /// The backend of the page that opened this one; null is the configured
  /// one.
  final String? backend;

  @override
  ConsumerState<PairingJoinScreen> createState() => _PairingJoinState();
}

class _PairingJoinState extends ConsumerState<PairingJoinScreen> {
  final _entry = TextEditingController();
  PairingPreview? _preview;
  String? _error;
  bool _busy = false;

  /// The link is being sent (not a read-only preview): back would drop its
  /// outcome.
  bool _sending = false;

  String? get _backend => widget.backend;

  @override
  void initState() {
    super.initState();
    final code = widget.code ?? ref.read(pairingInvitationProvider);
    _entry.text = code ?? '';
    _entry.addListener(() => setState(() => _error = null));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Taken once: providers may not change while the tree builds.
      ref.read(pairingInvitationProvider.notifier).state = null;
      if (code != null && pairingCodeComplete(code)) _lookUp();
    });
  }

  @override
  void dispose() {
    _entry.dispose();
    super.dispose();
  }

  BridgeApi get _api => ref.read(bridgeApiProvider);

  Future<void> _lookUp() async {
    final l10n = AppLocalizations.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final preview = await _api.pairingPreview(_entry.text, backend: _backend);
      if (mounted) setState(() => _preview = preview);
    } catch (error) {
      if (mounted) setState(() => _error = pairingErrorText(l10n, error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _scan() async {
    final code = await context.push<String>('/pair/scan');
    if (code == null || !mounted) return;
    _entry.text = code;
    await _lookUp();
  }

  /// What this device leaves by linking, asked about before anything changes.
  /// Null when the user said no; otherwise whether to leave current peers.
  Future<bool?> _confirmLeaving(PairingPreview preview) async {
    final l10n = AppLocalizations.of(context);
    final target =
        preview.devices
            .where((device) => device.id == preview.targetDeviceId)
            .map((device) => device.name)
            .firstOrNull ??
        preview.devices.first.name;
    final config = await ref.read(configProvider.future);
    // This identity's peers, signed in or still on the first screen: a
    // device that others linked into has a group to leave too.
    var peers = const <PairingDevice>[];
    try {
      final page = await _api.pairingDevices(backend: _backend);
      peers = [
        for (final device in page.devices)
          if (!device.isSelf) device,
      ];
    } on PairingFailure catch (error) {
      // No identity here has no peers. Anything else leaves the question
      // unanswerable, and a link must not go ahead without it.
      if (!const {'no_device', 'signed_out'}.contains(error.code)) {
        if (mounted) showToastError(context, pairingErrorText(l10n, error));
        return null;
      }
    } catch (error) {
      if (mounted) showToastError(context, pairingErrorText(l10n, error));
      return null;
    }
    if (!mounted) return null;
    var leave = false;
    if (peers.isNotEmpty) {
      final yes = await confirmPairing(
        context,
        title: l10n.pairingLeaveTitle(peers.length),
        body: l10n.pairingLeaveBody(
          peers.map((device) => device.name).join(l10n.pairingListSeparator),
          target,
        ),
        yes: l10n.pairingLeaveAndLink,
      );
      if (!yes || !mounted) return null;
      leave = true;
    }
    if (config.pairing) return leave;
    if (config.mode == 'account') {
      final yes = await confirmPairing(
        context,
        title: l10n.pairingSignOutTitle(config.accountLogin ?? ''),
        body: l10n.pairingSignOutBody(target),
        yes: l10n.pairingSignOutAndLink,
      );
      return yes ? leave : null;
    }
    if (config.mode == 'self_host') {
      final yes = await confirmPairing(
        context,
        title: l10n.pairingRelayTitle,
        body: l10n.pairingRelayBody(target),
        yes: l10n.pairingRelayAndLink,
      );
      return yes ? leave : null;
    }
    return leave;
  }

  Future<void> _link() async {
    final preview = _preview;
    if (preview == null) return;
    final l10n = AppLocalizations.of(context);
    final leaveCurrent = await _confirmLeaving(preview);
    if (leaveCurrent == null || !mounted) return;
    setState(() {
      _busy = true;
      _sending = true;
    });
    try {
      final hint = await pairingHardwareHint();
      final operation = await _api.pairingLink(
        ticket: preview.ticket,
        leaveCurrent: leaveCurrent,
        hint: hint,
        backend: _backend,
      );
      if (!mounted) return;
      if (operation.status == 'completed') {
        showToastOk(context, l10n.pairingLinked);
      }
      await followPairingOperation(context, ref, operation, backend: _backend);
    } on PairingFailure catch (error) {
      if (!mounted) return;
      if (followTransitionPending(context, error, backend: _backend)) return;
      if (error.code == 'preview_stale') {
        // The group changed since the preview: show it again, as new.
        showToast(context, l10n.pairingErrStale);
        setState(() => _preview = null);
        await _lookUp();
      } else {
        showToastError(context, pairingErrorText(l10n, error));
      }
    } catch (error) {
      if (mounted) showToastError(context, pairingErrorText(l10n, error));
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _sending = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final preview = _preview;
    if (preview != null) return _confirm(context, l10n, preview);
    return PairingPageFrame(
      title: l10n.pairingEnterOther,
      busy: _sending,
      logo: true,
      children: [
        PairingHeading(l10n.pairingEnterTitle, center: true),
        const SizedBox(height: 20),
        PairingCodeField(
          controller: _entry,
          error: _error,
          enabled: !_busy,
          autofocus: isDesktop,
          onScan: nativeDeviceStore ? _scan : null,
          onSubmitted: (_) {
            if (pairingCodeComplete(_entry.text)) _lookUp();
          },
        ),
        const SizedBox(height: 12),
        FilledButton(
          key: const Key('pairing-next'),
          onPressed: pairingCodeComplete(_entry.text) && !_busy
              ? _lookUp
              : null,
          style: pairingCta,
          child: Text(l10n.pairingNext),
        ),
        if (_busy) ...const [SizedBox(height: 12), PairingSpinner()],
      ],
    );
  }

  Widget _confirm(
    BuildContext context,
    AppLocalizations l10n,
    PairingPreview preview,
  ) {
    final theme = Theme.of(context);
    final rows = [
      for (final device in preview.devices)
        PairingDeviceRow(
          name: device.name,
          icon: pairingDeviceIcon(null),
          line: device.id == preview.targetDeviceId
              ? l10n.pairingOwnsCode
              : pairingLastActive(l10n, device.lastActiveDay),
        ),
    ];
    final actions = [
      FilledButton(
        key: const Key('pairing-link'),
        onPressed: _busy || preview.alreadyMember ? null : _link,
        style: pairingCta,
        child: Text(l10n.pairingLink),
      ),
      const SizedBox(height: 8),
      TextButton(
        key: const Key('pairing-link-cancel'),
        onPressed: _busy ? null : () => setState(() => _preview = null),
        child: Text(l10n.cancel),
      ),
    ];
    return PairingPageFrame(
      title: l10n.pairingConfirmTitle,
      busy: _sending,
      onBack: _busy ? () {} : () => setState(() => _preview = null),
      footer: isDesktop ? null : actions,
      children: [
        PairingHeading(
          preview.alreadyMember
              ? l10n.pairingAlreadyMember
              : l10n.pairingLinkQuestion,
        ),
        const SizedBox(height: 14),
        PairingPlate(rows),
        const SizedBox(height: 14),
        Text(
          l10n.pairingLinkBody,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        if (_busy) ...const [SizedBox(height: 12), PairingSpinner()],
        if (isDesktop) ...[const SizedBox(height: 24), ...actions],
      ],
    );
  }
}
