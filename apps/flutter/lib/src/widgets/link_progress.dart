import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/app_icons.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/desktop_theme.dart';
import 'package:pocox/src/fonts.dart';
import 'package:pocox/src/motion.dart';
import 'package:pocox/src/network/connection_paths.dart';
import 'package:pocox/src/network/link_activity.dart';
import 'package:pocox/src/service_key.dart';
import 'package:pocox/src/theme.dart';
import 'package:pocox/src/widgets/adaptive_sheet.dart';
import 'package:pocox/src/widgets/field_help.dart';
import 'package:pocox/src/widgets/status_dots.dart';

export 'package:pocox/src/network/link_activity.dart' show ReconnectState;

/// The colour and mark of a step in [state]; a direct step that succeeded
/// takes the galaxy's P2P colour.
({Color color, IconData? icon}) _look(
  ColorScheme scheme,
  LinkStepState state, {
  bool p2p = false,
}) => switch (state) {
  LinkStepState.waiting => (
    color: scheme.onSurface.withValues(alpha: 0.28),
    icon: null,
  ),
  LinkStepState.active => (color: signalColor(scheme), icon: null),
  LinkStepState.done => (
    color: p2p ? infoColor(scheme) : successColor(scheme),
    icon: AppIcons.check_rounded,
  ),
  LinkStepState.fallback => (
    color: scheme.onSurfaceVariant,
    icon: AppIcons.route,
  ),
  LinkStepState.failed => (color: scheme.error, icon: AppIcons.close_rounded),
  LinkStepState.skipped => (
    color: onSurfaceMuted(scheme),
    icon: AppIcons.remove,
  ),
};

/// Whether the step after one in [state] can begin.
bool _passed(LinkStepState state) =>
    state == LinkStepState.done ||
    state == LinkStepState.fallback ||
    state == LinkStepState.skipped;

/// The steps of reaching a service side by side: relay, P2P and session, or
/// this device and the session for a service this app hosts. The step under
/// way turns, a failed one says why, and the line between two fills once the
/// first is passed.
class LinkPipeline extends StatelessWidget {
  /// Creates the pipeline of [steps].
  const LinkPipeline(this.steps, {super.key});

  /// What each step is doing.
  final LinkSteps steps;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final local = steps.local;
    final columns = [
      if (local != null)
        _StepColumn(
          key: const Key('link-step-local'),
          name: l10n.servicesLocalDevice,
          step: local,
          // Its label is the listener's address.
          mono: local.state == LinkStepState.done,
        )
      else ...[
        _StepColumn(
          key: const Key('link-step-relay'),
          name: l10n.linkStepRelay,
          step: steps.relay,
        ),
        _StepColumn(
          key: const Key('link-step-p2p'),
          name: l10n.linkStepP2p,
          step: steps.p2p,
          p2p: true,
        ),
      ],
      _StepColumn(
        key: const Key('link-step-session'),
        name: l10n.linkStepSession,
        step: steps.session,
      ),
    ];
    final track = scheme.onSurface.withValues(alpha: 0.1);
    return CustomPaint(
      key: const Key('link-pipeline'),
      painter: _Connectors([
        for (final column in columns.take(columns.length - 1))
          _passed(column.step.state)
              ? _look(scheme, column.step.state, p2p: column.p2p).color
              : track,
      ]),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [for (final column in columns) Expanded(child: column)],
      ),
    );
  }
}

/// The node of each step is centred in its column, 12 px down; [segments]
/// colour the lines between neighbouring nodes.
class _Connectors extends CustomPainter {
  const _Connectors(this.segments);

  final List<Color> segments;

  static const _center = 12.0;
  static const _gap = 16.0;

