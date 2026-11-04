// Forking a host-access session (Claude, Grok, native OpenCode): what each
// provider can branch is what the view offers, and a held source keeps its own
// admission rules. The opt-in `fork_live` and `native_fork` tests prove the
// host's side against the real agents.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/screens/app_session/activity_cards.dart';
import 'package:pocox/src/screens/app_session_screen.dart';

import 'fake_bridge_api.dart';
import 'support/acp_capabilities.dart';
import 'support/opencode_chat.dart';

const acp = 'pcx:local:acp:agent';
const opencode = openCodeService;
const thread = 'original-session';

const finished = ThreadHistory(
  running: false,
  cwd: '/project',
  items: [
    ThreadItem(
      id: 'u1',
      itemType: 'userMessage',
      title: '',
      text: 'question',
      turnId: 'turn-1',
    ),
    ThreadItem(
      id: 'a1',
      itemType: 'agentMessage',
      title: '',
      text: 'answer',
      turnId: 'turn-1',
    ),
  ],
);

SessionAccess follow(String reason, {String turn = 'idle'}) => SessionAccess(
  sessionId: thread,
  hostId: 'host-1',
  generation: 7,
  provider: 'agent',
  mode: reason == 'not_found' ? 'blocked' : 'follow',
  writer: 'native_client',
  turn: turn,
  exclusion: '',
  reason: reason,
  recheck: true,
);

/// A Claude-like agent: latest state only, also of a held source.
AppCapabilities latestOnly() => negotiatedAcpCapabilities(
  providerName: 'Agent',
  generation: 7,
  nativeHistory: true,
  fork: true,
  forkBusySource: true,
);

/// A Grok-like agent: a turn boundary too.
AppCapabilities withBoundary() => negotiatedAcpCapabilities(
  providerName: 'Agent',
  generation: 7,
  nativeHistory: true,
  fork: true,
  forkThroughTurn: true,
  forkBusySource: true,
);

Future<FakeBridgeApi> openChat(
  WidgetTester t, {
  required AppCapabilities caps,
  String service = acp,
  List<SessionAccess> opens = const [],
  ThreadHistory history = finished,
}) {
  final api = FakeBridgeApi()
    ..acpCapabilities[service] = caps
    ..metadataOnlyFollow = true
    ..readResult = history;
  api.appThreads
    ..clear()
    ..add(
      const ThreadMeta(
        id: thread,
        preview: 'Source',
        cwd: '/project',
        updatedAt: 3,
      ),
    );
  api.sessionOpenResults.addAll(opens);
  return mountChat(
    t,
    api,
    service: service,
    threadId: thread,
    size: const Size(1280, 900),
  );
}

Future<void> disposeChat(WidgetTester t) async {
  await t.pumpWidget(const SizedBox.shrink());
  await frames(t);
  expect(t.takeException(), isNull);
}

/// The conversation menu offers Fork.
Future<bool> menuOffersFork(WidgetTester t) async {
  final contextButton = find.byKey(const Key('session-context-btn'));
  final menu = find.byType(PopupMenuButton<String>);
  if (contextButton.evaluate().isNotEmpty) {
    await t.tap(contextButton);
  } else if (menu.evaluate().isNotEmpty) {
    await t.tap(menu.first);
  } else {
    return false;
  }
  await frames(t);
  final offered = find.byKey(const Key('session-fork')).evaluate().isNotEmpty;
  await t.tapAt(Offset.zero);
  await frames(t);
  return offered;
}

