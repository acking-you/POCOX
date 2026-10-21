/// Shared driving for the native OpenCode and host-access chat suites.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/screens/app_session_screen.dart';

import '../fake_bridge_api.dart';
import 'screen_harness.dart';
import 'package:pocox/src/widgets/adaptive_sheet.dart';

/// The native OpenCode service key the suites use.
const openCodeService = 'pcx:local:opencode:opencode';

/// Pump [count] frames 50 ms apart (timers, async reads and their rebuilds).
Future<void> frames(WidgetTester t, [int count = 12]) async {
  for (var i = 0; i < count; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

/// Connect [api] and mount a desktop-sized English [AppSessionScreen].
Future<FakeBridgeApi> mountChat(
  WidgetTester t,
  FakeBridgeApi api, {
  String service = openCodeService,
  String? cwd,
  String? threadId,
  Size size = const Size(1400, 900),
}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await api.appConnect(service, 28080);
  await t.pumpWidget(
    host(
      AppSessionScreen(serviceKey: service, cwd: cwd, threadId: threadId),
      api,
      locale: const Locale('en'),
    ),
  );
  await frames(t);
  return api;
}

/// The open option menu's or searchable list's entry for [value].
Finder optionChoice(String value) {
  final listed = find.byKey(Key('agent-option-value-$value'));
  return listed.evaluate().isNotEmpty
      ? listed
      : find.byWidgetPredicate(
          (w) => w is ChoiceRow<String> && w.value == value,
        );
}

/// Choose [value] for session option [option].
Future<void> pickOption(WidgetTester t, String option, String value) async {
  await t.tap(find.byKey(Key('agent-config-$option')));
  await t.pumpAndSettle();
  final target = optionChoice(value);
  await t.ensureVisible(target);
  await t.pumpAndSettle();
  await t.tap(target);
  await t.pumpAndSettle();
}

/// Session option [option] shows [label].
Finder optionShows(String option, String label) => find.descendant(
  of: find.byKey(Key('agent-config-$option')),
  matching: find.text(label),
);

/// Replace the composer's text with [text].
Future<void> typeMessage(WidgetTester t, String text) async {
  await t.enterText(find.byKey(const Key('composer-input')), text);
  await t.pump();
}

/// The composer's text.
String composerText(WidgetTester t) => t
    .widget<TextField>(find.byKey(const Key('composer-input')))
    .controller!
    .text;

/// Tap send and let the send run.
Future<void> tapSend(WidgetTester t) async {
  await t.tap(find.byKey(const Key('send-btn')));
  await frames(t);
}

/// Switch the shown draft to project [path] from the project menu.
Future<void> pickProject(WidgetTester t, String path) async {
  await t.tap(find.byKey(const Key('project-switcher-btn')));
  await frames(t);
  await t.tap(find.byKey(Key('project-menu-item-$path')));
  await frames(t);
}

/// Nothing of the composer's own Codex model menu went out with the turn.
void expectNoModelMenuSettings(FakeBridgeApi api) {
  expect(api.lastModel, isNull);
  expect(api.lastTurnModel, isNull);
  expect(api.lastReasoningEffort, isNull);
  expect(api.lastCollaborationMode, isNull);
}

/// The host's answer that this view writes [sessionId] of an OpenCode host.
SessionAccess openCodeWritable(String sessionId, {int generation = 1}) =>
    SessionAccess(
      sessionId: sessionId,
      hostId: 'host-1',
      generation: generation,
      provider: 'opencode',
      mode: 'write',
      writer: 'this_host',
      turn: 'idle',
      exclusion: 'pocox',
      reason: 'owned',
      canRelease: true,
    );
