part of '../app_session_test.dart';

/// The conversation's chrome: the title, the status bar, theme, context gauge,
/// compaction and the review.
void _registerChrome() {
  testWidgets('The top-bar title hovers as an editable target', (t) async {
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
    t.view.physicalSize = const Size(1200, 900); // wide → desktop top bar
    addTearDown(t.view.reset);
    await t.pumpWidget(
      host(const AppSessionScreen(serviceKey: 'pcx:lb7666:app:default'), api),
    );
    await t.pumpAndSettle();
    await t.tap(find.text('original preview').first);
    await t.pumpAndSettle();

    // Hovering paints a highlight behind the title and shows a text cursor, so
    // the label reads as clickable rather than as window-drag chrome.
    final target = find.byKey(const Key('bar-title-tap'));
    final tapTarget = t.widget<InkWell>(target);
    expect(tapTarget.hoverColor, isNotNull);
    expect(tapTarget.mouseCursor, SystemMouseCursors.text);

    final gesture = await t.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(() => gesture.removePointer());
    await gesture.moveTo(t.getCenter(target));
    await t.pumpAndSettle();

    // And one click on the label starts editing — no double-click needed.
    await t.tap(target);
    await t.pumpAndSettle();
    expect(find.byKey(const Key('bar-title-field')), findsOneWidget);
  });

  testWidgets('Only an overflowing title fades at its trailing edge', (
    t,
  ) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
    );
    await api.appConnect('pcx:lb7666:app:default', 28080);
    api.appThreads.addAll([
      const ThreadMeta(id: 'short', preview: 'brief', cwd: '', updatedAt: 0),
      ThreadMeta(
        id: 'long',
        preview: 'a very long conversation title ${'that keeps going ' * 6}',
        cwd: '',
        updatedAt: 0,
      ),
    ]);
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(1200, 900); // wide → desktop top bar
    addTearDown(t.view.reset);
    await t.pumpWidget(
      host(const AppSessionScreen(serviceKey: 'pcx:lb7666:app:default'), api),
    );
    await t.pumpAndSettle();

    // A title that fits is painted plainly — no fade to explain away.
    await t.tap(find.text('brief').first);
    await t.pumpAndSettle();
    final bar = find.byKey(const Key('bar-title'));
    expect(
      find.descendant(of: bar, matching: find.byType(ShaderMask)),
      findsNothing,
    );

    // One that doesn't fit gets the fade, so it reads as text running past the
    // edge rather than as a short label.
    await t.tap(find.textContaining('a very long conversation').first);
    await t.pumpAndSettle();
    expect(
      find.descendant(of: bar, matching: find.byType(ShaderMask)),
      findsOneWidget,
    );
  });

  testWidgets('Clicking the top-bar title renames the conversation', (t) async {
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
    t.view.physicalSize = const Size(1200, 900); // wide → desktop top bar
    addTearDown(t.view.reset);
    await t.pumpWidget(
      host(const AppSessionScreen(serviceKey: 'pcx:lb7666:app:default'), api),
    );
    await t.pumpAndSettle();
    await t.tap(find.text('original preview').first);
    await t.pumpAndSettle();

    // The title is a label until clicked, then a text field.
    expect(find.byKey(const Key('bar-title-field')), findsNothing);
    await t.tap(find.byKey(const Key('bar-title-tap')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('bar-title-field')), findsOneWidget);

    // Submitting persists via the bridge and both the bar and the sidebar row
    // switch to the new name.
    await t.enterText(
      find.byKey(const Key('bar-title-field')),
      'renamed thread',
    );
    await t.testTextInput.receiveAction(TextInputAction.done);
    await t.pumpAndSettle();
    expect(api.setNames['t1'], 'renamed thread');
    expect(find.text('renamed thread'), findsWidgets);
    expect(find.text('original preview'), findsNothing);
  });

  testWidgets('A failed rename restores the previous title', (t) async {
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
    api.failSetThreadName = true;
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(1200, 900); // wide → desktop top bar
    addTearDown(t.view.reset);
    await t.pumpWidget(
      host(const AppSessionScreen(serviceKey: 'pcx:lb7666:app:default'), api),
    );
    await t.pumpAndSettle();
    await t.tap(find.text('original preview').first);
    await t.pumpAndSettle();

    await t.tap(find.byKey(const Key('bar-title-tap')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('bar-title-field')), 'nope');
    await t.testTextInput.receiveAction(TextInputAction.done);
    await t.pumpAndSettle();

    // The optimistic rename is rolled back rather than left claiming success.
    expect(find.text('nope'), findsNothing);
    expect(find.text('original preview'), findsWidgets);
    expect(find.textContaining('重命名失败'), findsOneWidget); // renameFailed (zh)
  });

  testWidgets('A stale rename failure does not clobber a newer rename', (
    t,
  ) async {
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
    t.view.physicalSize = const Size(1200, 900); // wide → desktop top bar
    addTearDown(t.view.reset);
    await t.pumpWidget(
      host(const AppSessionScreen(serviceKey: 'pcx:lb7666:app:default'), api),
    );
    await t.pumpAndSettle();
    await t.tap(find.text('original preview').first);
    await t.pumpAndSettle();

    // Rename twice, with the first request still in flight so its failure
    // lands AFTER the second rename was already applied.
    final gate = Completer<void>();
    api.renameGate = gate;
    api.failNextSetThreadName = true;
    await t.tap(find.byKey(const Key('bar-title-tap')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('bar-title-field')), 'first try');
    await t.testTextInput.receiveAction(TextInputAction.done);
    await t.pump(); // dispatched, parked on the gate

    await t.tap(find.byKey(const Key('bar-title-tap')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('bar-title-field')), 'second try');
    await t.testTextInput.receiveAction(TextInputAction.done);
    await t.pumpAndSettle();

    gate.complete(); // now let the FIRST request fail
    await t.pumpAndSettle();

    // The newer rename owns the outcome: rolling back to the pre-first-request
    // title would leave the UI permanently disagreeing with the server, which
    // stored "second try".
    expect(api.setNames['t1'], 'second try');
    expect(find.text('second try'), findsWidgets);
    expect(find.text('original preview'), findsNothing);
  });

  testWidgets('Committing the title untouched does not pin a name', (t) async {
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
    t.view.physicalSize = const Size(1200, 900); // wide → desktop top bar
    addTearDown(t.view.reset);
    await t.pumpWidget(
      host(const AppSessionScreen(serviceKey: 'pcx:lb7666:app:default'), api),
    );
    await t.pumpAndSettle();
    await t.tap(find.text('original preview').first);
    await t.pumpAndSettle();

    await t.tap(find.byKey(const Key('bar-title-tap')));
    await t.pumpAndSettle();
    // Submit the seeded text as-is.
    await t.testTextInput.receiveAction(TextInputAction.done);
    await t.pumpAndSettle();

    // Nothing was written, so the title keeps tracking the preview.
    expect(api.setNames, isEmpty);
    expect(find.byKey(const Key('bar-title-field')), findsNothing);
    expect(find.text('original preview'), findsWidgets);
  });

  testWidgets('Context gauge appears on token usage and opens a detail sheet', (
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

    // No gauge until a token-usage event arrives.
    expect(find.text('10%'), findsNothing);
    api.pushEvent(
      'pcx:lb7666:app:default',
      const AppEvent(
        kind: 'thread/tokenUsage/updated',
        threadId: 't1',
        raw:
            '{"tokenUsage":{"last":{"totalTokens":20000},"modelContextWindow":200000}}',
      ),
    );
    await t.pumpAndSettle();
    // 20000 / 200000 = 10%.
    expect(find.text('10%'), findsOneWidget);

    // Tapping the gauge opens the context/quota detail sheet.
    api.rateLimitsJson =
        '{"rateLimits":{"primary":{"usedPercent":42,"windowDurationMins":300}}}';
    await t.tap(find.text('10%'));
    await t.pumpAndSettle();
    expect(find.text('上下文与用量'), findsOneWidget); // contextUsageTitle (zh)
    // Scoped to the sheet: the same window label also names the always-visible
    // sidebar quota strip.
    expect(
      find.descendant(
        of: find.byType(Dialog),
        matching: find.text('5 小时额度'), // quota5h (zh)
      ),
      findsOneWidget,
    );
  });

  testWidgets('Theme button flips between light and dark', (t) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
    );
    await api.appConnect('pcx:lb7666:app:default', 28080);
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(1200, 900); // wide → left pane inline
    addTearDown(t.view.reset);
    // Its own host rather than `host`: the button reads the brightness in
    // EFFECT, so the app has to actually carry a light and a dark theme (and
    // honour the stored mode) the way main.dart does.
    await t.pumpWidget(
      ProviderScope(
        overrides: [bridgeApiProvider.overrideWithValue(api)],
        child: Consumer(
          builder: (context, ref, _) {
            final pref = ref.watch(uiPrefsProvider).valueOrNull?.themeMode;
            return MaterialApp(
              locale: const Locale('zh'),
              theme: ThemeData(brightness: Brightness.light),
              darkTheme: ThemeData(brightness: Brightness.dark),
              themeMode: switch (pref) {
                'light' => ThemeMode.light,
                'dark' => ThemeMode.dark,
                _ => ThemeMode.system,
              },
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: const AppSessionScreen(
                serviceKey: 'pcx:lb7666:app:default',
                home: true,
              ),
            );
          },
        ),
      ),
    );
    await t.pumpAndSettle();

    // Two states only — no third "auto" icon to land on.
    final btn = find.byKey(const Key('theme-toggle-btn'));
    expect(btn, findsOneWidget);
    expect(find.byIcon(AppIcons.brightness_auto_outlined), findsNothing);

    // The test platform reports light, so the button offers dark and the icon
    // shows what is currently in effect.
    expect(find.byIcon(AppIcons.light_mode_outlined), findsOneWidget);
    await t.tap(btn);
    await t.pumpAndSettle();
    expect(find.byIcon(AppIcons.dark_mode_outlined), findsOneWidget);
    expect(find.byIcon(AppIcons.light_mode_outlined), findsNothing);

    // And back — tapping twice returns to where it started rather than
    // advancing into a third state.
    await t.tap(btn);
    await t.pumpAndSettle();
    expect(find.byIcon(AppIcons.light_mode_outlined), findsOneWidget);
    expect(find.byIcon(AppIcons.brightness_auto_outlined), findsNothing);

    // It lives with the window's controls, not in the sessions pane, so
    // collapsing the sidebar must not take appearance away with it.
    await t.tap(find.byKey(const Key('sidebar-collapse-btn')));
    await t.pumpAndSettle();
    expect(btn, findsOneWidget);
  });

  testWidgets('Git branch badge shows changes and opens the review split', (
    t,
  ) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
    );
    await api.appConnect('pcx:lb7666:app:default', 28080);
    // Desktop width so the branch chip opens the inline review split (not the
    // mobile bottom sheet).
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(1400, 900);
    addTearDown(t.view.reset);
    api.readResult = const ThreadHistory(
      items: [
        ThreadItem(id: 'u1', itemType: 'userMessage', title: '', text: 'hi'),
      ],
      running: false,
      branch: 'feature/x',
      cwd: '/proj', // needed so _loadGit fetches the diff
      tokensUsed: 5000,
      contextWindow: 100000,
    );
    api.gitDiff = diffFixture('lib/x.dart', added: ['new', 'extra']);
    await t.pumpWidget(
      host(
        const AppSessionScreen(
          serviceKey: 'pcx:lb7666:app:default',
          threadId: 'thread-g',
        ),
        api,
      ),
    );
    await t.pumpAndSettle();

    // Branch + change counts in the unified status bar, and again on the
    // composer's context line (desktop width).
    expect(find.text('feature/x'), findsNWidgets(2));
    expect(find.byKey(const Key('composer-branch-chip')), findsOneWidget);
    expect(find.text('+2'), findsWidgets); // 2 added
    expect(find.text('−1'), findsWidgets); // 1 removed

    // Tapping the branch chip opens the review split: the file tree names the
    // changed file, and its diff is shown highlighted (the single changed file
    // is selected by default).
    await t.tap(find.byKey(const Key('status-branch-chip')));
    await t.pumpAndSettle();
    expect(find.text('审阅'), findsOneWidget); // reviewTitle (zh)
    expect(find.byKey(const Key('review-file-lib/x.dart')), findsOneWidget);
    // The diff pane renders the changed lines highlighted (RichText).
    expect(find.textContaining('new', findRichText: true), findsWidgets);
    expect(find.textContaining('old', findRichText: true), findsWidgets);

    // Closing the review hides it.
    await t.tap(find.byKey(const Key('review-close')));
    await t.pumpAndSettle();
    expect(find.text('审阅'), findsNothing);
  });

  testWidgets('A slow diff load spins on the badge and can be cancelled', (
    t,
  ) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
    );
    await api.appConnect('pcx:lb7666:app:default', 28080);
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(1400, 900);
    addTearDown(t.view.reset);
    api.readResult = const ThreadHistory(
      items: [
        ThreadItem(id: 'u1', itemType: 'userMessage', title: '', text: 'hi'),
      ],
      running: false,
      branch: 'feature/x',
      cwd: '/proj',
      tokensUsed: 5000,
      contextWindow: 100000,
    );
    api.gitDiff = diffFixture('lib/x.dart', added: ['new', 'extra']);
    // Gate the diff from the very start, so the screen reaches the badge with
    // NO diff read yet — the only case that has to block on a fetch.
    final gate = Completer<void>();
    api.gitDiffGate = gate;
    await t.pumpWidget(
      host(
        const AppSessionScreen(
          serviceKey: 'pcx:lb7666:app:default',
          threadId: 'thread-cancel',
        ),
        api,
      ),
    );
    await t.pump();
    await t.pump(const Duration(milliseconds: 100));

    await t.tap(find.byKey(const Key('status-branch-chip')));
    await t.pump();

    // The press is acknowledged immediately: the badge spins instead of sitting
    // inert until the diff lands.
    final spinner = find.descendant(
      of: find.byKey(const Key('status-branch-chip')),
      matching: find.byType(CircularProgressIndicator),
    );
    expect(spinner, findsWidgets);
    expect(find.text('审阅'), findsNothing); // review not open yet

    // Tapping again while it's in flight cancels: the spinner goes away and the
    // review never opens, even once the underlying call finally returns.
    await t.tap(find.byKey(const Key('status-branch-chip')));
    await t.pump();
    expect(spinner, findsNothing);

    gate.complete();
    await t.pumpAndSettle();
    expect(find.text('审阅'), findsNothing);

    // A fresh press still works — cancelling doesn't wedge the badge.
    api.gitDiffGate = null;
    await t.tap(find.byKey(const Key('status-branch-chip')));
    await t.pumpAndSettle();
    expect(find.text('审阅'), findsOneWidget);
  });

  testWidgets('Reopening the review does not wait on another diff fetch', (
    t,
  ) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
    );
    await api.appConnect('pcx:lb7666:app:default', 28080);
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(1400, 900);
    addTearDown(t.view.reset);
    api.readResult = const ThreadHistory(
      items: [
        ThreadItem(id: 'u1', itemType: 'userMessage', title: '', text: 'hi'),
      ],
      running: false,
      branch: 'feature/x',
      cwd: '/proj',
      tokensUsed: 5000,
      contextWindow: 100000,
    );
    api.gitDiff = diffFixture('lib/x.dart', added: ['new', 'extra']);
    await t.pumpWidget(
      host(
        const AppSessionScreen(
          serviceKey: 'pcx:lb7666:app:default',
          threadId: 'thread-warm',
        ),
        api,
      ),
    );
    await t.pumpAndSettle();

    // A diff is already in hand, so hanging every subsequent fetch must not stop
    // the review from opening: it shows what it has and refreshes behind itself.
    final stuck = Completer<void>();
    api.gitDiffGate = stuck;
    await t.tap(find.byKey(const Key('status-branch-chip')));
    await t.pump();
    expect(find.text('审阅'), findsOneWidget);
    expect(find.byKey(const Key('review-file-lib/x.dart')), findsOneWidget);

    stuck.complete();
    await t.pumpAndSettle();
  });

  testWidgets('Compact menu action calls the bridge after confirm', (t) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
    );
    await api.appConnect('pcx:lb7666:app:default', 28080);
    api.readResult = const ThreadHistory(
      items: [
        ThreadItem(id: 'u1', itemType: 'userMessage', title: '', text: 'hi'),
      ],
      running: false,
    );
    await t.pumpWidget(
      host(
        const AppSessionScreen(
          serviceKey: 'pcx:lb7666:app:default',
          threadId: 'thread-c',
        ),
        api,
      ),
    );
    await t.pumpAndSettle();

    await t.tap(find.byType(PopupMenuButton<String>));
    await t.pumpAndSettle();
    await t.tap(find.text('压缩对话').last); // compact (zh)
    await t.pumpAndSettle();
    // Confirm dialog → tap the confirm button (the FilledButton).
    await t.tap(find.widgetWithText(FilledButton, '压缩对话'));
    await t.pumpAndSettle();
    expect(api.compacted, isTrue);
  });

  testWidgets('Status bar reflects ready then working state', (t) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
    );
    await api.appConnect('pcx:lb7666:app:default', 28080);
    // Narrow so the sessions pane is a hidden drawer — the open thread's sidebar
    // "running" subtitle then can't collide with the status bar's working text.
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(400, 800);
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

    // Idle → the status bar reads "Ready".
    expect(find.text('就绪'), findsOneWidget); // stateReady (zh)

    // A running turn flips it to "Working…" (pump one frame — the typing
    // indicator animates forever, so the tree never fully settles).
    api.pushEvent(
      'pcx:lb7666:app:default',
      const AppEvent(
        kind: 'turn/started',
        threadId: 't1',
        raw: '{"turnId":"x"}',
      ),
    );
    await t.pump(); // deliver the broadcast event
    await t.pump(); // build the resulting frame
    expect(find.text('运行中…'), findsOneWidget); // stateWorking (zh)
    expect(find.text('就绪'), findsNothing);
  });
}
