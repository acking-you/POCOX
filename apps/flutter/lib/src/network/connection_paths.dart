import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/app_icons.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/fonts.dart';
import 'package:pocox/src/network/link_activity.dart';
import 'package:pocox/src/motion.dart';
import 'package:pocox/src/providers.dart';
import 'package:pocox/src/service_key.dart';
import 'package:pocox/src/theme.dart';
import 'package:pocox/src/widgets/adaptive_sheet.dart';
import 'package:pocox/src/widgets/field_help.dart';
import 'package:pocox/src/widgets/glass.dart';
import 'package:pocox/src/widgets/group_card.dart';
import 'package:pocox/src/widgets/icon_badge.dart';
import 'package:pocox/src/widgets/link_progress.dart';
import 'package:pocox/src/widgets/status_dots.dart';

/// This installation's saved path preferences.
final relayPreferencesProvider =
    AsyncNotifierProvider.autoDispose<RelayPreferencesStore, RelayPreferences>(
      RelayPreferencesStore.new,
    );

/// Reads and saves [RelayPreferences], showing a choice before it is written.
class RelayPreferencesStore extends AutoDisposeAsyncNotifier<RelayPreferences> {
  @override
  Future<RelayPreferences> build() =>
      ref.watch(bridgeApiProvider).relayPreferences();

  /// Show [next] at once and persist it. A failed write restores the previous
  /// value and rethrows, so the control springs back to what is saved.
  Future<void> save(RelayPreferences next) async {
    final previous = state.valueOrNull;
    if (previous == null || previous == next) return;
    // The write finishes even if the page closes while it runs.
    final link = ref.keepAlive();
    state = AsyncData(next);
    try {
      await ref.read(bridgeApiProvider).relaySetPreferences(next);
    } catch (_) {
      state = AsyncData(previous);
      rethrow;
    } finally {
      link.close();
    }
  }
}

/// How often live path counters refresh while something shows them.
const _pollInterval = Duration(seconds: 3);

/// How often they refresh while a tunnel is coming up, recovering or trying
/// a direct path: often enough to show a stage that lasts a second or two.
const _busyPollInterval = Duration(milliseconds: 500);

/// Active subscriptions with their live path counters, refreshed only while
/// something watches them. The timer stops with the last listener, not at
/// disposal: a container a test or caller owns can outlive its widgets.
final liveSubscriptionsProvider = FutureProvider.autoDispose<List<SubInfo>>((
  ref,
) async {
  final api = ref.watch(bridgeApiProvider);
  Timer? next;
  var watched = true;
  var loaded = false;
  var busy = false;
  void schedule() {
    next?.cancel();
    next = watched && loaded
        ? Timer(busy ? _busyPollInterval : _pollInterval, ref.invalidateSelf)
        : null;
  }

  void stop() {
    watched = false;
    schedule();
  }

  ref
    ..onCancel(stop)
    ..onDispose(stop)
    ..onResume(() {
      watched = true;
      schedule();
    });
  try {
    final subs = await api.subscriptions();
    busy = subs.any(
      (sub) => sub.alive && (sub.recovering || sub.attempt != null),
    );
    return subs;
  } finally {
    loaded = true;
    schedule();
  }
});

/// What [sub]'s status chip says: dropped, coming up or recovering, trying a
/// direct path, or the path its data takes now.
String tunnelPathLabel(AppLocalizations l10n, SubInfo sub) {
  if (!sub.alive) return l10n.subscribedDead;
  if (sub.recovering) {
    return sub.ready
        ? l10n.stateReconnecting
        : relayPhaseLabel(l10n, sub.relayPhase);
  }
  if (sub.attempt case final attempt?) {
    return directStageLabel(l10n, attempt.stage);
  }
  return switch (sub.path) {
    TunnelPath.relayOnly => l10n.connectionPathRelayOnly,
    TunnelPath.idle => l10n.tunnelPathIdle,
    TunnelPath.direct => l10n.tunnelPathDirect,
    TunnelPath.relay => l10n.tunnelPathRelay,
    TunnelPath.mixed => l10n.tunnelPathMixed(sub.activeDirect, sub.activeRelay),
  };
}

