part of '../app_session_test.dart';

/// Sending, stopping and queueing turns, a new conversation's first send, and
/// answering approvals and questions.
void _registerTurns() {
  testWidgets('composer starts compact and remembers a resized input height', (
    t,
  ) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'relay:7666', hasKey: true),
    );
    await api.appConnect('pcx:lb7666:app:default', 28080);
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(390, 844);
    addTearDown(t.view.reset);
    await t.pumpWidget(
      host(const AppSessionScreen(serviceKey: 'pcx:lb7666:app:default'), api),
    );
    await t.pumpAndSettle();
    final input = find.byKey(const Key('composer-input-area'));
    expect(t.getSize(input).height, 32);
    await t.drag(
      find.byKey(const Key('composer-resize-handle')),
      const Offset(0, -90),
    );
    await t.pumpAndSettle();
    final height = t.getSize(input).height;
    expect(height, greaterThan(90));
    final container = ProviderScope.containerOf(t.element(input));
    expect(container.read(uiPrefsProvider).valueOrNull?.composerHeight, height);

    final field = find.byKey(const Key('composer-input'));
    await t.enterText(field, List.filled(10, 'A multiline draft').join('\n'));
    await t.pumpAndSettle();
    expect(t.getSize(input).height, greaterThan(height));
    await t.tap(find.byKey(const Key('send-btn')));
    await t.pumpAndSettle();
    expect(t.widget<TextField>(field).controller!.text, isEmpty);
    expect(t.getSize(input).height, height);
    expect(container.read(uiPrefsProvider).valueOrNull?.composerHeight, height);
    expect(t.takeException(), isNull);
  });

  testWidgets('App session sends a turn and renders the streamed reply', (
    t,
  ) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
    );
    await api.appConnect('pcx:lb7666:app:default', 28080);
    // Narrow so the sessions pane is a hidden drawer — the new session's preview
    // (also "hello") then can't collide with the transcript bubble below.
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(400, 800);
    addTearDown(t.view.reset);
    await t.pumpWidget(
      host(const AppSessionScreen(serviceKey: 'pcx:lb7666:app:default'), api),
    );
    await t.pumpAndSettle();

    // A brand-new conversation shows the guidance view (not a bare hint).
    expect(find.byKey(const Key('project-switcher-btn')), findsOneWidget);

    await t.enterText(find.byType(TextField), 'hello');
    await t.pump(); // let the send button enable for the non-empty input
    await t.tap(find.byKey(const Key('send-btn')));
    await t.pumpAndSettle();

    // User bubble (plain Text) + the app bar, which titles the conversation
    // with its preview — the same text. The agent reply renders as Markdown
    // (RichText), so match with findRichText.
    expect(find.text('hello'), findsNWidgets(2));
    expect(
      find.textContaining('echo: hello', findRichText: true),
      findsOneWidget,
    );
  });

  testWidgets('composer fits a 360 px phone with 44 px targets and a '
      'readable model label', (t) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
    );
    await api.appConnect('pcx:lb7666:app:default', 28080);
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(360, 780); // a small phone
    addTearDown(t.view.reset);
    await t.pumpWidget(
      host(const AppSessionScreen(serviceKey: 'pcx:lb7666:app:default'), api),
    );
    await t.pumpAndSettle();

    // Everything the composer offers is on screen at once — no expand toggle,
    // nothing pushed off the right edge.
    for (final k in ['attach-menu-btn', 'permission-chip', 'model-chip']) {
      final rect = t.getRect(find.byKey(Key(k)));
      expect(rect.right, lessThanOrEqualTo(360.0), reason: k);
      expect(rect.height, greaterThanOrEqualTo(44.0), reason: k);
    }
    final send = t.getRect(find.byKey(const Key('send-btn')));
    expect(send.right, lessThanOrEqualTo(360.0));
    // The permission chip shares the attach and send line; the model chip
    // shares it too, or takes the line above where its label would not fit
    // beside them, never squeezed to its icon.
    final permission = t.getRect(find.byKey(const Key('permission-chip')));
    expect(permission.center.dy, closeTo(send.center.dy, 1));
    final model = t.getRect(find.byKey(const Key('model-chip')));
    expect(
      (model.center.dy - send.center.dy).abs() < 1 || model.bottom <= send.top,
      isTrue,
      reason: 'model chip beside or above the toolbar: $model',
    );
    final label = find.descendant(
      of: find.byKey(const Key('model-chip')),
      matching: find.text('默认模型'),
    );
    expect(label, findsOneWidget);
    expect(
      t.renderObject<RenderParagraph>(label).didExceedMaxLines,
      isFalse,
      reason: 'model label whole',
    );
    expect(t.takeException(), isNull); // no RenderFlex overflow
  });

  testWidgets('the attachment menu holds all three sources', (t) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
    );
    await api.appConnect('pcx:lb7666:app:default', 28080);
    await t.pumpWidget(
      host(const AppSessionScreen(serviceKey: 'pcx:lb7666:app:default'), api),
    );
    await t.pumpAndSettle();

    await t.tap(find.byKey(const Key('attach-menu-btn')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('attach-btn')), findsOneWidget);
    expect(find.byKey(const Key('attach-file-btn')), findsOneWidget);
    // Mobile now has a native Save As dialog too.
    expect(find.byKey(const Key('host-files-btn')), findsOneWidget);
  });

  testWidgets("A new conversation ignores another thread's events", (t) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
    );
    await api.appConnect('pcx:lb7666:app:default', 28080);
    // A brand-new conversation: no thread id until the first turn starts.
    await t.pumpWidget(
      host(const AppSessionScreen(serviceKey: 'pcx:lb7666:app:default'), api),
    );
    await t.pumpAndSettle();

    // The app session is shared and another thread's turn may still be
    // streaming; its events must not be absorbed into the blank conversation.
    api.pushEvent(
      'pcx:lb7666:app:default',
      const AppEvent(
        kind: 'item/agentMessage/delta',
        threadId: 'other-thread',
        itemId: 'x1',
        itemType: 'agentMessage',
        text: 'not mine',
        raw: '{}',
      ),
    );
    await t.pumpAndSettle();
    // Still the new-session guidance (the foreign event was dropped, no items).
    expect(find.byKey(const Key('project-switcher-btn')), findsOneWidget);
    expect(find.textContaining('not mine', findRichText: true), findsNothing);
  });

  testWidgets('A new conversation inherits the last-picked permission mode', (
    t,
  ) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
    );
    await api.appConnect('pcx:lb7666:app:default', 28080);
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(1200, 900); // wide → left pane inline
    addTearDown(t.view.reset);
    await t.pumpWidget(
      host(const AppSessionScreen(serviceKey: 'pcx:lb7666:app:default'), api),
    );
    await t.pumpAndSettle();

    // The default permission mode is "替我审批" (auto review). Switch it to "只读".
    await t.tap(find.byKey(const Key('permission-chip')));
    await t.pumpAndSettle();
    await t.tap(find.text('只读'));
    await t.pumpAndSettle();
    expect(find.text('只读'), findsOneWidget); // the pill now reads read-only

    // Start a brand-new conversation: it inherits the read-only mode the user
    // last chose instead of resetting to the auto-review default.
    await t.tap(find.byKey(const Key('new-conversation-btn')));
    await t.pumpAndSettle();
    expect(find.text('只读'), findsOneWidget);
    expect(find.text('替我审批'), findsNothing);
  });

  testWidgets('Empty-state title is the project switcher', (t) async {
    final nowS = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
    );
    await api.appConnect('pcx:lb7666:app:default', 28080);
    api.appThreads.addAll([
      ThreadMeta(
        id: 'a1',
        preview: 'a',
        cwd: '/work/alpha',
        updatedAt: nowS - 60,
      ),
      ThreadMeta(
        id: 'b1',
        preview: 'b',
        cwd: '/work/beta',
        updatedAt: nowS - 600,
      ),
    ]);
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(1200, 900);
    addTearDown(t.view.reset);
    await t.pumpWidget(
      host(
        const AppSessionScreen(
          serviceKey: 'pcx:lb7666:app:default',
          cwd: '/work/alpha',
        ),
        api,
      ),
    );
    await t.pumpAndSettle();

    // The headline names the project inline, and that name IS the trigger.
    expect(find.text('alpha'), findsWidgets);
    await t.tap(find.byKey(const Key('project-switcher-btn')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('project-menu-search')), findsOneWidget);
    expect(find.text('不在项目中工作'), findsOneWidget); // workOutsideProject (zh)
    expect(find.byKey(const Key('project-menu-new')), findsOneWidget);

    // Switching project retargets the conversation that hasn't started yet.
    await t.tap(find.byKey(const Key('project-menu-item-/work/beta')));
    await t.pumpAndSettle();
    expect(find.text('beta'), findsWidgets);
  });

  testWidgets('The composer card takes a text cursor and focuses on click', (
    t,
  ) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
    );
    await api.appConnect('pcx:lb7666:app:default', 28080);
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(1200, 900); // wide → desktop composer
    addTearDown(t.view.reset);
    await t.pumpWidget(
      host(const AppSessionScreen(serviceKey: 'pcx:lb7666:app:default'), api),
    );
    await t.pumpAndSettle();

    // The padding around the field is part of the input, not dead chrome: it
    // shows a text cursor and clicking it focuses the field.
    final field = find.byKey(const Key('composer-input'));
    final card = find
        .ancestor(of: field, matching: find.byType(MouseRegion))
        .last;
    expect(t.widget<MouseRegion>(card).cursor, SystemMouseCursors.text);

    expect(t.widget<TextField>(field).focusNode!.hasFocus, isFalse);
    // Tap the card's own padding below the field, clear of the field, the
    // resize edge along the top and the button row.
    final area = t.getRect(find.byKey(const Key('composer-input-area')));
    await t.tapAt(Offset(area.center.dx, area.bottom + 3));
    await t.pumpAndSettle();
    expect(t.widget<TextField>(field).focusNode!.hasFocus, isTrue);
  });

  testWidgets('App session answers an approval prompt interactively', (
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

    // Server pushes an approval request (carries a request id).
    api.pushEvent(
      'pcx:lb7666:app:default',
      const AppEvent(
        kind: 'execCommandApproval',
        requestId: '7',
        raw: '{"command":["ls"]}',
      ),
    );
    await t.pumpAndSettle();
    expect(find.byKey(const Key('approval-card')), findsOneWidget);

    await t.tap(find.byKey(const Key('approve-btn')));
    await t.pumpAndSettle();
    expect(api.lastApprovalDecision, 'accept');
    expect(find.byKey(const Key('approval-card')), findsNothing);
  });

  testWidgets('request_user_input renders an interactive question card, not an '
      'approval prompt', (t) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
    );
    await api.appConnect('pcx:lb7666:app:default', 28080);
    await t.pumpWidget(
      host(const AppSessionScreen(serviceKey: 'pcx:lb7666:app:default'), api),
    );
    await t.pumpAndSettle();

    // The model asks a structured multiple-choice question (NOT a command to
    // approve). It must render as an answerable question, not 智能体请求执行命令.
    api.pushEvent(
      'pcx:lb7666:app:default',
      const AppEvent(
        kind: 'item/tool/requestUserInput',
        requestId: '9',
        raw:
            '{"questions":[{"id":"theme","header":"题旨","question":"主题落在哪一类？",'
            '"isOther":false,"isSecret":false,"options":['
            '{"label":"山水抒怀","description":"d1"},'
            '{"label":"怀古咏史","description":"d2"}]}]}',
      ),
    );
    await t.pumpAndSettle();

    expect(find.byKey(const Key('user-input-card')), findsOneWidget);
    expect(find.byKey(const Key('approval-card')), findsNothing);
    expect(find.text('主题落在哪一类？'), findsOneWidget);
    expect(find.text('山水抒怀'), findsOneWidget);

    // Pick an option and submit → the answer is sent in the protocol shape.
    await t.tap(find.text('山水抒怀'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('user-input-submit')));
    await t.pumpAndSettle();
    expect(api.lastUserInputAnswers, '{"theme":["山水抒怀"]}');
    expect(find.byKey(const Key('user-input-card')), findsNothing);
  });

  testWidgets('request_user_input with no options renders an answerable '
      'free-text field', (t) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
    );
    await api.appConnect('pcx:lb7666:app:default', 28080);
    await t.pumpWidget(
      host(const AppSessionScreen(serviceKey: 'pcx:lb7666:app:default'), api),
    );
    await t.pumpAndSettle();

    // A question with no options must stay answerable as free text (not a card
    // with a permanently-disabled Submit).
    api.pushEvent(
      'pcx:lb7666:app:default',
      const AppEvent(
        kind: 'item/tool/requestUserInput',
        requestId: '9',
        raw:
            '{"questions":[{"id":"title","header":"标题","question":"取个标题？",'
            '"isOther":false,"isSecret":false,"options":[]}]}',
      ),
    );
    await t.pumpAndSettle();
    expect(find.byKey(const Key('user-input-card')), findsOneWidget);

    final field = find.descendant(
      of: find.byKey(const Key('user-input-card')),
      matching: find.byType(TextField),
    );
    expect(field, findsOneWidget);
    await t.enterText(field, '春日');
    await t.pump();
    await t.tap(find.byKey(const Key('user-input-submit')));
    await t.pumpAndSettle();
    expect(api.lastUserInputAnswers, '{"title":["春日"]}');
  });

  testWidgets('App session surfaces a turn failure with retry', (t) async {
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

    api.pushEvent(
      'pcx:lb7666:app:default',
      const AppEvent(
        kind: 'turn/failed',
        threadId: 't1',
        text: 'model overloaded',
        raw: '{}',
      ),
    );
    await t.pumpAndSettle();
    expect(find.byKey(const Key('session-error')), findsOneWidget);
    expect(find.text('model overloaded'), findsOneWidget);
  });

  testWidgets('The new-session project selector disappears after the first send', (
    t,
  ) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
    );
    await api.appConnect('pcx:lb7666:app:default', 28080);
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(1200, 900); // wide → desktop composer
    addTearDown(t.view.reset);
    await t.pumpWidget(
      host(
        const AppSessionScreen(
          serviceKey: 'pcx:lb7666:app:default',
          cwd: '/work/alpha',
        ),
        api,
      ),
    );
    await t.pumpAndSettle();

    // The empty view has one project selector, without a duplicate composer chip.
    expect(find.byKey(const Key('project-switcher-btn')), findsOneWidget);
    expect(find.byKey(const Key('composer-project-chip')), findsNothing);

    await t.enterText(find.byKey(const Key('composer-input')), 'hello');
    await t.pump();
    await t.tap(find.byKey(const Key('send-btn')));
    await t.pumpAndSettle();

    // Once the thread exists the cwd is fixed, so the chip would be a label you
    // can't act on — and the sidebar already heads the project.
    expect(find.byKey(const Key('composer-project-chip')), findsNothing);
    // The host chip stays: where the turn RUNS is the one fact only the
    // composer reports, and it isn't repeated in the sidebar.
    expect(find.byKey(const Key('composer-host-chip')), findsOneWidget);
  });

  testWidgets('New conversation applies the chosen permission mode', (t) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
    );
    await api.appConnect('pcx:lb7666:app:default', 28080);
    await t.pumpWidget(
      host(const AppSessionScreen(serviceKey: 'pcx:lb7666:app:default'), api),
    );
    await t.pumpAndSettle();

    // Default mode = Auto → on-request / workspace-write.
    await t.enterText(find.byType(TextField), 'hi');
    await t.pump(); // let the send button enable for the non-empty input
    await t.tap(find.byKey(const Key('send-btn')));
    await t.pumpAndSettle();
    expect(api.lastApproval, 'on-request');
    expect(api.lastSandbox, 'workspace-write');
  });

  testWidgets('Stop button interrupts the running turn with its turn id', (
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
          threadId: 't1',
        ),
        api,
      ),
    );
    await t.pumpAndSettle();

    // The server starts a turn carrying a turn id; the stop button appears.
    // A running turn animates the typing indicator forever, so pump one frame
    // rather than settling.
    api.pushEvent(
      'pcx:lb7666:app:default',
      const AppEvent(
        kind: 'turn/started',
        threadId: 't1',
        raw: '{"turnId":"turn-42"}',
      ),
    );
    await t.pump(); // deliver the broadcast event
    await t.pump(); // build the resulting frame
    expect(find.byKey(const Key('stop-btn')), findsOneWidget);

    // Tapping stop sends turn/interrupt with the captured turn id (the server
    // rejects an interrupt that omits it).
    await t.tap(find.byKey(const Key('stop-btn')));
    await t.pump();
    expect(api.interrupted, isTrue);
    expect(api.lastInterruptTurnId, 'turn-42');
  });

  testWidgets('Stop works for a thread already running when opened', (t) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
    );
    await api.appConnect('pcx:lb7666:app:default', 28080);
    // Resumed mid-turn: history.running=true, but the UI never saw turn/started
    // so it has no turn id. Stop must still fire (the engine supplies the id).
    api.readResult = const ThreadHistory(items: [], running: true);

    await t.pumpWidget(
      host(
        const AppSessionScreen(
          serviceKey: 'pcx:lb7666:app:default',
          threadId: 't1',
        ),
        api,
      ),
    );
    await t.pump(); // run the resume future
    await t
        .pump(); // build with _streaming=true (don't settle: typing animates)

    expect(find.byKey(const Key('stop-btn')), findsOneWidget);
    await t.tap(find.byKey(const Key('stop-btn')));
    await t.pump();
    expect(api.interrupted, isTrue);
    expect(api.lastInterruptTurnId, isNull); // UI had none; engine falls back
  });

  testWidgets('Stopping a turn shows a "stopped" marker in the transcript', (
    t,
  ) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
    );
    await api.appConnect('pcx:lb7666:app:default', 28080);
    // Opened mid-turn: streaming, stop button available.
    api.readResult = const ThreadHistory(items: [], running: true);

    await t.pumpWidget(
      host(
        const AppSessionScreen(
          serviceKey: 'pcx:lb7666:app:default',
          threadId: 't1',
        ),
        api,
      ),
    );
    await t.pump(); // run resume
    await t.pump(); // build with _streaming=true

    await t.tap(find.byKey(const Key('stop-btn')));
    await t.pump();
    expect(api.interrupted, isTrue);

    // The server ends the aborted turn; a "stopped" marker appears (and no
    // error banner).
    api.pushEvent(
      'pcx:lb7666:app:default',
      const AppEvent(kind: 'turn/completed', threadId: 't1', raw: '{}'),
    );
    await t.pump();
    await t.pump();
    expect(find.text('已停止'), findsOneWidget); // turnStopped (zh)
    expect(find.byKey(const Key('session-error')), findsNothing);
  });

  group('Esc state machine + message queue (codex-cli parity)', () {
    const svc = 'pcx:lb7666:app:default';

    // Run a test body with a desktop target forced (registers the Esc/paste key
    // handler). Reset inside the body — not addTearDown — so the framework's
    // debug-var invariant check passes.
    Future<void> onDesktop(Future<void> Function() body) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await body();
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    }

    // Mount a desktop session sitting on a running turn with NO output yet:
    // sends "first", and with autoCompleteTurn=false the fake emits only
    // turn/started — the exact state Esc "undoes".
    Future<FakeBridgeApi> pumpStreaming(WidgetTester t) async {
      final api = FakeBridgeApi(
        config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
      )..autoCompleteTurn = false;
      await api.appConnect(svc, 28080);
      await t.pumpWidget(
        host(const AppSessionScreen(serviceKey: svc, threadId: 't1'), api),
      );
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const Key('composer-input')), 'first');
      await t.testTextInput.receiveAction(TextInputAction.send);
      await t.pump();
      return api;
    }

    String composerText(WidgetTester t) => t
        .widget<TextField>(find.byKey(const Key('composer-input')))
        .controller!
        .text;

    // Ensure the composer is focused (the key handler requires it), then Esc.
    Future<void> pressEsc(WidgetTester t) async {
      await t.tap(find.byKey(const Key('composer-input')));
      await t.pump();
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pump();
    }

    Future<void> queue(WidgetTester t, String text) async {
      await t.enterText(find.byKey(const Key('composer-input')), text);
      await t.testTextInput.receiveAction(TextInputAction.send);
      await t.pump();
    }

    void pushDelta(FakeBridgeApi api) => api.pushEvent(
      svc,
      const AppEvent(
        kind: 'item/agentMessage/delta',
        threadId: 't1',
        itemId: 'a1',
        itemType: 'agentMessage',
        text: 'thinking…',
        raw: '{}',
      ),
    );

    void pushCompleted(FakeBridgeApi api) => api.pushEvent(
      svc,
      const AppEvent(kind: 'turn/completed', threadId: 't1', raw: '{}'),
    );

    testWidgets('Esc before any output undoes the send (restore, no marker)', (
      t,
    ) async {
      await onDesktop(() async {
        final api = await pumpStreaming(t);
        expect(find.byKey(const Key('stop-btn')), findsOneWidget);
        expect(composerText(t), '');

        await pressEsc(t);

        // Interrupted, the message is back in the box, and it was NOT resent.
        expect(api.interrupted, isTrue);
        expect(composerText(t), 'first');
        expect(api.turnStartCount, 1);

        // The aborted turn ends without a "stopped" marker — this was an undo.
        pushCompleted(api);
        await t.pumpAndSettle();
        expect(find.text('已停止'), findsNothing);
      });
    });

    testWidgets('Esc after output interrupts the turn (no restore, marker)', (
      t,
    ) async {
      await onDesktop(() async {
        final api = await pumpStreaming(t);
        pushDelta(api); // the model began replying → output has started
        await t.pump();

        await pressEsc(t);

        expect(api.interrupted, isTrue);
        expect(composerText(t), ''); // nothing restored
        expect(api.turnStartCount, 1);

        pushCompleted(api);
        await t.pumpAndSettle();
        expect(find.text('已停止'), findsOneWidget); // stopped marker shown
      });
    });

    testWidgets('a message sent mid-turn queues, then flushes on turn end', (
      t,
    ) async {
      await onDesktop(() async {
        final api = await pumpStreaming(t);
        pushDelta(api);
        await t.pump();

        await queue(t, 'second');
        expect(find.byKey(const Key('queued-0')), findsOneWidget);
        expect(find.text('second'), findsOneWidget);
        expect(api.lastTurnText, 'first'); // not sent yet

        // The running turn ends → the queued message flushes as the next turn.
        pushCompleted(api);
        await t.pump();
        expect(api.lastTurnText, 'second');
        expect(api.turnStartCount, 2);
        expect(find.byKey(const Key('queued-0')), findsNothing);
      });
    });

    testWidgets('Esc with a queued message pops it back before the turn', (
      t,
    ) async {
      await onDesktop(() async {
        final api = await pumpStreaming(t);
        pushDelta(api); // output started: a fall-through Esc would interrupt
        await t.pump();
        await queue(t, 'second');
        expect(find.byKey(const Key('queued-0')), findsOneWidget);

        // First Esc dequeues 'second' back to the composer — turn untouched.
        await pressEsc(t);
        expect(composerText(t), 'second');
        expect(find.byKey(const Key('queued-0')), findsNothing);
        expect(api.interrupted, isFalse);

        // Second Esc (queue now empty) interrupts the still-running turn.
        await pressEsc(t);
        expect(api.interrupted, isTrue);
      });
    });

    testWidgets('the ✕ on a queued chip discards it (not restored)', (t) async {
      await onDesktop(() async {
        final api = await pumpStreaming(t);
        await queue(t, 'second');
        expect(find.byKey(const Key('queued-0')), findsOneWidget);

        await t.tap(find.byKey(const Key('queued-remove-0')));
        await t.pump();
        expect(find.byKey(const Key('queued-0')), findsNothing);
        expect(composerText(t), ''); // discarded, not put back in the box

        // Nothing to flush when the turn ends.
        pushCompleted(api);
        await t.pump();
        expect(api.lastTurnText, 'first');
        expect(api.turnStartCount, 1);
      });
    });
  });
}