  @override
  void paint(Canvas canvas, Size size) {
    final column = size.width / (segments.length + 1);
    final paint = Paint()
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    for (final (from, color) in segments.indexed) {
      final start = column * (from + 0.5) + _gap;
      final end = column * (from + 1.5) - _gap;
      if (end <= start) continue;
      canvas.drawLine(
        Offset(start, _center),
        Offset(end, _center),
        paint..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(_Connectors old) => !listEquals(old.segments, segments);
}

class _StepColumn extends StatelessWidget {
  const _StepColumn({
    super.key,
    required this.name,
    required this.step,
    this.p2p = false,
    this.mono = false,
  });

  final String name;
  final LinkStep step;
  final bool p2p;

  /// The label is an address: set in code type and ink rather than the
  /// step's colour, which its node already carries.
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final look = _look(scheme, step.state, p2p: p2p);
    final detail = step.detail;
    return Semantics(
      label: [name, step.label, ?detail].join(', '),
      excludeSemantics: true,
      child: Column(
        children: [
          _Node(look: look, active: step.state == LinkStepState.active),
          const SizedBox(height: 6),
          Text(
            name,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.2,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 2),
          AnimatedSwitcher(
            duration: Motion.of(context, Motion.medium),
            child: Text(
              step.label,
              key: ValueKey(step.label),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: mono ? monoFontFamily : null,
                fontFamilyFallback: mono ? monoCjkFallback : null,
                fontSize: mono ? 12 : 12.5,
                height: 1.25,
                color: mono
                    ? scheme.onSurfaceVariant
                    : step.state == LinkStepState.waiting
                    ? onSurfaceMuted(scheme)
                    : step.state == LinkStepState.active
                    ? scheme.onSurface
                    : look.color,
              ),
            ),
          ),
          if (detail != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                detail,
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11.5, color: onSurfaceMuted(scheme)),
              ),
            ),
        ],
      ),
    );
  }
}

class _Node extends StatelessWidget {
  const _Node({required this.look, required this.active});