/// The line under a subscription's name: where it listens, and how often
/// direct setup fell back to the relay.
String tunnelSubtitle(AppLocalizations l10n, SubInfo sub) => sub.fallbacks > 0
    ? '${sub.localAddr} · ${l10n.tunnelFallbacks(sub.fallbacks)}'
    : sub.localAddr;

/// The live path of the tunnel subscribed as [serviceKey] itself (an app
/// session's or an API's), if one is up and has been observed carrying data.
TunnelPath? tunnelPathOf(List<SubInfo>? subs, String serviceKey) => switch (subs
    ?.where((sub) => sub.alive && sub.key == serviceKey)
    .firstOrNull
    ?.path) {
  TunnelPath.idle || null => null,
  final path => path,
};

/// The few words that say how a connected service travels, after its state.
String tunnelPathShort(AppLocalizations l10n, TunnelPath path) =>
    switch (path) {
      TunnelPath.direct => 'P2P',
      TunnelPath.mixed => l10n.tunnelShortMixed,
      TunnelPath.relay || TunnelPath.relayOnly => l10n.tunnelShortRelay,
      TunnelPath.idle => l10n.tunnelPathIdle,
    };

/// A connected service's status chip that also says how its data travels
/// once its tunnel carries any: "Connected · P2P". Watches only that path,
/// so the polling rebuilds this chip alone, and only when the path changes.
class ConnectedChip extends ConsumerWidget {
  /// Creates the chip for [serviceKey] in [label] and [color].
  const ConnectedChip({
    super.key,
    required this.serviceKey,
    required this.label,
    required this.color,
  });

  /// The service subscribed under its own key.
  final String serviceKey;

  /// Its state, such as Connected.
  final String label;

  /// The state's colour.
  final Color color;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final path = ref.watch(
      liveSubscriptionsProvider.select(
        (subs) => tunnelPathOf(subs.valueOrNull, serviceKey),
      ),
    );
    return StatusChip(
      color: color,
      label: path == null
          ? label
          : '$label · ${tunnelPathShort(AppLocalizations.of(context), path)}',
      filled: true,
    );
  }
}

/// A subscription's one status mark: healthy with its live path, or dropped.
class TunnelPathChip extends StatelessWidget {
  /// Creates the chip for [sub].
  const TunnelPathChip(this.sub, {super.key});

  /// The subscription shown.
  final SubInfo sub;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return StatusChip(
      color: !sub.alive
          ? scheme.error
          : sub.recovering
          ? cautionColor(scheme)
          : sub.attempt != null
          ? signalColor(scheme)
          : successColor(scheme),
      label: tunnelPathLabel(AppLocalizations.of(context), sub),
      filled: true,
    );
  }
}

/// Live path details of the subscription tracked as [subscriptionKey], from
/// the pressed row: a popover on desktop, a sheet on touch.
Future<void> showTunnelDetails(BuildContext context, String subscriptionKey) =>
    showAdaptivePanel<void>(
      context: context,
      anchored: true,
      maxWidth: 380,
      insetTop: false,
      builder: (_) => _TunnelDetails(subscriptionKey),
    );

/// A subscription's name under its device's heading: the service's name and
/// kind, such as `default · app`.
String subscriptionTitle(String subscriptionKey) {
  final service = subscriptionServiceKey(subscriptionKey);
  final parsed = parseServiceKey(service);
  return parsed.device.isEmpty ? service : '${parsed.name} · ${parsed.kind}';
}

/// [subs] by the device each reaches, devices in label order and each
/// device's subscriptions in key order.
List<({String device, List<SubInfo> subs})> subscriptionsByDevice(
  Iterable<SubInfo> subs,
) {
  final byDevice = <String, List<SubInfo>>{};
  for (final sub in subs) {
    byDevice
        .putIfAbsent(
          serviceKeyDevice(subscriptionServiceKey(sub.key)),
          () => [],
        )
        .add(sub);
  }
  final devices = byDevice.keys.toList()
    ..sort((a, b) => deviceLabel(a).compareTo(deviceLabel(b)));
  return [
    for (final device in devices)
      (
        device: device,
        subs: byDevice[device]!..sort((a, b) => a.key.compareTo(b.key)),
      ),
  ];
}

