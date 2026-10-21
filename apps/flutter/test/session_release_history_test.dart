// A session written here and then handed back is followed read-only from the
// host's history. A message sent here shows once when that history holds it
// (confirmed by a host user message of its turn not shown before); one the
// history does not hold yet stays, however often it is read again; two
// messages with the same text in different turns stay two messages.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/screens/app_session_screen.dart';

import 'fake_bridge_api.dart';
import 'support/acp_capabilities.dart';
import 'support/opencode_chat.dart';

const _svc = openCodeService;
const _thread = 'ses_shown';
const _ask = 'Reply with exactly PR109_OK.';
const _more = 'Also say DONE.';

ThreadItem _item(String id, String turn, String type, String text) =>
    ThreadItem(id: id, turnId: turn, itemType: type, title: '', text: text);

/// The host's history: an earlier turn that asked the same, then [turns].
ThreadHistory _history(List<ThreadItem> turns) => ThreadHistory(
  running: false,
  cwd: '/project',
  items: [
    _item('msg_1', 'msg_1', 'userMessage', _ask),
    _item('msg_1a', 'msg_1', 'agentMessage', 'first answer'),
    ...turns,
  ],
);

Future<FakeBridgeApi> _openWritable(WidgetTester t, ThreadHistory history) {
  final api = FakeBridgeApi()
    ..acpCapabilities[_svc] = negotiatedOpenCodeCapabilities(generation: 7)
    ..metadataOnlyFollow = true
    ..announceTurnStart = false
    ..appThreads.add(
      const ThreadMeta(
        id: _thread,
        preview: 'shown',
        cwd: '/project',
        updatedAt: 2,
      ),
    )
    ..readResult = history;
  api.sessionOpenResults.add(openCodeWritable(_thread, generation: 7));
  api.sessionSettings['$_svc|$_thread'] = const SessionSettings(
    configOptions: [
      SessionConfigOption(
        id: 'model',
        name: 'Model',
        category: 'model',
        currentValue: 'opencode/big-pickle',
        values: [
          SessionConfigValue(value: 'opencode/big-pickle', name: 'Pickle'),
        ],
      ),
    ],
  );
  return mountChat(
    t,
    api,
    threadId: _thread,
    cwd: '/project',
    size: const Size(1280, 900),
  );
}

/// Hand the session back from the conversation menu.
Future<void> _release(WidgetTester t) async {
  await t.tap(find.byTooltip('More').first);
  await frames(t);
  // Only what the engine has: OpenCode renames but has no manual compaction.
  expect(find.text('Rename'), findsOneWidget);
  expect(find.text('Compact conversation'), findsNothing);
  await t.tap(find.byKey(const Key('session-release')));
  await frames(t, 40);
  expect(find.byKey(const Key('access-panel-released_here')), findsOneWidget);
}

/// The host's follow stream reports a new history revision, so the view
/// reads the history again.
Future<void> _reread(WidgetTester t, FakeBridgeApi api, String revision) async {
  final reads = api.threadReads.length;
  api.pushMetaSessionUpdate(
    _thread,
    SessionFollowUpdate(
      liveness: await api.appSessionLiveness(_thread),
      items: const [],
      historyRevision: revision,
    ),
  );
  await frames(t, 40);
  expect(api.threadReads.length, greaterThan(reads));
}

/// Send [text] as a supplement to the running turn.
Future<void> _supplement(WidgetTester t, String text) async {
  await t.tap(find.byKey(const Key('supplement-toggle')));
  await frames(t, 2);
  await t.enterText(find.byKey(const Key('composer-input')), text);
  await frames(t, 2);
  await t.tap(find.byKey(const Key('send-btn')));
  await frames(t);
}

Finder _shown(String text) => find.text(text, findRichText: true);

