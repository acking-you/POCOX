import 'package:flutter_test/flutter_test.dart';
import 'package:pocox/l10n/gen/app_localizations_en.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/network/link_activity.dart';

void main() {
  final l10n = AppLocalizationsEn();
  const key = 'pcx:studio:app:default';
  final now = DateTime(2026, 10, 24, 12);

  SubInfo tunnel({
    bool ready = true,
    RelayPhase phase = RelayPhase.ready,
    TunnelPath path = TunnelPath.idle,
    bool retrying = false,
    int failures = 0,
    TunnelFailure? failure,
    int? nextRetryMs,
    DirectAttempt? attempt,
    List<LinkEvent> events = const [],
  }) => SubInfo(
    key: key,
    localAddr: '127.0.0.1:1',
    alive: true,
    path: path,
    ready: ready,
    relayPhase: phase,
    retrying: retrying,
    consecutiveFailures: failures,
    lastFailure: failure,
    nextRetryMs: nextRetryMs,
    attempt: attempt,
    events: events,
    setupLatencyMs: 42,
  );

  LinkSteps steps(
    LinkWatch watch, {
    ReconnectState? reconnect,
    bool connected = false,
  }) => linkSteps(
    l10n,
    watch,
    reconnect ??
        ReconnectState(
          active: true,
          attempt: 1,
          startedAt: now.subtract(const Duration(seconds: 2)),
        ),
    connected: connected,
    now: now,
  );

  test('reaching the relay shows each phase, and a failure its retry', () {
    var s = steps(const LinkWatch(stage: ConnectStage.tunnel));
    expect(
      (s.relay.state, s.relay.label),
      (LinkStepState.active, 'Reaching the relay'),
    );
    s = steps(
      LinkWatch(
        tunnel: tunnel(ready: false, phase: RelayPhase.connecting),
        stage: ConnectStage.tunnel,
      ),
    );
    expect(s.relay.label, 'Connecting to the relay');
    s = steps(
      LinkWatch(
        tunnel: tunnel(
          ready: false,
          phase: RelayPhase.backoff,
          retrying: true,
          failures: 2,
          failure: TunnelFailure.timeout,
          nextRetryMs: 3200,
        ),
      ),
    );
    expect(
      (s.relay.state, s.relay.label, s.relay.detail),
      (LinkStepState.failed, 'No answer in time', 'Retrying in 4s'),
    );
  });

  test('hole punching shows its stage while the session opens', () {
    final s = steps(
      LinkWatch(
        tunnel: tunnel(
          attempt: const DirectAttempt(
            stage: DirectStage.punching,
            elapsedMs: 800,
          ),
        ),
        stage: ConnectStage.session,
      ),
    );
    expect(s.relay.state, LinkStepState.done);
    expect(
      (s.p2p.state, s.p2p.label),
      (LinkStepState.active, 'Punching through NAT'),
    );
    expect(s.session.label, 'Opening the session');
    expect(
      linkHeadline(l10n, s, const ReconnectState(active: true)),
      'Punching through NAT',
      reason: 'the session is waiting on the direct attempt',
    );
  });

  test('a fallback during this attempt says where it gave up; an older one '
      'does not count', () {
    LinkEvent fallback(int ageMs) => LinkEvent(
      seq: ageMs,
      ageMs: ageMs,
      kind: LinkEventKind.directFallback,
      stage: DirectStage.punching,
    );
    var s = steps(LinkWatch(tunnel: tunnel(events: [fallback(500)])));
    expect(
      (s.p2p.state, s.p2p.label, s.p2p.detail),
      (
        LinkStepState.fallback,
        'Via relay',
        'Fell back to the relay while punching through NAT',
      ),
    );
    s = steps(LinkWatch(tunnel: tunnel(events: [fallback(60000)])));
    expect(s.p2p.state, LinkStepState.waiting);
    s = steps(
      LinkWatch(
        tunnel: tunnel(
          events: const [
            LinkEvent(
              seq: 1,
              ageMs: 100,
              kind: LinkEventKind.directEstablished,
              ms: 340,
            ),
          ],
        ),
      ),
    );
    expect((s.p2p.state, s.p2p.detail), (LinkStepState.done, '340 ms'));
    s = steps(LinkWatch(tunnel: tunnel(path: TunnelPath.relayOnly)));
    expect(s.p2p.state, LinkStepState.skipped);
  });

  test('waiting for the next attempt counts down; a connected session is '
      'done', () {
    final waiting = ReconnectState(
      active: true,
      attempt: 5,
      retryAt: now.add(const Duration(milliseconds: 7100)),
      lastError: 'relay down',
    );
    final s = steps(const LinkWatch(), reconnect: waiting);
    expect(s.session.state, LinkStepState.failed);
    expect(linkHeadline(l10n, s, waiting, now: now), 'Retrying in 8s');
    final up = steps(
      LinkWatch(tunnel: tunnel()),
      reconnect: ReconnectState.idle,
      connected: true,
    );
    expect(up.session.state, LinkStepState.done);
  });

  test('events read as sentences, repeats folded', () {
    expect(
      linkEventLabel(
        l10n,
        const LinkEvent(
          seq: 3,
          ageMs: 0,
          kind: LinkEventKind.relayFailed,
          failure: TunnelFailure.transport,
          repeats: 3,
        ),
      ),
      'Relay: Connection broke ×3',
    );
    expect(linkAgo(l10n, 1500), 'just now');
    expect(linkAgo(l10n, 42000), '42s ago');
  });

  test('a service\'s tunnel is found under any family, a live one first', () {
    const dead = SubInfo(key: key, localAddr: 'a', alive: false);
    const live = SubInfo(
      key: 'acp\u001fctx\u001f$key',
      localAddr: 'b',
      alive: true,
    );
    expect(tunnelFor([dead, live], key)?.localAddr, 'b');
    expect(tunnelFor([dead], key)?.localAddr, 'a');
    expect(tunnelFor([live], 'pcx:other:app:default'), isNull);
  });
}