/// What the SDK's fallback [code] means, or the code itself when it is new.
String fallbackReasonLabel(AppLocalizations l10n, String code) =>
    switch (code) {
      'direct_negotiation_unavailable' => l10n.tunnelFallbackNegotiation,
      'direct_timeout_or_unreachable' => l10n.tunnelFallbackUnreachable,
      _ => code,
    };

/// Why a tunnel's attempt to reach the relay failed, in words.
String tunnelFailureLabel(AppLocalizations l10n, TunnelFailure failure) =>
    switch (failure) {
      TunnelFailure.dns => l10n.tunnelFailureDns,
      TunnelFailure.transport => l10n.tunnelFailureTransport,
      TunnelFailure.timeout => l10n.tunnelFailureTimeout,
      TunnelFailure.serviceUnavailable => l10n.tunnelFailureServiceUnavailable,
      TunnelFailure.rejected => l10n.tunnelFailureRejected,
      TunnelFailure.networkChanged => l10n.tunnelFailureNetworkChanged,
    };

class _TunnelDetails extends ConsumerWidget {
  const _TunnelDetails(this.subscriptionKey);

  final String subscriptionKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    // Refreshed quickly while open, so a stage is seen as it happens.
    final live = ref.watch(linkWatchProvider(subscriptionKey)).valueOrNull;
    final subs = ref.watch(liveSubscriptionsProvider).valueOrNull;
    final sub =
        live?.tunnel ??
        subs?.where((s) => s.key == subscriptionKey).firstOrNull ??
        // Gone since the row was pressed: it was unsubscribed or dropped.
        SubInfo(key: subscriptionKey, localAddr: '', alive: false);
    final service = subscriptionServiceKey(subscriptionKey);
    return Padding(
      key: const Key('tunnel-details'),
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
                      service,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      deviceLabel(serviceKeyDevice(service)),
                      style: helpTextStyle(theme),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              TunnelPathChip(sub),
            ],
          ),
          if (sub.alive) ...[
            _Heading(l10n.tunnelSectionP2p),
            if (sub.path == TunnelPath.relayOnly)
              Text(l10n.tunnelRelayOnlyNote, style: helpTextStyle(theme))
            else ...[
              if (sub.attempt case final attempt?)
                _Fact(
                  l10n.tunnelRelayState,
                  directStageLabel(l10n, attempt.stage),
                ),
              _AttemptBar(sub),
              const SizedBox(height: 6),
              Text(
                sub.directAttempts == 0
                    ? l10n.tunnelP2pNoAttempts
                    : l10n.tunnelP2pAttempts(sub.directSessions, sub.fallbacks),
                key: const Key('tunnel-attempts'),
                style: TextStyle(
                  fontSize: 13,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 4),
              _Fact(
                l10n.tunnelOpenNow,
                l10n.tunnelPathMixed(sub.activeDirect, sub.activeRelay),
              ),
              if (sub.lastFallback case final reason?)
                _Fact(
                  l10n.tunnelLastFallback,
                  fallbackReasonLabel(l10n, reason),
                  detail: reason,
                ),
            ],
            _Heading(l10n.tunnelSectionRelay),
            _Fact(
              l10n.tunnelRelayState,
              !sub.ready
                  ? relayPhaseLabel(l10n, sub.relayPhase)
                  : sub.retrying
                  ? l10n.tunnelRelayRetrying(sub.consecutiveFailures)
                  : l10n.tunnelRelayConnected,
              detail: switch (sub.nextRetryMs) {
                final ms? when sub.retrying => l10n.linkRetryIn(
                  (ms + 999) ~/ 1000,
                ),
                _ => null,
              },
            ),
            if (sub.lastFailure case final failure?
                when sub.consecutiveFailures > 0)
              _Fact(l10n.tunnelLastFailure, tunnelFailureLabel(l10n, failure)),
            if (sub.setupLatencyMs case final ms?)
              _Fact(l10n.tunnelSetupLatency, l10n.tunnelMilliseconds(ms)),
            _Fact(l10n.tunnelLocalAddress, sub.localAddr, mono: true),
            _Heading(l10n.linkRecent),
            LinkTimeline(sub.events),
          ],
        ],
      ),
    );
  }
}

