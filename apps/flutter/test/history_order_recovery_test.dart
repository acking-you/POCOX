import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/screens/app_session/activity_cards.dart';
import 'package:pocox/src/screens/app_session/transcript_view.dart';
import 'package:pocox/src/screens/app_session_screen.dart';

import 'fake_bridge_api.dart';
import 'support/screen_harness.dart';

const service = 'pcx:host:app:default';
const thread = 'order-diagnosis';
const turn = 'one';
const reply = ThreadItem(
  id: 'final',
  turnId: turn,
  itemType: 'agentMessage',
  title: '',
  text: 'FINAL ANSWER',
);
const recent = ThreadItem(
  id: 'recent-tool',
  turnId: turn,
  itemType: 'commandExecution',
  title: 'recent tool',
  text: 'done',
);
const earlier = ThreadItem(
  id: 'earlier-tool',
  turnId: turn,
  itemType: 'commandExecution',
  title: 'earlier tool',
  text: 'done',
);
const tail = ThreadHistory(
  items: [recent, reply],
  running: false,
  turns: [TurnSummary(turnId: turn)],
);
const full = ThreadHistory(
  items: [earlier, recent, reply],
  running: false,
  turns: [TurnSummary(turnId: turn)],
);

Future<void> frames(WidgetTester t) async {
  for (var i = 0; i < 12; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Future<void> mount(WidgetTester t, FakeBridgeApi api) async {
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = const Size(900, 1000);
  await api.appConnect(service, 28080);
  await t.pumpWidget(
    host(const AppSessionScreen(serviceKey: service, threadId: thread), api),
  );
  await frames(t);
}

bool replyFolded(WidgetTester t) => t
    .widgetList<TurnWorkCard>(find.byType(TurnWorkCard))
    .any((card) => card.work.items.any((item) => item.id == 'final'));
List<List<String>> groups(WidgetTester t) => t
    .widgetList<TurnWorkCard>(find.byType(TurnWorkCard))
    .map((card) => card.work.items.map((item) => item.id).toList())
    .toList();
bool standaloneReply(WidgetTester t) => t
    .widgetList<MessageView>(find.byType(MessageView))
    .any((message) => message.item.id == 'final');

void main() {
  setUp(AppSessionScreen.debugResetThreadMemory);

  testWidgets(
    'a disjoint live event is reconciled before installing the history tail',
    (t) async {
      addTearDown(t.view.reset);
      final read = Completer<ThreadHistory>();
      final api = FakeBridgeApi()
        ..pendingReads[thread] = [read.future]
        ..readResult = full;
      await mount(t, api);
      expect(api.threadReads, isNotEmpty);
      // This step is outside the later bounded history window; only its event
      // arrives during recovery, so there is no shared ID to anchor the overlay.
      api.pushEvent(
        service,
        const AppEvent(
          kind: 'item/completed',
          threadId: thread,
          turnId: turn,
          itemId: 'earlier-tool',
          itemType: 'commandExecution',
          title: 'earlier tool',
          text: 'done',
          raw: '{"turnId":"one"}',
        ),
      );
      await frames(t);
      read.complete(tail);
      await frames(t);
      expect(api.threadReads, hasLength(2));
      expect(replyFolded(t), isFalse);
      expect(standaloneReply(t), isTrue);
      expect(groups(t).expand((items) => items), contains('earlier-tool'));
      expect(t.takeException(), isNull);
      // Reopen the same session with the same authoritative tail and no old
      // in-flight overlay. Neither the source text nor renderer changes.
      await t.pumpWidget(const SizedBox.shrink());
      await frames(t);
      api.readResult = tail;
      await mount(t, api);

      expect(replyFolded(t), isFalse);
      expect(standaloneReply(t), isTrue);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'live completion order cannot override history or lose the newer reply',
    (t) async {
      addTearDown(t.view.reset);
      final read = Completer<ThreadHistory>();
      final api = FakeBridgeApi()..pendingReads[thread] = [read.future];
      await mount(t, api);
      // Old tool completions can first reach a reconnecting view after the
      // answer. Their delivery order is not the order of the host's items.
      for (final item in [recent, reply, earlier]) {
        api.pushEvent(
          service,
          AppEvent(
            kind: 'item/completed',
            threadId: thread,
            turnId: turn,
            itemId: item.id,
            itemType: item.itemType,
            text: item.id == reply.id ? 'NEWER COMPLETE ANSWER' : item.text,
            raw: '{"turnId":"one"}',
          ),
        );
      }
      await frames(t);
      read.complete(full);
      await frames(t);
      expect(api.threadReads, hasLength(1));
      expect(replyFolded(t), isFalse);
      expect(standaloneReply(t), isTrue);
      expect(find.text('NEWER COMPLETE ANSWER'), findsOneWidget);
      expect(groups(t).expand((items) => items).toList(), [
        'earlier-tool',
        'recent-tool',
      ]);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'an authoritative follow refresh repairs existing wrong order in place',
    (t) async {
      addTearDown(t.view.reset);
      const idle = SessionLiveness(
        threadId: thread,
        turnState: 'completed',
        heldOpen: true,
        safety: 'ownedIdle',
        allowsResume: false,
        requiresTakeover: false,
        holders: [],
      );
      final api = FakeBridgeApi()
        ..metadataOnlyFollow = true
        ..appThreadResumeError = StateError(
          'thread already has an active writer',
        )
        ..readResult = const ThreadHistory(
          items: [recent, reply, earlier],
          running: false,
          turns: [TurnSummary(turnId: turn)],
        );
      api.liveness[thread] = idle;
      await mount(t, api);
      expect(replyFolded(t), isTrue);
      final before = api.threadReads.length;
      api.readResult = full;
      api.pushMetaSessionUpdate(
        thread,
        const SessionFollowUpdate(
          liveness: idle,
          items: [],
          historyRevision: 'correct-order',
        ),
      );
      await frames(t);
      expect(api.threadReads.length, greaterThan(before));
      expect(replyFolded(t), isFalse);
      expect(standaloneReply(t), isTrue);
      expect(groups(t).expand((items) => items).toList(), [
        'earlier-tool',
        'recent-tool',
      ]);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox.shrink());
      await frames(t);
      await mount(t, api);
      expect(replyFolded(t), isFalse);
      expect(standaloneReply(t), isTrue);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final running in [false, true]) {
    testWidgets(
      'a still-disjoint read is bounded and preserves running work ($running)',
      (t) async {
        addTearDown(t.view.reset);
        final read = Completer<ThreadHistory>();
        final history = ThreadHistory(
          items: running ? [recent] : tail.items,
          running: running,
          activeTurnId: running ? turn : null,
          turns: tail.turns,
        );
        final api = FakeBridgeApi()
          ..pendingReads[thread] = [read.future]
          ..readResult = history;
        await mount(t, api);
        api.pushEvent(
          service,
          AppEvent(
            kind: running ? 'item/started' : 'item/completed',
            threadId: thread,
            turnId: turn,
            itemId: 'unanchored',
            itemType: 'commandExecution',
            title: 'unanchored work',
            text: 'output',
            raw: '{"turnId":"one"}',
          ),
        );
        await frames(t);
        read.complete(history);
        await frames(t);
        expect(api.threadReads, hasLength(2));
        expect(
          groups(t).expand((items) => items).contains('unanchored'),
          running,
        );
        if (!running) {
          expect(replyFolded(t), isFalse);
          expect(standaloneReply(t), isTrue);
        }
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
