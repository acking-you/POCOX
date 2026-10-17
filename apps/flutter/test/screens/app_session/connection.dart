part of '../app_session_test.dart';

/// Opening, resuming and switching conversations, cold-start retries and
/// reconnecting.
void _registerConnection() {
  for (final delayed in ['config', 'models']) {
    testWidgets(
      'history is readable while optional $delayed is still pending',
      (t) async {
        final api = FakeBridgeApi(
          config: const ConfigInfo(relay: 'relay:7666', hasKey: true),
        );
        await api.appConnect('pcx:lb7666:app:default', 28080);
        final gate = Completer<void>();
        if (delayed == 'config') api.configReadGate = gate;
        if (delayed == 'models') api.modelListGate = gate;
        api.readResult = const ThreadHistory(
          items: [
            ThreadItem(
              id: 'answer',
              itemType: 'agentMessage',
              title: '',
              text: 'History already arrived',
            ),
          ],
          running: false,
          model: 'gpt-5.5',
        );
        await t.pumpWidget(
          host(
            const AppSessionScreen(
              serviceKey: 'pcx:lb7666:app:default',
              threadId: 'slow-metadata',
            ),
            api,
          ),
        );
        await t.pumpAndSettle();
        expect(gate.isCompleted, isFalse);
        expect(
          find.textContaining('History already arrived', findRichText: true),
          findsOneWidget,
        );
        await t.enterText(
          find.byKey(const Key('composer-input')),
          'Draft while reading',
        );
        gate.complete();
        await t.pumpAndSettle();
        expect(find.text('Draft while reading'), findsOneWidget);
        expect(t.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'A failed startup listing retries instead of stranding the pane',
    (t) async {
      final nowS = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final api = FakeBridgeApi(
        config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
      );
      await api.appConnect('pcx:lb7666:app:default', 28080);
      api.appThreads.add(
        ThreadMeta(
          id: 'a1',
          preview: 'alpha one',
          cwd: '/work/alpha',
          updatedAt: nowS - 300,
        ),
      );
      // The very first listing fails — the app opened before the host was
      // reachable, or the host restarted underneath it.
      api.failNextThreadList = true;
      t.view.devicePixelRatio = 1.0;
      t.view.physicalSize = const Size(1200, 900);
      addTearDown(t.view.reset);
      await t.pumpWidget(
        host(
          const AppSessionScreen(
            serviceKey: 'pcx:lb7666:app:default',
            home: true,
          ),
          api,
        ),
      );
      await t.pumpAndSettle();
      // Nothing yet: the one shot at listing failed and was swallowed.
      expect(convTiles(), findsNothing);

      // The retry lands and the pane fills itself in. Without it the sidebar
      // stayed empty for the whole session — nothing else re-lists unless the
      // user sends a message.
      await t.pump(const Duration(seconds: 2));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('conv-tile-a1')), findsOneWidget);
      expect(find.text('alpha one'), findsWidgets);
    },
  );

  testWidgets('A failed default-folder seed retries instead of rooting a new '
      'conversation in the wrong folder', (t) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
    );
    await api.appConnect('pcx:lb7666:app:default', 28080);
    api.projectConfigs['pcx:lb7666:app:default'] = const ProjectConfig(
      projectRoots: ['/work'],
      defaultProject: '/work/alpha',
    );
    // The meta tunnel isn't up on the first attempt — the cold-open race.
    api.failNextProjectConfig = true;
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(1200, 900);
    addTearDown(t.view.reset);
    // No threadId and no cwd: a brand-new conversation, which is the only case
    // that seeds a default folder.
    await t.pumpWidget(
      host(
        const AppSessionScreen(
          serviceKey: 'pcx:lb7666:app:default',
          home: true,
        ),
        api,
      ),
    );
    await t.pumpAndSettle();
    // The seed failed, so the folder is still unset ("default folder").
    expect(find.text('alpha'), findsNothing);

    // The retry lands and the conversation adopts the host's default. Without
    // it the chat would silently run in the wrong directory for the whole
    // session — the agent reading and editing files the user never chose.
    await t.pump(const Duration(seconds: 2));
    await t.pumpAndSettle();
    expect(find.text('alpha'), findsWidgets);
  });

  testWidgets('A settled default-folder seed stops retrying', (t) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
    );
    await api.appConnect('pcx:lb7666:app:default', 28080);
    // A host with NO default configured: answering is settled, even though
    // nothing was seeded. Retrying would just ask the same question five times.
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(1200, 900);
    addTearDown(t.view.reset);
    await t.pumpWidget(
      host(
        const AppSessionScreen(
          serviceKey: 'pcx:lb7666:app:default',
          home: true,
        ),
        api,
      ),
    );
    await t.pumpAndSettle();
    final after = api.projectConfigCalls;
    await t.pump(const Duration(seconds: 20));
    await t.pumpAndSettle();
    expect(api.projectConfigCalls, after, reason: 'no retry once answered');
  });

  testWidgets('A reconnect re-lists the sidebar, not just the transcript', (
    t,
  ) async {
    final nowS = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
    );
    await api.appConnect('pcx:lb7666:app:default', 28080);
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(1200, 900);
    addTearDown(t.view.reset);
    await t.pumpWidget(
      host(
        const AppSessionScreen(
          serviceKey: 'pcx:lb7666:app:default',
          home: true,
        ),
        api,
      ),
    );
    await t.pumpAndSettle();
    expect(convTiles(), findsNothing, reason: 'host had nothing to list yet');

    // The host restarts and now HAS history — exactly the case that left the
    // pane empty: the app listed once at startup against a host with no data
    // (or no connection), and nothing re-listed afterwards.
    api.appThreads.add(
      ThreadMeta(
        id: 'a1',
        preview: 'alpha one',
        cwd: '/work/alpha',
        updatedAt: nowS - 300,
      ),
    );

    await api.appDisconnect('pcx:lb7666:app:default');
    // The event stream or health timer notices the dead socket and reconnects.
    await t.pump(const Duration(seconds: 13));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('conv-tile-a1')), findsOneWidget);
  });

  testWidgets(
    'A slow sidebar does not hold a restored conversation reconnecting',
    (t) async {
      const service = 'pcx:lb7666:app:default';
      final api = FakeBridgeApi(
        config: const ConfigInfo(relay: 'relay:7666', hasKey: true),
      );
      await api.appConnect(service, 28080);
      await t.pumpWidget(
        host(const AppSessionScreen(serviceKey: service), api),
      );
      await t.pumpAndSettle();
      final list = Completer<void>();
      api.threadListGate = list.future;
      await api.appDisconnect(service);
      await t.pump();
      await t.pump(const Duration(seconds: 13));
      await t.pumpAndSettle();
      expect(api.appIsConnected(service), isTrue);
      expect(find.text('就绪'), findsOneWidget);
      expect(list.isCompleted, isFalse);
      list.complete();
      await t.pumpAndSettle();
      await t.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'disconnect publishes status and disposed reconnect cannot subscribe',
    (t) async {
      const service = 'pcx:lb7666:app:default';
      final api = FakeBridgeApi(
        config: const ConfigInfo(relay: 'relay:7666', hasKey: true),
      );
      await api.appConnect(service, 28080);
      await t.pumpWidget(
        host(const AppSessionScreen(serviceKey: service), api),
      );
      await t.pumpAndSettle();
      final container = ProviderScope.containerOf(
        t.element(find.byType(AppSessionScreen)),
      );
      final gate = Completer<void>();
      api.appConnectGate = gate.future;
      await api.appDisconnect(service);
      await t.pump();
      expect(container.read(observedDisconnectedProvider), contains(service));
      await t.pumpWidget(const SizedBox());
      gate.complete();
      await t.pump();
      await t.pump(const Duration(seconds: 10));
      expect(t.takeException(), isNull);
      expect(api.appConnectCount, 2);
    },
  );

  testWidgets(
    'reconnect becomes ready before metadata but sending waits for settings',
    (t) async {
      const service = 'pcx:lb7666:app:default';
      final api = FakeBridgeApi(
        config: const ConfigInfo(relay: 'relay:7666', hasKey: true),
      );
      await api.appConnect(service, 28080);
      await t.pumpWidget(
        host(const AppSessionScreen(serviceKey: service, threadId: 't1'), api),
      );
      await t.pumpAndSettle();
      final gate = Completer<void>();
      api.configReadGate = gate;
      await api.appDisconnect(service);
      await t.pump();
      await t.pumpAndSettle();
      expect(find.text('就绪'), findsOneWidget);
      expect(gate.isCompleted, isFalse);
      final container = ProviderScope.containerOf(
        t.element(find.byType(AppSessionScreen)),
      );
      expect(
        container.read(observedDisconnectedProvider),
        isNot(contains(service)),
      );
      await t.enterText(
        find.byKey(const Key('composer-input')),
        'Wait for permissions',
      );
      await t.pump();
      expect(
        t.widget<IconButton>(find.byKey(const Key('send-btn'))).onPressed,
        isNull,
      );
      gate.complete();
      await t.pumpAndSettle();
      expect(
        t.widget<IconButton>(find.byKey(const Key('send-btn'))).onPressed,
        isNotNull,
      );
      await t.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'background recovery waits until foreground then reconnects immediately',
    (t) async {
      const service = 'pcx:lb7666:app:default';
      final api = FakeBridgeApi(
        config: const ConfigInfo(relay: 'relay:7666', hasKey: true),
      );
      await api.appConnect(service, 28080);
      await t.pumpWidget(
        host(const AppSessionScreen(serviceKey: service), api),
      );
      await t.pumpAndSettle();
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await api.appDisconnect(service);
      await t.pump(const Duration(seconds: 13));
      expect(api.appConnectCount, 1);
      final gate = Completer<void>();
      api.appConnectGate = gate.future;
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await t.pump();
      expect(api.appConnectCount, 2);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      gate.complete();
      await t.pumpAndSettle();
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await t.pumpAndSettle();
      expect(find.text('就绪'), findsOneWidget);
      expect(api.appConnectCount, 2);
      await t.pumpWidget(const SizedBox());
    },
  );

  testWidgets('A reconnect stays disconnected when the first RPC times out', (
    t,
  ) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
    );
    const service = 'pcx:lb7666:app:default';
    await api.appConnect(service, 28080);
    await t.pumpWidget(host(const AppSessionScreen(serviceKey: service), api));
    await t.pumpAndSettle();
    api.disconnectOnThreadList = true;
    await api.appDisconnect(service);
    await t.pump();
    await t.pump(const Duration(seconds: 13));
    for (var i = 0; i < 5; i++) {
      await t.pump(const Duration(seconds: 2));
      await t.pump();
    }
    expect(api.appIsConnected(service), isFalse);
    expect(
      find.text('就绪'),
      findsNothing,
      reason: 'an initialize response alone must not restore the ready badge',
    );
    expect(api.appConnectCount, greaterThan(2));
    await t.pumpWidget(const SizedBox.shrink());
    await t.pump(const Duration(seconds: 10));
  });

  testWidgets('Opening an existing thread resumes it before reading', (
    t,
  ) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
    );
    await api.appConnect('pcx:lb7666:app:default', 28080);
    await t.pumpWidget(
      host(
        const AppSessionScreen(
          serviceKey: 'pcx:lb7666:app:default',
          threadId: 'thread-42',
        ),
        api,
      ),
    );
    await t.pumpAndSettle();
    // Must resume (load into session) before read/turn, else "thread not found".
    expect(api.lastResumed, 'thread-42');
  });

  testWidgets('Re-opening an in-flight thread restores history + thinking', (
    t,
  ) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
    );
    await api.appConnect('pcx:lb7666:app:default', 28080);
    // History recovered from disk + a turn still running.
    api.readResult = const ThreadHistory(
      items: [
        ThreadItem(
          id: 'u1',
          itemType: 'userMessage',
          title: '',
          text: 'earlier question',
        ),
      ],
      running: true,
    );
    await t.pumpWidget(
      host(
        const AppSessionScreen(
          serviceKey: 'pcx:lb7666:app:default',
          threadId: 'thread-7',
        ),
        api,
      ),
    );
    // Not pumpAndSettle: the restored typing indicator animates forever.
    await t.pump();
    await t.pump(const Duration(milliseconds: 50));
    // Past message recovered, with independent stop and queue actions.
    expect(find.text('earlier question'), findsOneWidget);
    expect(find.byKey(const Key('stop-btn')), findsOneWidget);
    expect(find.byKey(const Key('send-btn')), findsOneWidget);
  });

  for (final stage in ['resume', 'history']) {
    testWidgets('rapid A B A switching ignores obsolete $stage results', (
      t,
    ) async {
      final api = FakeBridgeApi(
        config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
      );
      await api.appConnect('pcx:lb7666:app:default', 28080);
      api.appThreads.addAll([
        const ThreadMeta(id: 'a', preview: 'chat A', cwd: '', updatedAt: 0),
        const ThreadMeta(id: 'b', preview: 'chat B', cwd: '', updatedAt: 0),
      ]);
      final resume = Completer<void>();
      final history = Completer<ThreadHistory>();
      if (stage == 'resume') api.pendingResumes['a'] = [resume.future];
      if (stage == 'history') api.pendingReads['a'] = [history.future];
      api.readResult = const ThreadHistory(
        items: [
          ThreadItem(
            id: 'fresh',
            itemType: 'agentMessage',
            title: '',
            text: 'fresh transcript',
          ),
        ],
        running: false,
      );
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(1200, 900);
      addTearDown(t.view.reset);
      await t.pumpWidget(
        host(const AppSessionScreen(serviceKey: 'pcx:lb7666:app:default'), api),
      );
      await t.pumpAndSettle();
      await t.tap(find.text('chat A'));
      await t.pump(const Duration(milliseconds: 50));
      await t.tap(find.text('chat B'));
      await t.pumpAndSettle();
      await t.tap(find.text('chat A'));
      await t.pumpAndSettle();
      if (stage == 'resume') {
        resume.complete();
      } else {
        history.complete(
          const ThreadHistory(
            items: [
              ThreadItem(
                id: 'stale',
                itemType: 'agentMessage',
                title: '',
                text: 'obsolete transcript',
              ),
            ],
            running: false,
          ),
        );
      }
      await t.pumpAndSettle();
      expect(
        find.textContaining('fresh transcript', findRichText: true),
        findsOneWidget,
      );
      expect(
        find.textContaining('obsolete transcript', findRichText: true),
        findsNothing,
      );
      expect(
        api.threadReads.where((id) => id == 'a').length,
        stage == 'resume' ? 1 : 2,
      );
      expect(t.takeException(), isNull);
    });
  }
}