/// A section's quiet heading inside the details panel.
class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 16, bottom: 6),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.2,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );
}

/// How this tunnel's direct setups went, as one bar: the part that went
/// direct in the galaxy's link colour, the part that fell back muted.
class _AttemptBar extends StatelessWidget {
  const _AttemptBar(this.sub);

  final SubInfo sub;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final total = sub.directAttempts;
    return Semantics(
      label: AppLocalizations.of(
        context,
      ).tunnelP2pAttempts(sub.directSessions, sub.fallbacks),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: SizedBox(
          height: 6,
          child: total == 0
              ? ColoredBox(color: scheme.onSurface.withValues(alpha: 0.08))
              : Row(
                  children: [
                    if (sub.directSessions > 0)
                      Expanded(
                        flex: sub.directSessions,
                        child: ColoredBox(color: infoColor(scheme)),
                      ),
                    if (sub.fallbacks > 0)
                      Expanded(
                        flex: sub.fallbacks,
                        child: ColoredBox(color: onSurfaceMuted(scheme)),
                      ),
                  ],
                ),
        ),
      ),
    );
  }
}

/// One labelled value of the details panel; long values wrap beside the
/// label. A [detail] (the raw SDK code behind words) goes small under it.
class _Fact extends StatelessWidget {
  const _Fact(this.label, this.value, {this.mono = false, this.detail});

