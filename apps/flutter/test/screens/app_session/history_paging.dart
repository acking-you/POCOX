part of '../app_session_test.dart';

/// A long conversation's history, read a page or a turn at a time, and turn
/// navigation.
void _registerHistoryPaging() {
  testWidgets(
    'turn-navigation controls appear with ≥2 turns and are tappable',
    (t) async {
      final api = FakeBridgeApi(
        config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
      );
      await api.appConnect('pcx:lb7666:app:default', 28080);
      // A resumed thread with two user turns.
      api.readResult = const ThreadHistory(
        items: [
          ThreadItem(
            id: 'u1',
            itemType: 'userMessage',
            title: '',
            text: 'first',
          ),
          ThreadItem(
            id: 'a1',
            itemType: 'agentMessage',
            title: '',
            text: 'reply one',
          ),
          ThreadItem(
            id: 'u2',
            itemType: 'userMessage',
            title: '',
            text: 'second',
          ),
          ThreadItem(
            id: 'a2',
            itemType: 'agentMessage',
            title: '',
            text: 'reply two',
          ),
        ],
        running: false,
      );
      t.view.devicePixelRatio = 1.0;
      t.view.physicalSize = const Size(400, 800);
      addTearDown(t.view.reset);
      await t.pumpWidget(
        host(
          const AppSessionScreen(
            serviceKey: 'pcx:lb7666:app:default',
            threadId: 'th-nav',
          ),
          api,
        ),
      );
      await t.pumpAndSettle();

      // Two turns ⇒ prev/next-turn jumps are offered, folded into a faint
      // handle until it is touched.
      expect(find.byKey(const Key('nav-prev-turn')), findsNothing);
      await t.tap(find.byKey(const Key('turn-navigation-handle')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('nav-prev-turn')), findsOneWidget);
      expect(find.byKey(const Key('nav-next-turn')), findsOneWidget);
      // They drive the list controller; tapping must not throw even when the
      // short transcript isn't scrollable.
      await t.tap(find.byKey(const Key('nav-next-turn')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('nav-prev-turn')));
      await t.pumpAndSettle();
      // Still present and functional after use (and the taps threw nothing —
      // pumpAndSettle would have surfaced any exception).
      expect(find.byKey(const Key('nav-prev-turn')), findsOneWidget);
      expect(find.byKey(const Key('nav-next-turn')), findsOneWidget);
    },
  );

  group('a long thread loads its history a page at a time', () {
    // The rail is desktop-only by construction, and the test harness forces
    // android. Restored in a finally so the debug-var invariant check passes.
    Future<void> onDesktop(Future<void> Function() body) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await body();
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    }

    ThreadItem user(String id, String text, String turn) => ThreadItem(
      id: id,
      itemType: 'userMessage',
      title: '',
      text: text,
      turnId: turn,
    );
    ThreadItem agent(String id, String text, String turn) => ThreadItem(
      id: id,
      itemType: 'agentMessage',
      title: '',
      text: text,
      turnId: turn,
    );

    /// A thread whose newest turn is loaded and whose earlier turns are not.
    Future<FakeBridgeApi> openPaginated(
      WidgetTester t, {
      bool tailOnly = false,
      bool longTail = false,
      bool nextThread = false,
    }) async {
      final api = FakeBridgeApi(
        config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
      );
      if (nextThread) {
        api.appThreads.add(
          const ThreadMeta(
            id: 'thread-next',
            preview: 'next history',
            cwd: '/work',
            updatedAt: 1,
          ),
        );
      }
      await api.appConnect('pcx:lb7666:app:default', 28080);
      api.readResult = ThreadHistory(
        items: [
          if (!tailOnly) user('u5', 'newest question', 't5'),
          agent(
            'a5',
            longTail ? 'newest answer\n\n' * 70 : 'newest answer',
            't5',
          ),
        ],
        running: false,
        hasOlder: true,
        firstTurnId: 't1',
        // The server enumerated every turn, including the four not loaded.
        // Five of them, so the count clears kTurnMinimapMinItems and the rail
        // is the affordance rather than the corner arrows.
        turns: const [
          TurnSummary(
            turnId: 't1',
            userText: 'first question',
            assistantText: 'first answer',
          ),
          TurnSummary(
            turnId: 't2',
            userText: 'second question',
            assistantText: 'second answer',
          ),
          TurnSummary(
            turnId: 't3',
            userText: 'third question',
            assistantText: 'third answer',
          ),
          TurnSummary(
            turnId: 't4',
            userText: 'fourth question',
            assistantText: 'fourth answer',
          ),
          TurnSummary(
            turnId: 't5',
            userText: 'newest question',
            assistantText: 'newest answer',
            loaded: true,
          ),
        ],
      );
      await t.pumpWidget(
        host(
          const AppSessionScreen(
            serviceKey: 'pcx:lb7666:app:default',
            threadId: 'thread-long',
          ),
          api,
        ),
      );
      await t.pumpAndSettle();
      return api;
    }

    testWidgets('opening it shows the newest turn, not the whole history', (
      t,
    ) async {
      await openPaginated(t);
      expect(find.text('newest answer'), findsOneWidget);
      expect(find.text('first answer'), findsNothing);
      // And it says so, rather than looking like the conversation starts here.
      expect(find.byKey(const Key('chat-older-history')), findsOneWidget);
    });

    testWidgets('compact previous button reads an unloaded turn', (t) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(390, 844);
      addTearDown(t.view.reset);
      final api = await openPaginated(t);
      api.turnItems = {
        't4': [
          user('u4', 'fourth question', 't4'),
          agent('a4', 'fourth answer', 't4'),
        ],
      };
      await t.tap(find.byKey(const Key('turn-navigation-handle')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('nav-prev-turn')));
      await t.pumpAndSettle();
      // The turn above the landing place is read ahead of the reader.
      expect(api.turnItemCalls, ['t4', 't3']);
      expect(find.text('fourth question'), findsOneWidget);
      final control = find.byKey(const Key('draggable-turn-navigation'));
      final before = t.getTopLeft(control);
      await t.drag(control, const Offset(-100, -100));
      await t.pumpAndSettle();
      expect(t.getTopLeft(control).dx, lessThan(before.dx - 60));
      expect(t.getTopLeft(control).dy, lessThan(before.dy - 60));
    });

    testWidgets('overscrolling a short transcript loads older history', (
      t,
    ) async {
      final api = await openPaginated(t);
      api.olderPages = [
        [
          user('u4', 'fourth question', 't4'),
          agent('a4', 'fourth answer', 't4'),
        ],
      ];
      await t.drag(find.text('newest answer'), const Offset(0, 160));
      await t.pumpAndSettle();
      expect(api.olderPageCalls, 1);
      expect(find.text('fourth question'), findsOneWidget);
    });

    testWidgets('the rail has a tick per turn of the WHOLE thread', (t) async {
      await onDesktop(() async {
        await t.binding.setSurfaceSize(const Size(1600, 900));
        addTearDown(() => t.binding.setSurfaceSize(null));
        await openPaginated(t);
        // Three turns exist; only one is loaded. A rail derived from loaded rows
        // would show one tick and misreport the conversation's shape.
        final rail = t.widget<TurnMinimap>(find.byType(TurnMinimap));
        expect(rail.items, hasLength(5));
        expect(rail.items.map((i) => i.turnId), ['t1', 't2', 't3', 't4', 't5']);
        // Only the loaded turn resolves to a row; the rest await their items.
        expect(rail.items[0].rowIndex, -1);
        expect(rail.items[4].rowIndex, greaterThanOrEqualTo(0));
      });
    });

    testWidgets('an unloaded tick still previews, without fetching', (t) async {
      await onDesktop(() async {
        await t.binding.setSurfaceSize(const Size(1600, 900));
        addTearDown(() => t.binding.setSurfaceSize(null));
        final api = await openPaginated(t);
        final rail = t.widget<TurnMinimap>(find.byType(TurnMinimap));
        // The skeleton carries the text, so hovering costs no round trip.
        expect(rail.items[0].userText, 'first question');
        expect(rail.items[0].assistantText, 'first answer');
        expect(api.turnItemCalls, isEmpty);
      });
    });

    testWidgets('selecting an unloaded turn fetches just that turn', (t) async {
      await onDesktop(() async {
        await t.binding.setSurfaceSize(const Size(1600, 900));
        addTearDown(() => t.binding.setSurfaceSize(null));
        final api = await openPaginated(t);
        api.turnItems = {
          't1': [
            user('u1', 'first question', 't1'),
            agent('a1', 'first answer', 't1'),
          ],
        };
        final rail = t.widget<TurnMinimap>(find.byType(TurnMinimap));
        rail.onSelect(rail.items[0]);
        await t.pumpAndSettle();
        expect(api.turnItemCalls, ['t1']);
        expect(find.text('first answer'), findsOneWidget);
        // The newest turn is still there — a jump adds, it doesn't replace.
        expect(find.text('newest answer'), findsOneWidget);
        expect(find.byKey(const Key('chat-older-history')), findsNothing);
        expect(find.text('对话开始'), findsOneWidget);
        expect(find.byKey(const Key('history-gap-t2')), findsOneWidget);
        final loadedRail = t.widget<TurnMinimap>(find.byType(TurnMinimap));
        loadedRail.onSelect(loadedRail.items.first);
        await t.pumpAndSettle();
        expect(api.turnItemCalls, ['t1']);
      });
    });

    testWidgets('an older page prepends, keeping what was already shown', (
      t,
    ) async {
      final api = await openPaginated(t);
      api.olderPages = [
        [
          user('u2', 'second question', 't2'),
          agent('a2', 'second answer', 't2'),
        ],
      ];
      // Reaching back past the top. Tapped rather than scrolled because the
      // loaded page is shorter than the viewport here, so there is nothing to
      // scroll — which is exactly why the row is tappable.
      await t.tap(find.byKey(const Key('chat-older-history-load')));
      await t.pumpAndSettle();
      expect(api.olderPageCalls, 1);
      expect(find.text('second answer'), findsOneWidget);
      expect(find.text('newest answer'), findsOneWidget);
      // That was the last page, so the header retires.
      expect(find.byKey(const Key('chat-older-history')), findsNothing);
    });

    testWidgets('a partially loaded turn can fetch its opening row', (t) async {
      await onDesktop(() async {
        await t.binding.setSurfaceSize(const Size(1600, 900));
        addTearDown(() => t.binding.setSurfaceSize(null));
        final api = await openPaginated(t, tailOnly: true);
        api.turnItems['t5'] = [
          user('u5', 'newest question', 't5'),
          agent('a5', 'newest answer', 't5'),
        ];
        final rail = t.widget<TurnMinimap>(find.byType(TurnMinimap));
        expect(rail.items.last.rowIndex, -1);
        rail.onSelect(rail.items.last);
        await t.pumpAndSettle();
        expect(api.turnItemCalls, ['t5', 't4']);
        expect(find.text('newest question'), findsOneWidget);
        expect(
          t.widget<TurnMinimap>(find.byType(TurnMinimap)).items.last.rowIndex,
          0,
        );
      });
    });

    testWidgets('gaps load in place after jumping to the first turn', (
      t,
    ) async {
      await onDesktop(() async {
        await t.binding.setSurfaceSize(const Size(1600, 900));
        addTearDown(() => t.binding.setSurfaceSize(null));
        final api = await openPaginated(t);
        api.turnItems['t1'] = [user('u1', 'first question', 't1')];
        final rail = t.widget<TurnMinimap>(find.byType(TurnMinimap));
        rail.onSelect(rail.items.first);
        await t.pumpAndSettle();
        api.turnItems['t2'] = [user('u2', 'second question', 't2')];
        api.turnItems['t3'] = [user('u3', 'third question', 't3')];
        await t.tap(find.byKey(const Key('history-gap-t2')));
        await t.pumpAndSettle();
        await t.tap(find.byKey(const Key('history-gap-t3')));
        await t.pumpAndSettle();
        final rows = t.widget<TurnMinimap>(find.byType(TurnMinimap)).items;
        expect(rows[0].rowIndex, lessThan(rows[1].rowIndex));
        expect(rows[1].rowIndex, lessThan(rows[2].rowIndex));
        expect(rows[2].rowIndex, lessThan(rows[4].rowIndex));
        expect(api.olderPageCalls, 0);
        expect(api.turnItemCalls, ['t1', 't2', 't3']);
      });
    });

    testWidgets('history filled in above the reader leaves the reader still', (
      t,
    ) async {
      await onDesktop(() async {
        await t.binding.setSurfaceSize(const Size(1600, 900));
        addTearDown(() => t.binding.setSurfaceSize(null));
        final api = await openPaginated(t, longTail: true);
        api.turnItems['t1'] = [
          user('u1', 'first question', 't1'),
          agent('a1', 'first answer', 't1'),
        ];
        final rail = t.widget<TurnMinimap>(find.byType(TurnMinimap));
        rail.onSelect(rail.items.first);
        await t.pumpAndSettle();
        // Read on past the gap the jump left, to the newest turn.
        final scroll = t
            .widget<MiddleClickScroll>(find.byType(MiddleClickScroll))
            .controller;
        final newest = find.byKey(const ValueKey('u5'));
        final top = t
            .getTopLeft(find.byKey(const Key('chat-conversation-layer')))
            .dy;
        scroll.jumpTo(scroll.offset + t.getTopLeft(newest).dy - top - 60);
        await t.pumpAndSettle();
        final pending = Completer<List<ThreadItem>>();
        api.pendingTurnItems['t2'] = pending.future;
        await t.drag(find.text('newest question'), const Offset(0, -40));
        await t.pump();
        expect(api.turnItemCalls, ['t1', 't2']);
        final before = t.getTopLeft(newest).dy;
        // The turn lands between the jump's landing place and the reader.
        pending.complete([
          user('u2', 'second question', 't2'),
          agent('a2', 'second answer\n\n' * 30, 't2'),
        ]);
        await t.pumpAndSettle();
        expect(t.getTopLeft(newest).dy, closeTo(before, 1));
        expect(t.takeException(), isNull);
      });
    });

    testWidgets('repeated selection shares the in-flight request', (t) async {
      await onDesktop(() async {
        await t.binding.setSurfaceSize(const Size(1600, 900));
        addTearDown(() => t.binding.setSurfaceSize(null));
        final api = await openPaginated(t, longTail: true);
        final response = Completer<List<ThreadItem>>();
        api.pendingTurnItems['t1'] = response.future;
        final rail = t.widget<TurnMinimap>(find.byType(TurnMinimap));
        final controller = t
            .widget<MiddleClickScroll>(find.byType(MiddleClickScroll))
            .controller;
        expect(controller.position.extentBefore, greaterThan(500));
        rail.onSelect(rail.items.first);
        await t.pump();
        rail.onSelect(rail.items.first);
        await t.pump();
        expect(api.turnItemCalls, ['t1']);
        response.complete([user('u1', 'first question', 't1')]);
        await t.pumpAndSettle();
        expect(api.turnItemCalls, ['t1']);
        expect(controller.position.extentBefore, lessThan(100));
        expect(find.text('first question'), findsOneWidget);
      });
    });

    testWidgets(
      'slow turn selection has one status and cancellation preserves reading position',
      (t) async {
        await onDesktop(() async {
          await t.binding.setSurfaceSize(const Size(1600, 900));
          addTearDown(() => t.binding.setSurfaceSize(null));
          final api = await openPaginated(t, longTail: true);
          final pending = Completer<List<ThreadItem>>();
          api.pendingTurnItems['t1'] = pending.future;
          final rail = t.widget<TurnMinimap>(find.byType(TurnMinimap));
          final scroll = t
              .widget<MiddleClickScroll>(find.byType(MiddleClickScroll))
              .controller;
          final before = scroll.offset;
          rail.onSelect(rail.items.first);
          await t.pump();
          expect(
            find.byKey(const Key('history-navigation-status')),
            findsOneWidget,
          );
          expect(find.text('正在加载历史消息…'), findsNothing);
          expect(scroll.offset, before);
          await t.tap(
            find.descendant(
              of: find.byKey(const Key('history-navigation-status')),
              matching: find.byType(IconButton),
            ),
          );
          // It fades out.
          await t.pumpAndSettle();
          expect(
            find.byKey(const Key('history-navigation-status')),
            findsNothing,
          );
          pending.complete([user('u1', 'first question', 't1')]);
          await t.pumpAndSettle();
          expect(scroll.position.extentBefore, greaterThan(500));
          expect(api.turnItemCalls, ['t1']);
          expect(t.takeException(), isNull);
        });
      },
    );

    testWidgets('new live turns join the paginated rail', (t) async {
      await onDesktop(() async {
        await t.binding.setSurfaceSize(const Size(1600, 900));
        addTearDown(() => t.binding.setSurfaceSize(null));
        await openPaginated(t);
        await t.enterText(find.byType(TextField).last, 'a new live question');
        await t.pump();
        await t.tap(find.byKey(const Key('send-btn')));
        await t.pumpAndSettle();
        final rail = t.widget<TurnMinimap>(find.byType(TurnMinimap));
        expect(rail.items, hasLength(6));
        expect(rail.items.last.userText, 'a new live question');
        expect(rail.items.last.rowIndex, greaterThanOrEqualTo(0));
      });
    });

    testWidgets('a stale failure cannot unlock another thread pagination', (
      t,
    ) async {
      await t.binding.setSurfaceSize(const Size(1600, 900));
      addTearDown(() => t.binding.setSurfaceSize(null));
      final api = await openPaginated(t, nextThread: true);
      final previous = Completer<OlderPage>();
      final current = Completer<OlderPage>();
      api.pendingOlderPages['thread-long'] = previous.future;
      api.pendingOlderPages['thread-next'] = current.future;
      await t.tap(find.byKey(const Key('chat-older-history-load')));
      await t.pump();
      await t.tap(find.byKey(const Key('conv-tile-thread-next')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('chat-older-history-load')));
      await t.pump();
      previous.completeError(StateError('previous thread failed'));
      await t.pump();
      expect(api.olderPageCalls, 2);
      expect(find.byKey(const Key('chat-older-history-load')), findsNothing);
      current.complete(const OlderPage(items: [], hasOlder: false));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
    });

    testWidgets('explicit history loading reveals the newly inserted message', (
      t,
    ) async {
      await t.binding.setSurfaceSize(const Size(1000, 800));
      addTearDown(() => t.binding.setSurfaceSize(null));
      final api = await openPaginated(t, longTail: true);
      final scroll = t
          .widget<MiddleClickScroll>(find.byType(MiddleClickScroll))
          .controller;
      scroll.jumpTo(scroll.position.minScrollExtent);
      await t.pumpAndSettle();
      api.olderPages = [
        [
          for (var i = 0; i < 4; i++) ...[
            user('u$i', 'Earlier question $i', 't$i'),
            agent('a$i', 'Earlier answer $i\n\n' * 15, 't$i'),
          ],
        ],
      ];
      await t.tap(find.byKey(const Key('chat-older-history-load')));
      await t.pumpAndSettle();
      expect(find.text('Earlier question 0').hitTestable(), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (widget) => widget is HistoryArrival && widget.revision == 1,
        ),
        findsOneWidget,
      );
      expect(api.olderPageCalls, 1);
    });

    testWidgets('automatic prepending preserves the reading anchor', (t) async {
      await t.binding.setSurfaceSize(const Size(1000, 800));
      addTearDown(() => t.binding.setSurfaceSize(null));
      final api = await openPaginated(t, longTail: true);
      final scroll = t
          .widget<MiddleClickScroll>(find.byType(MiddleClickScroll))
          .controller;
      scroll.jumpTo(scroll.position.minScrollExtent);
      await t.pumpAndSettle();
      final anchor = find.byKey(const ValueKey('a5'));
      final before = t.getTopLeft(anchor).dy;
      api.olderPages = [
        [
          for (var i = 0; i < 4; i++) ...[
            user('u$i', 'Earlier question $i', 't$i'),
            agent('a$i', 'Earlier answer $i\n\n' * 15, 't$i'),
          ],
        ],
      ];
      await t.drag(find.text('newest question'), const Offset(0, 80));
      await t.pumpAndSettle();
      expect(t.getTopLeft(anchor).dy, closeTo(before, 2));
      expect(api.olderPageCalls, 1);
    });

    testWidgets(
      'failed history pauses automatic requests until explicit retry',
      (t) async {
        final api = await openPaginated(t);
        final pending = Completer<OlderPage>();
        api.pendingOlderPages['thread-long'] = pending.future;
        await t.tap(find.byKey(const Key('chat-older-history-load')));
        await t.pump();
        pending.completeError(StateError('temporary failure'));
        await t.pumpAndSettle();
        expect(find.text('加载失败，点击重试'), findsOneWidget);
        await t.drag(find.byType(MiddleClickScroll), const Offset(0, 100));
        await t.pumpAndSettle();
        expect(api.olderPageCalls, 1);
        api.pendingOlderPages.clear();
        await t.tap(find.byKey(const Key('chat-older-history-load')));
        await t.pumpAndSettle();
        expect(api.olderPageCalls, 2);
        expect(find.byKey(const Key('chat-older-history')), findsNothing);
      },
    );

    testWidgets('a thread that arrives whole pages nothing', (t) async {
      final api = FakeBridgeApi(
        config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
      );
      await api.appConnect('pcx:lb7666:app:default', 28080);
      // A legacy thread: every item present, no turn enumeration, no older page.
      api.readResult = ThreadHistory(
        items: [
          user('u1', 'only question', 't1'),
          agent('a1', 'only answer', 't1'),
        ],
        running: false,
      );
      await t.pumpWidget(
        host(
          const AppSessionScreen(
            serviceKey: 'pcx:lb7666:app:default',
            threadId: 'thread-legacy',
          ),
          api,
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('only answer'), findsOneWidget);
      expect(find.byKey(const Key('chat-older-history')), findsNothing);
      expect(api.olderPageCalls, 0);
    });
  });
}
