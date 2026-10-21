// The composer's controls recover in the same session once a turn ends,
// whatever order its events arrive in: agent options a stale "running"
// state held become usable again, the queue waits for an admitted turn's
// start before sending the next message, a late or repeated terminal event
// never releases it early, and only an authoritative history reload of the
// same conversation, from the current host connection, settles an
// admission whose start never arrived — an older connection's answer
// changes nothing. A failed queued message keeps its text, attachments and
// place: a proven refusal may be retried, any other failure stays uncertain
// — no history answer resolves it — and is sent again only by the user's
// explicit Retry. A send outliving its host connection dispatches nothing
// more and adopts no outcome. Driven through hit-tested taps and typed
// input, with bounded pumps while a turn runs.

import 'dart:async';

import 'package:file_selector_platform_interface/file_selector_platform_interface.dart'
    as fsel;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:pocox/src/attachment_refs.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/image_attachments.dart';
import 'package:pocox/src/screens/app_session_screen.dart';

import 'fake_bridge_api.dart';
import 'support/acp_capabilities.dart';
import 'support/screen_harness.dart';

part 'composer_recovery/connection_history.dart';
part 'composer_recovery/reconciliation.dart';
part 'composer_recovery/send_ownership.dart';

const acp = 'pcx:dev:acp:agent';
const codex = 'pcx:dev:app:default';

AppCapabilities acpCapsOf({int generation = 1, bool imageInput = false}) =>
    negotiatedAcpCapabilities(
      providerName: 'Agent',
      generation: generation,
      imageInput: imageInput,
    );

SessionSettings settings({required bool running}) => SessionSettings(
  configOptions: const [
    SessionConfigOption(
      id: 'model',
      name: 'Model',
      category: 'model',
      currentValue: 'fast-1',
      values: [
        SessionConfigValue(value: 'fast-1', name: 'Fast'),
        SessionConfigValue(value: 'large-2', name: 'Large'),
      ],
    ),
  ],
  running: running,
);

Future<void> frames(WidgetTester t) async {
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

/// [n] seconds of reconnect backoff and recovery, then frames.
Future<void> seconds(WidgetTester t, int n) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(seconds: 1));
  }
  await frames(t);
}

/// Past the 20 s grace an admitted turn's start is waited for, then let the
/// reconciliation it starts run.
Future<void> pastGrace(WidgetTester t) async {
  await t.pump(const Duration(seconds: 21));
  await frames(t);
}

Future<void> type(WidgetTester t, String text) async {
  await t.enterText(find.byKey(const Key('composer-input')), text);
  await t.pump();
}

Future<void> send(WidgetTester t) async {
  await t.tap(find.byKey(const Key('send-btn')));
  await frames(t);
}

AppEvent turn(String kind, String thread, String id) =>
    AppEvent(kind: kind, threadId: thread, raw: '{"turnId":"$id"}');

String composerText(WidgetTester t) => t
    .widget<TextField>(find.byKey(const Key('composer-input')))
    .controller!
    .text;

Finder retryButton() => find.widgetWithText(TextButton, '重试').last;

/// The ACP host behind [acp] now answers as [generation]; [replaced] says
/// another host incarnation answers (the bridge's reconcile reports both).
Future<void> hostChange(
  WidgetTester t,
  FakeBridgeApi api,
  int generation, {
  bool replaced = true,
  bool imageInput = false,
}) async {
  api.acpCapabilities[acp] = acpCapsOf(
    generation: generation,
    imageInput: imageInput,
  );
  api.pushEvent(
    acp,
    AppEvent(
      kind: 'acp/host/state',
      raw: '{"generation":$generation,"connected":true,"replaced":$replaced}',
    ),
  );
  await frames(t);
}

/// One recorded turn/start is exactly [text] with [images], to [service]'s
/// [thread].
void expectTurn(
  (String, String, String, List<String>) call, {
  required String service,
  required String thread,
  required String text,
  List<String> images = const [],
}) {
  expect(call.$1, service, reason: 'the service it began on');
  expect(call.$2, thread);
  expect(call.$3, text);
  expect(call.$4, images, reason: 'its images, exactly and in order');
}

const wide = Size(1600, 900);

