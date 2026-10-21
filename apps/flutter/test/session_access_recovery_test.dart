// Host-access sessions the host holds no admission for or no longer has: a
// session reported `not_opened` (never opened there, or forgotten by a
// restart or to make room) is never opened by a background check, after a
// release or while following; an explicit Check now that finds it free, or
// Continue here, opens it afresh, while a session handed back here waits
// for Continue here alone. A session the host deleted leaves the list and,
// when shown, is neither followed nor reopened.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/screens/app_session_screen.dart';

import 'fake_bridge_api.dart';
import 'support/acp_capabilities.dart';
import 'support/opencode_chat.dart';

const _svc = openCodeService;
const _thread = 'ses_shown';
const _other = 'ses_other';

SessionAccess _access({
  String writer = 'none',
  String turn = 'idle',
  String reason = 'not_opened',
}) => SessionAccess(
  sessionId: _thread,
  hostId: 'host-1',
  generation: 7,
  provider: 'opencode',
  mode: 'follow',
  writer: writer,
  turn: turn,
  exclusion: 'pocox',
  reason: reason,
  recheck: true,
);

final _writable = openCodeWritable(_thread, generation: 7);

Future<FakeBridgeApi> _open(
  WidgetTester t, {
  List<SessionAccess> opens = const [],
}) {
  final api = FakeBridgeApi()
    ..acpCapabilities[_svc] = negotiatedOpenCodeCapabilities(generation: 7)
    ..metadataOnlyFollow = true
    ..appThreads.addAll(const [
      ThreadMeta(id: _thread, preview: 'shown', cwd: '/project', updatedAt: 2),
      ThreadMeta(id: _other, preview: 'other', cwd: '/project', updatedAt: 1),
    ])
    ..readResult = const ThreadHistory(
      running: false,
      cwd: '/project',
      items: [],
    );
  api.sessionOpenResults.addAll(opens);
  return mountChat(
    t,
    api,
    threadId: _thread,
    cwd: '/project',
    size: const Size(1280, 900),
  );
}

Future<void> _dispose(WidgetTester t) async {
  await t.pumpWidget(const SizedBox.shrink());
  await frames(t);
  expect(t.takeException(), isNull);
}

/// The host withdrew this view's admission (an eviction or a release).
void _withdrawn(FakeBridgeApi api) => api.pushEvent(
  _svc,
  const AppEvent(
    kind: 'acp/session/updated',
    threadId: _thread,
    raw: '{"sessionId":"ses_shown","admitted":false,"runningTurnId":null}',
  ),
);

Future<void> _wait(WidgetTester t, Duration time) async {
  await t.pump(time);
  await frames(t);
}

