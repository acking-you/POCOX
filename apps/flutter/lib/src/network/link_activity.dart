import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/network/connection_paths.dart';
import 'package:pocox/src/providers.dart';
import 'package:pocox/src/service_key.dart';

/// What one service's link is doing right now: its tunnel, and the step a
/// connect of it is at.
class LinkWatch {
  /// Creates a view of [tunnel] and [stage].
  const LinkWatch({this.tunnel, this.stage});

  /// The tunnel to the service, while one exists.
  final SubInfo? tunnel;

  /// The step a connect of the service is at, while one runs.
  final ConnectStage? stage;
}

/// How often a link on screen refreshes: often enough that a hole-punching
/// stage, which lasts a second or two, is seen as it happens.
const _linkPollInterval = Duration(milliseconds: 400);

/// The link of the service [serviceKey], refreshed only while something
/// watches it. Like [liveSubscriptionsProvider], the timer stops with the
/// last listener.
final linkWatchProvider = FutureProvider.autoDispose.family<LinkWatch, String>((
  ref,
  serviceKey,
) async {
  final api = ref.watch(bridgeApiProvider);
  Timer? next;
  var watched = true;
  var loaded = false;
  var interval = _linkPollInterval;
  void schedule() {
    next?.cancel();
    next = watched && loaded ? Timer(interval, ref.invalidateSelf) : null;
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
    final tunnel = tunnelFor(subs, serviceKey);
    interval = tunnel?.path == TunnelPath.local && tunnel!.alive
        ? const Duration(seconds: 3)
        : _linkPollInterval;
    return LinkWatch(tunnel: tunnel, stage: api.appConnectStage(serviceKey));
  } finally {
    loaded = true;
    schedule();
  }
});

/// The tunnel among [subs] that reaches [serviceKey], whatever family
/// tracks it; a live one first.
SubInfo? tunnelFor(Iterable<SubInfo> subs, String serviceKey) {
  SubInfo? found;
  for (final sub in subs) {
    if (sub.key != serviceKey &&
        subscriptionServiceKey(sub.key) != serviceKey) {
      continue;
    }
    if (found == null || (sub.alive && !found.alive)) found = sub;
  }
  return found;
}

/// A session's reconnect, as its controller drives it.
class ReconnectState {
  /// Creates a reconnect state.
  const ReconnectState({
    this.active = false,
    this.attempt = 0,
    this.startedAt,
    this.retryAt,
    this.lastError,
    this.restoring = false,
  });

  /// No reconnect.
  static const idle = ReconnectState();

  /// Reconnecting: an attempt runs, or the next one is scheduled.
  final bool active;

  /// The attempt running or last made, from 1.
  final int attempt;

  /// When the running attempt began.
  final DateTime? startedAt;

  /// When the next attempt starts, while waiting for it.
  final DateTime? retryAt;

  /// Why the last attempt failed.
  final String? lastError;

  /// The link is up again and the conversation is being read back.
  final bool restoring;
}

/// Where a step of connecting stands.
enum LinkStepState {
  /// Not reached yet.
  waiting,

  /// Under way.
  active,

  /// Done.
  done,

  /// Done another way: the relay carries what direct could not.
  fallback,

  /// Failed; it is tried again.
  failed,

  /// Not taken: direct is off.
  skipped,
}

/// One step of connecting, in words.
class LinkStep {
  /// Creates a step.
  const LinkStep(this.state, this.label, {this.detail});

  /// Where it stands.
  final LinkStepState state;

  /// What it is doing or did.
  final String label;

  /// More about it, such as why it failed.
  final String? detail;
}

/// The steps of reaching a service: its tunnel's relay link, a direct (P2P)
/// attempt over it, and the session opened through it. A service this app
/// hosts itself has [local], its own listener, in place of relay and P2P.
typedef LinkSteps = ({
  LinkStep? local,
  LinkStep relay,
  LinkStep p2p,
  LinkStep session,
});

/// The steps of [watch] for a session whose controller reports [reconnect];
/// [connected] is whether its session is up.
LinkSteps linkSteps(
  AppLocalizations l10n,
  LinkWatch watch,
  ReconnectState reconnect, {
  required bool connected,
  DateTime? now,
}) {
  final tunnel = watch.tunnel;
  final stage = watch.stage;
  final at = now ?? DateTime.now();
  // Only what happened during the running attempt says how it is going.
  final since = reconnect.startedAt == null
      ? null
      : at.difference(reconnect.startedAt!).inMilliseconds;
  final recent = tunnel == null
      ? const <LinkEvent>[]
      : [
          for (final event in tunnel.events)
            if (since == null || event.ageMs <= since) event,
        ];
  final waitingRetry = reconnect.active && reconnect.retryAt != null;
  return (
    local: _localStep(l10n, tunnel),
    relay: _relayStep(l10n, tunnel, stage, waitingRetry, reconnect),
    p2p: _p2pStep(l10n, tunnel, recent),
    session: _sessionStep(l10n, stage, reconnect, connected, waitingRetry),
  );
}