/// Two conversations in one project, for leaving and reopening `t1`. The
/// sessions pane lists the project of the open conversation (`/work`, from
/// the opened row), so both rows are on screen.
const twoThreads = [
  ThreadMeta(id: 't1', preview: 'one', cwd: '/work', updatedAt: 2),
  ThreadMeta(id: 't2', preview: 'two', cwd: '/work', updatedAt: 1),
];

/// Open [service]'s [thread] and send "first", which is admitted but whose
/// start never arrives; then queue "second" (and "third").
Future<FakeBridgeApi> admittedWithoutStart(
  WidgetTester t, {
  String service = codex,
  String thread = 't1',
  bool third = false,
  List<ThreadMeta> threads = const [],
}) async {
  final api = FakeBridgeApi()
    ..autoCompleteTurn = false
    ..announceTurnStart = false;
  if (service == acp) api.acpCapabilities[acp] = acpCapsOf();
  api.appThreads.addAll(threads);
  await api.appConnect(service, 28080);
  await t.pumpWidget(
    host(AppSessionScreen(serviceKey: service, threadId: thread), api),
  );
  await t.pumpAndSettle();
  await type(t, 'first');
  await send(t);
  await type(t, 'second');
  await send(t);
  if (third) {
    await type(t, 'third');
    await send(t);
  }
  expect(api.turnStartCount, 1, reason: 'nothing raced the admitted turn');
  expect(find.byKey(const Key('queued-0')), findsOneWidget);
  return api;
}

void main() {
  setUp(AppSessionScreen.debugResetThreadMemory);

  testWidgets(
    'agent options held by a running state work after the turn ends',
    (t) async {
      final api = FakeBridgeApi()
        ..acpCapabilities[acp] = acpCapsOf()
        ..autoCompleteTurn = false;
      api.sessionSettings['$acp|ses-1'] = settings(running: true);
      await api.appConnect(acp, 28080);
      await t.pumpWidget(
        host(const AppSessionScreen(serviceKey: acp, threadId: 'ses-1'), api),
      );
      await frames(t);
      api.pushEvent(acp, turn('turn/started', 'ses-1', 't1'));
      await frames(t);
      // While it runs the option is not offered. (Bounded pumps: a running
      // turn's progress indicator never settles.)
      await t.tap(find.byKey(const Key('agent-config-model')));
      await frames(t);
      expect(find.text('Large'), findsNothing);
      expect(api.sessionConfigCalls, isEmpty);

      // The engine's cached state no longer names the turn once it ended, but
      // no separate session update is delivered.
      api.sessionSettings['$acp|ses-1'] = settings(running: false);
      api.pushEvent(acp, turn('turn/completed', 'ses-1', 't1'));
      await frames(t);
      await t.tap(find.byKey(const Key('agent-config-model')));
      await t.pumpAndSettle();
      await t.tap(find.text('Large').last);
      await t.pumpAndSettle();
      expect(api.sessionConfigCalls, [('ses-1', 'model', 'large-2')]);
    },
  );

  testWidgets(
    'the queue waits for an admitted turn and ignores repeated ends',
    (t) async {
      final api = await admittedWithoutStart(t, third: true);
      expect(find.byKey(const Key('queued-1')), findsOneWidget);

      // A late end of the turn before it does not count.
      api
        ..pushEvent(codex, turn('turn/started', 't1', 'a'))
        ..pushEvent(codex, turn('turn/completed', 't1', 'a'));
      await frames(t);
      expect(api.turnStartCount, 2);
      expect(api.lastTurnText, 'second');
      // "second" is admitted and awaited; a repeated end of "a" is old news.
      api.pushEvent(codex, turn('turn/completed', 't1', 'a'));
      await frames(t);
      expect(api.turnStartCount, 2, reason: 'the queue stays held');
      expect(find.byKey(const Key('queued-1')), findsOneWidget);

      api
        ..pushEvent(codex, turn('turn/started', 't1', 'b'))
        ..pushEvent(codex, turn('turn/completed', 't1', 'b'));
      await frames(t);
      expect(api.turnStartCount, 3);
      expect(api.lastTurnText, 'third');
      expect(find.byKey(const Key('queued-1')), findsNothing);
    },
  );
  _registerReconciliation();
  _registerConnectionHistory();
  _registerSendOwnership();
}