  final ({Color color, IconData? icon}) look;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final icon = look.icon;
    return SizedBox.square(
      dimension: 24,
      child: Stack(
        alignment: Alignment.center,
        children: [
          AnimatedContainer(
            duration: Motion.of(context, Motion.medium),
            curve: Motion.move,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: icon == null
                  ? Colors.transparent
                  : look.color.withValues(alpha: 0.14),
              border: Border.all(
                color: look.color.withValues(alpha: active ? 0.25 : 1),
                width: 1.5,
              ),
            ),
          ),
          AnimatedSwitcher(
            duration: Motion.of(context, Motion.fast),
            child: icon == null
                ? const SizedBox.shrink()
                : Icon(icon, key: ValueKey(icon), size: 14, color: look.color),
          ),
          if (active)
            Positioned.fill(
              child: RepaintBoundary(
                child: CircularProgressIndicator(
                  value: Motion.ambientAllowed(context) ? null : 0.3,
                  strokeWidth: 1.5,
                  strokeCap: StrokeCap.round,
                  color: look.color,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The steps as dots small enough for a status line; the step under way
/// pulses.
class LinkDots extends StatelessWidget {
  /// Creates the dots of [steps].
  const LinkDots(this.steps, {super.key});

  /// What each step is doing.
  final LinkSteps steps;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget dot(LinkStep step, {bool p2p = false}) {
      final color = _look(scheme, step.state, p2p: p2p).color;
      return step.state == LinkStepState.active
          ? PulsingDot(color: color, size: 6)
          : Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            );
    }

    Widget joint(LinkStep before) => Container(
      width: 6,
      height: 1.5,
      margin: const EdgeInsets.symmetric(horizontal: 2),
      color: _passed(before.state)
          ? scheme.onSurfaceVariant.withValues(alpha: 0.6)
          : scheme.onSurface.withValues(alpha: 0.15),
    );
    return ExcludeSemantics(
      child: Row(
        key: const Key('link-dots'),
        mainAxisSize: MainAxisSize.min,
        children: [
          if (steps.local case final local?) ...[
            dot(local),
            joint(local),
          ] else ...[
            dot(steps.relay),
            joint(steps.relay),
            dot(steps.p2p, p2p: true),
            joint(steps.p2p),
          ],
          dot(steps.session),
        ],
      ),
    );
  }
}

/// A tunnel's recent history, newest first.
class LinkTimeline extends StatelessWidget {
  /// Creates the timeline of [events], given oldest first.
  const LinkTimeline(this.events, {super.key});

  /// What happened, oldest first.
  final List<LinkEvent> events;

  static const _shown = 8;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    if (events.isEmpty) {
      return Text(l10n.linkNoActivity, style: helpTextStyle(theme));
    }
    Color tone(LinkEventKind kind) => switch (kind) {
      LinkEventKind.relayReady => successColor(scheme),
      LinkEventKind.relayFailed => scheme.error,
      LinkEventKind.networkChanged => cautionColor(scheme),
      LinkEventKind.directEstablished => infoColor(scheme),
      LinkEventKind.directFallback => scheme.onSurfaceVariant,
    };
    return Column(
      key: const Key('link-timeline'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final event in events.reversed.take(_shown))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: tone(event.kind),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    linkEventLabel(l10n, event),
                    style: TextStyle(fontSize: 13, color: scheme.onSurface),
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  linkAgo(l10n, event.ageMs),
                  style: TextStyle(
                    fontSize: 12,
                    color: onSurfaceMuted(scheme),
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// A session's live status line while it reconnects: where the reconnect
/// stands in words, then its three steps as dots. Polls only while shown.
class LinkStatusLine extends ConsumerWidget {
  /// Creates the line for [serviceKey], driven by [reconnect].
  const LinkStatusLine({
    super.key,
    required this.serviceKey,
    required this.reconnect,
    required this.style,
  });

  /// The session's service.
  final String serviceKey;

  /// The controller's reconnect.
  final ValueListenable<ReconnectState> reconnect;

  /// The status line's text style.
  final TextStyle style;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final sample = ref.watch(linkWatchProvider(serviceKey)).valueOrNull;
    return ValueListenableBuilder<ReconnectState>(
      valueListenable: reconnect,
      builder: (context, state, _) {
        final steps = sample == null
            ? waitingSteps(l10n)
            : linkSteps(l10n, sample, state, connected: false);
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                linkHeadline(l10n, steps, state),
                key: const Key('link-status-line'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: style,
              ),
            ),
            const SizedBox(width: 8),
            LinkDots(steps),
          ],
        );
      },
    );
  }
}

/// How a session travels, as one small mark for its status bar: this
/// device's own listener, direct, through the relay, or recovering. Tapping
/// it opens the connection sheet.
class LinkPathMark extends ConsumerWidget {
  /// Creates the mark for [serviceKey].
  const LinkPathMark({
    super.key,
    required this.serviceKey,
    required this.onTap,
  });

  /// The session's service.
  final String serviceKey;

  /// Open the connection sheet.
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final state = ref.watch(
      liveSubscriptionsProvider.select((subs) {
        final tunnel = tunnelFor(subs.valueOrNull ?? const [], serviceKey);
        return tunnel == null || !tunnel.alive
            ? null
            : (path: tunnel.path, recovering: tunnel.recovering);
      }),
    );
    final (icon, color, label) = switch (state) {
      null => (
        AppIcons.link_outlined,
        onSurfaceMuted(scheme),
        l10n.linkSheetTitle,
      ),
      (recovering: true, path: _) => (
        AppIcons.sync,
        cautionColor(scheme),
        l10n.stateReconnecting,
      ),
      // The usual state of a desktop's own host: ink, like the rest of a
      // resting status bar.
      (path: TunnelPath.local, recovering: false) => (
        AppIcons.computer,
        scheme.onSurfaceVariant,
        l10n.tunnelPathLocal,
      ),
      (path: TunnelPath.direct, recovering: false) => (
        AppIcons.direct,
        infoColor(scheme),
        l10n.tunnelPathDirect,
      ),
      (path: TunnelPath.mixed, recovering: false) => (
        AppIcons.direct,
        infoColor(scheme),
        l10n.tunnelShortMixed,
      ),
      (path: TunnelPath.idle, recovering: false) => (
        AppIcons.link_outlined,
        scheme.onSurfaceVariant,
        l10n.tunnelPathIdle,
      ),
      (path: _, recovering: false) => (
        AppIcons.route,
        scheme.onSurfaceVariant,
        l10n.tunnelPathRelay,
      ),
    };
    return Tooltip(
      message: '${l10n.linkSheetTitle} · $label',
      child: InkWell(
        key: const Key('session-link-mark'),
        mouseCursor: clickable,
        onTap: onTap,
        borderRadius: BorderRadius.circular(kControlRadius),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
          child: Icon(icon, size: 13, color: color),
        ),
      ),
    );
  }
}

/// Open the connection sheet of [serviceKey]: its three steps live, where a
/// reconnect stands, and its recent history. A popover on desktop, a sheet
/// on touch.
Future<void> showLinkSheet(
  BuildContext context, {
  required String serviceKey,
  required ValueListenable<ReconnectState> reconnect,
  required bool Function() connected,
  VoidCallback? onRetry,
}) => showAdaptivePanel<void>(
  context: context,
  anchored: true,
  maxWidth: 420,
  insetTop: false,
  builder: (_) => LinkSheet(
    serviceKey: serviceKey,
    reconnect: reconnect,
    connected: connected,
    onRetry: onRetry,
  ),
);

/// The body of [showLinkSheet].
class LinkSheet extends ConsumerWidget {
  /// Creates the sheet for [serviceKey].
  const LinkSheet({
    super.key,
    required this.serviceKey,
    required this.reconnect,
    required this.connected,
    this.onRetry,
  });

