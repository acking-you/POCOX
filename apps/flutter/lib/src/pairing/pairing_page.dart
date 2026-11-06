import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/app_icons.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/pairing/pairing_session.dart';
import 'package:pocox/src/pairing/pairing_widgets.dart';
import 'package:pocox/src/providers.dart';
import 'package:pocox/src/widgets/brand_logo.dart';
import 'package:pocox/src/widgets/window_title_bar.dart';

/// A pairing page's frame, as sign-in lays itself out: a title bar with a way
/// back, and one narrow centred column.
class PairingPageFrame extends StatelessWidget {
  /// Creates the frame.
  const PairingPageFrame({
    super.key,
    required this.title,
    required this.children,
    this.onBack,
    this.logo = false,
    this.footer,
    this.busy = false,
    this.backTakesOver = false,
  });

  /// The title bar's title.
  final String title;

  /// The column.
  final List<Widget> children;

  /// Where back goes; popping by default.
  final VoidCallback? onBack;

  /// Whether the column starts with the logo.
  final bool logo;

  /// Actions kept at the bottom on a phone.
  final List<Widget>? footer;

  /// A change is being sent: going back now would drop its outcome, so
  /// neither the back button nor the system's back leaves.
  final bool busy;

  /// Whether the system's back goes through [onBack] too, for a page whose
  /// way back depends on where the device now stands.
  final bool backTakesOver;

  @override
  Widget build(BuildContext context) {
    void back() {
      if (onBack != null) {
        onBack!();
      } else if (context.canPop()) {
        context.pop();
      } else {
        context.go('/onboarding');
      }
    }

    final footer = this.footer;
    return PopScope(
      canPop: !busy && !backTakesOver,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !busy && backTakesOver) back();
      },
      child: _scaffold(context, back, footer),
    );
  }

  Widget _scaffold(
    BuildContext context,
    VoidCallback back,
    List<Widget>? footer,
  ) {
    return Scaffold(
      appBar: WindowTitleBar(
        leading: IconButton(
          key: const Key('pairing-back'),
          tooltip: MaterialLocalizations.of(context).backButtonTooltip,
          onPressed: busy ? null : back,
          icon: const Icon(AppIcons.arrow_back),
        ),
        automaticallyImplyLeading: false,
        title: Text(title),
        centerTitle: true,
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (logo) ...[
                          const Center(child: BrandLogo(size: 56)),
                          const SizedBox(height: 18),
                        ],
                        ...children,
                      ],
                    ),
                  ),
                ),
              ),
            ),
            if (footer != null)
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: footer,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A page's heading inside its column.
class PairingHeading extends StatelessWidget {
  /// Creates a heading.
  const PairingHeading(this.text, {super.key, this.center = false, this.info});

  /// Its text.
  final String text;

  /// Whether it is centred.
  final bool center;

  /// An explanation behind an info mark beside it.
  final Widget? info;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(
      context,
    ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600);
    final heading = Text(
      text,
      textAlign: center ? TextAlign.center : TextAlign.start,
      style: style,
    );
    if (info == null) return heading;
    return Row(
      mainAxisAlignment: center
          ? MainAxisAlignment.center
          : MainAxisAlignment.start,
      children: [
        Flexible(child: heading),
        const SizedBox(width: 6),
        info!,
      ],
    );
  }
}

/// A membership change the backend has yet to confirm: shown until it ends,
/// across restarts too, and never sent again. Checking reads its result.
class PairingPendingPage extends ConsumerStatefulWidget {
  /// Creates the page for [operation].
  const PairingPendingPage({super.key, this.operation, this.backend});

  /// The change waited on.
  final PairingOperation? operation;

  /// The backend it is on.
  final String? backend;

  @override
  ConsumerState<PairingPendingPage> createState() => _PairingPendingState();
}

class _PairingPendingState extends ConsumerState<PairingPendingPage> {
  Timer? _timer;
  var _wait = const Duration(seconds: 5);
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _schedule() {
    _timer?.cancel();
    _timer = Timer(_wait, _check);
    final next = _wait * 2;
    _wait = next > pairingPendingMaxWait ? pairingPendingMaxWait : next;
  }

  Future<void> _check() async {
    if (_checking) return;
    setState(() => _checking = true);
    final api = ref.read(bridgeApiProvider);
    try {
      final outcomes = await api.pairingSettle(backend: widget.backend);
      if (!mounted) return;
      final id = widget.operation?.id;
      final mine = outcomes.where((outcome) => outcome.id == id).firstOrNull;
      final open = outcomes.any((outcome) => outcome.status == 'pending');
      if (mine != null && mine.status != 'pending') {
        // Done lands; not done says why. Either way nothing is left to wait
        // for here.
        await followPairingOperation(
          context,
          ref,
          mine,
          backend: widget.backend,
        );
        if (mine.status != 'completed' && mounted) await _land();
        return;
      }
      if (!open) {
        // Read through to the end elsewhere: what it did shows in the state.
        await _land();
        return;
      }
    } catch (_) {
      // Still waiting; the next check asks again.
    } finally {
      if (mounted) setState(() => _checking = false);
    }
    if (mounted) _schedule();
  }

  /// Leave for where this device now stands: sign-in when the change left
  /// it signed out or never happened to one that was, the app otherwise.
  Future<void> _land() async {
    ref.invalidate(configProvider);
    ConfigInfo? config;
    try {
      config = await ref
          .read(configProvider.future)
          .timeout(const Duration(seconds: 2));
    } catch (_) {
      // The app's own start-up reads it again.
    }
    if (!mounted) return;
    if (config?.mode == 'unconfigured') {
      context.go('/onboarding');
    } else {
      await landAfterSignIn(context, ref);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final kind = widget.operation?.kind;
    final title = switch (kind) {
      'link' => l10n.pairingPendingLink,
      'leave' => l10n.pairingPendingLeave,
      'remove' => l10n.pairingPendingRemove,
      'restore' || 'retake' => l10n.pairingPendingRestore,
      _ => l10n.pairingPendingTitle,
    };
    return PairingPageFrame(
      title: l10n.pairingPendingTitle,
      onBack: _land,
      backTakesOver: true,
      logo: true,
      children: [
        PairingHeading(title, center: true),
        const SizedBox(height: 10),
        Text(
          l10n.pairingPendingBody,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 24),
        OutlinedButton(
          key: const Key('pairing-check-status'),
          onPressed: _checking ? null : _check,
          style: pairingCta,
          child: Text(l10n.pairingCheckStatus),
        ),
        if (_checking) ...const [SizedBox(height: 12), PairingSpinner()],
      ],
    );
  }
}

/// The longest wait between two checks of a change under way.
const pairingPendingMaxWait = Duration(seconds: 60);
