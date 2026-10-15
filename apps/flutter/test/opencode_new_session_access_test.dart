// A native OpenCode session created by this view's first send is written
// here: the host's own access answer (asked beside the send, never instead
// of it) offers "Hand back" as reopening it would, and a late answer never
// lands on another session or grants what the host did not report.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/screens/app_session_screen.dart';

import 'fake_bridge_api.dart';
import 'support/acp_capabilities.dart';
import 'support/opencode_chat.dart';

const _svc = openCodeService;
const _other = 'other-session';

/// The id the fake host gives the first session it creates.
const _created = 'thread-0';

/// The host's answer while a turn runs: this host writes, but a running
/// session cannot be handed back.
const _busy = SessionAccess(
  sessionId: _created,
  hostId: 'host-1',
  generation: 1,
  provider: 'opencode',
  mode: 'write',
  writer: 'this_host',
  turn: 'running',
  exclusion: 'pocket',
  reason: 'owned',
);

SessionAccess _follow(String id) => SessionAccess(
  sessionId: id,
  hostId: 'host-1',
  generation: 1,
  provider: 'opencode',
  mode: 'follow',
  writer: 'native_client',
  turn: 'idle',
  reason: 'external_source_open',
);

Future<FakeBridgeApi> _openDraft(WidgetTester t) {
  final api = FakeBridgeApi()
    ..acpCapabilities[_svc] = negotiatedOpenCodeCapabilities()
    ..metadataOnlyFollow = true
    ..readResult = const ThreadHistory(
      running: false,
      cwd: '/work/alpha',
      items: [],
    );
  // The host writes what this view creates and may hand it back.
  api.sessionAccess[_created] = openCodeWritable(_created);
  api.appThreads.add(
    const ThreadMeta(
      id: _other,
      preview: 'other',
      cwd: '/work/alpha',
      updatedAt: 1,
    ),
  );
  return mountChat(t, api, cwd: '/work/alpha');
}

Future<bool> _releaseOffered(WidgetTester t) async {
  final more = find.byTooltip('More');
  if (more.evaluate().isEmpty) return false;
  await t.tap(more.first);
  await frames(t);
  final offered = find
      .byKey(const Key('session-release'))
      .evaluate()
      .isNotEmpty;
  await t.tapAt(const Offset(4, 4));
  await frames(t);
  return offered;
}

Future<void> _openTile(WidgetTester t, String id) async {
  final tile = find.byKey(Key('conv-tile-$id'));
  await t.ensureVisible(tile.first);
  await t.tap(tile.first);
  await frames(t);
}