  /// The session's service.
  final String serviceKey;

  /// The controller's reconnect.
  final ValueListenable<ReconnectState> reconnect;

  /// Whether the session is up now.
  final bool Function() connected;

  /// Try again at once, while waiting to.
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final sample = ref.watch(linkWatchProvider(serviceKey)).valueOrNull;
    final watch = sample ?? const LinkWatch();
    final tunnel = watch.tunnel;
    final parsed = parseServiceKey(serviceKey);
    return ValueListenableBuilder<ReconnectState>(
      valueListenable: reconnect,
      builder: (context, state, _) {
        // Until the first sample lands nothing is known: no step shows as
        // failed only to turn green a moment later.
        final steps = sample == null
            ? waitingSteps(l10n)
            : linkSteps(l10n, watch, state, connected: connected());
        final error = state.lastError;
        return Padding(
          key: const Key('link-sheet'),
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.linkSheetTitle,
                          style: theme.textTheme.titleSmall,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          parsed.device.isEmpty
                              ? serviceKey
                              : '${deviceLabel(parsed.device)} · ${parsed.name}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: helpTextStyle(theme),
                        ),
                      ],
                    ),
                  ),
                  if (tunnel != null) ...[
                    const SizedBox(width: 12),
                    TunnelPathChip(tunnel),
                  ],
                ],
              ),
              if (state.active) ...[
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        linkHeadline(l10n, steps, state),
                        key: const Key('link-sheet-headline'),
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: signalColor(scheme),
                        ),
                      ),
                    ),
                    if (state.attempt > 0)
                      Text(
                        l10n.linkAttempt(state.attempt),
                        style: TextStyle(
                          fontSize: 12,
                          color: onSurfaceMuted(scheme),
                        ),
                      ),
                  ],
                ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      error,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: helpTextStyle(theme),
                    ),
                  ),
              ],
              const SizedBox(height: 18),
              LinkPipeline(steps),
              if (onRetry != null && state.active && state.retryAt != null)
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: FilledButton.tonalIcon(
                      key: const Key('link-retry-now'),
                      style: FilledButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        textStyle: theme.textTheme.labelLarge?.copyWith(
                          fontSize: 13,
                        ),
                      ),
                      onPressed: onRetry,
                      icon: const Icon(AppIcons.refresh, size: 16),
                      label: Text(l10n.linkRetryNow),
                    ),
                  ),
                ),
              // This app's own listener has no relay history, and its one
              // detail, the address, is on its step.
              if (steps.local == null) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 18, bottom: 6),
                  child: Text(
                    l10n.linkRecent,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.2,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                LinkTimeline(tunnel?.events ?? const []),
                if (tunnel != null)
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: TextButton(
                        key: const Key('link-show-details'),
                        onPressed: () => showTunnelDetails(context, tunnel.key),
                        child: Text(l10n.linkShowDetails),
                      ),
                    ),
                  ),
              ],
            ],
          ),
        );
      },
    );
  }
}
