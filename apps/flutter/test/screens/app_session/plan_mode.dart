part of '../app_session_test.dart';

/// Plan mode: offering it, sending it, remembering it and implementing a plan.
void _registerPlanMode() {
  testWidgets('Plan is only offered under advanced settings on mobile', (
    t,
  ) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'relay:7666', hasKey: true),
    );
    await api.appConnect('pcx:lb7666:app:default', 28080);
    await t.pumpWidget(
      host(const AppSessionScreen(serviceKey: 'pcx:lb7666:app:default'), api),
    );
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('model-chip')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('opt-plan')), findsNothing);
    await t.tap(find.byKey(const Key('opt-advanced')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('opt-plan')), findsOneWidget);
  });

  testWidgets('Plan-mode turn ending on prose still offers to implement', (
    t,
  ) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
    );
    await api.appConnect('pcx:lb7666:app:default', 28080);
    // A plan-mode turn: the plan checklist is followed by the model's prose plan
    // summary (目标/约束/假设) — so the plan is NOT the last item. The implement
    // choice must still appear (the bug was keying on "last item is a plan").
    api.readResult = const ThreadHistory(
      items: [
        ThreadItem(
          id: 'u1',
          itemType: 'userMessage',
          title: '',
          text: '规划写一篇古诗文',
        ),
        ThreadItem(id: 'p1', itemType: 'plan', title: '', text: '# Step 1'),
        ThreadItem(
          id: 'a1',
          itemType: 'agentMessage',
          title: '',
          text: '目标：……',
        ),
      ],
      running: false,
      collaborationMode: 'plan',
    );
    await t.pumpWidget(
      host(
        const AppSessionScreen(
          serviceKey: 'pcx:lb7666:app:default',
          threadId: 'thread-plan-prose',
        ),
        api,
      ),
    );
    await t.pumpAndSettle();
    expect(find.byKey(const Key('implement-btn')), findsOneWidget);
  });

  testWidgets('A re-plan after "keep planning" still offers to implement, even '
      'as a plain message', (t) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
    );
    await api.appConnect('pcx:lb7666:app:default', 28080);
    // The user got a plan, tapped "keep planning", steered ("in English"), and
    // the re-plan arrived as a PLAIN agent message (no typed `plan` item — codex
    // sometimes surfaces literal <proposed_plan> tags). The earlier `plan` item
    // now has the steering message after it; the implement choice must still
    // appear (the bug keyed on the last `plan` item).
    api.readResult = const ThreadHistory(
      items: [
        ThreadItem(id: 'u1', itemType: 'userMessage', title: '', text: 'plan'),
        ThreadItem(id: 'p1', itemType: 'plan', title: '', text: '# v1'),
        ThreadItem(
          id: 'u2',
          itemType: 'userMessage',
          title: '',
          text: 'in English',
        ),
        ThreadItem(
          id: 'a1',
          itemType: 'agentMessage',
          title: '',
          text: '<proposed_plan> English plan … </proposed_plan>',
        ),
      ],
      running: false,
      collaborationMode: 'plan',
    );
    await t.pumpWidget(
      host(
        const AppSessionScreen(
          serviceKey: 'pcx:lb7666:app:default',
          threadId: 'thread-replan',
        ),
        api,
      ),
    );
    await t.pumpAndSettle();
    expect(find.byKey(const Key('implement-btn')), findsOneWidget);
  });

  testWidgets('Plan mode toggle is sent with the turn', (t) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
    );
    await api.appConnect('pcx:lb7666:app:default', 28080);
    await t.pumpWidget(
      host(const AppSessionScreen(serviceKey: 'pcx:lb7666:app:default'), api),
    );
    await t.pumpAndSettle();

    // Toggle the plan pill on, then send.
    await turnSetting(t, 'plan');
    await t.pump();
    await t.enterText(find.byType(TextField), 'build a feature');
    await t.pump();
    await t.tap(find.byKey(const Key('send-btn')));
    await t.pumpAndSettle();
    expect(api.lastCollaborationMode, 'plan');
  });

  testWidgets('A finished plan turn offers to implement, and implementing '
      'leaves plan mode', (t) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
    );
    await api.appConnect('pcx:lb7666:app:default', 28080);
    // History ends on a plan item with the turn finished — the signature of a
    // completed plan-mode turn. This is what a resumed (restarted) thread looks
    // like, so the implement choice must persist from it.
    api.readResult = const ThreadHistory(
      items: [
        ThreadItem(
          id: 'u1',
          itemType: 'userMessage',
          title: '',
          text: 'plan a feature',
        ),
        ThreadItem(
          id: 'p1',
          itemType: 'plan',
          title: '',
          text: '# Step 1\n# Step 2',
        ),
      ],
      running: false,
      // The thread is genuinely in plan mode (sticky server setting), so
      // implementing must send "default" to leave it.
      collaborationMode: 'plan',
    );
    await t.pumpWidget(
      host(
        const AppSessionScreen(
          serviceKey: 'pcx:lb7666:app:default',
          threadId: 'thread-9',
        ),
        api,
      ),
    );
    await t.pumpAndSettle();
    // The implement choice is shown (derived from the trailing plan item).
    expect(find.byKey(const Key('implement-btn')), findsOneWidget);

    // Implementing leaves plan mode (sends "default", since it's sticky) and
    // starts a normal turn with the implement prompt.
    await t.tap(find.byKey(const Key('implement-btn')));
    await t.pumpAndSettle();
    expect(api.lastCollaborationMode, 'default');
    expect(api.lastTurnText, '请按上面的计划开始实现。');
    // Once a new turn runs, the plan is no longer trailing → choice goes away.
    expect(find.byKey(const Key('implement-btn')), findsNothing);
  });

  testWidgets('Implement bar survives a screen rebuild via in-memory cache '
      'when the persisted config is unavailable', (t) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
    );
    await api.appConnect('pcx:lb7666:app:default', 28080);

    // Screen A: a new plan-mode conversation. Sending creates thread-0 and
    // records its plan mode in the process-wide static cache.
    await t.pumpWidget(
      host(const AppSessionScreen(serviceKey: 'pcx:lb7666:app:default'), api),
    );
    await t.pumpAndSettle();
    await turnSetting(t, 'plan');
    await t.pump();
    await t.enterText(find.byType(TextField), 'plan it');
    await t.pump();
    await t.tap(find.byKey(const Key('send-btn')));
    await t.pumpAndSettle();

    // Tear the screen down (like going back to the session list) so reopening
    // builds a fresh State, and drop the persisted config to simulate the PUT
    // not having landed yet (the race behind "switching session hides the bar").
    await t.pumpWidget(const SizedBox());
    await t.pumpAndSettle();
    api.threadConfigs.clear();

    // Reopen thread-0. The server exposes no collaborationMode and there is no
    // persisted config, so the implement bar can only come from the static
    // cache populated by the send above.
    api.readResult = const ThreadHistory(
      items: [
        ThreadItem(
          id: 'u1',
          itemType: 'userMessage',
          title: '',
          text: 'plan it',
        ),
        ThreadItem(id: 'p1', itemType: 'plan', title: '', text: '# Step 1'),
      ],
      running: false,
    );
    await t.pumpWidget(
      host(
        const AppSessionScreen(
          serviceKey: 'pcx:lb7666:app:default',
          threadId: 'thread-0',
        ),
        api,
      ),
    );
    await t.pumpAndSettle();
    expect(find.byKey(const Key('implement-btn')), findsOneWidget);
  });

  testWidgets('Plan mode read from the server can be turned off', (t) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
    );
    await api.appConnect('pcx:lb7666:app:default', 28080);
    // A resumed plan-mode thread whose LAST item is a normal reply (not a plan)
    // — the old "last item is plan" heuristic wrongly concluded plan mode was
    // off, so toggling it off never sent "default" and it stayed stuck on.
    api.readResult = const ThreadHistory(
      items: [
        ThreadItem(id: 'u1', itemType: 'userMessage', title: '', text: 'hi'),
        ThreadItem(
          id: 'a1',
          itemType: 'agentMessage',
          title: '',
          text: 'Yes, I am in plan mode.',
        ),
      ],
      running: false,
      collaborationMode: 'plan',
    );
    await t.pumpWidget(
      host(
        const AppSessionScreen(
          serviceKey: 'pcx:lb7666:app:default',
          threadId: 't1',
        ),
        api,
      ),
    );
    await t.pumpAndSettle();

    // The toggle is synced ON from the server mode; tap it OFF and send → the
    // turn carries "default", actually leaving plan mode.
    await turnSetting(t, 'plan'); // currently active
    await t.pump();
    await t.enterText(find.byType(TextField), 'continue');
    await t.pump();
    await t.tap(find.byKey(const Key('send-btn')));
    await t.pumpAndSettle();
    expect(api.lastCollaborationMode, 'default');
  });

  testWidgets('Plan mode is remembered per thread across switching', (t) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
    );
    await api.appConnect('pcx:lb7666:app:default', 28080);
    api.appThreads.addAll(const [
      ThreadMeta(id: 'tA', preview: 'chat A', cwd: '', updatedAt: 0),
      ThreadMeta(id: 'tB', preview: 'chat B', cwd: '', updatedAt: 0),
    ]);
    api.readResult = const ThreadHistory(items: [], running: false);
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(1200, 900); // wide → left pane inline
    addTearDown(t.view.reset);

    await t.pumpWidget(
      host(
        const AppSessionScreen(
          serviceKey: 'pcx:lb7666:app:default',
          threadId: 'tA',
        ),
        api,
      ),
    );
    await t.pumpAndSettle();

    // Enter plan mode in tA and send.
    await turnSetting(t, 'plan');
    await t.pump();
    await t.enterText(find.byType(TextField), 'plan it');
    await t.pump();
    await t.tap(find.byKey(const Key('send-btn')));
    await t.pumpAndSettle();
    expect(api.lastCollaborationMode, 'plan');

    // Switch to tB and back to tA via the pane; tA's plan mode is remembered.
    await t.tap(find.text('chat B'));
    await t.pumpAndSettle();
    await t.tap(find.text('chat A'));
    await t.pumpAndSettle();

    // Turning plan OFF in tA now sends "default" (proving it was restored ON).
    await turnSetting(t, 'plan');
    await t.pump();
    await t.enterText(find.byType(TextField), 'stop planning');
    await t.pump();
    await t.tap(find.byKey(const Key('send-btn')));
    await t.pumpAndSettle();
    expect(api.lastCollaborationMode, 'default');
  });

  testWidgets('A normal multi-step turn does not offer to implement', (
    t,
  ) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
    );
    await api.appConnect('pcx:lb7666:app:default', 28080);
    // A plan item appears mid-turn but the turn ends on a message — not a
    // plan-mode turn, so no implement choice.
    api.readResult = const ThreadHistory(
      items: [
        ThreadItem(id: 'u1', itemType: 'userMessage', title: '', text: 'do it'),
        ThreadItem(id: 'p1', itemType: 'plan', title: '', text: '# Step 1'),
        ThreadItem(id: 'a1', itemType: 'agentMessage', title: '', text: 'done'),
      ],
      running: false,
    );
    await t.pumpWidget(
      host(
        const AppSessionScreen(
          serviceKey: 'pcx:lb7666:app:default',
          threadId: 'thread-10',
        ),
        api,
      ),
    );
    await t.pumpAndSettle();
    expect(find.byKey(const Key('implement-btn')), findsNothing);
  });

  testWidgets('Leaving plan mode sends "default" once, then null thereafter', (
    t,
  ) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
    );
    await api.appConnect('pcx:lb7666:app:default', 28080);
    await t.pumpWidget(
      host(const AppSessionScreen(serviceKey: 'pcx:lb7666:app:default'), api),
    );
    await t.pumpAndSettle();

    // Turn 1: plan mode on → "plan".
    await turnSetting(t, 'plan');
    await t.pump();
    await t.enterText(find.byType(TextField), 'plan it');
    await t.pump();
    await t.tap(find.byKey(const Key('send-btn')));
    await t.pumpAndSettle();
    expect(api.lastCollaborationMode, 'plan');

    // Turn 2: plan mode off → must send "default" to leave sticky plan mode.
    await turnSetting(t, 'plan');
    await t.pump();
    await t.enterText(find.byType(TextField), 'now normally');
    await t.pump();
    await t.tap(find.byKey(const Key('send-btn')));
    await t.pumpAndSettle();
    expect(api.lastCollaborationMode, 'default');

    // Turn 3: still off → null, NOT "default" forever (the _planActive reset).
    await t.enterText(find.byType(TextField), 'and again');
    await t.pump();
    await t.tap(find.byKey(const Key('send-btn')));
    await t.pumpAndSettle();
    expect(api.lastCollaborationMode, isNull);
  });

  testWidgets(
    '"Keep planning" dismisses the implement choice, keeping history',
    (t) async {
      final api = FakeBridgeApi(
        config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
      );
      await api.appConnect('pcx:lb7666:app:default', 28080);
      api.readResult = const ThreadHistory(
        items: [
          ThreadItem(
            id: 'u1',
            itemType: 'userMessage',
            title: '',
            text: 'plan a feature',
          ),
          ThreadItem(id: 'p1', itemType: 'plan', title: '', text: '# Step 1'),
        ],
        running: false,
        // The implement choice only shows for a genuine plan-mode thread (a
        // plan checklist in a normal turn must not trigger it).
        collaborationMode: 'plan',
      );
      await t.pumpWidget(
        host(
          const AppSessionScreen(
            serviceKey: 'pcx:lb7666:app:default',
            threadId: 'thread-11',
          ),
          api,
        ),
      );
      await t.pumpAndSettle();
      expect(find.byKey(const Key('implement-btn')), findsOneWidget);

      // Dismiss → the whole bar (implement + keep-planning) hides, but the
      // conversation timeline is untouched.
      await t.tap(find.text('继续规划'));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('implement-btn')), findsNothing);
      expect(find.text('继续规划'), findsNothing);
      expect(find.text('plan a feature'), findsOneWidget);
    },
  );

  testWidgets('Plan mode with no available model surfaces an error, no turn', (
    t,
  ) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
    )..emptyModelList = true;
    await api.appConnect('pcx:lb7666:app:default', 28080);
    await t.pumpWidget(
      host(const AppSessionScreen(serviceKey: 'pcx:lb7666:app:default'), api),
    );
    await t.pumpAndSettle();

    await turnSetting(t, 'plan');
    await t.pump();
    await t.enterText(find.byType(TextField), 'plan it');
    await t.pump();
    await t.tap(find.byKey(const Key('send-btn')));
    await t.pumpAndSettle();

    // Collaboration mode can't apply without a model, so the turn is refused
    // (nothing sent) and an error is shown instead of silently dropping it.
    expect(find.byKey(const Key('session-error')), findsOneWidget);
    expect(api.lastCollaborationMode, isNull);
    expect(api.lastTurnText, isNull);
  });
}