void main() {
  setUp(AppSessionScreen.debugResetThreadMemory);

  testWidgets('the first send offers Hand back from the host answer', (
    t,
  ) async {
    final api = await _openDraft(t);
    await typeMessage(t, 'hello');
    await tapSend(t);
    final created = api.threadStartResults.single!;
    expect(created, _created);
    expect(api.lastTurnThread, created);
    // Asked, not opened: no admission is taken for it.
    expect(api.sessionAccessCalls, [created]);
    expect(api.sessionOpenCalls, isEmpty);
    expect(await _releaseOffered(t), isTrue);
    await t.tap(find.byTooltip('More').first);
    await frames(t);
    await t.tap(find.byKey(const Key('session-release')));
    await frames(t);
    expect(api.sessionReleaseCalls.single.sessionId, created);
    expect(find.byKey(const Key('access-panel-released_here')), findsOneWidget);
    // Handed back stays handed back.
    await t.pump(const Duration(minutes: 1));
    await frames(t);
    expect(api.sessionOpenCalls, isEmpty);
  });

  testWidgets('an answer that is not a write here grants nothing', (t) async {
    final api = await _openDraft(t);
    // Every read (after the send and at the turn's end) answers the same.
    api.sessionAccess[_created] = _follow(_created);
    await typeMessage(t, 'hello');
    await tapSend(t);
    final created = api.threadStartResults.single!;
    expect(created, _created);
    expect(api.lastTurnThread, created);
    expect(api.sessionAccessCalls, isNotEmpty);
    expect(await _releaseOffered(t), isFalse);
    expect(api.sessionOpenCalls, isEmpty);
    expect(api.sessionReleaseCalls, isEmpty);
  });

  testWidgets('a write read while the turn ran is read again at its end', (
    t,
  ) async {
    final api = await _openDraft(t)
      ..autoCompleteTurn = false;
    // The host's answer while the first turn runs: it writes, but cannot
    // hand back a running session.
    api.sessionAccessResults.add(_busy);
    await typeMessage(t, 'hello');
    await tapSend(t);
    expect(api.threadStartResults.single, _created);
    expect(api.sessionAccessCalls, [_created]);
    // The turn ends: the next answer (idle, releasable) is asked for.
    api.pushEvent(
      _svc,
      const AppEvent(kind: 'turn/completed', threadId: _created, raw: '{}'),
    );
    await frames(t);
    expect(api.sessionAccessCalls, [_created, _created]);
    expect(await _releaseOffered(t), isTrue);
    expect(api.sessionOpenCalls, isEmpty);
    // Known releasable now: a later turn's end asks nothing more.
    api.pushEvent(
      _svc,
      const AppEvent(kind: 'turn/completed', threadId: _created, raw: '{}'),
    );
    await frames(t);
    expect(api.sessionAccessCalls, hasLength(2));
  });

  testWidgets('an older read answering last replaces nothing', (t) async {
    final api = await _openDraft(t)
      ..autoCompleteTurn = false;
    final gate = Completer<void>();
    api.sessionAccessGate = gate;
    await typeMessage(t, 'hello');
    await tapSend(t);
    // The read after the send is still out when the turn ends; the read at
    // the end answers idle and releasable.
    api.pushEvent(
      _svc,
      const AppEvent(kind: 'turn/completed', threadId: _created, raw: '{}'),
    );
    await frames(t);
    expect(api.sessionAccessCalls, [_created, _created]);
    expect(await _releaseOffered(t), isTrue);
    // The older read then answers "running": it is dropped.
    api.sessionAccessResults.add(_busy);
    gate.complete();
    await frames(t);
    expect(await _releaseOffered(t), isTrue);
  });

  testWidgets('a failed first read recovers at the turn end', (t) async {
    final api = await _openDraft(t)
      ..autoCompleteTurn = false
      ..sessionAccessError = StateError('host busy');
    await typeMessage(t, 'hello');
    await tapSend(t);
    expect(api.threadStartResults.single, _created);
    expect(api.turnStartCount, 1);
    expect(api.sessionAccessCalls, [_created]);
    // No error is shown for a read that decides nothing.
    expect(find.textContaining('host busy'), findsNothing);
    api.pushEvent(
      _svc,
      const AppEvent(kind: 'turn/completed', threadId: _created, raw: '{}'),
    );
    await frames(t);
    expect(api.sessionAccessCalls, [_created, _created]);
    expect(await _releaseOffered(t), isTrue);
    expect(api.sessionOpenCalls, isEmpty);
  });

  testWidgets('after handing back, a turn end reads nothing and takes '
      'nothing', (t) async {
    final api = await _openDraft(t);
    await typeMessage(t, 'hello');
    await tapSend(t);
    await t.tap(find.byTooltip('More').first);
    await frames(t);
    await t.tap(find.byKey(const Key('session-release')));
    await frames(t);
    final reads = api.sessionAccessCalls.length;
    api.pushEvent(
      _svc,
      const AppEvent(kind: 'turn/completed', threadId: _created, raw: '{}'),
    );
    await frames(t);
    expect(api.sessionAccessCalls, hasLength(reads));
    expect(api.sessionOpenCalls, isEmpty);
    expect(find.byKey(const Key('access-panel-released_here')), findsOneWidget);
  });

  testWidgets('a late answer neither holds the send nor lands on the session '
      'shown since; reopening asks afresh', (t) async {
    // The turn keeps running, so only the read after the send is asked.
    final api = await _openDraft(t)
      ..autoCompleteTurn = false;
    api.sessionAccess[_other] = _follow(_other);
    final gate = Completer<void>();
    api.sessionAccessGate = gate;
    await typeMessage(t, 'hello');
    await tapSend(t);
    final created = api.threadStartResults.single!;
    expect(created, _created);
    // The send went out while the access read waits.
    expect(api.turnStartCount, 1);
    expect(api.lastTurnThread, created);
    expect(api.sessionAccessCalls, [created]);
    // Switch to another session before the answer arrives.
    await _openTile(t, _other);
    expect(
      find.byKey(const Key('access-panel-external_source_open')),
      findsOneWidget,
    );
    gate.complete();
    await frames(t);
    // The created session's writable answer does not unlock this one.
    expect(
      find.byKey(const Key('access-panel-external_source_open')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('composer-input')), findsNothing);
    expect(await _releaseOffered(t), isFalse);
    // Reopening the created session takes the ordinary open path.
    await _openTile(t, created);
    expect(api.sessionOpenCalls, contains(created));
    expect(await _releaseOffered(t), isTrue);
    expect(api.turnStartCount, 1);
  });
}