void main() {
  setUp(AppSessionScreen.debugResetThreadMemory);

  testWidgets('a message sent here shows once after the session is handed '
      'back, and a repeated ask stays', (t) async {
    final api = await _openWritable(t, _history(const []));
    expect(_shown(_ask), findsOneWidget);

    // Ask the same again here; OpenCode names the turn after the message.
    await t.enterText(find.byKey(const Key('composer-input')), _ask);
    await frames(t, 2);
    await t.tap(find.byKey(const Key('send-btn')));
    await frames(t, 4);
    expect(api.turnStartCount, 1);
    for (final event in const [
      AppEvent(
        kind: 'turn/started',
        threadId: _thread,
        raw: '{"turn":{"id":"msg_2"}}',
      ),
      AppEvent(
        kind: 'item/completed',
        threadId: _thread,
        itemId: 'msg_2a',
        itemType: 'agentMessage',
        text: 'PR109_OK',
        raw: '{"turnId":"msg_2"}',
      ),
      AppEvent(
        kind: 'turn/completed',
        threadId: _thread,
        raw: '{"turn":{"id":"msg_2"}}',
      ),
    ]) {
      api.pushEvent(_svc, event);
    }
    await frames(t);
    expect(_shown(_ask), findsNWidgets(2));
    expect(_shown('PR109_OK'), findsOneWidget);

    // The host's history now holds the message sent here.
    api.readResult = _history([
      _item('msg_2', 'msg_2', 'userMessage', _ask),
      _item('msg_2a', 'msg_2', 'agentMessage', 'PR109_OK'),
    ]);
    await _release(t);
    expect(api.threadReads, isNotEmpty);
    expect(_shown(_ask), findsNWidgets(2));
    expect(_shown('PR109_OK'), findsOneWidget);
    expect(_shown('first answer'), findsOneWidget);
    expect(api.turnStartCount, 1);

    await t.pumpWidget(const SizedBox.shrink());
    await frames(t);
    expect(t.takeException(), isNull);
  });

  testWidgets('a supplement the host has not shown yet stays, however often '
      'the history is read again', (t) async {
    final api = await _openWritable(t, _history(const []));
    await t.enterText(find.byKey(const Key('composer-input')), _ask);
    await frames(t, 2);
    await t.tap(find.byKey(const Key('send-btn')));
    await frames(t, 4);
    api.pushEvent(
      _svc,
      const AppEvent(
        kind: 'turn/started',
        threadId: _thread,
        raw: '{"turn":{"id":"msg_2"}}',
      ),
    );
    await frames(t);
    await _supplement(t, _more);
    expect(api.supplementCalls, hasLength(1));
    expect(_shown(_more), findsOneWidget);
    for (final event in const [
      AppEvent(
        kind: 'item/completed',
        threadId: _thread,
        itemId: 'msg_2a',
        itemType: 'agentMessage',
        text: 'PR109_OK',
        raw: '{"turnId":"msg_2"}',
      ),
      AppEvent(
        kind: 'turn/completed',
        threadId: _thread,
        raw: '{"turn":{"id":"msg_2"}}',
      ),
    ]) {
      api.pushEvent(_svc, event);
    }
    await frames(t);

    // The host's history holds the message but not yet the supplement.
    api.readResult = _history([
      _item('msg_2', 'msg_2', 'userMessage', _ask),
      _item('msg_2a', 'msg_2', 'agentMessage', 'PR109_OK'),
    ]);
    await _release(t);
    expect(_shown(_ask), findsNWidgets(2));
    expect(_shown(_more), findsOneWidget);
    await _reread(t, api, 'r2');
    await _reread(t, api, 'r3');
    expect(_shown(_ask), findsNWidgets(2));
    expect(_shown(_more), findsOneWidget);

    // Once the history holds it too, it still shows once.
    api.readResult = _history([
      _item('msg_2', 'msg_2', 'userMessage', _ask),
      _item('msg_2b', 'msg_2', 'userMessage', _more),
      _item('msg_2a', 'msg_2', 'agentMessage', 'PR109_OK'),
    ]);
    await _reread(t, api, 'r4');
    await _reread(t, api, 'r5');
    expect(_shown(_ask), findsNWidgets(2));
    expect(_shown(_more), findsOneWidget);
    expect(api.turnStartCount, 1);

    await t.pumpWidget(const SizedBox.shrink());
    await frames(t);
    expect(t.takeException(), isNull);
  });

  testWidgets('a host message already shown does not confirm a later '
      'supplement of its turn', (t) async {
    const asked = [
      ThreadItem(
        id: 'msg_2',
        turnId: 'msg_2',
        itemType: 'userMessage',
        title: '',
        text: _ask,
      ),
    ];
    final api = await _openWritable(
      t,
      ThreadHistory(
        running: true,
        activeTurnId: 'msg_2',
        cwd: '/project',
        items: _history(asked).items,
      ),
    );
    expect(_shown(_ask), findsNWidgets(2));
    await _supplement(t, _more);
    expect(api.supplementCalls, hasLength(1));
    expect(_shown(_more), findsOneWidget);
    api.pushEvent(
      _svc,
      const AppEvent(
        kind: 'turn/completed',
        threadId: _thread,
        raw: '{"turn":{"id":"msg_2"}}',
      ),
    );
    await frames(t);

    // The history still shows only the message that was already there.
    api.readResult = _history([
      ...asked,
      _item('msg_2a', 'msg_2', 'agentMessage', 'PR109_OK'),
    ]);
    await _release(t);
    expect(_shown(_ask), findsNWidgets(2));
    expect(_shown(_more), findsOneWidget);
    await _reread(t, api, 'r2');
    expect(_shown(_more), findsOneWidget);
    expect(api.turnStartCount, 0);

    await t.pumpWidget(const SizedBox.shrink());
    await frames(t);
    expect(t.takeException(), isNull);
  });
}
