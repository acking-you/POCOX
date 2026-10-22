part of '../app_session_test.dart';

/// The sessions pane: projects, search, renames from elsewhere and running
/// badges.
void _registerSidebar() {
  testWidgets('A new session appears in the sessions pane after first send', (
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

    // No conversations in the pane yet.
    expect(find.text('暂无会话'), findsOneWidget); // noThreads (zh)

    // Sending the first message surfaces the new session in the left pane.
    await t.enterText(find.byType(TextField), 'hello there');
    await t.pump();
    await t.tap(find.byKey(const Key('send-btn')));
    await t.pumpAndSettle();

    expect(find.text('暂无会话'), findsNothing);
    // The new session shows in the pane as a conversation tile, with its message
    // preserved as the preview (not "(未命名)" — the server preview is still
    // empty for a just-started thread, so the optimistic one must win).
    expect(convTiles(), findsOneWidget);
    expect(find.text('（未命名）'), findsNothing);
  });

  testWidgets('Home pane groups conversations under their project', (t) async {
    final nowS = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
    );
    await api.appConnect('pcx:lb7666:app:default', 28080);
    // Two projects, interleaved in time — grouping must beat pure recency.
    api.appThreads.addAll([
      ThreadMeta(
        id: 'a1',
        preview: 'alpha newest',
        cwd: '/work/alpha',
        updatedAt: nowS - 60,
      ),
      ThreadMeta(
        id: 'b1',
        preview: 'beta middle',
        cwd: '/work/beta',
        updatedAt: nowS - 3600,
      ),
      ThreadMeta(
        id: 'a2',
        preview: 'alpha oldest',
        cwd: '/work/alpha',
        updatedAt: nowS - 5 * 86400,
      ),
    ]);
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(1200, 900); // wide → left pane inline
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

    // A heading per project, not per time bucket.
    expect(projectHeading('/work/alpha', 'alpha'), findsOneWidget);
    expect(projectHeading('/work/beta', 'beta'), findsOneWidget);
    expect(find.text('今天'), findsNothing); // groupToday (zh)
    expect(find.text('更早'), findsNothing); // groupEarlier (zh)

    // Both of alpha's conversations sit under the alpha heading — including the
    // 5-day-old one, which recency bucketing would have split off.
    final alphaY = t.getTopLeft(projectHeading('/work/alpha', 'alpha')).dy;
    final betaY = t.getTopLeft(projectHeading('/work/beta', 'beta')).dy;
    expect(alphaY, lessThan(betaY)); // newest project first
    expect(t.getTopLeft(find.text('alpha newest')).dy, greaterThan(alphaY));
    final oldestY = t.getTopLeft(find.text('alpha oldest')).dy;
    expect(oldestY, greaterThan(alphaY));
    expect(oldestY, lessThan(betaY));
  });

  testWidgets('A project heading outranks the conversation rows under it', (
    t,
  ) async {
    final nowS = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
    );
    await api.appConnect('pcx:lb7666:app:default', 28080);
    api.appThreads.add(
      ThreadMeta(
        id: 'a1',
        preview: 'a conversation',
        cwd: '/work/alpha',
        updatedAt: nowS - 60,
      ),
    );
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(1200, 900); // wide → left pane inline
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

    // The project is the tree's top level: a bold group heading above
    // regular-weight rows, which indent beneath its name.
    final heading = t.widget<Text>(projectHeading('/work/alpha', 'alpha'));
    final row = t.widget<Text>(find.text('a conversation'));
    expect(heading.style!.fontWeight, FontWeight.w600);
    expect(row.style!.fontWeight, FontWeight.w400);
    expect(
      t.getTopLeft(find.text('a conversation')).dx,
      greaterThanOrEqualTo(
        t.getTopLeft(projectHeading('/work/alpha', 'alpha')).dx,
      ),
    );

    // Rows carry no leading glyph of their own and the heading no folder:
    // the fold chevron is the tree's only icon.
    expect(find.byIcon(AppIcons.chat_bubble_outline), findsNothing);
    expect(find.byIcon(AppIcons.folder_open_outlined), findsNothing);
    expect(find.byIcon(AppIcons.keyboard_arrow_right), findsOneWidget);
  });

  testWidgets('Clicking a project folder collapses its conversations', (
    t,
  ) async {
    final nowS = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
    );
    await api.appConnect('pcx:lb7666:app:default', 28080);
    api.appThreads.addAll([
      ThreadMeta(
        id: 'a1',
        preview: 'alpha one',
        cwd: '/work/alpha',
        updatedAt: nowS - 60,
      ),
      ThreadMeta(
        id: 'b1',
        preview: 'beta one',
        cwd: '/work/beta',
        updatedAt: nowS - 3600,
      ),
    ]);
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(1200, 900); // wide → left pane inline
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
    expect(find.text('alpha one'), findsOneWidget);

    // Collapsing hides only that project's rows; the sibling project stays.
    await t.tap(find.byKey(const Key('project-header-/work/alpha')));
    await t.pumpAndSettle();
    expect(find.text('alpha one'), findsNothing);
    expect(find.text('beta one'), findsOneWidget);
    expect(
      projectHeading('/work/alpha', 'alpha'),
      findsOneWidget,
    ); // the heading itself remains

    // And clicking again brings them back.
    await t.tap(find.byKey(const Key('project-header-/work/alpha')));
    await t.pumpAndSettle();
    expect(find.text('alpha one'), findsOneWidget);
  });

  testWidgets('A project shows only its newest few rows until expanded', (
    t,
  ) async {
    final nowS = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
    );
    await api.appConnect('pcx:lb7666:app:default', 28080);
    // Seven conversations in one project — two past the 5-row peek.
    for (var i = 0; i < 7; i++) {
      api.appThreads.add(
        ThreadMeta(
          id: 't$i',
          preview: 'row $i',
          cwd: '/work/alpha',
          updatedAt: nowS - 60 * (i + 1),
        ),
      );
    }
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(1200, 900); // wide → left pane inline
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

    // The newest five show; the rest sit behind "show more" (2 hidden).
    expect(find.text('row 0'), findsOneWidget);
    expect(find.text('row 4'), findsOneWidget);
    expect(find.text('row 5'), findsNothing);
    expect(find.text('row 6'), findsNothing);
    expect(find.text('展开显示（2）'), findsOneWidget); // showMoreCount (zh)

    await t.tap(find.byKey(const Key('project-peek-/work/alpha')));
    await t.pumpAndSettle();
    expect(find.text('row 5'), findsOneWidget);
    expect(find.text('row 6'), findsOneWidget);
    expect(find.text('收起'), findsOneWidget); // showLess (zh)
  });

  testWidgets('A search reaches conversations inside a collapsed project', (
    t,
  ) async {
    final nowS = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
    );
    await api.appConnect('pcx:lb7666:app:default', 28080);
    for (var i = 0; i < 8; i++) {
      api.appThreads.add(
        ThreadMeta(
          id: 't$i',
          preview: i == 7 ? 'findme needle' : 'row $i',
          cwd: '/work/alpha',
          updatedAt: nowS - 60 * (i + 1),
        ),
      );
    }
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(1200, 900); // wide → left pane inline
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

    await t.tap(find.byKey(const Key('project-header-/work/alpha')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('conv-tile-t0')), findsNothing); // collapsed

    // A collapsed project must not swallow search hits: the filter found this
    // row, so hiding it would answer "nothing found" to a search that did.
    await t.enterText(find.byKey(const Key('conv-search')), 'findme');
    await t.pumpAndSettle();
    expect(find.text('findme needle'), findsOneWidget);

    // Clearing the query returns the project to its collapsed state.
    await t.enterText(find.byKey(const Key('conv-search')), '');
    await t.pumpAndSettle();
    expect(find.byKey(const Key('conv-tile-t0')), findsNothing);
  });

  testWidgets('The open conversation stays visible past the project peek', (
    t,
  ) async {
    final nowS = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
    );
    await api.appConnect('pcx:lb7666:app:default', 28080);
    // 8 rows in one project; the open one is the OLDEST, so the newest-5 peek
    // would otherwise bury it and the sidebar would show no selection at all.
    for (var i = 0; i < 8; i++) {
      api.appThreads.add(
        ThreadMeta(
          id: 't$i',
          preview: 'row $i',
          cwd: '/work/alpha',
          updatedAt: nowS - 60 * (i + 1),
        ),
      );
    }
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(1200, 900); // wide → left pane inline
    addTearDown(t.view.reset);
    await t.pumpWidget(
      host(
        const AppSessionScreen(
          serviceKey: 'pcx:lb7666:app:default',
          threadId: 't7',
          home: true,
        ),
        api,
      ),
    );
    await t.pumpAndSettle();

    expect(find.byKey(const Key('conv-tile-t7')), findsOneWidget);
    // The peek still previews the newest rows, and still offers the rest.
    expect(find.byKey(const Key('conv-tile-t0')), findsOneWidget);
    expect(find.byKey(const Key('project-peek-/work/alpha')), findsOneWidget);
  });

  testWidgets('A conversation is searchable by the name the user gave it', (
    t,
  ) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
    );
    await api.appConnect('pcx:lb7666:app:default', 28080);
    api.appThreads.addAll([
      const ThreadMeta(
        id: 'n1',
        preview: 'aaa original preview',
        name: 'zzz custom name',
        cwd: '',
        updatedAt: 10,
      ),
      // Enough rows for the search box to appear (>6).
      for (var i = 0; i < 7; i++)
        ThreadMeta(id: 'f$i', preview: 'filler $i', cwd: '', updatedAt: 9 - i),
    ]);
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(1200, 900); // wide → left pane inline
    addTearDown(t.view.reset);
    await t.pumpWidget(
      host(const AppSessionScreen(serviceKey: 'pcx:lb7666:app:default'), api),
    );
    await t.pumpAndSettle();

    // The row shows the user's name, so that's the text a search must match —
    // filtering on the preview alone would miss it entirely.
    await t.enterText(find.byKey(const Key('conv-search')), 'zzz custom');
    await t.pumpAndSettle();
    expect(find.text('zzz custom name'), findsOneWidget);
    expect(find.byKey(const Key('conv-tile-f0')), findsNothing);
  });

  testWidgets('A rename from another device updates the list', (t) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
    );
    await api.appConnect('pcx:lb7666:app:default', 28080);
    api.appThreads.add(
      const ThreadMeta(
        id: 't1',
        preview: 'original preview',
        cwd: '',
        updatedAt: 0,
      ),
    );
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(1200, 900); // wide → left pane inline
    addTearDown(t.view.reset);
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

    // Titles live on the server, so a rename elsewhere arrives as a
    // notification. Nothing polls the thread list, so ignoring it would leave
    // the old title on screen indefinitely.
    api.pushEvent(
      'pcx:lb7666:app:default',
      const AppEvent(
        kind: 'thread/name/updated',
        threadId: 't1',
        raw: '{"threadId":"t1","name":"renamed elsewhere"}',
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('renamed elsewhere'), findsWidgets);
    expect(find.text('original preview'), findsNothing);
  });

  testWidgets('A renamed conversation shows its name in the sidebar', (
    t,
  ) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
    );
    await api.appConnect('pcx:lb7666:app:default', 28080);
    api.appThreads.add(
      const ThreadMeta(
        id: 't1',
        preview: 'raw first message',
        name: 'My tidy name',
        cwd: '',
        updatedAt: 0,
      ),
    );
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(1200, 900); // wide → left pane inline
    addTearDown(t.view.reset);
    await t.pumpWidget(
      host(const AppSessionScreen(serviceKey: 'pcx:lb7666:app:default'), api),
    );
    await t.pumpAndSettle();

    // The server-set name replaces the preview everywhere it's shown.
    expect(find.text('My tidy name'), findsWidgets);
    expect(find.text('raw first message'), findsNothing);
  });

  testWidgets(
    'Conversations pane groups by time with relative-time subtitles',
    (t) async {
      final nowS = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final api = FakeBridgeApi(
        config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
      );
      await api.appConnect('pcx:lb7666:app:default', 28080);
      api.appThreads.addAll([
        ThreadMeta(
          id: 'tRecent',
          preview: 'recent chat',
          cwd: '',
          updatedAt: nowS - 120,
        ),
        ThreadMeta(
          id: 'tOld',
          preview: 'ancient chat',
          cwd: '',
          updatedAt: nowS - 5 * 86400,
        ),
      ]);
      t.view.devicePixelRatio = 1.0;
      t.view.physicalSize = const Size(1200, 900); // wide → left pane inline
      addTearDown(t.view.reset);
      await t.pumpWidget(
        host(const AppSessionScreen(serviceKey: 'pcx:lb7666:app:default'), api),
      );
      await t.pumpAndSettle();

      // Each conversation shows its preview + a relative-time subtitle, and the
      // older one is bucketed under "Earlier".
      expect(find.text('recent chat'), findsOneWidget);
      expect(find.text('ancient chat'), findsOneWidget);
      expect(find.text('2 分钟前'), findsOneWidget); // timeMinutesAgo (zh)
      expect(find.text('5 天前'), findsOneWidget); // timeDaysAgo (zh)
      expect(find.text('更早'), findsOneWidget); // groupEarlier (zh)
    },
  );

  testWidgets('Conversations search box filters the list', (t) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
    );
    await api.appConnect('pcx:lb7666:app:default', 28080);
    // The search box only appears once there are enough conversations (>6).
    api.appThreads.addAll(const [
      ThreadMeta(id: 't1', preview: 'alpha', cwd: '', updatedAt: 0),
      ThreadMeta(id: 't2', preview: 'beta', cwd: '', updatedAt: 0),
      ThreadMeta(id: 't3', preview: 'gamma', cwd: '', updatedAt: 0),
      ThreadMeta(id: 't4', preview: 'delta', cwd: '', updatedAt: 0),
      ThreadMeta(id: 't5', preview: 'epsilon', cwd: '', updatedAt: 0),
      ThreadMeta(id: 't6', preview: 'zeta', cwd: '', updatedAt: 0),
      ThreadMeta(id: 't7', preview: 'needle', cwd: '', updatedAt: 0),
    ]);
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(1200, 900); // wide → left pane inline
    addTearDown(t.view.reset);
    await t.pumpWidget(
      host(const AppSessionScreen(serviceKey: 'pcx:lb7666:app:default'), api),
    );
    await t.pumpAndSettle();

    expect(find.text('alpha'), findsOneWidget);
    expect(find.text('needle'), findsOneWidget);

    // Typing a query filters the list to matching previews only — non-matches
    // disappear and exactly one conversation tile remains.
    await t.enterText(find.byKey(const Key('conv-search')), 'needle');
    await t.pumpAndSettle();
    expect(find.text('alpha'), findsNothing);
    expect(find.text('beta'), findsNothing);
    expect(convTiles(), findsOneWidget);
  });

  testWidgets('Quota is warm in the sidebar without opening anything', (
    t,
  ) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
    );
    await api.appConnect('pcx:lb7666:app:default', 28080);
    // 88% of the weekly window used → 12% left, and the weekly window is the
    // tighter of the two so it is the one the strip shows.
    api.rateLimitsJson =
        '{"rateLimits":{'
        '"primary":{"usedPercent":10,"windowDurationMins":300},'
        '"secondary":{"usedPercent":88,"windowDurationMins":10080}}}';
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

    // No tap, no sheet — the numbers are already on screen because the quota
    // is fetched with the subscription rather than on demand.
    expect(find.byKey(const Key('sidebar-quota')), findsOneWidget);
    expect(find.text('剩余用量'), findsOneWidget); // quotaRemaining (zh)
    expect(find.text('12%'), findsOneWidget);
  });

  testWidgets('Sessions pane shows inline when wide, hidden when narrow', (
    t,
  ) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
    );
    await api.appConnect('pcx:lb7666:app:default', 28080);
    api.appThreads.add(
      const ThreadMeta(id: 't9', preview: 'past chat', cwd: '', updatedAt: 0),
    );
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);

    // Wide: the left sessions pane is inline (header + thread visible).
    t.view.physicalSize = const Size(1200, 900);
    await t.pumpWidget(
      host(const AppSessionScreen(serviceKey: 'pcx:lb7666:app:default'), api),
    );
    await t.pumpAndSettle();
    expect(find.text('会话'), findsOneWidget); // conversationsSection (zh)
    expect(find.text('past chat'), findsOneWidget);

    // Narrow: no inline pane (it moves into a closed drawer).
    t.view.physicalSize = const Size(400, 900);
    await t.pumpWidget(
      host(const AppSessionScreen(serviceKey: 'pcx:lb7666:app:default'), api),
    );
    await t.pumpAndSettle();
    expect(find.text('past chat'), findsNothing);
  });

  testWidgets('Sessions pane buttons switch threads without crashing', (
    t,
  ) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
    );
    await api.appConnect('pcx:lb7666:app:default', 28080);
    api.appThreads.add(
      const ThreadMeta(id: 't9', preview: 'old chat', cwd: '', updatedAt: 0),
    );
    api.readResult = const ThreadHistory(
      items: [
        ThreadItem(
          id: 'm1',
          itemType: 'agentMessage',
          title: '',
          text: 'hello',
        ),
      ],
      running: false,
    );
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(1200, 900);
    addTearDown(t.view.reset);
    await t.pumpWidget(
      host(const AppSessionScreen(serviceKey: 'pcx:lb7666:app:default'), api),
    );
    await t.pumpAndSettle();

    // Tap an existing thread in the pane → resumes it (no Scaffold.of crash).
    await t.tap(find.text('old chat'));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    expect(api.lastResumed, 't9');
    // The live feed follows the conversation in place; replacing it would
    // drop whatever the host sent in between (an approval, a turn end).
    expect(api.followedThreads, ['t9']);

    // Tap "new conversation" (+) → clears to an empty conversation.
    await t.tap(find.byKey(const Key('new-conversation-btn')));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    expect(api.followedThreads, ['t9', null]);
    // Tapping "new conversation" shows the new-session guidance.
    expect(
      find.byKey(const Key('project-switcher-btn')),
      findsOneWidget,
    ); // guidance (zh)
  });

  testWidgets('Running sessions show a pulsing badge in the sessions pane', (
    t,
  ) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
    );
    await api.appConnect('pcx:lb7666:app:default', 28080);
    api.appThreads.addAll(const [
      ThreadMeta(id: 'tOpen', preview: 'open chat', cwd: '', updatedAt: 0),
      ThreadMeta(id: 't9', preview: 'other chat', cwd: '', updatedAt: 0),
    ]);
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(1200, 900); // wide → left pane inline
    addTearDown(t.view.reset);

    await t.pumpWidget(
      host(
        const AppSessionScreen(
          serviceKey: 'pcx:lb7666:app:default',
          threadId: 'tOpen',
        ),
        api,
      ),
    );
    await t.pumpAndSettle();
    expect(find.byType(PulsingDot), findsNothing);

    // A turn starts on the OTHER thread (t9), not the open one. The session's
    // own handler ignores cross-thread events, but the shared provider tracks
    // it, so the pane shows a running badge + header count.
    api.pushEvent(
      'pcx:lb7666:app:default',
      const AppEvent(kind: 'turn/started', threadId: 't9', raw: '{}'),
    );
    await t.pump(); // deliver the broadcast event
    await t.pump(); // build the resulting frame
    // The running thread moves into the "Active" group with a pulsing dot.
    expect(find.text('进行中'), findsOneWidget); // groupActive (zh)
    expect(find.byType(PulsingDot), findsAtLeastNWidgets(1));

    // Turn completes → the badge clears.
    api.pushEvent(
      'pcx:lb7666:app:default',
      const AppEvent(kind: 'turn/completed', threadId: 't9', raw: '{}'),
    );
    await t.pump();
    await t.pump();
    expect(find.byType(PulsingDot), findsNothing);
  });
}