void main() {
  setUp(AppSessionScreen.debugResetThreadMemory);

  testWidgets('a session the host let go of while open is followed and '
      'reopened only by Continue here', (t) async {
    final api = await _open(t, opens: [_writable]);
    await t.enterText(find.byKey(const Key('composer-input')), 'keep me');
    for (var i = 0; i < 4; i++) {
      api.sessionAccessResults.add(_access());
    }
    _withdrawn(api);
    await frames(t);
    expect(find.byKey(const Key('access-panel-not_opened')), findsOneWidget);
    expect(find.byKey(const Key('access-continue')), findsOneWidget);
    // Nobody writes it, yet the view never opens it by itself.
    await _wait(t, const Duration(seconds: 3));
    await _wait(t, const Duration(seconds: 3));
    expect(api.sessionAccessCalls.length, greaterThanOrEqualTo(2));
    expect(api.sessionOpenCalls, [_thread]);
    expect(api.turnStartCount, 0);

    api.sessionOpenResults.add(_writable);
    await t.tap(find.byKey(const Key('access-continue')));
    await frames(t);
    expect(api.sessionOpenCalls, [_thread, _thread]);
    expect(composerText(t), 'keep me');
    expect(api.turnStartCount, 0);
    await _dispose(t);
  });

  testWidgets('a followed session the host let go of is not taken when its '
      'holder leaves', (t) async {
    final api = await _open(
      t,
      opens: [_access(writer: 'native_client', reason: 'external_idle')],
    );
    expect(find.byKey(const Key('access-panel-external_idle')), findsOneWidget);
    api.sessionAccessResults.add(_access());
    await _wait(t, const Duration(seconds: 3));
    expect(find.byKey(const Key('access-panel-not_opened')), findsOneWidget);
    api.sessionAccessResults.add(_access());
    await _wait(t, const Duration(seconds: 3));
    expect(api.sessionOpenCalls, hasLength(1));
    expect(find.byKey(const Key('composer-input')), findsNothing);
    await _dispose(t);
  });

  testWidgets('a session handed back here and then let go of by the host '
      'stays handed back', (t) async {
    final api = await _open(t, opens: [_writable]);
    await t.tap(find.byTooltip('More').first);
    await frames(t);
    await t.tap(find.byKey(const Key('session-release')));
    await frames(t);
    expect(find.byKey(const Key('access-panel-released_here')), findsOneWidget);
    // The host evicts it: no writer, nothing kept open.
    for (var i = 0; i < 30; i++) {
      api.sessionAccessResults.add(_access());
    }
    api.pushEvent(
      _svc,
      const AppEvent(
        kind: 'session/access/changed',
        threadId: _thread,
        raw: '{}',
      ),
    );
    await _wait(t, const Duration(minutes: 1));
    expect(api.sessionOpenCalls, hasLength(1));
    expect(find.byKey(const Key('access-continue')), findsOneWidget);

    api.sessionOpenResults.add(_writable);
    await t.tap(find.byKey(const Key('access-continue')));
    await frames(t);
    expect(api.sessionOpenCalls, hasLength(2));
    expect(find.byKey(const Key('composer-input')), findsOneWidget);
    await _dispose(t);
  });

  testWidgets('a deleted session leaves the list and is neither followed nor '
      'reopened', (t) async {
    final api = await _open(t, opens: [_writable]);
    expect(find.byKey(const Key('conv-tile-$_thread')), findsOneWidget);
    expect(find.byKey(const Key('conv-tile-$_other')), findsOneWidget);
    await t.enterText(find.byKey(const Key('composer-input')), 'unsent');
    // The withdrawal's access check is still out when the deletion lands,
    // and answers "free".
    final check = Completer<void>();
    addTearDown(() {
      if (!check.isCompleted) check.complete();
    });
    api
      ..sessionAccessGate = check
      ..sessionAccessResults.add(_access(reason: 'released'));
    _withdrawn(api);
    await frames(t, 2);
    expect(api.sessionAccessCalls, [_thread]);
    api.pushEvent(
      _svc,
      const AppEvent(
        kind: 'thread/deleted',
        threadId: _thread,
        raw: '{"threadId":"ses_shown"}',
      ),
    );
    await frames(t);
    expect(find.byKey(const Key('conv-tile-$_thread')), findsNothing);
    expect(find.byKey(const Key('conv-tile-$_other')), findsOneWidget);
    expect(find.byKey(const Key('access-panel-not_found')), findsOneWidget);
    expect(find.text('This session is no longer on the host'), findsOneWidget);
    expect(find.byKey(const Key('access-check')), findsNothing);
    expect(find.byKey(const Key('access-continue')), findsNothing);
    expect(find.byKey(const Key('composer-input')), findsNothing);

    // The stale answer opens nothing, and nothing is asked again.
    check.complete();
    await _wait(t, const Duration(seconds: 20));
    expect(api.sessionOpenCalls, [_thread]);
    expect(api.sessionAccessCalls, [_thread]);
    expect(find.byKey(const Key('access-panel-not_found')), findsOneWidget);
    // A re-list that still names it (the fake's listing keeps it, and
    // another session's turn end re-lists) does not bring it back.
    expect(api.appThreads.map((t) => t.id), contains(_thread));
    api.pushEvent(
      _svc,
      const AppEvent(kind: 'turn/completed', threadId: _other, raw: '{}'),
    );
    await _wait(t, const Duration(seconds: 1));
    expect(find.byKey(const Key('conv-tile-$_thread')), findsNothing);
    expect(find.byKey(const Key('conv-tile-$_other')), findsOneWidget);
    expect(api.turnStartCount, 0);
    await _dispose(t);
  });

  testWidgets('a session handed back here and then deleted is gone, not '
      'handed back, and nothing said about it afterwards acts on it', (
    t,
  ) async {
    final api = await _open(t, opens: [_writable]);
    await t.tap(find.byTooltip('More').first);
    await frames(t);
    await t.tap(find.byKey(const Key('session-release')));
    await frames(t);
    expect(find.byKey(const Key('access-panel-released_here')), findsOneWidget);
    expect(find.byKey(const Key('access-continue')), findsOneWidget);

    api.pushEvent(
      _svc,
      const AppEvent(
        kind: 'thread/deleted',
        threadId: _thread,
        raw: '{"threadId":"ses_shown"}',
      ),
    );
    await frames(t);
    expect(find.byKey(const Key('access-panel-not_found')), findsOneWidget);
    expect(find.byKey(const Key('access-panel-released_here')), findsNothing);
    expect(find.byKey(const Key('access-check')), findsNothing);
    expect(find.byKey(const Key('access-continue')), findsNothing);
    expect(find.byKey(const Key('composer-input')), findsNothing);
    expect(find.byKey(const Key('conv-tile-$_thread')), findsNothing);
    final accessCalls = api.sessionAccessCalls.length;
    final openCalls = api.sessionOpenCalls.length;
    final settingsReads = api.sessionSettingsRefreshCalls.length;
    final reads = api.threadReads.length;

    // Answers a check would get, should one be made.
    for (var i = 0; i < 10; i++) {
      api.sessionAccessResults.add(_access());
    }
    for (final event in const [
      AppEvent(kind: 'session/access/changed', threadId: _thread, raw: '{}'),
      AppEvent(
        kind: 'acp/session/updated',
        threadId: _thread,
        raw: '{"sessionId":"ses_shown","admitted":false}',
      ),
      AppEvent(
        kind: 'acp/session/updated',
        threadId: _thread,
        raw: '{"sessionId":"ses_shown","admitted":true}',
      ),
      AppEvent(
        kind: 'turn/started',
        threadId: _thread,
        raw: '{"turn":{"id":"late-turn"}}',
      ),
      AppEvent(
        kind: 'execCommandApproval',
        threadId: _thread,
        requestId: 'late-approval',
        raw: '{"command":["ls"]}',
      ),
      // A request that names no thread is not this deleted view's either.
      AppEvent(
        kind: 'execCommandApproval',
        requestId: 'unnamed-approval',
        raw: '{"command":["ls"]}',
      ),
      // The host itself answers again: connection handling still runs.
      AppEvent(
        kind: 'acp/host/state',
        raw: '{"generation":7,"connected":true}',
      ),
    ]) {
      api.pushEvent(_svc, event);
    }
    await _wait(t, const Duration(seconds: 20));
    expect(api.sessionAccessCalls, hasLength(accessCalls));
    expect(api.sessionOpenCalls, hasLength(openCalls));
    expect(api.sessionSettingsRefreshCalls, hasLength(settingsReads));
    expect(api.threadReads, hasLength(reads));
    expect(find.byKey(const Key('access-panel-not_found')), findsOneWidget);
    expect(find.byKey(const Key('access-continue')), findsNothing);
    expect(find.byKey(const Key('approval-card')), findsNothing);
    expect(find.byKey(const Key('stop-btn')), findsNothing);
    expect(find.byKey(const Key('composer-input')), findsNothing);
    expect(find.byKey(const Key('agent-config-model')), findsNothing);

    // Other sessions still work: one is opened from the list as usual.
    api.sessionOpenResults.add(openCodeWritable(_other, generation: 7));
    await t.tap(find.byKey(const Key('conv-tile-$_other')));
    await frames(t);
    expect(api.sessionOpenCalls.last, _other);
    expect(find.byKey(const Key('composer-input')), findsOneWidget);
    expect(api.turnStartCount, 0);
    await _dispose(t);
  });

  for (final (reason, writer) in const [
    ('external_source_open', 'unknown'),
    ('source_unknown', 'unknown'),
    ('transition', 'none'),
  ]) {
    testWidgets('a session followed for $reason that becomes free without an '
        'admission opens only on Check now', (t) async {
      final api = await _open(t, opens: [_writable]);
      await t.enterText(find.byKey(const Key('composer-input')), 'keep me');
      api.sessionAccessResults.add(_access(writer: writer, reason: reason));
      for (var i = 0; i < 8; i++) {
        api.sessionAccessResults.add(_access());
      }
      _withdrawn(api);
      await frames(t);
      expect(find.byKey(Key('access-panel-$reason')), findsOneWidget);

      // Background checks find it free, but the host holds no admission:
      // the view says so and waits for the user.
      await _wait(t, const Duration(seconds: 3));
      expect(find.byKey(const Key('access-panel-not_opened')), findsOneWidget);
      await _wait(t, const Duration(seconds: 3));
      await _wait(t, const Duration(seconds: 3));
      expect(api.sessionAccessCalls.length, greaterThanOrEqualTo(3));
      expect(api.sessionOpenCalls, [_thread]);
      expect(find.byKey(const Key('composer-input')), findsNothing);

      // Check now asks afresh and, still free, opens it.
      final asked = api.sessionAccessCalls.length;
      api.sessionOpenResults.add(_writable);
      await t.tap(find.byKey(const Key('access-check')));
      await frames(t);
      expect(api.sessionAccessCalls, hasLength(asked + 1));
      expect(api.sessionOpenCalls, [_thread, _thread]);
      expect(composerText(t), 'keep me');
      expect(api.turnStartCount, 0);
      await _dispose(t);
    });
  }

  testWidgets('Check now leaves a session read-only while it is held or '
      'running elsewhere', (t) async {
    final api = await _open(t, opens: [_writable]);
    api.sessionAccessResults.addAll([
      _access(writer: 'unknown', reason: 'external_source_open'),
      _access(writer: 'unknown', reason: 'external_source_open'),
    ]);
    _withdrawn(api);
    await frames(t);
    await t.tap(find.byKey(const Key('access-check')));
    await frames(t);
    expect(
      find.byKey(const Key('access-panel-external_source_open')),
      findsOneWidget,
    );
    // Free of writers, but a turn runs: still not opened.
    api.sessionAccessResults.add(_access(turn: 'running'));
    await t.tap(find.byKey(const Key('access-check')));
    await frames(t);
    expect(api.sessionOpenCalls, [_thread]);
    expect(find.byKey(const Key('composer-input')), findsNothing);
    await _dispose(t);
  });

  testWidgets('a session handed back here stays handed back while a check '
      'that finds it free is out', (t) async {
    final api = await _open(t, opens: [_writable]);
    await t.tap(find.byTooltip('More').first);
    await frames(t);
    await t.tap(find.byKey(const Key('session-release')));
    await frames(t);
    expect(find.byKey(const Key('access-panel-released_here')), findsOneWidget);
    // Nothing here asks again on the user's behalf.
    expect(find.byKey(const Key('access-check')), findsNothing);
    final check = Completer<void>();
    addTearDown(() {
      if (!check.isCompleted) check.complete();
    });
    api
      ..sessionAccessGate = check
      ..sessionAccessResults.add(_access());
    for (var i = 0; i < 20; i++) {
      api.sessionAccessResults.add(_access());
    }
    final asked = api.sessionAccessCalls.length;
    api.pushEvent(
      _svc,
      const AppEvent(
        kind: 'session/access/changed',
        threadId: _thread,
        raw: '{}',
      ),
    );
    await frames(t, 2);
    expect(api.sessionAccessCalls, hasLength(asked + 1));
    check.complete();
    await frames(t);
    await _wait(t, const Duration(seconds: 30));
    expect(find.byKey(const Key('access-panel-released_here')), findsOneWidget);
    expect(api.sessionOpenCalls, [_thread]);

    api.sessionOpenResults.add(_writable);
    await t.tap(find.byKey(const Key('access-continue')));
    await frames(t);
    expect(api.sessionOpenCalls, [_thread, _thread]);
    expect(find.byKey(const Key('composer-input')), findsOneWidget);
    await _dispose(t);
  });
}
