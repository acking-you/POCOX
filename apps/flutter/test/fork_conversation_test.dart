import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/screens/app_session/activity_cards.dart';
import 'package:pocox/src/screens/app_session_screen.dart';
import 'package:pocox/src/screens/local_session_view_screen.dart';

import 'fake_bridge_api.dart';
import 'support/screen_harness.dart';

const service = 'pcx:fork:app:default';
const source = ThreadMeta(
  id: 'source',
  preview: 'Source work',
  cwd: '/repo',
  updatedAt: 3,
);
const other = ThreadMeta(
  id: 'other',
  preview: 'Other work',
  cwd: '/repo',
  updatedAt: 2,
);
const items = [
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
    turnCompletedAt: 100,
  ),
];

final l10n = lookupAppLocalizations(const Locale('zh'));

SessionLiveness held({required bool running}) => SessionLiveness(
  threadId: 'source',
  turnState: running ? 'incomplete' : 'completed',
  heldOpen: true,
  safety: running ? 'ownedRunning' : 'ownedIdle',
  allowsResume: !running,
  requiresTakeover: !running,
  holders: const [],
);

Future<void> frames(WidgetTester t) async {
  for (var i = 0; i < 10; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

/// Run on the desktop layout, with its hover actions and top-bar menu.
void desktop(String description, Future<void> Function(WidgetTester) body) {
  testWidgets(description, (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      await t.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await body(t);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 11));
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

Future<FakeBridgeApi> openSource(
  WidgetTester t, {
  FakeBridgeApi? api,
  String thread = 'source',
  String key = service,
  bool home = true,
}) async {
  final bridge =
      api ??
      (FakeBridgeApi()
        ..appThreads.clear()
        ..appThreads.addAll([source, other])
        ..readResult = const ThreadHistory(items: items, running: false));
  await bridge.appConnect(key, 28080);
  await t.pumpWidget(
    host(
      AppSessionScreen(serviceKey: key, threadId: thread, home: home),
      bridge,
    ),
  );
  await frames(t);
  return bridge;
}

Future<void> openMenu(WidgetTester t) async {
  await t.tap(find.byKey(const Key('conversation-menu')));
  await frames(t);
}

Future<void> forkFromMenu(WidgetTester t) async {
  await openMenu(t);
  await t.tap(find.byKey(const Key('session-fork')));
  await frames(t);
  await t.tap(find.byKey(const Key('fork-confirm')));
  await frames(t);
}

void main() {
  setUp(AppSessionScreen.debugResetThreadMemory);

  desktop(
    'a fork opens a new conversation and leaves the source and its draft alone',
    (t) async {
      final api = await openSource(t);
      api.threadConfigs['source'] = const ThreadConfig(planMode: true);
      await t.enterText(
        find.byKey(const Key('composer-input')),
        'unsent draft',
      );
      await frames(t);

      await forkFromMenu(t);

      expect(api.forkCalls, [(service, 'source', null)]);
      final fork = api.forkedThreads.single;
      expect(fork.forkedFromId, 'source');
      expect(api.lastResumed, fork.id);
      expect(api.turnStartCalls, isEmpty, reason: 'a fork sends nothing');
      expect(
        api.threadConfigs[fork.id]?.planMode,
        isTrue,
        reason: 'the server does not carry plan mode over by itself',
      );
      final composer = find.byKey(const Key('composer-input'));
      expect(t.widget<TextField>(composer).controller?.text, isEmpty);

      // No card has the room here, so the status line marks it.
      await t.tap(find.byKey(const Key('fork-source-mark')));
      await frames(t);
      expect(api.lastResumed, 'source');
      expect(t.widget<TextField>(composer).controller?.text, 'unsent draft');
      expect(
        find.byKey(Key('fork-mark-${fork.id}')),
        findsOneWidget,
        reason: 'the host does not list a fork yet to have a turn of its own',
      );
    },
  );

  desktop('only a finished turn offers itself as a boundary', (t) async {
    final api = await openSource(
      t,
      api: FakeBridgeApi()
        ..appThreads.clear()
        ..appThreads.addAll([source, other])
        ..readResult = const ThreadHistory(
          items: [
            ...items,
            ThreadItem(
              id: 'u2',
              itemType: 'userMessage',
              title: '',
              text: 'next',
              turnId: 'turn-2',
            ),
            ThreadItem(
              id: 'a2',
              itemType: 'agentMessage',
              title: '',
              text: 'partial',
              turnId: 'turn-2',
            ),
          ],
          running: true,
          activeTurnId: 'turn-2',
        ),
    );
    // The finished turn's question and reply, and nothing of the running one.
    final action = find.byKey(const Key('message-fork'));
    expect(action, findsNWidgets(2));
    t.widget<MessageAction>(action.first).onPressed();
    await frames(t);
    expect(find.text(l10n.forkDialogThroughTurn), findsOneWidget);
    await t.tap(find.byKey(const Key('fork-confirm')));
    await frames(t);
    expect(api.forkCalls, [(service, 'source', 'turn-1')]);
  });

  desktop('with nothing running, a turn with no recorded end still offers', (
    t,
  ) async {
    await openSource(
      t,
      api: FakeBridgeApi()
        ..appThreads.clear()
        ..appThreads.addAll([source, other])
        ..readResult = const ThreadHistory(
          items: [
            ThreadItem(
              id: 'a1',
              itemType: 'agentMessage',
              title: '',
              text: 'answer',
              turnId: 'turn-1',
            ),
          ],
          running: false,
        ),
    );
    expect(find.byKey(const Key('message-fork')), findsOneWidget);
  });

  testWidgets('a long press on a finished reply offers the boundary on touch', (
    t,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await t.binding.setSurfaceSize(const Size(1100, 800));
      addTearDown(() => t.binding.setSurfaceSize(null));
      final api = await openSource(t, home: false);
      await t.longPress(find.text('answer'));
      await frames(t);
      await t.tap(find.text(l10n.forkThroughTurn));
      await frames(t);
      await t.tap(find.byKey(const Key('fork-confirm')));
      await frames(t);
      expect(api.forkCalls, [(service, 'source', 'turn-1')]);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 11));
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  for (final running in [false, true]) {
    desktop(
      'a held source forks without being taken over (running: $running)',
      (t) async {
        final api = FakeBridgeApi()
          ..appThreads.clear()
          ..appThreads.addAll([source, other])
          ..appThreadResumeError = StateError(
            'thread already has an active writer',
          );
        api.transcripts['source'] = items;
        api.liveness['source'] = held(running: running);
        await openSource(t, api: api);
        expect(find.byKey(const Key('composer-input')), findsNothing);
        expect(
          find.byKey(const Key('chat-takeover-action')),
          running ? findsNothing : findsOneWidget,
        );

        await t.tap(find.byKey(const Key('chat-fork-action')));
        await frames(t);
        expect(
          find.text(l10n.forkDialogRunning),
          running ? findsOneWidget : findsNothing,
        );
        // The fork is its own session: the source's writer is not in its way.
        api.appThreadResumeError = null;
        await t.tap(find.byKey(const Key('fork-confirm')));
        await frames(t);

        expect(api.forkCalls, [(service, 'source', null)]);
        expect(api.lastMetaResumedKey, isNull, reason: 'nothing was evicted');
        expect(api.lastResumed, api.forkedThreads.single.id);
        expect(find.byKey(const Key('composer-input')), findsOneWidget);
      },
    );
  }

  desktop('a Guardian review offers no fork', (t) async {
    const review = ThreadMeta(
      id: 'review',
      preview: 'Approval review',
      cwd: '/repo',
      updatedAt: 3,
      threadSource: 'guardian_review',
    );
    await openSource(
      t,
      thread: 'review',
      api: FakeBridgeApi()
        ..appThreads.clear()
        ..appThreads.add(review)
        ..readResult = const ThreadHistory(items: items, running: false),
    );
    expect(find.byKey(const Key('guardian-read-only')), findsOneWidget);
    expect(find.byKey(const Key('chat-fork-action')), findsNothing);
    expect(find.byKey(const Key('message-fork')), findsNothing);
    await openMenu(t);
    expect(find.byKey(const Key('session-fork')), findsNothing);
  });

  desktop('a provider without forks offers none', (t) async {
    await openSource(t, key: 'pcx:fork:acp:default', home: false);
    expect(find.byKey(const Key('message-fork')), findsNothing);
    expect(find.byKey(const Key('session-fork')), findsNothing);
  });

  desktop('a refused or lost fork stays put and is never retried', (t) async {
    final api = await openSource(t);

    api.forkError = StateError('thread not found');
    await forkFromMenu(t);
    expect(find.textContaining(l10n.forkFailed), findsOneWidget);
    expect(api.lastResumed, 'source');
    expect(api.lastMetaResumedKey, isNull, reason: 'no fallback to takeover');
    await t.pump(const Duration(seconds: 5));

    // The answer was lost: a session may exist, so nothing asks again.
    api.forkResult = const ThreadForkResult();
    await forkFromMenu(t);
    expect(find.text(l10n.forkOutcomeUnknown), findsOneWidget);
    expect(api.forkCalls, hasLength(2));
    expect(api.lastResumed, 'source');
    await t.pump(const Duration(seconds: 5));

    // A server that ignored the boundary leaves a session to look at, not one
    // presented as the selection.
    const wider = ThreadMeta(
      id: 'wider',
      preview: 'Source work',
      forkedFromId: 'source',
      cwd: '/repo',
      updatedAt: 4,
    );
    api.appThreads.insert(0, wider);
    api.forkResult = const ThreadForkResult(thread: wider);
    await forkFromMenu(t);
    expect(find.text(l10n.forkBoundaryUnconfirmed), findsOneWidget);
    expect(api.lastResumed, 'source');
    expect(find.byKey(const Key('activity-tile-wider')), findsOneWidget);
  });

  desktop('a fork confirmation cannot cross a reconnect', (t) async {
    final api = await openSource(t);
    await openMenu(t);
    await t.tap(find.byKey(const Key('session-fork')));
    await frames(t);

    await api.appDisconnect(service);
    for (var i = 0; i < 3; i++) {
      await frames(t);
    }
    expect(api.appIsConnected(service), isTrue);
    await t.tap(find.byKey(const Key('fork-confirm')));
    await frames(t);
    expect(api.forkCalls, isEmpty);
    expect(api.lastResumed, 'source');
  });

  desktop('a pending fork blocks another and a late answer moves no one', (
    t,
  ) async {
    final api = await openSource(t);
    final gate = Completer<void>();
    api.forkGate = gate;
    await forkFromMenu(t);
    expect(find.text(l10n.forkPending), findsOneWidget);

    await openMenu(t);
    final item = t.widget<PopupMenuItem<Object?>>(
      find.byKey(const Key('session-fork')),
    );
    expect(item.enabled, isFalse);
    await t.tapAt(Offset.zero);
    await frames(t);

    await t.tap(find.byKey(const Key('activity-tile-other')));
    await frames(t);
    expect(api.lastResumed, 'other');

    gate.complete();
    await frames(t);
    expect(
      api.lastResumed,
      'other',
      reason: 'the reader stays where they went',
    );
    expect(find.text(l10n.forkPending), findsNothing);
    await t.tap(find.text(l10n.forkReadyOpen));
    await frames(t);
    expect(api.lastResumed, api.forkedThreads.single.id);
    expect(api.forkCalls, hasLength(1));
  });

  for (final duringSettings in [false, true]) {
    desktop('a fork finishing after the host changed is not adopted '
        '(during settings copy: $duringSettings)', (t) async {
      final api = await openSource(t);
      final gate = Completer<void>();
      if (duringSettings) {
        api.configReadGate = gate;
      } else {
        api.forkGate = gate;
      }
      await forkFromMenu(t);

      const elsewhere = 'pcx:fork2:app:default';
      await api.appConnect(elsewhere, 28081);
      await t.pumpWidget(
        host(
          const AppSessionScreen(
            serviceKey: elsewhere,
            threadId: 'other',
            home: true,
          ),
          api,
        ),
      );
      await frames(t);
      final resumed = api.lastResumed;

      gate.complete();
      await frames(t);
      final fork = api.forkedThreads.single;
      expect(api.lastResumed, resumed, reason: 'the fork opened nothing');
      expect(find.text(l10n.forkHostChanged), findsOneWidget);
      expect(find.byKey(Key('activity-tile-${fork.id}')), findsNothing);
    });
  }

  desktop('the session viewer forks on the host serving the session', (
    t,
  ) async {
    final api = FakeBridgeApi()
      ..appThreads.clear()
      ..appThreads.add(source);
    api.transcripts['source'] = items;
    api.liveness['source'] = held(running: true);
    await api.appConnect(service, 28080);
    await t.pumpWidget(
      routerHost(
        api,
        initial: '/',
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => const LocalSessionViewScreen(
              threadId: 'source',
              serviceKey: service,
            ),
          ),
          GoRoute(
            path: '/app/:key/session',
            builder: (_, state) =>
                Text('opened ${state.uri.queryParameters['tid']}'),
          ),
        ],
      ),
    );
    await frames(t);
    expect(find.byKey(const Key('view-resume')), findsNothing);

    // The viewer keeps re-reading the session, and that must not cancel a fork
    // waiting on the confirmation or on the host.
    final gate = Completer<void>();
    api.forkGate = gate;
    await t.tap(find.byKey(const Key('view-fork')));
    await frames(t);
    await t.pump(const Duration(seconds: 4));
    await t.tap(find.byKey(const Key('fork-confirm')));
    await frames(t);
    await t.pump(const Duration(seconds: 4));
    gate.complete();
    await frames(t);

    expect(api.forkCalls, [(service, 'source', null)]);
    expect(api.lastMetaResumedKey, isNull);
    expect(find.text('opened ${api.forkedThreads.single.id}'), findsOneWidget);
  });

  desktop('a session on this device forks only on a host this device runs', (
    t,
  ) async {
    const localHost = 'pcx:thisdevice:app:default';
    // Reachable and connected, but the session read from this device's disk
    // is not there.
    final api =
        FakeBridgeApi(
            services: const [
              ServiceEntry(
                device: 'fork',
                kind: 'app',
                name: 'default',
                key: service,
              ),
            ],
          )
          ..appThreads.clear()
          ..appThreads.add(source);
    api.transcripts['source'] = items;
    api.liveness['source'] = held(running: false);
    await api.appConnect(service, 28080);
    await t.pumpWidget(
      routerHost(
        api,
        initial: '/',
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => const LocalSessionViewScreen(threadId: 'source'),
          ),
          GoRoute(
            path: '/app/:key/session',
            builder: (_, state) =>
                Text('opened ${state.uri.queryParameters['tid']}'),
          ),
        ],
      ),
    );
    await frames(t);

    await t.tap(find.byKey(const Key('view-fork')));
    await frames(t);
    expect(find.text(l10n.forkNoLocalHost), findsOneWidget);
    expect(find.byKey(const Key('fork-dialog')), findsNothing);
    expect(api.forkCalls, isEmpty);
    await t.pump(const Duration(seconds: 5));

    api.serveHosts.add(
      const AppServeStatus(
        name: 'local',
        device: 'thisdevice',
        alive: true,
        appServiceKey: localHost,
      ),
    );
    await t.tap(find.byKey(const Key('view-fork')));
    await frames(t);
    await t.tap(find.byKey(const Key('fork-confirm')));
    await frames(t);
    expect(api.forkCalls, [(localHost, 'source', null)]);
  });
}
