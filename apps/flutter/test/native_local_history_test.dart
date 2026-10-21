import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/providers.dart';
import 'package:pocox/src/screens/local_sessions_screen.dart';
import 'package:pocox/src/screens/local_session_view_screen.dart';
import 'package:pocox/src/screens/local_session_view/native_window.dart';
import 'fake_bridge_api.dart';

LocalSession session(String title) => LocalSession(
  threadId: title,
  preview: title,
  updatedAt: 0,
  turnState: 'unknown',
  heldOpen: false,
  safety: 'unknown',
  allowsResume: true,
  requiresTakeover: true,
); // Native UI must never trust a write flag.
ThreadItem item(int n, [String? text]) => ThreadItem(
  id: 'i$n',
  turnId: 'native:t$n',
  itemType: 'agentMessage',
  title: '',
  text: text ?? 'message $n',
);
NativeSessionPage page(
  List<ThreadItem> items, {
  String gen = 'g1',
  String rev = 'r1',
  String? before,
}) => NativeSessionPage(
  sourceId: 'root',
  generation: gen,
  revision: rev,
  items: items,
  nextBefore: before,
);
const live = SessionLiveness(
  threadId: 's',
  turnState: 'unknown',
  heldOpen: false,
  safety: 'unknown',
  allowsResume: true,
  requiresTakeover: true,
  holders: [],
);

class NativeFake extends FakeBridgeApi {
  Completer<NativeSessionList>? claudeList;
  Completer<NativeSessionPage>? olderGate;
  StreamController<NativeSessionRevision>? follow;
  String generation = 'g1', revision = 'r1';
  final calls = <String>[];
  @override
  Future<NativeSessionList> appNativeSessions(
    String provider, {
    String? cursor,
    String? sourceId,
  }) async {
    calls.add('list:$provider');
    if (provider == 'claude' && claudeList != null) return claudeList!.future;
    return NativeSessionList(
      sourceId: 'root',
      location: '/fixture/$provider',
      sessions: [session(provider)],
    );
  }

  @override
  Future<NativeSessionRevision> appNativeSessionRevision(
    String provider,
    String threadId, {
    String? sourceId,
  }) async {
    calls.add('revision:$provider:$threadId');
    return NativeSessionRevision(
      sourceId: 'root',
      generation: generation,
      revision: revision,
      liveness: live,
    );
  }

  @override
  Stream<NativeSessionRevision> appNativeSessionFollow(
    String provider,
    String threadId, {
    String? sourceId,
  }) =>
      follow?.stream ??
      super.appNativeSessionFollow(provider, threadId, sourceId: sourceId);

  @override
  Future<NativeSessionPage> appNativeSessionPage(
    String provider,
    String threadId, {
    String? before,
    String? sourceId,
  }) async {
    calls.add('page:$provider:$threadId:$before');
    if (before != null && olderGate != null) return olderGate!.future;
    return before == null
        ? page(
            [item(2, '$provider $threadId $revision')],
            gen: generation,
            rev: revision,
            before: 'native:t2',
          )
        : page([item(1)], gen: generation, rev: revision);
  }
}

Widget host(Widget child, FakeBridgeApi api) => ProviderScope(
  overrides: [bridgeApiProvider.overrideWithValue(api)],
  child: MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: child,
  ),
);
Future<void> settle(WidgetTester t) async {
  await t.pump();
  await t.pump(const Duration(milliseconds: 300));
  await t.pump();
}

