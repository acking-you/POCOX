part of '../app_session_test.dart';

/// A turn's work: folded activity, tool cards, plans, file changes and
/// compactions.
void _registerWork() {
  group("a turn's work folds behind one row", () {
    /// Mount a thread whose history is one turn: a question, [work] items, and
    /// an answer — the shape a real turn arrives in.
    Future<FakeBridgeApi> openThread(
      WidgetTester t, {
      required List<ThreadItem> work,
      int? durationMs = 151000,
    }) async {
      ThreadItem stamp(ThreadItem i) => ThreadItem(
        id: i.id,
        itemType: i.itemType,
        title: i.title,
        text: i.text,
        turnId: 'turn-1',
        turnDurationMs: durationMs,
      );
      final api =
          FakeBridgeApi(
              config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
            )
            ..readResult = ThreadHistory(
              items: [
                stamp(
                  const ThreadItem(
                    id: 'u1',
                    itemType: 'userMessage',
                    title: '',
                    text: 'why does edge fail?',
                  ),
                ),
                ...work.map(stamp),
                stamp(
                  const ThreadItem(
                    id: 'a1',
                    itemType: 'agentMessage',
                    title: '',
                    text: 'It is the taskbar shortcut, not Edge.',
                  ),
                ),
              ],
              running: false,
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
      return api;
    }

    const alternating = [
      ThreadItem(
        id: 'c1',
        itemType: 'commandExecution',
        title: 'pwsh -Command x',
        text: 'out',
      ),
      ThreadItem(id: 'r1', itemType: 'reasoning', title: 'checking', text: ''),
      ThreadItem(
        id: 'c2',
        itemType: 'commandExecution',
        title: 'pwsh -Command y',
        text: 'out',
      ),
      ThreadItem(id: 's1', itemType: 'webSearch', title: 'taskbar', text: ''),
    ];

    testWidgets('an alternating run folds into ONE row, not four', (t) async {
      // This is the bug the fold exists for. Grouping used to merge only
      // same-type neighbours, and a real turn alternates — so four rows of tool
      // machinery sat between the question and its answer, and nothing collapsed.
      await openThread(t, work: alternating);

      expect(find.byKey(const Key('turn-work-toggle')), findsOneWidget);
      for (final hidden in [
        'pwsh -Command x',
        'pwsh -Command y',
        'checking',
        'taskbar',
      ]) {
        expect(find.text(hidden), findsNothing, reason: '$hidden must fold');
      }
    });

    testWidgets('the answer stays visible while the work is folded', (t) async {
      // The point is to surface the answer, not to hide the turn.
      await openThread(t, work: alternating);
      expect(
        find.textContaining('taskbar shortcut', findRichText: true),
        findsOneWidget,
      );
    });

    testWidgets("the row names the turn's duration", (t) async {
      // From the server's own turn stamp, so it survives a reload — the locally
      // timed footnote only exists for a turn this app watched run.
      await openThread(t, work: alternating);
      expect(find.textContaining('已处理'), findsOneWidget);
      expect(find.textContaining('2:31'), findsOneWidget);
    });

    testWidgets('a turn with no reported duration says how much it did', (
      t,
    ) async {
      // A rollout read from disk carries no turn stamp. Better to count the steps
      // than to invent a time, which would read as fact.
      await openThread(t, work: alternating, durationMs: null);
      expect(find.textContaining('已处理'), findsNothing);
      expect(find.textContaining('正在处理'), findsNothing);
      expect(find.text('4 步操作'), findsOneWidget);
      expect(find.textContaining('4'), findsWidgets);
    });

    testWidgets('expanding reveals the work, grouped by type', (t) async {
      // Two levels: the turn opens to sub-runs, and a sub-run opens to its calls.
      await openThread(t, work: alternating);
      await openTurnWork(t);

      // The two commands are adjacent in neither position, so they stay separate
      // rows; each type is present with its own label.
      expect(find.text('pwsh -Command x'), findsOneWidget);
      expect(find.text('taskbar'), findsOneWidget);
    });

    testWidgets('same-type neighbours stay grouped inside the fold', (t) async {
      await openThread(
        t,
        work: const [
          ThreadItem(id: 'r1', itemType: 'reasoning', title: 'first', text: ''),
          ThreadItem(
            id: 'r2',
            itemType: 'reasoning',
            title: 'second',
            text: '',
          ),
        ],
      );
      await openTurnWork(t);
      // "思考 ×2", not two loose rows — the inner level survives.
      expect(find.text('思考 ×2'), findsOneWidget);
      expect(find.text('first'), findsNothing);
    });

    testWidgets('one turn is ONE row, however it was interleaved', (t) async {
      // The reported bug: a turn whose work was broken up by intermediate prose
      // and a compaction rendered as three 已处理 rows that each reported the
      // SAME duration — visibly one turn, presented as several.
      await openThread(
        t,
        work: const [
          ThreadItem(
            id: 'c1',
            itemType: 'commandExecution',
            title: 'first batch',
            text: '',
          ),
          ThreadItem(
            id: 'p1',
            itemType: 'agentMessage',
            title: '',
            text: 'now let me check the other layer',
          ),
          ThreadItem(
            id: 'cc1',
            itemType: 'contextCompaction',
            title: '',
            text: '',
          ),
          ThreadItem(
            id: 'c2',
            itemType: 'commandExecution',
            title: 'second batch',
            text: '',
          ),
        ],
      );

      expect(
        find.byKey(const Key('turn-work-toggle')),
        findsOneWidget,
        reason: 'one turn, one fold',
      );
      // And the answer is still the thing on screen.
      expect(
        find.textContaining('taskbar shortcut', findRichText: true),
        findsOneWidget,
      );
      // Everything in between is inside it, prose and compaction included.
      await openTurnWork(t);
      expect(find.text('first batch'), findsOneWidget);
      expect(find.text('second batch'), findsOneWidget);
      expect(find.text('对话已压缩'), findsOneWidget);
      expect(
        find.textContaining('check the other layer', findRichText: true),
        findsWidgets,
      );
    });

    testWidgets('a running turn is already open, and folds when it ends', (
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

      // An in-flight command: visible without anyone opening anything, so the
      // user can watch the agent work.
      api.pushEvent(
        'pcx:lb7666:app:default',
        const AppEvent(
          kind: 'item/started',
          threadId: 't1',
          itemId: 'c1',
          itemType: 'commandExecution',
          title: 'cargo build',
          text: '',
          raw: '{}',
        ),
      );
      await t.pump(const Duration(milliseconds: 100));
      expect(find.text('cargo build'), findsOneWidget);

      // Settling hands control back to the fold, and the work goes away.
      api.pushEvent(
        'pcx:lb7666:app:default',
        const AppEvent(
          kind: 'item/completed',
          threadId: 't1',
          itemId: 'c1',
          itemType: 'commandExecution',
          title: 'cargo build',
          text: 'done',
          raw: '{}',
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('cargo build'), findsNothing);
      expect(find.byKey(const Key('turn-work-toggle')), findsOneWidget);
    });
  });

  testWidgets('Tool calls render as expandable activity cards', (t) async {
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

    // A web-search tool item arrives as an item event.
    api.pushEvent(
      'pcx:lb7666:app:default',
      const AppEvent(
        kind: 'item/completed',
        threadId: 't1',
        itemId: 's1',
        itemType: 'webSearch',
        title: 'rust async',
        text: '',
        raw: '{}',
      ),
    );
    await t.pumpAndSettle();
    // The turn's work is folded by default; open it to see the calls.
    await openTurnWork(t);
    // Localized label + the query are shown.
    expect(find.text('联网搜索'), findsOneWidget);
    expect(find.text('rust async'), findsOneWidget);

    // A command with output is expandable.
    api.pushEvent(
      'pcx:lb7666:app:default',
      const AppEvent(
        kind: 'item/completed',
        threadId: 't1',
        itemId: 'c1',
        itemType: 'commandExecution',
        title: 'ls -la',
        text: 'total 0\n[exit 0]',
        raw: '{}',
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('执行命令'), findsOneWidget);
    // Detail hidden until expanded.
    expect(find.textContaining('total 0', findRichText: true), findsNothing);
    await t.tap(find.text('ls -la'));
    await t.pumpAndSettle();
    expect(find.textContaining('total 0', findRichText: true), findsOneWidget);
  });

  testWidgets('Extended thread-item types keep distinct activity visuals', (
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

    const items = [
      ('collabAgentToolCall', 'spawnAgent'),
      ('subAgentActivity', 'started'),
      ('imageView', r'C:\tmp\screen.png'),
      ('imageGeneration', 'A blue square'),
      ('sleep', '1250 ms'),
      ('hookPrompt', 'run-1'),
      ('enteredReviewMode', 'Review the patch'),
      ('exitedReviewMode', 'Review complete'),
    ];
    for (var i = 0; i < items.length; i++) {
      final (type, title) = items[i];
      api.pushEvent(
        'pcx:lb7666:app:default',
        AppEvent(
          kind: 'item/completed',
          threadId: 't1',
          itemId: 'extended-$i',
          itemType: type,
          title: title,
          text: '',
          raw: '{}',
        ),
      );
    }
    await t.pumpAndSettle();
    await openTurnWork(t);

    for (final label in [
      '协作智能体',
      '子智能体动态',
      '查看图片',
      '生成图片',
      '等待',
      '钩子提示',
      '进入审查',
      '退出审查',
    ]) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.byIcon(AppIcons.groups_outlined), findsOneWidget);
    expect(find.byIcon(AppIcons.image_search_outlined), findsOneWidget);
  });

  testWidgets('Camel-case outputDelta keeps a command visibly running', (
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

    api.pushEvent(
      'pcx:lb7666:app:default',
      const AppEvent(
        kind: 'item/started',
        threadId: 't1',
        itemId: 'c1',
        itemType: 'commandExecution',
        title: 'cargo test',
        text: '',
        raw: '{}',
      ),
    );
    api.pushEvent(
      'pcx:lb7666:app:default',
      const AppEvent(
        kind: 'item/commandExecution/outputDelta',
        threadId: 't1',
        itemId: 'c1',
        itemType: 'commandExecution',
        title: '',
        text: 'building...',
        raw: '{}',
      ),
    );
    await t.pump(const Duration(milliseconds: 100));
    await openTurnWork(t);
    expect(find.text('cargo test'), findsOneWidget);
    // Scoped to the card: the turn-work fold above it spins too while the turn
    // runs, so a bare type count would pass on either one.
    expect(
      find.descendant(
        of: find.byType(ActivityCard),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );

    api.pushEvent(
      'pcx:lb7666:app:default',
      const AppEvent(
        kind: 'item/completed',
        threadId: 't1',
        itemId: 'c1',
        itemType: 'commandExecution',
        title: 'cargo test',
        text: 'ok',
        raw: '{}',
      ),
    );
    await t.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(ActivityCard),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsNothing,
    );
  });

  testWidgets('a finished turn drops a 用时 duration footnote', (t) async {
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

    // No footnote before a turn runs.
    expect(find.textContaining('用时'), findsNothing);

    // A turn starts (elapsed clock begins) then completes.
    api.pushEvent(
      'pcx:lb7666:app:default',
      const AppEvent(
        kind: 'turn/started',
        threadId: 't1',
        itemId: '',
        itemType: '',
        title: '',
        text: '',
        raw: '{}',
      ),
    );
    await t.pump();
    api.pushEvent(
      'pcx:lb7666:app:default',
      const AppEvent(
        kind: 'turn/completed',
        threadId: 't1',
        itemId: '',
        itemType: '',
        title: '',
        text: '',
        raw: '{}',
      ),
    );
    await t.pumpAndSettle();

    // The per-turn footnote is dropped into the transcript (用时 0:00 for an
    // instant test turn).
    expect(find.textContaining('用时'), findsOneWidget);
  });

  testWidgets('A huge file-change card is capped instead of laid out whole', (
    t,
  ) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
    );
    await api.appConnect('pcx:lb7666:app:default', 28080);
    api.readResult = const ThreadHistory(
      items: [
        ThreadItem(id: 'u1', itemType: 'userMessage', title: '', text: 'hi'),
      ],
      running: false,
      branch: 'dev',
      cwd: '/proj',
    );
    await t.pumpWidget(
      host(
        const AppSessionScreen(
          serviceKey: 'pcx:lb7666:app:default',
          threadId: 't-diff',
        ),
        api,
      ),
    );
    await t.pumpAndSettle();

    // A 900-line file-change card — the inline card's `_DiffHunks` bounds it so
    // one huge expansion can't make the transcript drag.
    final buf = StringBuffer()
      ..writeln('diff --git a/Cargo.lock b/Cargo.lock')
      ..writeln('--- a/Cargo.lock')
      ..writeln('+++ b/Cargo.lock')
      ..writeln('@@ -1 +1,900 @@');
    for (var i = 0; i < 900; i++) {
      buf.writeln('+line $i');
    }
    api.pushEvent(
      'pcx:lb7666:app:default',
      AppEvent(
        kind: 'item/completed',
        threadId: 't-diff',
        itemId: 'f1',
        itemType: 'fileChange',
        title: 'Cargo.lock',
        diff: diffFixture(
          'Cargo.lock',
          removed: [],
          added: [for (var i = 0; i < 900; i++) 'line $i'],
        ),
        text: buf.toString(),
        raw: '{}',
      ),
    );
    await t.pumpAndSettle();
    await openTurnWork(t);
    await t.tap(find.text('Cargo.lock'));
    await t.pumpAndSettle();

    // Capped at 200 rendered rows, with the remainder accounted for rather
    // than silently dropped. The `@@` hunk header takes one of the 200, so the
    // last body line rendered is 198 out of 901 parsed rows. The `+` marker
    // lives in the gutter, so the highlighted row (a RichText) is the code
    // alone — textContaining skips RichText unless asked to include it.
    expect(find.textContaining('line 0', findRichText: true), findsOneWidget);
    expect(find.textContaining('line 198', findRichText: true), findsOneWidget);
    expect(find.textContaining('line 199', findRichText: true), findsNothing);
    expect(find.textContaining('另有 701 行未显示'), findsOneWidget);
  });

  testWidgets('Consecutive same-type tool calls collapse into one group', (
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

    for (final id in ['c1', 'c2', 'c3']) {
      api.pushEvent(
        'pcx:lb7666:app:default',
        AppEvent(
          kind: 'item/completed',
          threadId: 't1',
          itemId: id,
          itemType: 'commandExecution',
          title: 'cmd-$id',
          text: 'out-$id',
          raw: '{}',
        ),
      );
    }
    await t.pumpAndSettle();

    // The turn's work folds first, so nothing about the commands is on screen —
    // not even the group header.
    expect(find.text('执行命令 ×3'), findsNothing);
    expect(find.text('cmd-c1'), findsNothing);

    // First level: the turn's work. Reveals the group, still collapsed.
    await openTurnWork(t);
    expect(find.text('执行命令 ×3'), findsOneWidget);
    expect(find.text('cmd-c1'), findsNothing);

    // Second level: the group. Reveals the individual activity cards.
    await t.tap(find.text('执行命令 ×3'));
    await t.pumpAndSettle();
    expect(find.text('cmd-c1'), findsOneWidget);
    expect(find.text('cmd-c3'), findsOneWidget);
  });

  testWidgets('Plan renders as a status-iconed checklist', (t) async {
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
        kind: 'item/completed',
        threadId: 't1',
        itemId: 'p1',
        itemType: 'plan',
        title: '',
        // Summarizer format: explanation + `- [x|~| ] step` lines.
        text: 'Add a feature\n- [x] research\n- [~] implement\n- [ ] test',
        raw: '{}',
      ),
    );
    await t.pumpAndSettle();
    // Checklist is shown expanded by default: header + progress + each step.
    expect(find.text('计划'), findsWidgets); // toolPlan label (pill + card)
    expect(find.text('1/3'), findsOneWidget); // 1 of 3 completed
    expect(find.text('research'), findsOneWidget);
    expect(find.text('implement'), findsOneWidget);
    expect(find.text('test'), findsOneWidget);
    // Completed step shows a filled check; pending shows an empty circle.
    // The step marks (16 px), not the status bar's own check.
    Finder inPanel(IconData icon) => find.byWidgetPredicate(
      (w) => w is Icon && w.icon == icon && w.size == 16,
    );
    expect(inPanel(AppIcons.check_circle_rounded), findsOneWidget);
    expect(inPanel(AppIcons.timelapse_rounded), findsOneWidget);
    expect(inPanel(AppIcons.radio_button_unchecked), findsOneWidget);
    // The explanation renders as Markdown above the steps.
    expect(
      find.textContaining('Add a feature', findRichText: true),
      findsWidgets,
    );
  });

  testWidgets('Running plan tracker fits phone width and can collapse', (
    t,
  ) async {
    const key = 'pcx:lb7666:app:default';
    final api =
        FakeBridgeApi(
            config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
          )
          ..appThreadResumeError = StateError(
            'thread t-mobile already has an active writer',
          );
    await api.appConnect(key, 28080);
    api.transcripts['t-mobile'] = const [
      ThreadItem(id: 'u1', itemType: 'userMessage', title: '', text: 'ship it'),
      ThreadItem(
        id: 'p1',
        itemType: 'plan',
        title: '',
        text: '- [x] inspect\n- [~] implement\n- [ ] verify',
      ),
    ];
    api.liveness['t-mobile'] = const SessionLiveness(
      threadId: 't-mobile',
      turnState: 'incomplete',
      heldOpen: true,
      safety: 'ownedRunning',
      allowsResume: false,
      requiresTakeover: false,
      holders: [],
    );
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(360, 700);
    addTearDown(t.view.reset);

    await t.pumpWidget(
      host(const AppSessionScreen(serviceKey: key, threadId: 't-mobile'), api),
    );
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(t.takeException(), isNull);
    expect(find.text('第 2 / 3 步'), findsOneWidget);
    expect(find.byKey(const Key('turn-progress-panel')), findsOneWidget);
    expect(
      find.ancestor(
        of: find.byKey(const Key('turn-progress-summary')),
        matching: find.byKey(const Key('chat-conversation-layer')),
      ),
      findsOneWidget,
      reason: 'the live tracker floats over the conversation layer',
    );

    await t.tap(find.byKey(const Key('turn-progress-summary')));
    await t.pump(const Duration(milliseconds: 250));
    expect(find.byKey(const Key('turn-progress-panel')), findsNothing);

    await t.pumpWidget(const SizedBox());
  });

  testWidgets('File change shows ± counts and expands to the diff', (t) async {
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
      AppEvent(
        kind: 'item/completed',
        threadId: 't1',
        itemId: 'f1',
        itemType: 'fileChange',
        title: 'lib/x.dart',
        diff: diffFixture(
          'lib/x.dart',
          removed: ['old'],
          added: ['new', 'more'],
        ),
        text:
            'diff --git a/lib/x.dart b/lib/x.dart\n'
            '--- a/lib/x.dart\n'
            '+++ b/lib/x.dart\n'
            '@@ -1 +1,2 @@\n'
            '-old\n'
            '+new\n'
            '+more\n',
        raw: '{}',
      ),
    );
    await t.pumpAndSettle();
    await openTurnWork(t);

    // Collapsed: an "Edited files" header with the path and the ± counts.
    expect(find.text('修改文件'), findsOneWidget); // toolEdited (zh)
    expect(find.text('lib/x.dart'), findsOneWidget);
    expect(find.text('+2'), findsWidgets);
    expect(find.text('−1'), findsWidgets);

    // Expanding reveals the highlighted diff lines for review — the +/−
    // markers moved to the gutter, so each row (a RichText) carries just code.
    await t.tap(find.text('lib/x.dart'));
    await t.pumpAndSettle();
    expect(find.textContaining('new', findRichText: true), findsOneWidget);
    expect(find.textContaining('old', findRichText: true), findsOneWidget);
  });

  testWidgets('Compactions fold with the work, and are not counted as one', (
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

    for (final id in ['c1', 'c2']) {
      api.pushEvent(
        'pcx:lb7666:app:default',
        AppEvent(
          kind: 'item/completed',
          threadId: 't1',
          itemId: id,
          itemType: 'contextCompaction',
          title: '',
          text: '',
          raw: '{}',
        ),
      );
    }
    await t.pumpAndSettle();
    // Compaction happens during a turn, so it folds with the work rather than
    // interrupting it — leaving it out split one turn into several 已处理 rows
    // that each reported the same duration.
    expect(find.text('对话已压缩'), findsNothing);

    // Opened, each still renders as its own notice rather than collapsing into a
    // single "×2" row: a compaction is an event, and two of them mean the context
    // was squeezed twice.
    await openTurnWork(t);
    expect(find.text('对话已压缩'), findsNWidgets(2));
  });
}