void main() {
  setUp(AppSessionScreen.debugResetThreadMemory);

  testWidgets(
    'a held session forks from its footer and leaves the source to its writer',
    (t) async {
      final api = await openChat(
        t,
        caps: latestOnly(),
        opens: [follow('external_idle')],
      );
      api.threadConfigs[thread] = const ThreadConfig(planMode: true);
      expect(find.byKey(const Key('composer-input')), findsNothing);
      await t.tap(find.byKey(const Key('chat-fork-action')));
      await frames(t);
      await t.tap(find.byKey(const Key('fork-confirm')));
      await frames(t);

      expect(api.forkCalls, [(acp, thread, null)]);
      final fork = api.forkedThreads.single;
      // The fork gets its own admission; the source is never opened again.
      expect(api.sessionOpenCalls, [thread, fork.id]);
      expect(api.lastResumed, fork.id);
      expect(api.turnStartCount, 0, reason: 'a fork sends nothing');
      expect(
        api.threadConfigs.containsKey(fork.id),
        isFalse,
        reason: 'these providers restore what they keep themselves',
      );
      await disposeChat(t);
    },
  );

  testWidgets('a provider with no reliable boundary offers no turn fork', (
    t,
  ) async {
    await openChat(t, caps: latestOnly());
    expect(find.byKey(const Key('message-fork')), findsNothing);
    expect(await menuOffersFork(t), isTrue);
    await disposeChat(t);

    AppSessionScreen.debugResetThreadMemory();
    await openChat(t, caps: withBoundary());
    expect(find.byKey(const Key('message-fork')), findsNWidgets(2));
    await disposeChat(t);
  });

  testWidgets('an agent stamps no completion time, so the running turn says', (
    t,
  ) async {
    // Its own running turn is no boundary.
    await openChat(
      t,
      caps: withBoundary(),
      history: ThreadHistory(
        running: true,
        activeTurnId: 'turn-1',
        cwd: '/project',
        items: finished.items,
      ),
    );
    expect(find.byKey(const Key('message-fork')), findsNothing);
    await disposeChat(t);

    // Following another writer whose turn state is unknown, the newest turn
    // may still run there.
    AppSessionScreen.debugResetThreadMemory();
    await openChat(
      t,
      caps: withBoundary(),
      opens: [follow('external_open', turn: 'unknown')],
    );
    expect(find.byKey(const Key('message-fork')), findsNothing);
    await disposeChat(t);

    // Held but idle, it is over.
    AppSessionScreen.debugResetThreadMemory();
    await openChat(t, caps: withBoundary(), opens: [follow('external_idle')]);
    expect(find.byKey(const Key('message-fork')), findsNWidgets(2));
    await disposeChat(t);
  });

  testWidgets('OpenCode offers no fork beside another engine on its source', (
    t,
  ) async {
    final caps = negotiatedOpenCodeCapabilities(generation: 7, fork: true);
    await openChat(
      t,
      caps: caps,
      service: opencode,
      opens: [follow('external_source_open')],
    );
    expect(
      find.byKey(const Key('access-panel-external_source_open')),
      findsOne,
    );
    expect(find.byKey(const Key('chat-fork-action')), findsNothing);
    expect(find.byKey(const Key('message-fork')), findsNothing);
    await disposeChat(t);

    // Nobody else is known to hold a session this host handed back or never
    // opened, so it can branch.
    AppSessionScreen.debugResetThreadMemory();
    await openChat(
      t,
      caps: caps,
      service: opencode,
      opens: [follow('not_opened')],
    );
    expect(find.byKey(const Key('chat-fork-action')), findsOneWidget);
    await disposeChat(t);
  });

  testWidgets('a running OpenCode turn keeps only the boundaries before it', (
    t,
  ) async {
    final api = await openChat(
      t,
      caps: negotiatedOpenCodeCapabilities(generation: 7, fork: true),
      service: opencode,
      history: ThreadHistory(
        running: true,
        activeTurnId: 'turn-2',
        cwd: '/project',
        items: [
          ...finished.items,
          const ThreadItem(
            id: 'u2',
            itemType: 'userMessage',
            title: '',
            text: 'next',
            turnId: 'turn-2',
          ),
        ],
      ),
    );
    expect(await menuOffersFork(t), isFalse);
    final boundary = find.byKey(const Key('message-fork'));
    expect(boundary, findsNWidgets(2));
    t.widget<MessageAction>(boundary.first).onPressed();
    await frames(t);
    await t.tap(find.byKey(const Key('fork-confirm')));
    await frames(t);
    expect(api.forkCalls, [(opencode, thread, 'turn-1')]);
    await disposeChat(t);
  });

  testWidgets('a session the host says is gone has nothing to branch', (
    t,
  ) async {
    await openChat(t, caps: withBoundary(), opens: [follow('not_found')]);
    expect(find.byKey(const Key('chat-fork-action')), findsNothing);
    expect(find.byKey(const Key('message-fork')), findsNothing);
    await disposeChat(t);
  });
}