  final String label;
  final String value;
  final bool mono;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final detail = this.detail;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                SelectableText(
                  value,
                  textAlign: TextAlign.end,
                  style: TextStyle(
                    fontSize: mono ? 12.5 : 13,
                    fontFamily: mono ? monoFontFamily : null,
                    fontFeatures: const [FontFeature.tabularFigures()],
                    color: scheme.onSurface,
                  ),
                ),
                if (detail != null && detail != value)
                  SelectableText(
                    detail,
                    textAlign: TextAlign.end,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontFamily: monoFontFamily,
                      color: onSurfaceMuted(scheme),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Which preference a save or its failure belongs to.
enum _Preference { outgoing, incoming }

/// Settings › Connection path: how this installation reaches other devices,
/// and (on desktop) whether they may reach it directly. Choices apply
/// immediately, to connections opened from then on.
class ConnectionPathSettings extends ConsumerStatefulWidget {
  /// Creates the group.
  const ConnectionPathSettings({super.key});

  @override
  ConsumerState<ConnectionPathSettings> createState() =>
      _ConnectionPathSettingsState();
}

class _ConnectionPathSettingsState
    extends ConsumerState<ConnectionPathSettings> {
  /// What was saved when this page opened: a choice that differs from it
  /// says when it takes effect.
  RelayPreferences? _opened;
  bool _saving = false;
  _Preference? _failed;

  Future<void> _save(RelayPreferences next, _Preference preference) async {
    setState(() {
      _saving = true;
      _failed = null;
    });
    try {
      await ref.read(relayPreferencesProvider.notifier).save(next);
    } catch (_) {
      if (mounted) setState(() => _failed = preference);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final saved = ref.watch(relayPreferencesProvider);
    final prefs = saved.valueOrNull;
    _opened ??= prefs;
    final opened = _opened;
    final ready = prefs != null && !_saving;
    String? state(_Preference preference, {required bool changed}) =>
        _failed == preference
        ? l10n.connectionPathSaveFailed
        : changed
        ? switch (preference) {
            _Preference.outgoing => l10n.connectionPathOutgoingPending,
            _Preference.incoming => l10n.connectionPathIncomingPending,
          }
        : null;
    return GroupCard(
      key: const Key('connection-path-settings'),
      title: l10n.connectionPathTitle,
      info: l10n.connectionPathInfo,
      children: [
        if (prefs == null && saved.hasError)
          _ReadFailed(onRetry: () => ref.invalidate(relayPreferencesProvider))
        else ...[
          _PreferenceRow(
            icon: AppIcons.route,
            title: l10n.connectionPathOutgoing,
            state: state(
              _Preference.outgoing,
              changed: opened != null && prefs?.path != opened.path,
            ),
            failed: _failed == _Preference.outgoing,
            stackWhenNarrow: true,
            control: (expand) => IgnorePointer(
              ignoring: !ready,
              child: GlassSegmented<ConnectionPath?>(
                key: const Key('connection-path-outgoing'),
                expand: expand,
                // Nothing is selected until the saved choice is known.
                selected: prefs?.path,
                onChanged: (path) {
                  if (prefs != null && path != null) {
                    _save(prefs.copyWith(path: path), _Preference.outgoing);
                  }
                },
                segments: [
                  GlassSegment(
                    key: const Key('connection-path-relay-only'),
                    value: ConnectionPath.relayOnly,
                    icon: AppIcons.server,
                    label: l10n.connectionPathRelayOnly,
                  ),
                  GlassSegment(
                    key: const Key('connection-path-auto'),
                    value: ConnectionPath.auto,
                    icon: AppIcons.direct,
                    label: l10n.connectionPathAuto,
                  ),
                ],
              ),
            ),
          ),
          // Only a computer publishes services for others to reach.
          if (isDesktop)
            _PreferenceRow(
              icon: AppIcons.laptop,
              title: l10n.connectionPathIncoming,
              info: l10n.connectionPathIncomingInfo,
              state: state(
                _Preference.incoming,
                changed:
                    opened != null && prefs?.allowDirect != opened.allowDirect,
              ),
              failed: _failed == _Preference.incoming,
              // The themed switch, like the other settings toggles.
              control: (_) => Switch(
                key: const Key('connection-path-incoming'),
                value: prefs?.allowDirect ?? false,
                onChanged: ready
                    ? (allow) => _save(
                        prefs.copyWith(allowDirect: allow),
                        _Preference.incoming,
                      )
                    : null,
              ),
            ),
        ],
      ],
    );
  }
}

/// A preference: its mark, name and (when there is one) state line, with its
/// control at the end, or under it on a narrow row when [stackWhenNarrow].
class _PreferenceRow extends StatelessWidget {
  const _PreferenceRow({
    required this.icon,
    required this.title,
    required this.control,
    this.info,
    this.state,
    this.failed = false,
    this.stackWhenNarrow = false,
  });

  final IconData icon;
  final String title;
  final String? info;

  /// Pending or failed, never instructions.
  final String? state;
  final bool failed;
  final bool stackWhenNarrow;

  /// The control; `true` asks it to fill the row's width.
  final Widget Function(bool expand) control;

  /// The narrowest row that holds a segmented control beside its title.
  static const double _sideBySide = 480;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = this.state;
    final lead = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        IconBadge(icon: icon),
        const SizedBox(width: 11),
        Expanded(
          child: Padding(
            // Centres a one-line title on the badge.
            padding: const EdgeInsets.only(top: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                InfoTitle(
                  title: Text(
                    title,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  info: info,
                ),
                Motion.resize(
                  context,
                  duration: Motion.fast,
                  curve: Motion.emphasized,
                  alignment: AlignmentDirectional.topStart,
                  child: state == null
                      ? const SizedBox(width: double.infinity)
                      : Padding(
                          padding: const EdgeInsets.only(top: 3),
                          child: Text(
                            state,
                            key: const Key('connection-path-state'),
                            style: helpTextStyle(theme).copyWith(
                              color: failed ? theme.colorScheme.error : null,
                            ),
                          ),
                        ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(13, 10, 13, 10),
      child: LayoutBuilder(
        builder: (context, box) {
          if (stackWhenNarrow && box.maxWidth < _sideBySide) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [lead, const SizedBox(height: 12), control(true)],
            );
          }
          return Row(
            children: [
              Expanded(child: lead),
              const SizedBox(width: 16),
              control(false),
            ],
          );
        },
      ),
    );
  }
}

/// The saved preferences could not be read: say so, and offer a retry.
class _ReadFailed extends StatelessWidget {
  const _ReadFailed({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(13, 8, 8, 8),
      child: Row(
        children: [
          IconBadge(icon: AppIcons.route),
          const SizedBox(width: 11),
          Expanded(
            child: Text(
              l10n.connectionPathReadFailed,
              style: TextStyle(color: scheme.error),
            ),
          ),
          TextButton(
            key: const Key('connection-path-retry'),
            onPressed: onRetry,
            child: Text(l10n.retry),
          ),
        ],
      ),
    );
  }
}
