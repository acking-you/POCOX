part of '../app_session_test.dart';

/// The model and reasoning effort: what the server reports and what the next
/// turn sends.
void _registerTurnSettings() {
  group('runtime config visibility', () {
    const key = 'pcx:lb7666:app:default';

    testWidgets('resume adopts the server-reported model + permissions: the '
        'active-model chip and the pills show server truth', (t) async {
      final api = FakeBridgeApi(
        config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
      );
      await api.appConnect(key, 28080);
      // The resume response reported what this thread actually runs with.
      api.readResult = const ThreadHistory(
        items: [],
        running: false,
        model: 'gpt-5',
        modelProvider: 'openai',
        approvalPolicy: 'never',
        sandboxMode: 'danger-full-access',
        reasoningEffort: 'high',
      );
      await t.pumpWidget(
        host(const AppSessionScreen(serviceKey: key, threadId: 'th-1'), api),
      );
      await t.pumpAndSettle();
      // Status bar carries the active-model chip, resolved to its display name.
      final chip = find.byKey(const Key('active-model-chip'));
      expect(chip, findsOneWidget);
      expect(
        find.descendant(of: chip, matching: find.text('GPT-5')),
        findsOneWidget,
      );
      // The permission pill followed the server (never + danger-full-access =
      // 完全放行), not the local default (对话确认).
      expect(find.text('完全放行'), findsOneWidget);
      // The effort pill shows the server's sticky effort.
      expect(find.textContaining('· 高'), findsOneWidget);
      // The details sheet reports snapshot provenance (no live update yet).
      await t.tap(chip);
      await t.pumpAndSettle();
      expect(find.text('运行时配置'), findsOneWidget);
      expect(find.textContaining('来自服务器会话快照'), findsOneWidget);
    });

    testWidgets('a thread/settings/updated notification confirms a switch: '
        'chip, plan state and effort follow the server', (t) async {
      final api = FakeBridgeApi(
        config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
      );
      await api.appConnect(key, 28080);
      api.readResult = const ThreadHistory(items: [], running: false);
      await t.pumpWidget(
        host(const AppSessionScreen(serviceKey: key, threadId: 'th-2'), api),
      );
      await t.pumpAndSettle();
      // Nothing reported yet → no chip (never guess).
      expect(find.byKey(const Key('active-model-chip')), findsNothing);
      api.pushEvent(
        key,
        AppEvent(
          kind: 'thread/settings/updated',
          threadId: 'th-2',
          raw: jsonEncode({
            'threadId': 'th-2',
            'threadSettings': {
              'model': 'gpt-5.5-codex',
              'modelProvider': 'openai',
              'effort': 'xhigh',
              'approvalPolicy': 'never',
              'sandboxPolicy': {'type': 'dangerFullAccess'},
              'collaborationMode': {
                'mode': 'plan',
                'settings': {'model': 'gpt-5.5-codex'},
              },
            },
          }),
        ),
      );
      await t.pumpAndSettle();
      // The chip appears with the server-confirmed model (raw id — it isn't in
      // the cached model list, and a raw id is still truthful)...
      final chip = find.byKey(const Key('active-model-chip'));
      expect(chip, findsOneWidget);
      expect(
        find.descendant(of: chip, matching: find.text('gpt-5.5-codex')),
        findsOneWidget,
      );
      // ...the status chip flips to the server-reported plan mode...
      expect(find.text('计划模式'), findsOneWidget);
      // ...and the effort pill follows the server's sticky effort.
      expect(find.textContaining('· 极高'), findsOneWidget);
      // The details sheet reports live confirmation.
      await t.tap(chip);
      await t.pumpAndSettle();
      expect(find.textContaining('服务器已确认'), findsOneWidget);
    });

    testWidgets('each completed turn is stamped with the model that actually '
        'handled it', (t) async {
      final api = FakeBridgeApi(
        config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
      );
      await api.appConnect(key, 28080);
      t.view.devicePixelRatio = 1.0;
      t.view.physicalSize = const Size(400, 800);
      addTearDown(t.view.reset);
      await t.pumpWidget(host(const AppSessionScreen(serviceKey: key), api));
      await t.pumpAndSettle();
      // Turn 1: the server never reported and nothing explicit was sent → the
      // footnote carries no stamp (honest absence beats a guess).
      await t.enterText(find.byType(TextField), 'hello');
      await t.pump();
      await t.tap(find.byKey(const Key('send-btn')));
      await t.pumpAndSettle();
      expect(find.textContaining('gpt-5.5-codex'), findsNothing);
      // The server then confirms the thread's effective settings...
      final tid = api.appThreads.first.id;
      api.pushEvent(
        key,
        AppEvent(
          kind: 'thread/settings/updated',
          threadId: tid,
          raw: jsonEncode({
            'threadId': tid,
            'threadSettings': {
              'model': 'gpt-5.5-codex',
              'effort': 'high',
              'approvalPolicy': 'on-request',
              'sandboxPolicy': {'type': 'workspaceWrite'},
            },
          }),
        ),
      );
      await t.pumpAndSettle();
      // ...and the next turn's footnote records what handled it. Target the
      // footnote stamp by key — the collapsed composer summary also shows the
      // active model, so a plain text match would be ambiguous.
      await t.enterText(find.byType(TextField), 'again');
      await t.pump();
      await t.tap(find.byKey(const Key('send-btn')));
      await t.pumpAndSettle();
      final stamp = t.widget<Text>(find.byKey(const Key('turn-model-stamp')));
      expect(stamp.data, contains('gpt-5.5-codex'));
      expect(stamp.data, contains('高'));
    });
  });

  testWidgets('Model chip opens a desktop popover with an effort slider', (
    t,
  ) async {
    // The popover is the desktop treatment; a phone keeps the sheet flow.
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
    );
    await api.appConnect('pcx:lb7666:app:default', 28080);
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(1200, 900);
    addTearDown(t.view.reset);
    await t.pumpWidget(
      host(const AppSessionScreen(serviceKey: 'pcx:lb7666:app:default'), api),
    );
    await t.pumpAndSettle();

    await t.tap(find.byKey(const Key('model-chip')));
    await t.pumpAndSettle();
    // Common controls stay on the first level; Plan requires an explicit
    // visit to advanced settings.
    expect(find.byKey(const Key('model-menu-item-gpt-5.5')), findsOneWidget);
    expect(find.byKey(const Key('model-menu-item-gpt-5')), findsOneWidget);
    expect(find.byKey(const Key('effort-steps')), findsOneWidget);
    expect(find.byKey(const Key('plan-toggle-row')), findsNothing);
    expect(find.byKey(const Key('advanced-turn-settings')), findsOneWidget);
    await t.tap(find.byKey(const Key('advanced-turn-settings')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('opt-plan')), findsOneWidget);
    await t.tap(find.byKey(const Key('opt-plan')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('model-chip')));
    await t.pumpAndSettle();

    // Tapping the right end of the stepped selector sets the top level (gpt-5.5
    // advertises low/medium/high/xhigh → xhigh). The label reflects it.
    final steps = t.getRect(find.byKey(const Key('effort-steps')));
    await t.tapAt(Offset(steps.right - 4, steps.center.dy));
    await t.pumpAndSettle();
    expect(find.text('极高'), findsWidgets); // effortXhigh (zh)

    // Picking a model updates the chip without leaving the popover flow.
    await t.tap(find.byKey(const Key('model-menu-item-gpt-5')));
    await t.pumpAndSettle();
    expect(find.textContaining('GPT-5'), findsWidgets);
    // Must be cleared inside the body: the framework's end-of-test invariant
    // check runs before addTearDown callbacks.
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('a long model name ellipsizes instead of overflowing the row', (
    t,
  ) async {
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(360, 760); // a phone-ish viewport
    addTearDown(t.view.reset);
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
    );
    await api.appConnect('pcx:lb7666:app:default', 28080);
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

    // Turn on plan so the chip carries the longest label it ever shows
    // (model · effort · plan) on the narrowest phone.
    await turnSetting(t, 'plan');
    expect(
      t.getRect(find.byKey(const Key('model-chip'))).right,
      lessThanOrEqualTo(360.0),
    );
    expect(t.takeException(), isNull);

    // Common settings stay one tap away; Plan remains in advanced settings.
    await t.tap(find.byKey(const Key('model-chip')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('opt-model')), findsOneWidget);
    expect(find.byKey(const ValueKey('opt-effort')), findsOneWidget);
    expect(find.byKey(const ValueKey('opt-plan')), findsNothing);
    expect(find.byKey(const ValueKey('opt-advanced')), findsOneWidget);
  });

  testWidgets('#2: a thread restores its persisted config on open', (t) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
    );
    await api.appConnect('pcx:lb7666:app:default', 28080);
    api.readResult = const ThreadHistory(items: [], running: false);
    // The host persisted a non-default model for this thread; the server does
    // not restore the model, so without persistence it would reset to default.
    api.threadConfigs['thread-cfg'] = const ThreadConfig(model: 'gpt-5');
    await t.pumpWidget(
      host(
        const AppSessionScreen(
          serviceKey: 'pcx:lb7666:app:default',
          threadId: 'thread-cfg',
        ),
        api,
      ),
    );
    await t.pumpAndSettle();
    // The screen fetched this thread's persisted config and applied the stored
    // model to the composer chip (instead of the default).
    expect(api.lastConfigGetThread, 'thread-cfg');
    expect(find.text('GPT-5'), findsOneWidget);
  });

  testWidgets('Picking a reasoning effort sends it on the next turn', (
    t,
  ) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
    );
    await api.appConnect('pcx:lb7666:app:default', 28080);
    api.readResult = const ThreadHistory(items: [], running: false);
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

    // A fresh turn with no effort picked sends nothing (Auto = model default).
    await t.enterText(find.byType(TextField), 'hi');
    await t.pump();
    await t.tap(find.byKey(const Key('send-btn')));
    await t.pumpAndSettle();
    expect(api.lastReasoningEffort, isNull);

    // Open the effort picker (the chip shows the localized "Effort" label) and
    // choose High; the next turn carries "high". The pills scroll horizontally,
    // so scroll the chip into view before tapping.
    await turnSetting(t, 'effort');
    await t.tap(find.text('高'));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField), 'think hard');
    await t.pump();
    await t.tap(find.byKey(const Key('send-btn')));
    await t.pumpAndSettle();
    expect(api.lastReasoningEffort, 'high');
  });

  testWidgets('Effort picker offers the model-supported levels incl. xhigh', (
    t,
  ) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
    );
    await api.appConnect('pcx:lb7666:app:default', 28080);
    api.readResult = const ThreadHistory(items: [], running: false);
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

    // The default model (gpt-5.5 in the fake) supports low/medium/high/xhigh.
    await turnSetting(t, 'effort');
    expect(find.text('极高'), findsOneWidget); // xhigh is offered
    expect(find.text('最低'), findsNothing); // minimal: not supported by gpt-5.5

    // Pick Extra-high and send → "xhigh" goes on the wire.
    await t.tap(find.text('极高'));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField), 'think harder');
    await t.pump();
    await t.tap(find.byKey(const Key('send-btn')));
    await t.pumpAndSettle();
    expect(api.lastReasoningEffort, 'xhigh');
  });

  testWidgets('Reasoning effort is restored from the thread on resume', (
    t,
  ) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
    );
    await api.appConnect('pcx:lb7666:app:default', 28080);
    api.readResult = const ThreadHistory(
      items: [],
      running: false,
      reasoningEffort: 'high',
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
    // The chip reflects the thread's current effort ("Effort · High").
    expect(find.textContaining('· 高'), findsOneWidget);
  });

  testWidgets('Toggling plan re-asserts the effort instead of wiping it', (
    t,
  ) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
    );
    await api.appConnect('pcx:lb7666:app:default', 28080);
    api.readResult = const ThreadHistory(items: [], running: false);
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

    // Set High and send.
    await turnSetting(t, 'effort');
    await t.tap(find.text('高'));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField), 'one');
    await t.pump();
    await t.tap(find.byKey(const Key('send-btn')));
    await t.pumpAndSettle();
    expect(api.lastReasoningEffort, 'high');

    // Now toggle plan ON (no new effort pick) and send: the collaborationMode
    // turn must still carry "high", not wipe the thread's effort to null.
    await turnSetting(t, 'plan');
    await t.pump();
    await t.enterText(find.byType(TextField), 'two');
    await t.pump();
    await t.tap(find.byKey(const Key('send-btn')));
    await t.pumpAndSettle();
    expect(api.lastCollaborationMode, 'plan');
    expect(api.lastReasoningEffort, 'high');
  });

  testWidgets('A reasoning-effort pick made mid-turn is not reverted (R4)', (
    t,
  ) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
    );
    await api.appConnect('pcx:lb7666:app:default', 28080);
    api.readResult = const ThreadHistory(items: [], running: false);
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

    // Pick xhigh, then send a turn that we hold in-flight via the gate.
    await turnSetting(t, 'effort');
    await t.tap(find.text('极高'));
    await t.pumpAndSettle();
    api.turnStartGate = Completer<void>();
    await t.enterText(find.byType(TextField), 'one');
    await t.pump();
    await t.tap(find.byKey(const Key('send-btn')));
    await t.pump(); // _send is now suspended awaiting the gate (turn in flight)
    expect(api.lastReasoningEffort, 'xhigh');

    // While the turn is in flight, change effort to High.
    await turnSetting(t, 'effort');
    await t.tap(find.text('高'));
    await t.pumpAndSettle();

    // Let the in-flight turn finish. Post-turn reconciliation must NOT revert the
    // mid-turn pick (the R4 guard keeps the pending effort = High, not xhigh).
    api.turnStartGate!.complete();
    await t.pumpAndSettle();
    api.turnStartGate = null;

    // The next turn carries the mid-turn pick, proving it survived.
    await t.enterText(find.byType(TextField), 'two');
    await t.pump();
    await t.tap(find.byKey(const Key('send-btn')));
    await t.pumpAndSettle();
    expect(api.lastReasoningEffort, 'high');
  });

  testWidgets('An unsent effort pick does not leak across threads', (t) async {
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

    // Pick High on tA but DON'T send.
    await turnSetting(t, 'effort');
    await t.tap(find.text('高'));
    await t.pumpAndSettle();
    expect(find.textContaining('· 高'), findsOneWidget);

    // Switch to tB and send: the unsent High pick must NOT carry over.
    await t.tap(find.text('chat B'));
    await t.pumpAndSettle();
    expect(find.textContaining('· 高'), findsNothing);
    await t.enterText(find.byType(TextField), 'hi from B');
    await t.pump();
    await t.tap(find.byKey(const Key('send-btn')));
    await t.pumpAndSettle();
    expect(api.lastReasoningEffort, isNull);
  });
}
