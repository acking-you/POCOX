part of '../app_session_test.dart';

/// How messages render: Markdown, images, links, copying, wire context and
/// merged replies.
void _registerTranscript() {
  testWidgets(
    'live native generation stays visible and loads its remote artifact',
    (t) async {
      const service = 'pcx:lb7666:app:default';
      final api = FakeBridgeApi(
        config: const ConfigInfo(relay: 'relay:7666', hasKey: true),
      );
      await api.appConnect(service, 28080);
      api.threadImageBytes['/host/generated.png'] = onePixelPng;
      await t.pumpWidget(
        host(const AppSessionScreen(serviceKey: service, threadId: 't1'), api),
      );
      await t.pumpAndSettle();
      api.pushEvent(
        service,
        const AppEvent(
          kind: 'turn/started',
          threadId: 't1',
          raw: '{"turn":{"id":"turn1"}}',
        ),
      );
      api.pushEvent(
        service,
        const AppEvent(
          kind: 'item/started',
          threadId: 't1',
          itemId: 'image1',
          itemType: 'imageGeneration',
          text: '{"status":"in_progress"}',
          raw: '{}',
        ),
      );
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));
      expect(find.byType(ImageLoadingPlaceholder), findsOneWidget);
      api.pushEvent(
        service,
        const AppEvent(
          kind: 'item/completed',
          threadId: 't1',
          itemId: 'image1',
          itemType: 'imageGeneration',
          title: 'A blue circle',
          text: '{"status":"completed"}',
          images: ['/host/generated.png'],
          raw: '{}',
        ),
      );
      api.pushEvent(
        service,
        const AppEvent(kind: 'turn/completed', threadId: 't1', raw: '{}'),
      );
      await t.pumpAndSettle();
      expect(find.byKey(const Key('generated-image-image1')), findsOneWidget);
      expect(find.byKey(const Key('msg-image-0')), findsOneWidget);
      expect(find.byType(ImageLoadingPlaceholder), findsNothing);
      await t.tap(find.byKey(const Key('msg-image-0')));
      await t.pumpAndSettle();
      expect(find.byType(ImageViewerPage), findsOneWidget);
    },
  );

  testWidgets('reopened generated images render without expanding work', (
    t,
  ) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'relay:7666', hasKey: true),
    );
    await api.appConnect('pcx:lb7666:app:default', 28080);
    api.readResult = ThreadHistory(
      items: [
        ThreadItem(
          id: 'restored-image',
          itemType: 'imageGeneration',
          title: 'Blue circle',
          text: '{"status":"completed"}',
          images: ['data:image/png;base64,${base64Encode(onePixelPng)}'],
        ),
      ],
      running: false,
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
    expect(
      find.byKey(const Key('generated-image-restored-image')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('msg-image-0')), findsOneWidget);
  });

  for (final knownTurn in [true, false]) {
    testWidgets(
      'history only animates images in the known active turn ($knownTurn)',
      (t) async {
        await t.binding.setSurfaceSize(const Size(800, 1200));
        addTearDown(() => t.binding.setSurfaceSize(null));
        const service = 'pcx:lb7666:app:default';
        final api = FakeBridgeApi(
          config: const ConfigInfo(relay: 'relay:7666', hasKey: true),
        );
        await api.appConnect(service, 28080);
        api.readResult = ThreadHistory(
          items: const [
            ThreadItem(
              id: 'current-image',
              itemType: 'imageGeneration',
              title: '',
              text: '{"status":"in_progress"}',
              turnId: 'current',
            ),
          ],
          running: true,
          activeTurnId: knownTurn ? 'current' : null,
          turns: knownTurn
              ? const [
                  TurnSummary(turnId: 'old'),
                  TurnSummary(turnId: 'current'),
                ]
              : const [],
          turnPages: const [
            TurnItemsPage(
              turnId: 'old',
              items: [
                ThreadItem(
                  id: 'old-image',
                  itemType: 'imageGeneration',
                  title: '',
                  text: '{"status":"in_progress"}',
                  turnId: 'old',
                ),
              ],
              hasMore: false,
            ),
          ],
        );
        await t.pumpWidget(
          host(
            const AppSessionScreen(serviceKey: service, threadId: 't1'),
            api,
          ),
        );
        for (var i = 0; i < 5; i++) {
          await t.pump(const Duration(milliseconds: 200));
        }
        final current = t.widget<GeneratedImageCard>(
          find.byWidgetPredicate(
            (w) => w is GeneratedImageCard && w.item.id == 'current-image',
          ),
        );
        final old = t.widget<GeneratedImageCard>(
          find.byWidgetPredicate(
            (w) => w is GeneratedImageCard && w.item.id == 'old-image',
          ),
        );
        expect(current.item.streaming, knownTurn);
        expect(old.item.streaming, isFalse);
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('a message from an IDE client shows the request, not the wire '
      'context, and its mentioned image becomes an attachment', (t) async {
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
          text:
              '# Files mentioned by the user:\n\n'
              '## shot.png: C:/Users/u/AppData/Local/Temp/shot.png\n\n'
              '## My request for Codex:\n为什么仍然黑屏',
        ),
      ],
      running: false,
    );
    await t.pumpWidget(
      host(
        const AppSessionScreen(
          serviceKey: 'pcx:lb7666:app:default',
          threadId: 'th-ide',
        ),
        api,
      ),
    );
    await t.pumpAndSettle();

    expect(find.text('为什么仍然黑屏'), findsOneWidget);
    expect(find.textContaining('My request for Codex'), findsNothing);
    expect(find.textContaining('Files mentioned'), findsNothing);
    // The mentioned image is surfaced as an attachment, named by its basename.
    expect(find.textContaining('shot.png'), findsOneWidget);
  });

  testWidgets('a user message from history renders its Markdown and keeps '
      'its typed line breaks', (t) async {
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
          text: 'Please **check** the build\nthen ship it',
        ),
      ],
      running: false,
    );
    await t.pumpWidget(
      host(
        const AppSessionScreen(
          serviceKey: 'pcx:lb7666:app:default',
          threadId: 'th-md',
        ),
        api,
      ),
    );
    await t.pumpAndSettle();

    final markdown = find.byType(MarkdownView);
    expect(
      find.descendant(
        of: markdown,
        matching: find.text(
          'Please check the build\nthen ship it',
          findRichText: true,
        ),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: markdown,
        matching: find.textContaining('**', findRichText: true),
      ),
      findsNothing,
    );
  });

  testWidgets('injected fragments are dropped and a voice handoff unwrapped', (
    t,
  ) async {
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
          text:
              '<recommended_plugins>\n- Box (box@openai)\n</recommended_plugins>',
        ),
        ThreadItem(
          id: 'u2',
          itemType: 'userMessage',
          title: '',
          text:
              '<realtime_delegation>\n  <input>切换到 Live 模式</input>\n'
              '  <transcript_delta>user: …</transcript_delta>\n</realtime_delegation>',
        ),
      ],
      running: false,
    );
    await t.pumpWidget(
      host(
        const AppSessionScreen(
          serviceKey: 'pcx:lb7666:app:default',
          threadId: 'th-frag',
        ),
        api,
      ),
    );
    await t.pumpAndSettle();

    // The machine-written message is gone; the spoken one shows what was said.
    expect(find.textContaining('recommended_plugins'), findsNothing);
    expect(find.textContaining('transcript_delta'), findsNothing);
    expect(find.text('切换到 Live 模式'), findsOneWidget);
  });

  testWidgets('a reasoning card renders its summary as markdown', (t) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
    );
    await api.appConnect('pcx:lb7666:app:default', 28080);
    api.readResult = const ThreadHistory(
      items: [
        ThreadItem(
          id: 'r1',
          itemType: 'reasoning',
          title: '',
          text: '**Planning emulator restart**\n\nChecking the GPU flag.',
        ),
      ],
      running: false,
    );
    await t.pumpWidget(
      host(
        const AppSessionScreen(
          serviceKey: 'pcx:lb7666:app:default',
          threadId: 'th-reason',
        ),
        api,
      ),
    );
    await t.pumpAndSettle();
    await openTurnWork(t);

    // The collapsed peek shows the header with its markup removed.
    expect(find.text('Planning emulator restart'), findsOneWidget);
    expect(find.textContaining('**'), findsNothing);
  });

  testWidgets('Messages are copyable (copy button puts text on clipboard)', (
    t,
  ) async {
    final copied = <String>[];
    // Intercept the clipboard channel to capture what gets copied.
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
    );
    await api.appConnect('pcx:lb7666:app:default', 28080);
    await t.pumpWidget(
      host(const AppSessionScreen(serviceKey: 'pcx:lb7666:app:default'), api),
    );
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField), 'hello');
    await t.pump(); // let the send button enable for the non-empty input
    await t.tap(find.byKey(const Key('send-btn')));
    await t.pumpAndSettle();

    // The copy action appears on hover (desktop). Hover the agent message
    // (the last one rendered, after the user's own), then tap its copy icon.
    final gesture = await t.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(() => gesture.removePointer());
    await gesture.moveTo(t.getCenter(find.byType(MarkdownView).last));
    await t.pumpAndSettle();
    await t.tap(find.byIcon(AppIcons.content_copy_outlined).last);
    await t.pump();
    expect(copied, isNotEmpty);
  });

  testWidgets('One turn is one block, however many items it arrives in', (
    t,
  ) async {
    final copied = <String>[];
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
    );
    await api.appConnect('pcx:lb7666:app:default', 28080);
    // One reply the server split across three items, the way it does when a
    // preamble precedes a tool batch and the answer follows it.
    api.readResult = const ThreadHistory(
      items: [
        ThreadItem(id: 'u1', itemType: 'userMessage', title: '', text: 'ask'),
        ThreadItem(
          id: 'a1',
          itemType: 'agentMessage',
          title: '',
          text: 'part one',
        ),
        ThreadItem(
          id: 'a2',
          itemType: 'agentMessage',
          title: '',
          text: 'part two',
        ),
        ThreadItem(
          id: 'a3',
          itemType: 'agentMessage',
          title: '',
          text: 'part three',
        ),
      ],
      running: false,
    );
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(1400, 900);
    addTearDown(t.view.reset);
    await t.pumpWidget(
      host(
        const AppSessionScreen(
          serviceKey: 'pcx:lb7666:app:default',
          threadId: 'th-merge',
        ),
        api,
      ),
    );
    await t.pumpAndSettle();

    // All three parts are on screen, but as ONE rendered block — not three,
    // each with its own hover actions.
    expect(find.textContaining('part one', findRichText: true), findsWidgets);
    expect(find.textContaining('part three', findRichText: true), findsWidgets);
    final reply = find.byWidgetPredicate(
      (w) => w is MarkdownView && w.data.contains('part one'),
    );
    expect(reply, findsOneWidget);

    // And copying takes the whole turn, not just the part under the pointer.
    final gesture = await t.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(() => gesture.removePointer());
    await gesture.moveTo(t.getCenter(reply));
    await t.pumpAndSettle();
    await t.tap(find.byIcon(AppIcons.content_copy_outlined).last);
    await t.pump();
    expect(copied.single, contains('part one'));
    expect(copied.single, contains('part three'));
  });

  testWidgets('Agent replies render as Markdown (headings, not a bubble)', (
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
        kind: 'item/agentMessage/delta',
        threadId: 't1',
        itemId: 'a1',
        itemType: 'agentMessage',
        text: '# Title\n\nsome **bold** body',
        raw: '{}',
      ),
    );
    await t.pumpAndSettle();
    // Markdown produces RichText spans, not a Text bubble.
    expect(find.byType(MarkdownView), findsOneWidget);
    expect(find.textContaining('Title', findRichText: true), findsWidgets);
  });

  testWidgets('A <proposed_plan> message renders without the wrapper tags', (
    t,
  ) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
    );
    await api.appConnect('pcx:lb7666:app:default', 28080);
    api.readResult = const ThreadHistory(
      items: [
        ThreadItem(
          id: 'a1',
          itemType: 'agentMessage',
          title: '',
          text: '<proposed_plan>\n# English Plan\nStep one.\n</proposed_plan>',
        ),
      ],
      running: false,
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
    // The rendered markdown shows the plan content but not the wrapper tags.
    final md = t
        .widgetList<MarkdownView>(find.byType(MarkdownView))
        .firstWhere((w) => w.data.contains('English Plan'));
    expect(md.data.contains('proposed_plan'), isFalse);
  });

  testWidgets('Resume collapses a back-to-back duplicate user message', (
    t,
  ) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
    );
    await api.appConnect('pcx:lb7666:app:default', 28080);
    // The artifact of a dropped-but-committed send recorded twice.
    api.readResult = const ThreadHistory(
      items: [
        ThreadItem(id: 'u1', itemType: 'userMessage', title: '', text: 'do it'),
        ThreadItem(id: 'u2', itemType: 'userMessage', title: '', text: 'do it'),
      ],
      running: false,
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
    expect(find.text('do it'), findsOneWidget);
  });

  testWidgets('Resume keeps a genuine re-ask (a reply sits between)', (
    t,
  ) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
    );
    await api.appConnect('pcx:lb7666:app:default', 28080);
    api.readResult = const ThreadHistory(
      items: [
        ThreadItem(id: 'u1', itemType: 'userMessage', title: '', text: 'do it'),
        ThreadItem(id: 'a1', itemType: 'agentMessage', title: '', text: 'ok'),
        ThreadItem(id: 'u2', itemType: 'userMessage', title: '', text: 'do it'),
      ],
      running: false,
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
    expect(find.text('do it'), findsNWidgets(2));
  });

  testWidgets('URLs in a message render as tappable links', (t) async {
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
          text: 'see https://example.com for details',
        ),
      ],
      running: false,
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
    // The user bubble renders its bare URL as a link (highlighted and
    // tappable) rather than as inert text: a span carrying a tap recognizer.
    final linked = find.byWidgetPredicate((w) {
      if (w is! RichText) return false;
      var found = false;
      w.text.visitChildren((span) {
        if (span is TextSpan &&
            span.recognizer != null &&
            (span.text ?? '').contains('example.com')) {
          found = true;
        }
        return !found;
      });
      return found;
    });
    expect(linked, findsWidgets);
  });

  testWidgets('A compaction item shows its live lifecycle in the transcript', (
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
        itemId: 'cc1',
        itemType: 'contextCompaction',
        title: '',
        text: '',
        raw: '{}',
      ),
    );
    await t.pump();
    await t.pump(const Duration(milliseconds: 100));
    // In flight, so the turn's work is already open.
    expect(find.text('正在自动压缩上下文'), findsOneWidget);
    expect(find.byKey(const Key('chat-compaction-progress')), findsOneWidget);

    api.pushEvent(
      'pcx:lb7666:app:default',
      const AppEvent(
        kind: 'item/completed',
        threadId: 't1',
        itemId: 'cc1',
        itemType: 'contextCompaction',
        title: '',
        text: '',
        raw: '{}',
      ),
    );
    await t.pumpAndSettle();
    // Settled, so the work folded away with it. Re-open to see the outcome.
    await openTurnWork(t);
    expect(find.text('对话已压缩'), findsOneWidget); // compacted (zh)
    expect(find.byKey(const Key('chat-compaction-progress')), findsNothing);
  });
}