void main() {
  test('window merges overlap, invalidates replacement and exposes gaps', () {
    final window = NativeHistoryWindow()
      ..tail(page([item(3), item(4)], before: 'native:t3'));
    expect(window.prepend(page([item(1), item(2)])), isTrue);
    window.tail(
      page([item(4, 'updated'), item(5)], rev: 'r2', before: 'native:t4'),
    );
    expect(window.items.map((v) => v.text), [
      'message 1',
      'message 2',
      'message 3',
      'updated',
      'message 5',
    ]);
    window.tail(page([item(8)], rev: 'r3', before: 'native:t8'));
    expect(window.items.map((v) => v.id), ['i8']);
    expect(window.truncated, isTrue);
    window.tail(page([item(9)], gen: 'g2'));
    expect(window.items.map((v) => v.id), ['i9']);
    expect(window.truncated, isFalse);
    expect(window.prepend(page([item(0)])), isFalse);
  });
  test(
    'retained windows have a turn and byte budget with a reloadable edge',
    () {
      final window = NativeHistoryWindow()
        ..tail(page(List.generate(170, item)));
      expect(window.items.length, 160);
      expect(window.nextBefore, 'native:t10');
      expect(window.truncated, isTrue);
      window.tail(
        page([item(180, 'x' * (NativeHistoryWindow.maxBytes ~/ 2 + 1))]),
      );
      expect(window.items, isEmpty);
      expect(window.truncated, isTrue);
    },
  );
  testWidgets(
    'provider switch rejects late inventory and remote never calls native reader',
    (t) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      try {
        final api = NativeFake()..claudeList = Completer();
        await t.pumpWidget(
          host(
            const LocalSessionsScreen(
              source: SessionSource.local(provider: 'claude'),
            ),
            api,
          ),
        );
        await settle(t);
        await t.tap(find.byKey(const Key('local-provider-opencode')));
        await settle(t);
        expect(find.byKey(const Key('local-opencode')), findsOneWidget);
        api.claudeList!.complete(
          NativeSessionList(
            sourceId: 'old',
            location: '/old',
            sessions: [session('old')],
          ),
        );
        await settle(t);
        expect(find.byKey(const Key('local-old')), findsNothing);
        expect(find.byKey(const Key('resume-opencode')), findsNothing);
        final count = api.calls.length;
        await t.pumpWidget(
          host(
            const LocalSessionsScreen(
              source: SessionSource.remote('pcx:remote:app:test'),
            ),
            api,
          ),
        );
        await settle(t);
        expect(api.calls.length, count);
        expect(find.byKey(const Key('local-provider-opencode')), findsNothing);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );
  testWidgets(
    'unknown ownership still follows revisions and never offers takeover',
    (t) async {
      final api = NativeFake();
      await t.pumpWidget(
        host(
          const LocalSessionViewScreen(threadId: 's', provider: 'claude'),
          api,
        ),
      );
      await settle(t);
      expect(find.text('claude s r1').hitTestable(), findsOneWidget);
      expect(find.byKey(const Key('view-resume')), findsNothing);
      // The continue bar sizes to its content, below the transcript.
      final bar = t.getRect(find.byKey(const Key('view-native-elsewhere')));
      final older = t.getRect(find.byKey(const Key('native-history-older')));
      expect(bar.top, greaterThan(older.bottom));
      expect(
        find.byKey(const Key('native-history-older')).hitTestable(),
        findsOneWidget,
      );
      await t.tap(find.byKey(const Key('native-history-older')));
      await settle(t);
      expect(find.text('message 1'), findsOneWidget);
      api.revision = 'r2';
      await t.pump(const Duration(seconds: 3));
      await settle(t);
      expect(find.text('claude s r2'), findsOneWidget);
      expect(find.text('message 1'), findsOneWidget);
      api.generation = 'g2';
      api.revision = 'r3';
      await t.pump(const Duration(seconds: 3));
      await settle(t);
      expect(find.text('message 1'), findsNothing);
      expect(api.localSessionCalls, 0);
      expect(api.lastForceResumedThread, isNull);
      // Without a serving host nothing continues it here.
      expect(find.byKey(const Key('view-continue-native')), findsNothing);
      expect(find.byKey(const Key('view-native-elsewhere')), findsOneWidget);
      await t.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'a live change re-reads the tail at once and ends with the view',
    (t) async {
      final api = NativeFake()..follow = StreamController();
      await t.pumpWidget(
        host(
          const LocalSessionViewScreen(threadId: 's', provider: 'grok'),
          api,
        ),
      );
      await settle(t);
      expect(find.text('grok s r1'), findsOneWidget);
      expect(api.follow!.hasListener, isTrue);
      // A Grok terminal client's turn streams through the leader.
      api.revision = 'r2';
      api.follow!.add(
        NativeSessionRevision(
          sourceId: 'root',
          generation: 'g1',
          revision: 'r2',
          liveness: const SessionLiveness(
            threadId: 's',
            turnState: 'running',
            heldOpen: true,
            safety: 'nativeOwnedRunning',
            allowsResume: false,
            requiresTakeover: false,
            holders: [],
          ),
        ),
      );
      await t.pump();
      await t.pump();
      expect(find.text('grok s r2'), findsOneWidget);
      expect(find.textContaining('Running elsewhere'), findsOneWidget);
      await t.pumpWidget(const SizedBox.shrink());
      expect(
        api.follow!.hasListener,
        isFalse,
        reason: 'closing ends the follow',
      );
    },
  );
  testWidgets('a hidden view ends its follow and follows again when shown', (
    t,
  ) async {
    final api = NativeFake()..follow = StreamController.broadcast();
    await t.pumpWidget(
      host(const LocalSessionViewScreen(threadId: 's', provider: 'grok'), api),
    );
    await settle(t);
    expect(api.follow!.hasListener, isTrue);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await t.pump();
    expect(api.follow!.hasListener, isFalse, reason: 'in the background');
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await settle(t);
    expect(api.follow!.hasListener, isTrue);
    final navigator = t.state<NavigatorState>(find.byType(Navigator));
    unawaited(
      navigator.push(MaterialPageRoute<void>(builder: (_) => const Scaffold())),
    );
    await settle(t);
    expect(api.follow!.hasListener, isFalse, reason: 'covered by a route');
    navigator.pop();
    await settle(t);
    expect(api.follow!.hasListener, isTrue);
    await t.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a running OpenCode host continues the native session there', (
    t,
  ) async {
    final api = NativeFake();
    api.serveHosts.add(FakeBridgeApi.openCodeHost('studio'));
    await t.pumpWidget(
      host(
        const LocalSessionViewScreen(threadId: 's', provider: 'opencode'),
        api,
      ),
    );
    await settle(t);
    expect(find.byKey(const Key('view-continue-native')), findsOneWidget);
    expect(find.byKey(const Key('view-resume')), findsNothing);
    // Reading it opened, forked or resumed nothing.
    expect(api.sessionOpenCalls, isEmpty);
    expect(api.lastForceResumedThread, isNull);
    await t.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('late older page cannot mutate a newly selected source', (
    t,
  ) async {
    final api = NativeFake()..olderGate = Completer();
    await t.pumpWidget(
      host(
        const LocalSessionViewScreen(threadId: 's', provider: 'claude'),
        api,
      ),
    );
    await settle(t);
    await t.tap(find.byKey(const Key('native-history-older')));
    await settle(t);
    await t.pumpWidget(
      host(
        const LocalSessionViewScreen(threadId: 'other', provider: 'opencode'),
        api,
      ),
    );
    await settle(t);
    api.olderGate!.complete(page([item(1, 'obsolete older page')]));
    await settle(t);
    expect(find.text('obsolete older page'), findsNothing);
    expect(find.text('opencode other r1'), findsOneWidget);
    await t.pumpWidget(const SizedBox.shrink());
  });
}