/// This app's own listener: current, or retired by a stop or restart. Null
/// for a remote service.
LinkStep? _localStep(AppLocalizations l10n, SubInfo? tunnel) {
  if (tunnel == null || tunnel.path != TunnelPath.local) return null;
  return tunnel.alive
      ? LinkStep(LinkStepState.done, tunnel.localAddr)
      : LinkStep(
          LinkStepState.failed,
          l10n.subscribedDead,
          detail: tunnel.localAddr,
        );
}

LinkStep _relayStep(
  AppLocalizations l10n,
  SubInfo? tunnel,
  ConnectStage? stage,
  bool waitingRetry,
  ReconnectState reconnect,
) {
  if (tunnel?.path == TunnelPath.local) {
    return LinkStep(LinkStepState.skipped, l10n.tunnelPathLocal);
  }
  if (tunnel == null || !tunnel.alive) {
    if (stage == ConnectStage.tunnel) {
      return LinkStep(LinkStepState.active, l10n.linkRelayReaching);
    }
    return waitingRetry
        ? LinkStep(LinkStepState.failed, l10n.linkStepRelay)
        : LinkStep(LinkStepState.waiting, l10n.linkStepRelay);
  }
  if (tunnel.relayPhase == RelayPhase.backoff || tunnel.retrying) {
    final retry = tunnel.nextRetryMs;
    return LinkStep(
      LinkStepState.failed,
      switch (tunnel.lastFailure) {
        final failure? => tunnelFailureLabel(l10n, failure),
        null => l10n.linkRelayReaching,
      },
      detail: retry == null ? null : l10n.linkRetryIn(_seconds(retry)),
    );
  }
  if (!tunnel.ready || tunnel.consecutiveFailures > 0) {
    return LinkStep(
      LinkStepState.active,
      relayPhaseLabel(l10n, tunnel.relayPhase),
    );
  }
  return LinkStep(
    LinkStepState.done,
    l10n.linkRelayReady,
    detail: switch (tunnel.setupLatencyMs) {
      final ms? => l10n.tunnelMilliseconds(ms),
      null => null,
    },
  );
}

LinkStep _p2pStep(
  AppLocalizations l10n,
  SubInfo? tunnel,
  List<LinkEvent> recent,
) {
  if (tunnel == null) return LinkStep(LinkStepState.waiting, l10n.linkStepP2p);
  if (tunnel.path == TunnelPath.local) {
    return LinkStep(LinkStepState.skipped, l10n.tunnelPathLocal);
  }
  if (tunnel.path == TunnelPath.relayOnly) {
    return LinkStep(LinkStepState.skipped, l10n.linkP2pOff);
  }
  if (tunnel.attempt case final attempt?) {
    return LinkStep(
      LinkStepState.active,
      directStageLabel(l10n, attempt.stage),
    );
  }
  final last = recent.lastWhere(
    (event) =>
        event.kind == LinkEventKind.directEstablished ||
        event.kind == LinkEventKind.directFallback,
    orElse: () =>
        const LinkEvent(seq: 0, ageMs: 0, kind: LinkEventKind.relayReady),
  );
  return switch (last.kind) {
    LinkEventKind.directEstablished => LinkStep(
      LinkStepState.done,
      l10n.linkDirectUp,
      detail: switch (last.ms) {
        final ms? => l10n.tunnelMilliseconds(ms),
        null => null,
      },
    ),
    LinkEventKind.directFallback => LinkStep(
      LinkStepState.fallback,
      l10n.linkViaRelay,
      detail: switch (last.stage) {
        final stage? => l10n.linkFellBackAt(directStageWords(l10n, stage)),
        null => null,
      },
    ),
    _ when tunnel.activeDirect > 0 => LinkStep(
      LinkStepState.done,
      l10n.linkDirectUp,
    ),
    _ when tunnel.activeRelay > 0 => LinkStep(
      LinkStepState.fallback,
      l10n.linkViaRelay,
    ),
    _ => LinkStep(LinkStepState.waiting, l10n.linkStepP2p),
  };
}

LinkStep _sessionStep(
  AppLocalizations l10n,
  ConnectStage? stage,
  ReconnectState reconnect,
  bool connected,
  bool waitingRetry,
) {
  if (reconnect.restoring) {
    return LinkStep(LinkStepState.active, l10n.linkSessionRestoring);
  }
  switch (stage) {
    case ConnectStage.session:
      return LinkStep(LinkStepState.active, l10n.linkSessionOpening);
    case ConnectStage.handshake:
      return LinkStep(LinkStepState.active, l10n.linkSessionHandshake);
    case ConnectStage.tunnel || null:
      break;
  }
  if (connected && !reconnect.active) {
    return LinkStep(LinkStepState.done, l10n.linkSessionReady);
  }
  if (waitingRetry) {
    return LinkStep(LinkStepState.failed, l10n.linkStepSession);
  }
  return LinkStep(LinkStepState.waiting, l10n.linkStepSession);
}

