// Supplementing a running ACP turn: offered only when the agent negotiated
// steering, sent for exactly the running turn, input cleared only when the
// turn took it, and an input the ended turn did not consume becomes the next
// turn exactly once. An answer is applied only while it still owns its input
// — the same service, host connection, conversation view, draft and request;
// arriving after any of them changed, it leaves the draft, its attachments,
// the queue and a newer request's state exactly as they were. Driven through
// the real composer (pointer taps on the hit-tested buttons, typed text,
// the desktop paste shortcut) with bounded pumps, since a running turn never
// settles.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/image_attachments.dart';
import 'package:pocox/src/screens/app_session_screen.dart';

import 'fake_bridge_api.dart';
import 'support/acp_capabilities.dart';
import 'support/screen_harness.dart';

const acp = 'pcx:dev:acp:claude';

AppCapabilities caps({
  required bool steer,
  int generation = 1,
  bool imageInput = false,
}) => negotiatedAcpCapabilities(
  providerName: 'Claude',
  generation: generation,
  imageInput: imageInput,
  steer: steer,
);

Future<void> frames(WidgetTester t) async {
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

/// Open session `ses-1` with turn `t1` running.
Future<FakeBridgeApi> running(
  WidgetTester t, {
  bool steer = true,
  bool imageInput = false,
  List<ThreadMeta> threads = const [],
}) async {
  final api = FakeBridgeApi()
    ..acpCapabilities[acp] = caps(steer: steer, imageInput: imageInput)
    ..autoCompleteTurn = false;
  api.appThreads.addAll(threads);
  await api.appConnect(acp, 28080);
  await t.pumpWidget(
    host(const AppSessionScreen(serviceKey: acp, threadId: 'ses-1'), api),
  );
  await frames(t);
  api.pushEvent(
    acp,
    const AppEvent(
      kind: 'turn/started',
      threadId: 'ses-1',
      raw: '{"turnId":"t1"}',
    ),
  );
  await frames(t);
  return api;
}

void ended(FakeBridgeApi api, String turn) => api.pushEvent(
  acp,
  AppEvent(
    kind: 'turn/completed',
    threadId: 'ses-1',
    raw: '{"turnId":"$turn"}',
  ),
);

String composerText(WidgetTester t) => t
    .widget<TextField>(find.byKey(const Key('composer-input')))
    .controller!
    .text;

/// Type [text] with Supplement selected and press Send.
Future<void> supplement(WidgetTester t, String text) async {
  await t.tap(find.byKey(const Key('supplement-toggle')));
  await t.pump();
  await t.enterText(find.byKey(const Key('composer-input')), text);
  await t.pump();
  await t.tap(find.byKey(const Key('send-btn')));
  await frames(t);
}

/// Pick [names] as images through the `+` menu while a turn runs.
Future<void> attachImages(
  WidgetTester t,
  FakeImagePicker picker,
  List<String> names,
) async {
  picker.files = [for (final name in names) MemXFile(tinyPng(), name)];
  await t.tap(find.byKey(const Key('attach-menu-btn')));
  await frames(t);
  await t.tap(find.byKey(const Key('attach-btn')));
  await frames(t);
}

/// Replace the host behind [acp] with generation 2 while a request waits.
Future<void> replaceHost(
  WidgetTester t,
  FakeBridgeApi api, {
  bool imageInput = false,
}) async {
  api.acpCapabilities[acp] = caps(
    steer: true,
    generation: 2,
    imageInput: imageInput,
  );
  api.pushEvent(
    acp,
    const AppEvent(kind: 'acp/host/state', raw: '{"generation":2}'),
  );
  await frames(t);
}

const twoSessions = [
  ThreadMeta(id: 'ses-1', preview: 'one', cwd: '/work', updatedAt: 2),
  ThreadMeta(id: 'ses-2', preview: 'two', cwd: '/work', updatedAt: 1),
];

/// The notice an answer that no longer owns its input shows.
Finder staleNotice() => find.textContaining('回复到达时');

void main() {
  setUp(AppSessionScreen.debugResetThreadMemory);

  testWidgets('a supplement the running turn took is sent once and cleared', (
    t,
  ) async {
    final api = await running(t);
    await supplement(t, 'also check the tests');
    // Once, for the running turn, with exactly its text and no images (a
    // record's list field compares by identity, so the fields are checked).
    expect(api.supplementCalls, hasLength(1));
    final (thread, turn, text, images) = api.supplementCalls.single;
    expect((thread, turn, text), ('ses-1', 't1', 'also check the tests'));
    expect(images, isEmpty);
    expect(composerText(t), '');
    expect(find.text('also check the tests'), findsOneWidget);
    expect(api.turnStartCount, 0, reason: 'never a prompt');
    // The turn ends: nothing was queued, nothing is sent.
    ended(api, 't1');
    await frames(t);
    expect(api.turnStartCount, 0);
  });

  testWidgets('a supplement stays below the reply it arrived during until '
      'the agent merges it', (t) async {
    final api = await running(t);
    await supplement(t, 'also the docs');
    AppEvent agent(String id, String text) => AppEvent(
      kind: 'item/completed',
      threadId: 'ses-1',
      itemId: id,
      itemType: 'agentMessage',
      text: text,
      raw: '{"turnId":"t1"}',
    );
    double top(String text) => t.getTopLeft(find.text(text)).dy;
    // The reply streaming when it was sent keeps going above it.
    api.pushEvent(acp, agent('ses-1:a1', 'still reading'));
    await frames(t);
    expect(top('still reading'), lessThan(top('also the docs')));
    // The host's copy marks the merge point; what follows comes after it.
    api.pushEvent(
      acp,
      AppEvent(
        kind: 'item/completed',
        threadId: 'ses-1',
        itemId: 'ses-1:s1',
        itemType: 'userMessage',
        text: 'also the docs',
        raw: jsonEncode({
          'turnId': 't1',
          'clientId': api.lastSupplementClientId,
        }),
      ),
    );
    api.pushEvent(acp, agent('ses-1:a2', 'docs updated'));
    await frames(t);
    expect(find.text('also the docs'), findsOneWidget);
    expect(top('also the docs'), lessThan(top('docs updated')));
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.macOS]) {
    testWidgets(
      'supplement stays usable after normal send on $platform',
      (t) async {
        final api = await running(t);
        ended(api, 't1');
        await frames(t);
        await t.enterText(
          find.byKey(const Key('composer-input')),
          'first turn',
        );
        await t.pump();
        await t.tap(find.byKey(const Key('send-btn')));
        await frames(t);
        expect(api.turnStartCount, 1);
        final toggle = find.byKey(const Key('supplement-toggle'));
        expect(t.widget<FilterChip>(toggle).onSelected, isNotNull);
        await supplement(t, 'adjust while running');
        expect(api.supplementCalls, hasLength(1));
        expect(api.supplementCalls.single.$1, 'ses-1');
        expect(api.supplementCalls.single.$3, 'adjust while running');
        expect(api.turnStartCount, 1, reason: 'no replacement turn');
        expect(composerText(t), isEmpty);
        expect(find.byKey(const Key('queued-0')), findsNothing);
      },
      variant: TargetPlatformVariant({platform}),
    );
  }

  testWidgets(
    'input the ended turn did not consume becomes the next turn once',
    (t) async {
      final api = await running(t)
        ..supplementInjects = false;
      await supplement(t, 'one more thing');
      expect(api.supplementCalls, hasLength(1));
      expect(composerText(t), '');
      expect(find.byKey(const Key('queued-0')), findsOneWidget);
      // Not before the turn's end is confirmed.
      expect(api.turnStartCount, 0);
      ended(api, 't1');
      await frames(t);
      expect(api.turnStartCount, 1);
      expect(api.lastTurnText, 'one more thing');
      expect(find.byKey(const Key('queued-0')), findsNothing);
      // A repeated end of that turn sends nothing again.
      ended(api, 't1');
      await frames(t);
      expect(api.turnStartCount, 1);
      expect(api.supplementCalls, hasLength(1), reason: 'never retried');
    },
  );

  testWidgets('edits made while the supplement was in flight are kept', (
    t,
  ) async {
    final api = await running(t);
    final gate = Completer<void>();
    api.supplementGate = gate;
    await supplement(t, 'first words');
    await t.enterText(find.byKey(const Key('composer-input')), 'newer words');
    await t.pump();
    gate.complete();
    await frames(t);
    expect(
      composerText(t),
      'newer words',
      reason: 'only the accepted input is cleared',
    );
    expect(find.text('first words'), findsOneWidget);
  });

  testWidgets('edited input the ended turn did not take stays, unsent', (
    t,
  ) async {
    final api = await running(t)
      ..supplementInjects = false;
    final gate = Completer<void>();
    api.supplementGate = gate;
    await supplement(t, 'first words');
    await t.enterText(find.byKey(const Key('composer-input')), 'newer words');
    await t.pump();
    gate.complete();
    await frames(t);
    expect(composerText(t), 'newer words');
    expect(find.byKey(const Key('queued-0')), findsNothing);
    ended(api, 't1');
    await frames(t);
    expect(
      api.turnStartCount,
      0,
      reason: "nothing is sent on the user's behalf",
    );
  });

  testWidgets(
    'a refused or unknown outcome keeps the input and is not retried',
    (t) async {
      final api = await running(t)
        ..supplementError = StateError(
          'the agent host changed before it answered, so the message may or '
          'may not have been added; check the conversation before sending it '
          'again',
        );
      await supplement(t, 'keep me');
      expect(composerText(t), 'keep me');
      expect(find.byKey(const Key('session-error')), findsOneWidget);
      expect(find.textContaining('may or may not'), findsOneWidget);
      ended(api, 't1');
      await frames(t);
      expect(api.supplementCalls, hasLength(1));
      expect(api.turnStartCount, 0, reason: 'never converted into a prompt');
    },
  );

  testWidgets('an agent without steering says so and queues instead', (
    t,
  ) async {
    final api = await running(t, steer: false);
    expect(find.byKey(const Key('supplement-toggle')), findsNothing);
    final unavailable = find.byKey(const Key('supplement-unavailable'));
    expect(unavailable, findsOneWidget);
    expect(find.text('仅支持排队'), findsOneWidget);
    await t.enterText(find.byKey(const Key('composer-input')), 'later');
    await t.pump();
    await t.tap(unavailable);
    await frames(t);
    expect(find.text('补充说明不可用'), findsOneWidget);
    expect(find.textContaining('Claude 没有通过当前 ACP 连接声明'), findsOneWidget);
    expect(api.supplementCalls, isEmpty);
    expect(api.turnStartCount, 0);
    expect(composerText(t), 'later');
    // The note is a popover: Escape (or a click outside) closes it.
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await frames(t);
    expect(find.text('补充说明不可用'), findsNothing);
    await t.tap(find.byKey(const Key('send-btn')));
    await frames(t);
    expect(api.supplementCalls, isEmpty);
    expect(find.byKey(const Key('queued-0')), findsOneWidget);
    ended(api, 't1');
    await frames(t);
    expect(api.turnStartCount, 1);
    expect(api.lastTurnText, 'later');
  });

  group('an answer that no longer owns its input', () {
    for (final injects in [true, false]) {
      final outcome = injects ? 'injected' : 'not consumed';

      testWidgets('$outcome after a host change keeps the draft', (t) async {
        final api = await running(t)
          ..supplementInjects = injects;
        final gate = Completer<void>();
        api.supplementGate = gate;
        await supplement(t, 'late words');
        await replaceHost(t, api);
        final reads = api.threadReads.length;
        gate.complete();
        await frames(t);
        expect(composerText(t), 'late words', reason: 'kept as it was');
        expect(find.byKey(const Key('queued-0')), findsNothing);
        expect(staleNotice(), findsOneWidget);
        // No local copy; when the host reported it added, the history
        // (reloaded) is what shows it.
        expect(
          find.text('late words'),
          findsOneWidget,
          reason: 'composer only',
        );
        if (injects) {
          expect(api.threadReads.length, greaterThan(reads));
        }
        await frames(t);
        expect(
          staleNotice(),
          findsOneWidget,
          reason: 'its own (display-only) refresh keeps the notice',
        );
        ended(api, 't1');
        await frames(t);
        expect(
          api.turnStartCount,
          0,
          reason: "nothing is sent on the user's behalf",
        );
        expect(api.supplementCalls, hasLength(1));
      });

      testWidgets('$outcome after leaving and reopening keeps the draft', (
        t,
      ) async {
        await t.binding.setSurfaceSize(const Size(1600, 900));
        addTearDown(() => t.binding.setSurfaceSize(null));
        final api = await running(t, threads: twoSessions)
          ..supplementInjects = injects;
        final gate = Completer<void>();
        api.supplementGate = gate;
        await supplement(t, 'away words');
        await t.tap(find.byKey(const Key('conv-tile-ses-2')));
        await frames(t);
        await t.tap(find.byKey(const Key('conv-tile-ses-1')));
        await frames(t);
        gate.complete();
        await frames(t);
        // The same session id, but another request: not this view's answer.
        expect(composerText(t), 'away words');
        expect(find.byKey(const Key('queued-0')), findsNothing);
        await frames(t);
        expect(staleNotice(), findsOneWidget, reason: 'after any refresh');
        expect(api.turnStartCount, 0, reason: 'never queued as a prompt');
        expect(api.supplementCalls, hasLength(1));
      });

      testWidgets('$outcome after the screen is gone changes nothing', (
        t,
      ) async {
        final api = await running(t)
          ..supplementInjects = injects;
        final gate = Completer<void>();
        api.supplementGate = gate;
        await supplement(t, 'gone words');
        await t.pumpWidget(const SizedBox());
        gate.complete();
        await t.pump();
        await t.pump(const Duration(milliseconds: 50));
        expect(t.takeException(), isNull);
        expect(api.turnStartCount, 0);
        expect(api.supplementCalls, hasLength(1));
      });
    }
  });

  group('one copy of an accepted supplement', () {
    const added = ThreadItem(
      id: 'ses-1:s1',
      itemType: 'userMessage',
      title: '',
      text: 'once only',
      turnId: 't1',
    );
    // The host's item, naming the client id this view sent it with.
    AppEvent echo(FakeBridgeApi api) => AppEvent(
      kind: 'item/completed',
      threadId: 'ses-1',
      itemId: added.id,
      itemType: 'userMessage',
      text: added.text,
      raw: jsonEncode({'turnId': 't1', 'clientId': api.lastSupplementClientId}),
    );

    /// A supplement whose (injected) answer waits for the returned gate.
    Future<(FakeBridgeApi, Completer<void>)> held(WidgetTester t) async {
      final api = await running(t);
      final gate = Completer<void>();
      api.supplementGate = gate;
      await supplement(t, 'once only');
      return (api, gate);
    }

    testWidgets('the event before the answer', (t) async {
      final (api, gate) = await held(t);
      api.pushEvent(acp, echo(api));
      await frames(t);
      gate.complete();
      await frames(t);
      expect(find.text('once only'), findsOneWidget);
      expect(composerText(t), '');
    });

    testWidgets('the answer before the event', (t) async {
      final (api, gate) = await held(t);
      gate.complete();
      await frames(t);
      api.pushEvent(acp, echo(api));
      await frames(t);
      expect(find.text('once only'), findsOneWidget);
    });

    testWidgets('the turn ending before the answer', (t) async {
      final (api, gate) = await held(t);
      ended(api, 't1');
      await frames(t);
      gate.complete();
      await frames(t);
      expect(find.text('once only'), findsOneWidget);
      expect(composerText(t), '', reason: 'the host took it');
      expect(api.turnStartCount, 0, reason: 'never a second prompt');
    });

    testWidgets('what follows comes after it, whichever arrives first', (
      t,
    ) async {
      AppEvent agent(String turn, String id, String text) => AppEvent(
        kind: 'item/completed',
        threadId: 'ses-1',
        itemId: id,
        itemType: 'agentMessage',
        text: text,
        raw: '{"turnId":"$turn"}',
      );
      double top(String text) => t.getTopLeft(find.text(text)).dy;
      final (api, gate) = await held(t);
      api.pushEvent(acp, echo(api));
      await frames(t);
      gate.complete();
      await frames(t);
      api.pushEvent(acp, agent('t1', 'ses-1:a1', 'after it'));
      await frames(t);
      expect(top('once only'), lessThan(top('after it')));
      // A turn that ends before the agent merged one releases it in place.
      await supplement(t, 'never merged');
      ended(api, 't1');
      await frames(t);
      api.pushEvent(
        acp,
        const AppEvent(
          kind: 'turn/started',
          threadId: 'ses-1',
          raw: '{"turnId":"t2"}',
        ),
      );
      api.pushEvent(acp, agent('t2', 'ses-1:a2', 'next turn'));
      await frames(t);
      expect(top('never merged'), lessThan(top('next turn')));
    });

    testWidgets('a reload after it', (t) async {
      final (api, gate) = await held(t);
      gate.complete();
      await frames(t);
      api.readResult = const ThreadHistory(items: [added], running: true);
      api.pushEvent(
        acp,
        const AppEvent(kind: 'thread/compacted', threadId: 'ses-1', raw: '{}'),
      );
      await frames(t);
      expect(find.text('once only'), findsOneWidget, reason: "the host's copy");
    });
  });

  group('attachments', () {
    late FakeImagePicker picker;
    // Every global seam this group replaces is put back exactly as found.
    late ImagePickerPlatform previousPicker;
    late Future<ProcessedImage> Function(Uint8List) previousProcess;
    setUp(() {
      previousProcess = processImageImpl;
      previousPicker = ImagePickerPlatform.instance;
      processImageImpl = (bytes) async => processImageBytes(bytes);
      picker = FakeImagePicker();
      ImagePickerPlatform.instance = picker;
    });
    tearDown(() {
      processImageImpl = previousProcess;
      ImagePickerPlatform.instance = previousPicker;
    });

    testWidgets('a changed attachment set is kept, not queued', (t) async {
      final api = await running(t, imageInput: true)
        ..supplementInjects = false;
      await attachImages(t, picker, ['a.png', 'b.png']);
      expect(find.byKey(const Key('attachment-0')), findsOneWidget);
      expect(find.byKey(const Key('attachment-1')), findsOneWidget);
      final gate = Completer<void>();
      api.supplementGate = gate;
      await supplement(t, 'with images');
      expect(api.supplementCalls.single.$4, hasLength(2));
      // One image is taken out while the answer is pending.
      await t.tap(find.byKey(const Key('attachment-remove-1')));
      await t.pump();
      gate.complete();
      await frames(t);
      expect(find.byKey(const Key('queued-0')), findsNothing);
      expect(composerText(t), 'with images');
      expect(find.byKey(const Key('attachment-0')), findsOneWidget);
      expect(find.byKey(const Key('attachment-1')), findsNothing);
      ended(api, 't1');
      await frames(t);
      expect(api.turnStartCount, 0);
    });

    testWidgets('an accepted input takes exactly its own attachments', (
      t,
    ) async {
      final api = await running(t, imageInput: true);
      await attachImages(t, picker, ['a.png', 'b.png']);
      final gate = Completer<void>();
      api.supplementGate = gate;
      await supplement(t, 'with images');
      // One sent image is removed meanwhile, and the text is edited.
      await t.tap(find.byKey(const Key('attachment-remove-1')));
      await t.enterText(find.byKey(const Key('composer-input')), 'edited');
      await t.pump();
      gate.complete();
      await frames(t);
      expect(composerText(t), 'edited', reason: 'the edit is newer');
      expect(find.byKey(const Key('attachment-0')), findsNothing);
      expect(find.byKey(const Key('attachment-1')), findsNothing);
      expect(api.supplementCalls.single.$4, hasLength(2));
    });

    testWidgets('the host\'s copy arriving first shows the images sent', (
      t,
    ) async {
      final api = await running(t, imageInput: true);
      await attachImages(t, picker, ['a.png']);
      final gate = Completer<void>();
      api.supplementGate = gate;
      await supplement(t, 'look at this');
      // The host keeps only an image count, so its item has no image data.
      api.pushEvent(
        acp,
        AppEvent(
          kind: 'item/completed',
          threadId: 'ses-1',
          itemId: 'ses-1:s1',
          itemType: 'userMessage',
          text: 'look at this',
          raw: jsonEncode({
            'turnId': 't1',
            'clientId': api.lastSupplementClientId,
          }),
        ),
      );
      await frames(t);
      gate.complete();
      await frames(t);
      expect(find.text('look at this'), findsOneWidget);
      expect(find.byKey(const Key('msg-image-0')), findsOneWidget);
    });

    testWidgets('an unchanged input with images is queued once', (t) async {
      final api = await running(t, imageInput: true)
        ..supplementInjects = false;
      await attachImages(t, picker, ['a.png']);
      await supplement(t, 'same input');
      expect(find.byKey(const Key('queued-0')), findsOneWidget);
      expect(find.byKey(const Key('attachment-0')), findsNothing);
      ended(api, 't1');
      await frames(t);
      expect(api.turnStartCount, 1);
      expect(api.lastTurnText, 'same input');
      expect(api.lastTurnImages, hasLength(1));
    });
  });

  // Leaving and reopening drops a pending request; a newer one may then be
  // sent from the same retained draft. Whatever the older one's answer is —
  // added, not consumed, or an error — it changes nothing the newer one
  // owns (mode, notice, Retry, draft, lock) and sends nothing, and a message
  // queued before both stays queued until the turn ends.
  group('an older answer while a newer request waits', () {
    for (final outcome in ['injected', 'not consumed', 'error']) {
      testWidgets(outcome, (t) async {
        await t.binding.setSurfaceSize(const Size(1600, 900));
        addTearDown(() => t.binding.setSurfaceSize(null));
        final api = await running(t, threads: twoSessions);
        // Queued before either supplement.
        await t.enterText(find.byKey(const Key('composer-input')), 'waiting');
        await t.pump();
        await t.tap(find.byKey(const Key('send-btn')));
        await frames(t);
        expect(find.byKey(const Key('queued-0')), findsOneWidget);

        final older = Completer<void>();
        api.supplementGate = older;
        await supplement(t, 'old words');
        await t.tap(find.byKey(const Key('conv-tile-ses-2')));
        await frames(t);
        // "t1" still runs when the conversation is reopened.
        api.readResult = const ThreadHistory(
          items: [],
          running: true,
          activeTurnId: 't1',
        );
        await t.tap(find.byKey(const Key('conv-tile-ses-1')));
        await frames(t);
        expect(composerText(t), 'old words', reason: 'the retained draft');

        final newer = Completer<void>();
        api.supplementGate = newer;
        await t.enterText(find.byKey(const Key('composer-input')), 'new words');
        await t.pump();
        await t.tap(find.byKey(const Key('supplement-toggle')));
        await t.pump();
        await t.tap(find.byKey(const Key('send-btn')));
        await frames(t);
        expect(api.supplementCalls, hasLength(2));

        // The older answer arrives first.
        switch (outcome) {
          case 'injected':
            api.supplementInjects = true;
          case 'not consumed':
            api.supplementInjects = false;
          case 'error':
            api.supplementError = StateError('the agent did not answer');
        }
        final reads = api.threadReads.length;
        older.complete();
        await frames(t);
        expect(
          t
              .widget<FilterChip>(find.byKey(const Key('supplement-toggle')))
              .selected,
          isTrue,
          reason: "the newer request's mode",
        );
        expect(find.byKey(const Key('session-error')), findsNothing);
        expect(staleNotice(), findsNothing);
        expect(composerText(t), 'new words');
        expect(
          t
              .widget<PopupMenuButton<void>>(
                find.byKey(const Key('attach-menu-btn')),
              )
              .enabled,
          isFalse,
          reason: 'the newer request still holds the composer',
        );
        expect(find.byKey(const Key('queued-0')), findsOneWidget);
        expect(api.threadReads.length, reads, reason: 'no refresh for it');
        expect(api.turnStartCount, 0);

        // The newer answer is applied as usual.
        api
          ..supplementInjects = true
          ..supplementError = null;
        newer.complete();
        await frames(t);
        expect(composerText(t), '', reason: 'the newer input was taken');
        expect(find.byKey(const Key('queued-0')), findsOneWidget);
        ended(api, 't1');
        await frames(t);
        expect(api.turnStartCount, 1, reason: 'the queue goes once');
        expect(api.lastTurnText, 'waiting');
      });
    }
  });

  // The newer request has already finished — its notice and Retry are on
  // screen, its lock released — when the older answer arrives last. A free
  // lock is no proof that nothing newer ran: the older answer still changes
  // none of it, starts no refresh and sends nothing.
  group('an older answer arriving after a newer request finished', () {
    for (final outcome in ['injected', 'not consumed', 'error']) {
      testWidgets(outcome, (t) async {
        await t.binding.setSurfaceSize(const Size(1600, 900));
        addTearDown(() => t.binding.setSurfaceSize(null));
        final api = await running(t, threads: twoSessions);
        await t.enterText(find.byKey(const Key('composer-input')), 'waiting');
        await t.pump();
        await t.tap(find.byKey(const Key('send-btn')));
        await frames(t);
        expect(find.byKey(const Key('queued-0')), findsOneWidget);

        final older = Completer<void>();
        api.supplementGate = older;
        await supplement(t, 'old words');
        await t.tap(find.byKey(const Key('conv-tile-ses-2')));
        await frames(t);
        api.readResult = const ThreadHistory(
          items: [],
          running: true,
          activeTurnId: 't1',
        );
        await t.tap(find.byKey(const Key('conv-tile-ses-1')));
        await frames(t);

        // The newer request fails and finishes first: its error and the
        // composer it released are the view's state now.
        api
          ..supplementGate = null
          ..supplementError = StateError('the newer request failed');
        await t.enterText(find.byKey(const Key('composer-input')), 'new words');
        await t.pump();
        await t.tap(find.byKey(const Key('supplement-toggle')));
        await t.pump();
        await t.tap(find.byKey(const Key('send-btn')));
        await frames(t);
        expect(api.supplementCalls, hasLength(2));
        expect(find.textContaining('the newer request failed'), findsOneWidget);
        expect(composerText(t), 'new words');

        api.supplementError = switch (outcome) {
          'error' => StateError('the older request failed'),
          _ => null,
        };
        api.supplementInjects = outcome == 'injected';
        final reads = api.threadReads.length;
        older.complete();
        await frames(t);
        expect(
          find.textContaining('the newer request failed'),
          findsOneWidget,
          reason: "the newer request's notice stays",
        );
        expect(find.textContaining('the older request failed'), findsNothing);
        expect(staleNotice(), findsNothing);
        expect(composerText(t), 'new words');
        expect(
          t
              .widget<FilterChip>(find.byKey(const Key('supplement-toggle')))
              .selected,
          isTrue,
          reason: "the newer request's mode",
        );
        expect(find.byKey(const Key('queued-0')), findsOneWidget);
        expect(find.byKey(const Key('queued-1')), findsNothing);
        expect(api.threadReads.length, reads, reason: 'no refresh for it');
        expect(api.turnStartCount, 0);
        ended(api, 't1');
        await frames(t);
        expect(api.turnStartCount, 1, reason: 'the queue goes once');
        expect(api.lastTurnText, 'waiting');
      });
    }
  });

  // A failure that reaches the view after its host was replaced does not
  // say the turn ended or that nothing was consumed: whether the input was
  // added is unknown, and that notice outlives the reconnect's ready step.
  group('a failure after the host changed', () {
    testWidgets('is an unknown outcome, kept through the reconnect', (t) async {
      final api = await running(t);
      final gate = Completer<void>();
      api.supplementGate = gate;
      await supplement(t, 'maybe added');
      // The reconnect waits at its connect until after the answer arrived.
      final connect = Completer<void>();
      api.appConnectGate = connect.future;
      api.acpCapabilities[acp] = caps(steer: true, generation: 2);
      api.pushEvent(
        acp,
        const AppEvent(
          kind: 'acp/host/state',
          raw: '{"generation":2,"connected":true,"replaced":true}',
        ),
      );
      await frames(t);
      api.supplementError = StateError('connection reset');
      gate.complete();
      await frames(t);
      expect(staleNotice(), findsOneWidget);
      expect(find.textContaining('当前轮次已变更或结束'), findsNothing);
      expect(composerText(t), 'maybe added');
      // The reconnect becomes ready (its own history read clears the
      // banner first) and offers the notice again.
      final reads = api.threadReads.length;
      api.appConnectGate = null;
      connect.complete();
      for (var i = 0; i < 6; i++) {
        await t.pump(const Duration(seconds: 1));
      }
      await frames(t);
      expect(api.threadReads.length, greaterThan(reads), reason: 'reconnected');
      expect(staleNotice(), findsOneWidget, reason: 'offered again');
      expect(composerText(t), 'maybe added');
      expect(api.supplementCalls, hasLength(1), reason: 'never retried');
      expect(api.turnStartCount, 0, reason: 'never turned into a prompt');
      // Dismissing ends it: no reload brings it back.
      await t.tap(find.byKey(const Key('session-error-dismiss')));
      await frames(t);
      expect(staleNotice(), findsNothing);
    });
  });

  // On desktop an image can be pasted (Ctrl+V). The composer refuses it
  // while a supplement holds it; after leaving and reopening, the retained
  // draft takes it, and an answer that no longer owns that draft keeps it —
  // with an added and a removed image — exactly as the user left it.
  group('desktop attachments', () {
    final red = tinyPng(red: 10);
    final blue = tinyPng(red: 90);
    Uint8List? clipboard;
    final previousImage = AppSessionScreen.debugClipboardImage;
    final previousFiles = AppSessionScreen.debugClipboardFiles;
    late Future<ProcessedImage> Function(Uint8List) previousProcess;
    setUp(() {
      previousProcess = processImageImpl;
      processImageImpl = (bytes) async => processImageBytes(bytes);
      clipboard = null;
      AppSessionScreen.debugClipboardImage = () async => clipboard;
      AppSessionScreen.debugClipboardFiles = () async => const <String>[];
    });
    tearDown(() {
      processImageImpl = previousProcess;
      AppSessionScreen.debugClipboardImage = previousImage;
      AppSessionScreen.debugClipboardFiles = previousFiles;
    });

    /// Run [body] as a desktop app; reset inside, after the screen is gone,
    /// so the key handler is removed and the debug-variable check passes.
    Future<void> onDesktop(WidgetTester t, Future<void> Function() body) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        await body();
        await t.pumpWidget(const SizedBox.shrink());
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    }

    Future<void> paste(WidgetTester t, Uint8List image) async {
      clipboard = image;
      await t.tap(find.byKey(const Key('composer-input')));
      await t.pump();
      await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.keyV);
      await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await frames(t);
    }

    final redUrl = processImageBytes(red).dataUrl;

    testWidgets('a paste while a supplement waits is refused', (t) async {
      await onDesktop(t, () async {
        final api = await running(t, imageInput: true);
        await paste(t, red);
        expect(find.byKey(const Key('attachment-0')), findsOneWidget);
        final gate = Completer<void>();
        api.supplementGate = gate;
        await supplement(t, 'with red');
        await paste(t, blue);
        expect(
          find.byKey(const Key('attachment-1')),
          findsNothing,
          reason: 'the composer is held',
        );
        api.supplementInjects = false;
        gate.complete();
        await frames(t);
        // Unchanged input: queued once, with exactly its image.
        expect(find.byKey(const Key('queued-0')), findsOneWidget);
        ended(api, 't1');
        await frames(t);
        expect(api.turnStartCount, 1);
        expect(api.lastTurnImages, [redUrl]);
      });
    });

    for (final injects in [true, false]) {
      final outcome = injects ? 'injected' : 'not consumed';

      testWidgets('$outcome after leaving and reopening keeps an added and a '
          'removed image as left', (t) async {
        await onDesktop(t, () async {
          await t.binding.setSurfaceSize(const Size(1600, 900));
          addTearDown(() => t.binding.setSurfaceSize(null));
          final api = await running(t, imageInput: true, threads: twoSessions)
            ..supplementInjects = injects;
          await paste(t, red);
          final gate = Completer<void>();
          api.supplementGate = gate;
          await supplement(t, 'with images');
          expect(api.supplementCalls.single.$4, [redUrl]);
          await t.tap(find.byKey(const Key('conv-tile-ses-2')));
          await frames(t);
          await t.tap(find.byKey(const Key('conv-tile-ses-1')));
          await frames(t);
          // The retained draft: blue is added, red removed.
          await paste(t, blue);
          expect(find.byKey(const Key('attachment-1')), findsOneWidget);
          await t.tap(find.byKey(const Key('attachment-remove-0')));
          await t.pump();
          gate.complete();
          await frames(t);
          expect(composerText(t), 'with images');
          expect(find.byKey(const Key('attachment-0')), findsNothing);
          expect(find.byKey(const Key('attachment-1')), findsOneWidget);
          expect(find.byKey(const Key('queued-0')), findsNothing);
          expect(staleNotice(), findsOneWidget);
          ended(api, 't1');
          await frames(t);
          expect(api.turnStartCount, 0, reason: 'nothing sent for the user');
        });
      });

      testWidgets('$outcome after a host change keeps the draft and its '
          'image', (t) async {
        await onDesktop(t, () async {
          final api = await running(t, imageInput: true)
            ..supplementInjects = injects;
          await paste(t, red);
          final gate = Completer<void>();
          api.supplementGate = gate;
          await supplement(t, 'with red');
          await replaceHost(t, api, imageInput: true);
          gate.complete();
          await frames(t);
          expect(composerText(t), 'with red');
          expect(find.byKey(const Key('attachment-0')), findsOneWidget);
          expect(find.byKey(const Key('queued-0')), findsNothing);
          expect(staleNotice(), findsOneWidget);
          ended(api, 't1');
          await frames(t);
          expect(api.turnStartCount, 0);
        });
      });
    }
  });
}
