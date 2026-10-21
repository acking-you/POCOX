part of '../composer_recovery_test.dart';

void _registerSendOwnership() {
  group('failed and outlived sends', () {
    // Two images with different content and one uploaded file, so a resend can
    // be checked for exactly its own payload, in order.
    final red = tinyPng(red: 10);
    final blue = tinyPng(red: 90);
    const notesPath = '/host/uploads/123/notes.md';

    late FakeImagePicker picker;
    late FakeFileSelector files;
    ImagePickerPlatform? previousPicker;
    fsel.FileSelectorPlatform? previousFiles;
    Future<ProcessedImage> Function(Uint8List)? previousProcess;
    setUp(() {
      previousProcess = processImageImpl;
      // compute() never completes under the fake clock: process inline.
      processImageImpl = (bytes) async => preparedImageFixture(bytes);
      previousPicker = ImagePickerPlatform.instance;
      previousFiles = fsel.FileSelectorPlatform.instance;
      picker = FakeImagePicker();
      files = FakeFileSelector();
      ImagePickerPlatform.instance = picker;
      fsel.FileSelectorPlatform.instance = files;
    });
    tearDown(() {
      processImageImpl = previousProcess!;
      ImagePickerPlatform.instance = previousPicker!;
      fsel.FileSelectorPlatform.instance = previousFiles!;
    });

    /// Attach [red] and [blue] (one pick) and `notes.md` through the `+` menu,
    /// with bounded pumps (a turn may be running).
    Future<void> attachAll(WidgetTester t) async {
      picker.files = [MemXFile(red, 'red.png'), MemXFile(blue, 'blue.png')];
      await t.tap(find.byKey(const Key('attach-menu-btn')));
      await frames(t);
      await t.tap(find.byKey(const Key('attach-btn')));
      await frames(t);
      files.files = [
        MemXFile(Uint8List.fromList([1, 2, 3]), 'notes.md'),
      ];
      await t.tap(find.byKey(const Key('attach-menu-btn')));
      await frames(t);
      await t.tap(find.byKey(const Key('attach-file-btn')));
      await frames(t);
      for (final id in [0, 1, 2]) {
        expect(find.byKey(Key('attachment-$id')), findsOneWidget);
      }
    }

    final allImages = [
      preparedImageFixture(red).dataUrl,
      preparedImageFixture(blue).dataUrl,
    ];
    final secondWithFile = appendFileRefs('second', [notesPath]);

    for (final service in [codex, acp]) {
      final engine = service == codex ? 'Codex' : 'ACP';
      group('$engine: a failed queued message', () {
        /// Queue "second" (with its images and file when [attach]) and
        /// "third" behind a running "first", type "still typing" into the
        /// composer, then end "first" with the next turn/start failing as given.
        Future<FakeBridgeApi> failQueuedSend(
          WidgetTester t, {
          Object? refused,
          Object? lost,
          bool attach = false,
          List<ThreadMeta> threads = const [],
        }) async {
          final api = FakeBridgeApi()..autoCompleteTurn = false;
          if (service == acp) {
            api.acpCapabilities[acp] = acpCapsOf(imageInput: true);
          }
          api.appThreads.addAll(threads);
          await api.appConnect(service, 28080);
          await t.pumpWidget(
            host(AppSessionScreen(serviceKey: service, threadId: 't1'), api),
          );
          await t.pumpAndSettle();
          await type(t, 'first');
          await send(t);
          if (attach) await attachAll(t);
          await type(t, 'second');
          await send(t);
          await type(t, 'third');
          await send(t);
          await type(t, 'still typing');
          api
            ..turnStartError = refused
            ..turnStartLostAnswer = lost;
          api.pushEvent(
            service,
            const AppEvent(kind: 'turn/completed', threadId: 't1', raw: '{}'),
          );
          await frames(t);
          expect(api.turnStartCount, 2, reason: 'tried once');
          return api;
        }

        testWidgets('a proven refusal keeps its place until Retry', (t) async {
          // The agent host's own pre-admission refusal, verbatim.
          final api = await failQueuedSend(
            t,
            refused: 'a turn is already running in this session',
          );
          // Still first in line, not shown as sent, and the queue paused.
          expect(find.byKey(const Key('queued-0')), findsOneWidget);
          expect(find.byKey(const Key('queued-uncertain-0')), findsNothing);
          expect(find.byKey(const Key('queued-1')), findsOneWidget);
          // Only in its queue chip: not in the rendered conversation. (The
          // bar title falls back to the last text sent or retried.)
          expect(
            find.descendant(
              of: find.byKey(const Key('queued-0')),
              matching: find.text('second'),
            ),
            findsOneWidget,
            reason: 'its queue chip',
          );
          expect(
            find.descendant(
              of: find.byKey(const ValueKey('chat-content')),
              matching: find.text('second'),
            ),
            findsNothing,
            reason: 'not shown as sent',
          );
          expect(find.byKey(const Key('session-error')), findsOneWidget);
          await frames(t);
          expect(api.turnStartCount, 2, reason: 'never replayed by itself');

          await t.tap(retryButton());
          await frames(t);
          expect(api.turnStartCount, 3);
          expect(api.lastTurnText, 'second', reason: 'order preserved');
          expect(find.byKey(const Key('queued-0')), findsNothing);
          expect(find.byKey(const Key('queued-1')), findsOneWidget);
          expect(composerText(t), 'still typing');
        });

        for (final phrasing in [
          'request timed out after 30s',
          'the agent did not answer in time',
          'connection reset by peer',
          'something unfamiliar happened',
        ]) {
          testWidgets('"$phrasing" keeps it queued as uncertain', (t) async {
            final api = await failQueuedSend(t, refused: phrasing);
            expect(find.byKey(const Key('queued-0')), findsOneWidget);
            expect(find.byKey(const Key('queued-uncertain-0')), findsOneWidget);
            expect(find.byKey(const Key('queued-1')), findsOneWidget);
            expect(
              composerText(t),
              'still typing',
              reason: 'the newer draft is untouched',
            );
            // Sending more queues behind it and does not replay it.
            await type(t, 'fourth');
            await send(t);
            expect(api.turnStartCount, 2, reason: 'never replayed by itself');
            expect(find.byKey(const Key('queued-2')), findsOneWidget);
          });
        }

        // A readable history never settles an uncertain message: content is
        // no request identity, the tail is bounded and other writers add to it.
        final histories = <String, ThreadHistory>{
          'a later message of another writer': const ThreadHistory(
            items: [
              ThreadItem(
                id: 'u2',
                itemType: 'userMessage',
                title: '',
                text: 'x',
              ),
              ThreadItem(
                id: 'u3',
                itemType: 'userMessage',
                title: '',
                text: 'from another device',
              ),
            ],
            running: false,
          ),
          'a bounded tail without it': const ThreadHistory(
            items: [],
            running: false,
            hasOlder: true,
          ),
          'an identical earlier prompt': const ThreadHistory(
            items: [
              ThreadItem(
                id: 'u0',
                itemType: 'userMessage',
                title: '',
                text: 'second',
              ),
            ],
            running: false,
          ),
        };
        for (final MapEntry(key: name, value: history) in histories.entries) {
          testWidgets('$name leaves it uncertain and unsent', (t) async {
            final api = await failQueuedSend(t, lost: 'request timed out');
            expect(api.lastTurnText, 'second', reason: 'it reached the host');
            api.readResult = history;
            // A reload of the conversation reads that history.
            api.pushEvent(
              service,
              const AppEvent(
                kind: 'thread/compacted',
                threadId: 't1',
                raw: '{}',
              ),
            );
            await frames(t);
            await pastGrace(t);
            expect(api.turnStartCount, 2, reason: 'nothing resent by itself');
            expect(find.byKey(const Key('queued-uncertain-0')), findsOneWidget);
            expect(find.byKey(const Key('queued-1')), findsOneWidget);
            expect(composerText(t), 'still typing');
            // The reload cleared the banner; its Retry is offered again.
            expect(find.textContaining('不会自动发送'), findsOneWidget);
          });
        }

        testWidgets('Retry resends it exactly as queued, images and file', (
          t,
        ) async {
          final api = await failQueuedSend(
            t,
            lost: 'request timed out',
            attach: true,
          );
          expectTurn(
            api.turnStartCalls[1],
            service: service,
            thread: 't1',
            text: secondWithFile,
            images: allImages,
          );
          expect(find.byKey(const Key('queued-uncertain-0')), findsOneWidget);
          expect(
            find.textContaining('不会自动发送'),
            findsOneWidget,
            reason: 'the banner says it may already have arrived',
          );
          await t.tap(retryButton());
          await frames(t);
          expect(api.turnStartCount, 3);
          expectTurn(
            api.turnStartCalls[2],
            service: service,
            thread: 't1',
            text: secondWithFile,
            images: allImages,
          );
          expect(find.byKey(const Key('queued-0')), findsNothing);
          expect(find.byKey(const Key('queued-1')), findsOneWidget);
          expect(composerText(t), 'still typing');
        });

        testWidgets('removing it keeps the rest queued until the user sends', (
          t,
        ) async {
          final api = await failQueuedSend(t, lost: 'request timed out');
          await t.tap(find.byKey(const Key('queued-remove-0')));
          await frames(t);
          expect(find.byKey(const Key('queued-0')), findsNothing);
          expect(find.byKey(const Key('queued-1')), findsOneWidget);
          expect(api.turnStartCount, 2, reason: 'the paused queue holds');
          await type(t, 'fourth');
          await send(t);
          expect(api.turnStartCount, 3);
          expect(
            api.lastTurnText,
            'third',
            reason: 'the queue resumes in order',
          );
        });

        testWidgets('it survives leaving and reopening, unsent', (t) async {
          await t.binding.setSurfaceSize(wide);
          addTearDown(() => t.binding.setSurfaceSize(null));
          final api = await failQueuedSend(
            t,
            refused: 'request timed out',
            threads: twoThreads,
          );
          await t.tap(find.byKey(const Key('conv-tile-t2')));
          await frames(t);
          await t.tap(find.byKey(const Key('conv-tile-t1')));
          await frames(t);
          expect(find.byKey(const Key('queued-uncertain-0')), findsOneWidget);
          expect(find.byKey(const Key('queued-1')), findsOneWidget);
          expect(api.turnStartCount, 2, reason: 'reopening replays nothing');
          // Its explicit Retry is offered again in the reopened conversation.
          expect(retryButton(), findsOneWidget);
        });
      });
    }

    // Every step of a send belongs to the host connection it began on: a step
    // finishing after that connection was lost or replaced dispatches nothing
    // more and adopts nothing (no queue removal, no admission, no drain). Its
    // input stays the user's: back in its draft, or still queued.
    group('a send outliving its host connection', () {
      /// The notice that put an ordinary message back in the composer.
      Finder returned() => find.textContaining('消息已放回输入框');

      // A session created through a connection that moved (another
      // generation or source of the same service name, or a replaced host)
      // is not known to belong to whichever host answers now: it is never
      // adopted, recorded or listed, and the input stays in its own unsent
      // draft. The draft's session on the current host is opened anew, and
      // the user's next send uses that one.
      for (final replaced in [false, true]) {
        testWidgets('a thread start finishing after a host change '
            '(replaced: $replaced) is not adopted; the input returns', (
          t,
        ) async {
          final api = FakeBridgeApi()..acpCapabilities[acp] = acpCapsOf();
          await api.appConnect(acp, 28080);
          // The new conversation opens its session by itself; this one is
          // held, and the send below waits for it.
          final gate = Completer<void>();
          api.threadStartGate = gate;
          await t.pumpWidget(
            host(const AppSessionScreen(serviceKey: acp, cwd: '/work'), api),
          );
          await frames(t);
          await type(t, 'hello');
          await send(t);
          expect(api.threadStartCalls, [acp]);
          await hostChange(t, api, 2, replaced: replaced);
          gate.complete();
          // The brief notice says so as the late answer arrives...
          await frames(t);
          expect(find.textContaining('没有发送这条消息'), findsOneWidget);
          expect(returned(), findsOneWidget);
          // ...and through the reconnect nothing reaches any host.
          await seconds(t, 4);
          expect(api.turnStartCount, 0, reason: 'nothing to any host');
          expect(composerText(t), 'hello');
          expect(
            find.text('thread-0'),
            findsNothing,
            reason: 'the old connection\'s session is not listed',
          );
          // The current host opened its own session for the draft, which
          // the user's own send uses.
          expect(api.threadStartCalls, [acp, acp]);
          await send(t);
          expect(api.threadStartCalls, [acp, acp]);
          expect(api.turnStartCalls, hasLength(1));
          expectTurn(
            api.turnStartCalls.single,
            service: acp,
            thread: 'thread-1',
            text: 'hello',
          );
        });
      }

      testWidgets('a model list of a new conversation finishing after the '
          'connection dropped starts no session; the input returns', (t) async {
        final api = FakeBridgeApi();
        await api.appConnect(codex, 28080);
        await t.pumpWidget(
          host(const AppSessionScreen(serviceKey: codex, cwd: '/work'), api),
        );
        await t.pumpAndSettle();
        await turnSetting(t, 'plan');
        final gate = Completer<void>();
        api.modelListGate = gate;
        await type(t, 'plan this');
        await send(t);
        await api.appDisconnect(codex);
        await frames(t);
        gate.complete();
        await frames(t);
        expect(find.textContaining('没有发送这条消息'), findsOneWidget);
        expect(returned(), findsOneWidget);
        await seconds(t, 4);
        expect(api.threadStartCalls, isEmpty, reason: 'no session anywhere');
        expect(api.turnStartCount, 0);
        expect(composerText(t), 'plan this');
        await send(t);
        expect(api.threadStartCalls, [codex]);
        expect(api.turnStartCalls, hasLength(1));
        expectTurn(
          api.turnStartCalls.single,
          service: codex,
          thread: 'thread-0',
          text: 'plan this',
        );
        expect(api.lastCollaborationMode, 'plan');
      });

      testWidgets('a model list finishing after the connection dropped sends '
          'nothing; the input returns', (t) async {
        final api = FakeBridgeApi();
        await api.appConnect(codex, 28080);
        await t.pumpWidget(
          host(const AppSessionScreen(serviceKey: codex, threadId: 't1'), api),
        );
        await t.pumpAndSettle();
        // Plan mode needs a concrete model, resolved from the list on send.
        await turnSetting(t, 'plan');
        final gate = Completer<void>();
        api.modelListGate = gate;
        await type(t, 'plan this');
        await send(t);
        // The event stream closes: the view reconnects meanwhile.
        await api.appDisconnect(codex);
        await frames(t);
        gate.complete();
        await frames(t);
        expect(returned(), findsOneWidget);
        await seconds(t, 4);
        expect(api.turnStartCount, 0);
        expect(composerText(t), 'plan this');
        await send(t);
        expect(api.turnStartCalls, hasLength(1));
        expectTurn(
          api.turnStartCalls.single,
          service: codex,
          thread: 't1',
          text: 'plan this',
        );
        expect(api.lastCollaborationMode, 'plan');
      });

      testWidgets('an answer after a host change is not adopted; the input '
          'returns', (t) async {
        final api = FakeBridgeApi()
          ..acpCapabilities[acp] = acpCapsOf()
          ..autoCompleteTurn = false
          ..announceTurnStart = false;
        await api.appConnect(acp, 28080);
        await t.pumpWidget(
          host(const AppSessionScreen(serviceKey: acp, threadId: 'ses-1'), api),
        );
        await t.pumpAndSettle();
        final gate = Completer<void>();
        api.turnStartGate = gate;
        await type(t, 'hello');
        await send(t);
        await hostChange(t, api, 2, replaced: false);
        gate.complete();
        await frames(t);
        expect(composerText(t), 'hello', reason: 'kept for the user');
        // In the composer only: the rendered conversation holds no
        // optimistic copy. (The bar title falls back to the last text sent.)
        expect(
          find.descendant(
            of: find.byKey(const Key('composer-input')),
            matching: find.text('hello'),
          ),
          findsOneWidget,
          reason: 'kept in the composer',
        );
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('chat-content')),
            matching: find.text('hello'),
          ),
          findsNothing,
          reason: 'no optimistic copy',
        );
        expect(find.textContaining('无法确定'), findsOneWidget);
        expect(find.byKey(const Key('stop-btn')), findsNothing);
        expect(api.turnStartCalls, hasLength(1), reason: 'never resent');
        // Not awaiting any admission and not locked: the user's send goes.
        await send(t);
        expect(api.turnStartCalls, hasLength(2));
        expectTurn(
          api.turnStartCalls.last,
          service: acp,
          thread: 'ses-1',
          text: 'hello',
        );
      });

      testWidgets('a queued answer after a host change stays queued, uncertain '
          'and exact', (t) async {
        final api = FakeBridgeApi()
          ..acpCapabilities[acp] = acpCapsOf(imageInput: true)
          ..autoCompleteTurn = false
          ..announceTurnStart = false;
        await api.appConnect(acp, 28080);
        await t.pumpWidget(
          host(const AppSessionScreen(serviceKey: acp, threadId: 't1'), api),
        );
        await t.pumpAndSettle();
        await type(t, 'first');
        await send(t);
        api.pushEvent(acp, turn('turn/started', 't1', 'a'));
        await frames(t);
        await attachAll(t);
        await type(t, 'second');
        await send(t);
        await type(t, 'third');
        await send(t);
        await type(t, 'still typing');
        final gate = Completer<void>();
        api.turnStartGate = gate;
        api.pushEvent(acp, turn('turn/completed', 't1', 'a'));
        await frames(t);
        expect(api.turnStartCalls, hasLength(2), reason: '"second" is out');
        await hostChange(t, api, 2, replaced: false, imageInput: true);
        gate.complete();
        await frames(t);
        expect(find.byKey(const Key('queued-uncertain-0')), findsOneWidget);
        expect(find.byKey(const Key('queued-1')), findsOneWidget);
        expect(composerText(t), 'still typing');
        expect(find.textContaining('不会自动发送'), findsOneWidget);
        // No admission, no drain: nothing else goes, not even later.
        await pastGrace(t);
        expect(api.turnStartCalls, hasLength(2));
        await t.tap(retryButton());
        await frames(t);
        expect(api.turnStartCalls, hasLength(3));
        for (final call in api.turnStartCalls.skip(1)) {
          expectTurn(
            call,
            service: acp,
            thread: 't1',
            text: secondWithFile,
            images: allImages,
          );
        }
        expect(find.byKey(const Key('queued-0')), findsNothing);
        expect(find.byKey(const Key('queued-1')), findsOneWidget);
      });

      testWidgets('a thread start finishing after the user moved on still '
          'sends for its own draft; the newer view is untouched', (t) async {
        await t.binding.setSurfaceSize(wide);
        addTearDown(() => t.binding.setSurfaceSize(null));
        final api = FakeBridgeApi()..acpCapabilities[acp] = acpCapsOf();
        api.appThreads.addAll(const [
          ThreadMeta(id: 'ses-1', preview: 'one', cwd: '/work', updatedAt: 2),
          ThreadMeta(id: 'ses-2', preview: 'two', cwd: '/work', updatedAt: 1),
        ]);
        await api.appConnect(acp, 28080);
        // The draft's own session opening is held; the send waits for it.
        final gate = Completer<void>();
        api.threadStartGate = gate;
        await t.pumpWidget(
          host(const AppSessionScreen(serviceKey: acp, cwd: '/work'), api),
        );
        await frames(t);
        await type(t, 'hello');
        await send(t);
        // Away to another conversation, and a newer send there.
        await t.tap(find.byKey(const Key('conv-tile-ses-2')));
        await frames(t);
        await type(t, 'other');
        await send(t);
        expect(api.turnStartCalls, hasLength(1));
        expectTurn(
          api.turnStartCalls.single,
          service: acp,
          thread: 'ses-2',
          text: 'other',
        );
        gate.complete();
        await frames(t);
        expect(api.threadStartCalls, [acp]);
        expect(api.turnStartCalls, hasLength(2));
        expectTurn(
          api.turnStartCalls.last,
          service: acp,
          thread: 'thread-0',
          text: 'hello',
        );
        expect(composerText(t), '', reason: 'the shown draft is untouched');
        expect(returned(), findsNothing);
        // Neither send holds the composer: the next one goes too.
        await type(t, 'more');
        await send(t);
        expect(api.turnStartCalls, hasLength(3));
        expectTurn(
          api.turnStartCalls.last,
          service: acp,
          thread: 'ses-2',
          text: 'more',
        );
      });
    });
  });
}
