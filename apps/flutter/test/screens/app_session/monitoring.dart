part of '../app_session_test.dart';

/// Following a conversation another writer holds, and taking it over.
void _registerMonitoring() {
  for (final refreshAt in ['none', 'while pressed', 'after release']) {
    testWidgets(
      'external writer first-turn navigation survives snapshot refresh: $refreshAt',
      (t) async {
        final previousPlatform = debugDefaultTargetPlatformOverride;
        debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
        try {
          await t.binding.setSurfaceSize(const Size(1600, 900));
          addTearDown(() => t.binding.setSurfaceSize(null));
          const service = 'pcx:lb7666:app:default';
          const thread = 'external-navigation';
          final api =
              FakeBridgeApi(
                  config: const ConfigInfo(
                    relay: 'lb7666.top:7666',
                    hasKey: true,
                  ),
                )
                ..appThreadResumeError = StateError(
                  'thread already has an active writer',
                );
          await api.appConnect(service, 28080);
          final items = [
            for (var i = 0; i < 12; i++) ...[
              ThreadItem(
                id: 'user-$i',
                itemType: 'userMessage',
                title: '',
                text: 'external question $i',
              ),
              ThreadItem(
                id: 'reply-$i',
                itemType: 'agentMessage',
                title: '',
                text: List.filled(20, 'reply $i').join('\n\n'),
              ),
            ],
          ];
          const liveness = SessionLiveness(
            threadId: thread,
            turnState: 'completed',
            heldOpen: true,
            safety: 'ownedIdle',
            allowsResume: true,
            requiresTakeover: true,
            holders: [],
          );
          api.transcripts[thread] = items;
          api.liveness[thread] = liveness;
          await t.pumpWidget(
            host(
              const AppSessionScreen(serviceKey: service, threadId: thread),
              api,
            ),
          );
          await t.pumpAndSettle();
          expect(find.byKey(const Key('chat-takeover-action')), findsOneWidget);
          final scroll = t
              .widget<MiddleClickScroll>(find.byType(MiddleClickScroll))
              .controller;
          // Opened at the end, far below the conversation's start.
          expect(scroll.position.extentBefore, greaterThan(500));
          final rail = t.getRect(find.byKey(const Key('turn-minimap-rail')));
          final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
          await mouse.addPointer(location: Offset.zero);
          addTearDown(mouse.removePointer);
          final point = Offset(rail.left + 4, rail.top);
          await mouse.moveTo(point);
          await t.pumpAndSettle();
          await mouse.down(point);
          await t.pump(const Duration(milliseconds: 150));
          if (refreshAt == 'while pressed') {
            api.pushMetaSessionUpdate(
              thread,
              SessionFollowUpdate(liveness: liveness, items: [...items]),
            );
            await t.pumpAndSettle();
          }
          await mouse.up();
          if (refreshAt == 'after release') {
            api.pushMetaSessionUpdate(
              thread,
              SessionFollowUpdate(liveness: liveness, items: [...items]),
            );
          }
          await mouse.moveTo(const Offset(1500, 850));
          await t.pumpAndSettle();
          expect(scroll.position.extentBefore, lessThan(20));
          expect(find.text('external question 0'), findsOneWidget);
          final firstTick = t.widget<Container>(
            find.byKey(const ValueKey('turn-minimap-tick-0')),
          );
          expect(firstTick.constraints!.maxWidth, 13);
          expect(find.byKey(const Key('chat-takeover-action')), findsOneWidget);
          expect(api.lastMetaResumedThread, isNull);
          await t.pumpWidget(const SizedBox());
        } finally {
          debugDefaultTargetPlatformOverride = previousPlatform;
        }
      },
    );
  }

  testWidgets(
    'remote monitoring updates a running image in place on completion',
    (t) async {
      const service = 'pcx:lb7666:app:default';
      final api =
          FakeBridgeApi(
              config: const ConfigInfo(relay: 'relay:7666', hasKey: true),
            )
            ..metadataOnlyFollow = true
            ..appThreadResumeError = StateError(
              'thread already has an active writer',
            );
      await api.appConnect(service, 28080);
      const running = SessionLiveness(
        threadId: 'watched',
        turnState: 'incomplete',
        heldOpen: true,
        safety: 'ownedRunning',
        allowsResume: false,
        requiresTakeover: false,
        holders: [],
      );
      api.liveness['watched'] = running;
      api.readResult = ThreadHistory(
        items: [
          ThreadItem(
            id: 'remote-image',
            itemType: 'imageGeneration',
            title: 'Blue circle',
            text: '{"status":"in_progress"}',
            turnId: 'turn',
          ),
        ],
        running: true,
        activeTurnId: 'turn',
        turns: [TurnSummary(turnId: 'turn')],
      );
      await t.pumpWidget(
        host(
          const AppSessionScreen(serviceKey: service, threadId: 'watched'),
          api,
        ),
      );
      for (var i = 0; i < 5; i++) {
        await t.pump(const Duration(milliseconds: 300));
      }
      expect(find.byType(ImageLoadingPlaceholder), findsOneWidget);
      api.threadImageBytes['/remote/circle.png'] = onePixelPng;
      api.readResult = ThreadHistory(
        items: [
          ThreadItem(
            id: 'remote-image',
            itemType: 'imageGeneration',
            title: 'Blue circle',
            text: '{"status":"completed"}',
            images: ['/remote/circle.png'],
            turnId: 'turn',
          ),
        ],
        running: false,
      );
      const completed = SessionLiveness(
        threadId: 'watched',
        turnState: 'completed',
        heldOpen: true,
        safety: 'ownedIdle',
        allowsResume: false,
        requiresTakeover: false,
        holders: [],
      );
      api.pushMetaSessionUpdate(
        'watched',
        const SessionFollowUpdate(
          liveness: completed,
          items: [],
          historyRevision: 'image-completed',
        ),
      );
      await t.pump();
      await t.pump(const Duration(seconds: 1));
      await t.pumpAndSettle();
      expect(
        find.byKey(const Key('generated-image-remote-image')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('msg-image-0')), findsOneWidget);
      expect(find.byType(ImageLoadingPlaceholder), findsNothing);
    },
  );

  testWidgets(
    'metadata-only monitoring pages history and retains it across updates',
    (t) async {
      const service = 'pcx:lb7666:app:default';
      final api =
          FakeBridgeApi(
              config: const ConfigInfo(relay: 'relay:7666', hasKey: true),
            )
            ..metadataOnlyFollow = true
            ..appThreadResumeError = StateError(
              'thread already has an active writer',
            );
      await api.appConnect(service, 28080);
      const live = SessionLiveness(
        threadId: 'watched',
        turnState: 'completed',
        heldOpen: true,
        safety: 'ownedIdle',
        allowsResume: false,
        requiresTakeover: false,
        holders: [],
      );
      api.liveness['watched'] = live;
      const turns = [
        TurnSummary(
          turnId: 'first',
          userText: 'opening',
          assistantText: '',
          loaded: true,
        ),
        TurnSummary(
          turnId: 'last',
          userText: 'last',
          assistantText: '',
          loaded: true,
        ),
      ];
      api.readResult = ThreadHistory(
        items: [
          ThreadItem(
            id: 'opening',
            itemType: 'userMessage',
            title: '',
            text: 'Opening question',
            turnId: 'first',
          ),
          ThreadItem(
            id: 'reply',
            itemType: 'agentMessage',
            title: '',
            text: 'Before update',
            turnId: 'last',
          ),
        ],
        running: false,
        turns: turns,
        firstTurnId: 'first',
      );
      await t.pumpWidget(
        host(
          const AppSessionScreen(serviceKey: service, threadId: 'watched'),
          api,
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('Opening question'), findsOneWidget);
      expect(find.text('Before update'), findsOneWidget);
      api.readResult = ThreadHistory(
        items: [
          ThreadItem(
            id: 'reply',
            itemType: 'agentMessage',
            title: '',
            text: 'After update',
            turnId: 'last',
          ),
        ],
        running: false,
        turns: turns,
        firstTurnId: 'first',
      );
      api.pushMetaSessionUpdate(
        'watched',
        const SessionFollowUpdate(
          liveness: live,
          items: [],
          historyRevision: 'next',
        ),
      );
      await t.pump();
      await t.pump(const Duration(seconds: 1));
      await t.pumpAndSettle();
      expect(find.text('Opening question'), findsOneWidget);
      expect(find.text('After update'), findsOneWidget);
      expect(find.text('Before update'), findsNothing);
      expect(t.takeException(), isNull);
    },
  );

  for (final recovery in ['heartbeat', 'reconnect']) {
    testWidgets('monitor retries missed history after $recovery', (t) async {
      const service = 'pcx:lb7666:app:default';
      const thread = 'watched';
      final api =
          FakeBridgeApi(
              config: const ConfigInfo(relay: 'relay:7666', hasKey: true),
            )
            ..metadataOnlyFollow = true
            ..appThreadResumeError = StateError(
              'thread already has an active writer',
            );
      await api.appConnect(service, 28080);
      await t.pumpWidget(
        host(
          const AppSessionScreen(serviceKey: service, threadId: thread),
          api,
        ),
      );
      await t.pumpAndSettle();
      final pending = Completer<ThreadHistory>();
      api.pendingReads[thread] = [pending.future];
      final update = SessionFollowUpdate(
        liveness: await api.appSessionLiveness(thread),
        items: const [],
        historyRevision: 'missed',
      );
      api.pushMetaSessionUpdate(thread, update);
      await t.pump();
      await t.pump(const Duration(seconds: 1));
      pending.completeError(StateError('app-server connection closed'));
      await t.pumpAndSettle();
      api.readResult = ThreadHistory(
        items: [
          ThreadItem(
            id: 'recovered',
            itemType: 'agentMessage',
            title: '',
            text: 'Recovered monitor content',
            turnId: 'turn',
          ),
        ],
        running: false,
      );
      if (recovery == 'heartbeat') {
        // A retry must not depend on the rollout changing again.
        api.pushMetaSessionUpdate(thread, update);
      } else {
        await api.appDisconnect(service);
      }
      await t.pump();
      await t.pump(const Duration(seconds: 13));
      await t.pumpAndSettle();
      expect(find.text('Recovered monitor content'), findsOneWidget);
      expect(find.text('连接已断开'), findsNothing);
      await t.pumpWidget(const SizedBox());
    });
  }

  testWidgets('monitor history renders before the ownership probe completes', (
    t,
  ) async {
    const service = 'pcx:lb7666:app:default';
    final ownership = Completer<void>();
    final api =
        FakeBridgeApi(
            config: const ConfigInfo(relay: 'relay:7666', hasKey: true),
          )
          ..metadataOnlyFollow = true
          ..metaFollowGate = ownership.future
          ..appThreadResumeError = StateError(
            'thread already has an active writer',
          )
          ..readResult = ThreadHistory(
            items: [
              ThreadItem(
                id: 'first',
                itemType: 'userMessage',
                title: '',
                text: 'History is ready',
                turnId: 'turn',
              ),
            ],
            running: false,
          );
    await api.appConnect(service, 28080);
    await t.pumpWidget(
      host(
        const AppSessionScreen(serviceKey: service, threadId: 'watched'),
        api,
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('History is ready'), findsOneWidget);
    expect(ownership.isCompleted, isFalse);
    ownership.complete();
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
  });

  testWidgets('leaving a monitored session during a history read is safe', (
    t,
  ) async {
    const service = 'pcx:lb7666:app:default';
    final api =
        FakeBridgeApi(
            config: const ConfigInfo(relay: 'relay:7666', hasKey: true),
          )
          ..metadataOnlyFollow = true
          ..appThreadResumeError = StateError(
            'thread already has an active writer',
          );
    await api.appConnect(service, 28080);
    final pending = Completer<ThreadHistory>();
    api.pendingReads['watched'] = [pending.future];
    await t.pumpWidget(
      host(
        const AppSessionScreen(serviceKey: service, threadId: 'watched'),
        api,
      ),
    );
    for (var i = 0; i < 5; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    await t.pumpWidget(const SizedBox());
    pending.complete(ThreadHistory(items: [], running: false));
    await t.pump(const Duration(seconds: 2));
    expect(t.takeException(), isNull);
  });

  testWidgets('Active writer stays in chat read-only, then can be taken over', (
    t,
  ) async {
    const key = 'pcx:lb7666:app:default';
    final api =
        FakeBridgeApi(
            config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
          )
          ..appThreadResumeError = StateError(
            'thread t-active already has an active writer',
          )
          ..gitDiff = diffFixture('lib/live.dart');
    await api.appConnect(key, 28080);
    api.transcripts['t-active'] = const [
      ThreadItem(
        id: 'remote-progress',
        itemType: 'agentMessage',
        title: '',
        text: 'work from the other client',
      ),
      ThreadItem(
        id: 'remote-compaction',
        itemType: 'contextCompaction',
        title: 'inProgress',
        text: '',
      ),
      ThreadItem(
        id: 'remote-plan',
        itemType: 'plan',
        title: '',
        text: '- [x] inspect\n- [~] implement\n- [ ] test',
      ),
    ];
    api.liveness['t-active'] = const SessionLiveness(
      threadId: 't-active',
      turnState: 'incomplete',
      heldOpen: true,
      safety: 'ownedRunning',
      allowsResume: false,
      requiresTakeover: false,
      holders: [],
    );

    await t.pumpWidget(
      host(
        const AppSessionScreen(
          serviceKey: key,
          threadId: 't-active',
          cwd: r'E:\project',
        ),
        api,
      ),
    );
    // External-writer mode deliberately keeps several animations alive. Use
    // bounded pumps rather than pumpAndSettle, which can never settle them.
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }

    // This is still AppSessionScreen: its chat status, transcript and sessions
    // chrome remain mounted, while only the composer becomes read-only.
    expect(find.byType(AppSessionScreen), findsOneWidget);
    expect(find.text('其他进程运行中'), findsOneWidget);
    expect(find.text('work from the other client'), findsOneWidget);
    // Compaction happens during a turn, so it folds with the rest of the work.
    await openTurnWork(t);
    expect(find.text('正在自动压缩上下文'), findsOneWidget);
    expect(find.byKey(const Key('chat-compaction-progress')), findsOneWidget);
    expect(find.byKey(const Key('turn-progress-panel')), findsOneWidget);
    expect(find.byKey(const Key('turn-progress-summary')), findsOneWidget);
    expect(find.text('第 2 / 3 步'), findsOneWidget);
    expect(find.text('inspect'), findsWidgets);
    expect(find.text('implement'), findsWidgets);
    expect(find.text('test'), findsWidgets);
    expect(find.text('只读 — 其他客户端正在使用此会话'), findsOneWidget);
    expect(find.byKey(const Key('composer-input')), findsNothing);
    expect(find.byKey(const Key('chat-read-only-action')), findsOneWidget);
    expect(find.byKey(const Key('chat-external-diff-action')), findsOneWidget);
    expect(
      find.byKey(const Key('chat-external-output-indicator')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('chat-status-running-pulse')), findsOneWidget);
    final selectedConversation = find.byKey(const Key('conv-tile-t-active'));
    expect(
      find.descendant(
        of: selectedConversation,
        matching: find.byType(PulsingDot),
      ),
      findsOneWidget,
    );
    expect(find.text('进行中'), findsOneWidget);
    expect(find.text('会话'), findsOneWidget);
    expect(api.metaSessionEventSubscriptions, 1);

    // The working-tree diff remains directly reviewable without taking over.
    await t.tap(find.byKey(const Key('chat-external-diff-action')));
    for (var i = 0; i < 4; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(find.textContaining('live.dart'), findsWidgets);
    await t.tap(find.byKey(const Key('review-close')));
    for (var i = 0; i < 4; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }

    const running = SessionLiveness(
      threadId: 't-active',
      turnState: 'incomplete',
      heldOpen: true,
      safety: 'ownedRunning',
      allowsResume: false,
      requiresTakeover: false,
      holders: [],
    );
    final liveItems = [
      ThreadItem(
        id: 'remote-progress',
        itemType: 'agentMessage',
        title: '',
        text: 'work from the other client',
      ),
      ThreadItem(
        id: 'remote-progress-2',
        itemType: 'agentMessage',
        title: '',
        text: 'new progress from subscription',
      ),
      ThreadItem(
        id: 'remote-command',
        itemType: 'commandExecution',
        title: 'cargo test',
        text: 'all tests passed',
      ),
      ThreadItem(
        id: 'remote-edit',
        itemType: 'fileChange',
        diff: diffFixture('lib/live.dart'),
        title: 'lib/live.dart',
        text: '''--- a/lib/live.dart
+++ b/lib/live.dart
@@ -1 +1 @@
-old
+new
''',
      ),
      ThreadItem(
        id: 'remote-plan',
        itemType: 'plan',
        title: '',
        text: '- [x] inspect\n- [x] implement\n- [~] test',
      ),
    ];
    api.pushMetaSessionUpdate(
      't-active',
      SessionFollowUpdate(liveness: running, items: liveItems),
    );
    await t.pump();
    await t.pump(const Duration(milliseconds: 100));
    // This prose has a command and a file change AFTER it, so it is the agent
    // narrating what it is about to do — a preamble, which folds with the work
    // rather than standing above it as the answer.
    await openTurnWork(t);
    // Rendered as markdown inside the fold, hence `findRichText`.
    expect(
      find.textContaining('new progress from subscription', findRichText: true),
      findsWidgets,
    );
    expect(find.text('cargo test'), findsOneWidget);
    expect(find.textContaining('live.dart'), findsWidgets);
    expect(find.text('第 3 / 3 步'), findsOneWidget);
    expect(find.byKey(const Key('turn-progress-panel')), findsOneWidget);
    expect(find.byKey(const Key('turn-progress-diff')), findsOneWidget);
    expect(find.text('1 个文件有变更'), findsWidgets);

    // A stream update flips the action immediately when the other turn ends.
    api.pushMetaSessionUpdate(
      't-active',
      SessionFollowUpdate(
        liveness: SessionLiveness(
          threadId: 't-active',
          turnState: 'completed',
          heldOpen: true,
          safety: 'ownedIdle',
          allowsResume: true,
          requiresTakeover: true,
          holders: [],
        ),
        items: liveItems,
      ),
    );
    await t.pumpAndSettle();
    expect(find.byType(AppSessionScreen), findsOneWidget);
    expect(
      find.byKey(const Key('chat-external-output-indicator')),
      findsNothing,
    );
    expect(
      find.descendant(
        of: selectedConversation,
        matching: find.byType(PulsingDot),
      ),
      findsNothing,
    );
    expect(find.byKey(const Key('chat-takeover-action')), findsOneWidget);
    expect(find.text('强制接管'), findsOneWidget);
    expect(find.text('被其他进程占用'), findsOneWidget);
    expect(find.byKey(const Key('turn-progress-summary')), findsNothing);

    // Confirming takeover resumes in place; it must not navigate away from the
    // chat route or leave the user stranded in a separate viewer.
    api.appThreadResumeError = null;
    await t.tap(find.byKey(const Key('chat-takeover-action')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('takeover-dialog')), findsOneWidget);
    await t.tap(find.byKey(const Key('takeover-confirm')));
    await t.pumpAndSettle();
    expect(api.lastMetaResumedKey, key);
    expect(api.lastMetaResumedThread, 't-active');
    expect(find.byType(AppSessionScreen), findsOneWidget);
    expect(find.byKey(const Key('composer-input')), findsOneWidget);

    await t.pumpWidget(const SizedBox());
  });
}