/// The steps before anything is known: every one waiting, so the first real
/// sample changes them without a false failure in between.
LinkSteps waitingSteps(AppLocalizations l10n) => (
  local: null,
  relay: LinkStep(LinkStepState.waiting, l10n.linkStepRelay),
  p2p: LinkStep(LinkStepState.waiting, l10n.linkStepP2p),
  session: LinkStep(LinkStepState.waiting, l10n.linkStepSession),
);

/// The one line that says where a reconnect stands: the countdown while it
/// waits, else the step under way, else the step that failed.
String linkHeadline(
  AppLocalizations l10n,
  LinkSteps steps,
  ReconnectState reconnect, {
  DateTime? now,
}) {
  if (reconnect.retryAt case final retryAt? when reconnect.active) {
    final left = retryAt.difference(now ?? DateTime.now()).inMilliseconds;
    return l10n.linkRetryIn(_seconds(left));
  }
  // Session opening waits on the transport: show the actual network work
  // while it is in flight instead of hiding it behind "Opening the session".
  final order = [?steps.local, steps.relay, steps.p2p, steps.session];
  for (final step in order) {
    if (step.state == LinkStepState.active) return step.label;
  }
  for (final step in order) {
    if (step.state == LinkStepState.failed) return step.label;
  }
  return l10n.stateReconnecting;
}

/// Whole seconds left of [ms], at least one while any time is left.
int _seconds(int ms) => ms <= 0 ? 0 : (ms + 999) ~/ 1000;

/// What a relay link in [phase] is doing.
String relayPhaseLabel(AppLocalizations l10n, RelayPhase phase) =>
    switch (phase) {
      RelayPhase.starting || RelayPhase.stopped => l10n.linkRelayStarting,
      RelayPhase.queued => l10n.linkRelayQueued,
      RelayPhase.resolving => l10n.linkRelayResolving,
      RelayPhase.connecting || RelayPhase.backoff => l10n.linkRelayConnecting,
      RelayPhase.handshake => l10n.linkRelayHandshake,
      RelayPhase.ready => l10n.linkRelayReady,
    };

/// What a direct attempt at [stage] is doing, as a status.
String directStageLabel(AppLocalizations l10n, DirectStage stage) =>
    switch (stage) {
      DirectStage.negotiating => l10n.linkDirectNegotiating,
      DirectStage.discovering => l10n.linkDirectDiscovering,
      DirectStage.punching => l10n.linkDirectPunching,
      DirectStage.committing => l10n.linkDirectCommitting,
    };

/// [stage] as words inside a sentence ("while punching through NAT").
String directStageWords(AppLocalizations l10n, DirectStage stage) =>
    switch (stage) {
      DirectStage.negotiating => l10n.linkStageNegotiating,
      DirectStage.discovering => l10n.linkStageDiscovering,
      DirectStage.punching => l10n.linkStagePunching,
      DirectStage.committing => l10n.linkStageCommitting,
    };

/// What [event] records, in words.
String linkEventLabel(AppLocalizations l10n, LinkEvent event) {
  final text = switch (event.kind) {
    LinkEventKind.relayReady => l10n.linkEventRelayReady(event.ms ?? 0),
    LinkEventKind.relayFailed => l10n.linkEventRelayFailed(
      switch (event.failure) {
        final failure? => tunnelFailureLabel(l10n, failure),
        null => l10n.tunnelFailureTransport,
      },
    ),
    LinkEventKind.networkChanged => l10n.tunnelFailureNetworkChanged,
    LinkEventKind.directEstablished => l10n.linkEventDirect(event.ms ?? 0),
    LinkEventKind.directFallback => l10n.linkEventFallback(
      directStageWords(l10n, event.stage ?? DirectStage.negotiating),
    ),
  };
  return event.repeats > 1
      ? '$text ${l10n.linkEventRepeats(event.repeats)}'
      : text;
}

/// How long ago [ageMs] was, briefly.
String linkAgo(AppLocalizations l10n, int ageMs) {
  final seconds = ageMs ~/ 1000;
  if (seconds < 3) return l10n.timeJustNow;
  if (seconds < 60) return l10n.linkAgoSeconds(seconds);
  if (seconds < 3600) return l10n.timeMinutesAgo(seconds ~/ 60);
  return l10n.timeHoursAgo(seconds ~/ 3600);
}
