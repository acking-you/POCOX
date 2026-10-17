part of '../app_session_test.dart';

/// The sessions pane grouped by day, with each conversation's summary.
void _registerActivityView() {
  testWidgets('The activity view groups by day and summarizes each row', (
    t,
  ) async {
    final now = DateTime.now();
    int at(Duration ago) => now.subtract(ago).millisecondsSinceEpoch ~/ 1000;
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
    );
    await api.appConnect('pcx:lb7666:app:default', 28080);
    api.appThreads.addAll([
      ThreadMeta(
        id: 'a1',
        preview: 'alpha one',
        cwd: '/work/alpha',
        updatedAt: at(Duration.zero),
      ),
      // Comfortably inside yesterday whatever time the test runs at.
      ThreadMeta(
        id: 'b1',
        preview: 'beta one',
        cwd: '/work/beta',
        updatedAt: at(Duration(hours: 24 + now.hour, minutes: now.minute)),
      ),
    ]);
    api.summaries['a1'] = 'Rewrote the retry loop.';
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

    // The project tree is the default, so no summaries are fetched for it —
    // one thread/read per row is far too much to spend on a sidebar nobody
    // asked to see this way.
    expect(api.summaryCalls, isEmpty);
    expect(find.byKey(const Key('project-header-/work/alpha')), findsOneWidget);

    await t.tap(find.byKey(const Key('activity-view-btn')));
    await t.pumpAndSettle();

    // Day headings replace the project headings.
    expect(find.byKey(const Key('project-header-/work/alpha')), findsNothing);
    expect(find.text('今天'), findsOneWidget);
    expect(find.text('昨天'), findsOneWidget);
    // Both rows are present, each under its own day.
    expect(find.byKey(const Key('activity-tile-a1')), findsOneWidget);
    expect(find.byKey(const Key('activity-tile-b1')), findsOneWidget);
    // The summary is the agent's own last line, not the user's first message.
    expect(find.text('Rewrote the retry loop.'), findsOneWidget);
    expect(api.summaryCalls, containsAll(<String>['a1', 'b1']));

    // And the toggle goes back to the project tree.
    await t.tap(find.byKey(const Key('activity-view-btn')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('project-header-/work/alpha')), findsOneWidget);
    expect(find.byKey(const Key('activity-tile-a1')), findsNothing);
  });

  testWidgets('The activity view fetches summaries for visible rows only', (
    t,
  ) async {
    final nowS = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
    );
    await api.appConnect('pcx:lb7666:app:default', 28080);
    // Far more rows than one viewport holds. The earlier test used two, which
    // both fit on screen — so "only the visible ones" and "all of them" looked
    // identical and an eager fetch passed it.
    const total = 60;
    for (var i = 0; i < total; i++) {
      api.appThreads.add(
        ThreadMeta(
          id: 't$i',
          preview: 'row $i',
          cwd: '/work/alpha',
          updatedAt: nowS - 60 * i,
        ),
      );
      api.summaries['t$i'] = 'gist $i';
    }
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
    await t.tap(find.byKey(const Key('activity-view-btn')));
    await t.pumpAndSettle();

    // Each summary costs a full `thread/read` server-side, so the toggle must
    // not fan out over the whole history to fill one screen.
    expect(
      api.summaryCalls.length,
      lessThan(total),
      reason:
          'a pre-built ListView would fetch all $total transcripts at once; '
          'got ${api.summaryCalls.length}',
    );
    expect(api.summaryCalls, isNotEmpty, reason: 'visible rows still load');

    // Scrolling brings more rows in, and those fetch on arrival.
    final before = api.summaryCalls.length;
    await t.drag(
      find.byKey(const Key('activity-tile-t0')),
      const Offset(0, -900),
    );
    await t.pumpAndSettle();
    expect(
      api.summaryCalls.length,
      greaterThan(before),
      reason: 'rows scrolled into view fetch their summary',
    );
  });

  testWidgets('The activity view keeps one row shape, Active group included', (
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
        updatedAt: nowS - 300,
      ),
      ThreadMeta(
        id: 'a2',
        preview: 'alpha two',
        cwd: '/work/alpha',
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
          home: true,
        ),
        api,
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('activity-view-btn')));
    await t.pumpAndSettle();

    // a1 starts a turn, so it moves up into the "Active" group.
    api.pushEvent(
      'pcx:lb7666:app:default',
      const AppEvent(kind: 'turn/started', threadId: 'a1', raw: '{}'),
    );
    await t.pump();
    await t.pump();
    expect(find.text('进行中'), findsOneWidget); // groupActive (zh)

    // Both rows are activity tiles: the Active group must not fall back to the
    // project tree's compact row while the rest of the list is summarized.
    expect(find.byKey(const Key('activity-tile-a1')), findsOneWidget);
    expect(find.byKey(const Key('activity-tile-a2')), findsOneWidget);
    expect(convTiles(), findsNothing);
  });

  testWidgets('A finished turn refreshes that row\'s cached summary', (
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
        preview: 'alpha one',
        cwd: '/work/alpha',
        updatedAt: nowS - 300,
      ),
    );
    api.summaries['a1'] = 'Looked at the retry loop.';
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(1200, 900);
    addTearDown(t.view.reset);
    await t.pumpWidget(
      host(
        const AppSessionScreen(
          serviceKey: 'pcx:lb7666:app:default',
          threadId: 'a1',
          home: true,
        ),
        api,
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('activity-view-btn')));
    await t.pumpAndSettle();
    expect(find.text('Looked at the retry loop.'), findsOneWidget);
    expect(api.summaryCalls, ['a1']);

    // A turn runs and produces a newer reply. The cached line now describes the
    // previous turn, so it has to be re-read rather than kept forever.
    api.summaries['a1'] = 'Rewrote the retry loop.';
    api.pushEvent(
      'pcx:lb7666:app:default',
      const AppEvent(kind: 'turn/started', threadId: 'a1', raw: '{}'),
    );
    await t.pump();
    api.pushEvent(
      'pcx:lb7666:app:default',
      const AppEvent(kind: 'turn/completed', threadId: 'a1', raw: '{}'),
    );
    await t.pumpAndSettle();

    expect(find.text('Rewrote the retry loop.'), findsOneWidget);
    expect(find.text('Looked at the retry loop.'), findsNothing);
    expect(api.summaryCalls, ['a1', 'a1']); // re-read exactly once
  });

  testWidgets('A turn finishing on a BACKGROUND thread refreshes its row', (
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
        updatedAt: nowS - 300,
      ),
      ThreadMeta(
        id: 'b1',
        preview: 'beta one',
        cwd: '/work/alpha',
        updatedAt: nowS - 600,
      ),
    ]);
    api.summaries['b1'] = 'First pass at the parser.';
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(1200, 900);
    addTearDown(t.view.reset);
    // a1 is the OPEN conversation; b1 runs in the background.
    await t.pumpWidget(
      host(
        const AppSessionScreen(
          serviceKey: 'pcx:lb7666:app:default',
          threadId: 'a1',
          home: true,
        ),
        api,
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('activity-view-btn')));
    await t.pumpAndSettle();
    expect(find.text('First pass at the parser.'), findsOneWidget);

    // b1 finishes a turn while a1 stays selected. `_onEvent` drops events for
    // other threads — but the summary IS that thread's newest reply, so the
    // cache has to be dropped anyway or b1's row is stale for the session.
    api.summaries['b1'] = 'Parser handles nested groups now.';
    api.pushEvent(
      'pcx:lb7666:app:default',
      const AppEvent(kind: 'turn/completed', threadId: 'b1', raw: '{}'),
    );
    await t.pumpAndSettle();

    expect(find.text('Parser handles nested groups now.'), findsOneWidget);
    expect(find.text('First pass at the parser.'), findsNothing);
  });

  testWidgets('A finished turn re-lists so the day grouping stays current', (
    t,
  ) async {
    final now = DateTime.now();
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
    );
    await api.appConnect('pcx:lb7666:app:default', 28080);
    // A conversation last touched two days ago: it opens under a weekday
    // heading, not "today".
    api.appThreads.add(
      ThreadMeta(
        id: 'a1',
        preview: 'alpha one',
        cwd: '/work/alpha',
        updatedAt:
            now
                .subtract(Duration(days: 2, hours: now.hour))
                .millisecondsSinceEpoch ~/
            1000,
      ),
    );
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(1200, 900);
    addTearDown(t.view.reset);
    await t.pumpWidget(
      host(
        const AppSessionScreen(
          serviceKey: 'pcx:lb7666:app:default',
          threadId: 'a1',
          home: true,
        ),
        api,
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('activity-view-btn')));
    await t.pumpAndSettle();
    expect(find.text('今天'), findsNothing, reason: 'starts under an old day');

    // The user resumes it and a turn completes: the server moves `updatedAt` to
    // now, so the row belongs under "today". Nothing used to re-list on turn
    // end, leaving it filed under the old day with a stale relative time.
    final i = api.appThreads.indexWhere((x) => x.id == 'a1');
    api.appThreads[i] = ThreadMeta(
      id: 'a1',
      preview: 'alpha one',
      cwd: '/work/alpha',
      updatedAt: now.millisecondsSinceEpoch ~/ 1000,
    );
    api.pushEvent(
      'pcx:lb7666:app:default',
      const AppEvent(kind: 'turn/completed', threadId: 'a1', raw: '{}'),
    );
    // Past the re-list debounce.
    await t.pump(const Duration(milliseconds: 500));
    await t.pumpAndSettle();

    expect(find.text('今天'), findsOneWidget); // groupToday (zh)
  });

  testWidgets('An activity row stays readable before its summary arrives', (
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
        preview: 'alpha one',
        cwd: '/work/alpha',
        name: 'Retry work',
        updatedAt: nowS - 300,
      ),
    );
    api.summaries['a1'] = 'Rewrote the retry loop.';
    // Hold the summary in flight so the pre-load row is observable.
    final gate = Completer<void>();
    api.summaryGate = gate;
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
    await t.tap(find.byKey(const Key('activity-view-btn')));
    await t.pumpAndSettle();

    // Loading: the name leads and the preview stands in for the summary, so
    // the row reads immediately and the layout won't jump when the real one
    // lands.
    expect(find.text('Retry work'), findsOneWidget);
    expect(find.text('alpha one'), findsOneWidget);

    gate.complete();
    await t.pumpAndSettle();
    expect(find.text('Rewrote the retry loop.'), findsOneWidget);
    expect(find.text('alpha one'), findsNothing);
  });
}
