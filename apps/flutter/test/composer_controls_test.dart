// Every composer control works in the same conversation while a turn runs
// and after it completes, fails or is cancelled — for native Codex and for
// an ACP agent, without switching sessions, on a touch device and on a
// desktop. Each control is checked three ways: its callback is enabled (or
// it is legitimately absent or disabled, which is asserted with the reason),
// a pointer at its own centre reaches it (no layer left over it), and acting
// on it has its real effect: a sent prompt, a supplement for the running
// turn, an interrupt naming that turn, a queued message (sent once after the
// end), an open menu or sheet that is dismissed again, the expanded editor,
// a permission, model or agent option change. Touch acts through pointer
// taps and the semantics tap action; the desktop also through its own
// paths: the hardware Escape that hands a queued message back, the anchored
// model menu, Tab focus traversal with Enter/Space activation, and Enter in
// the composer. Bounded pumps only: a running turn's progress indicators
// never settle. Only the test's own turn ids are in play (the fake
// announces no start of its own).

import 'dart:ui' show SemanticsAction;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/screens/app_session_screen.dart';

import 'fake_bridge_api.dart';
import 'support/screen_harness.dart';

const codex = 'pcx:dev:app:default';
const acp = 'pcx:dev:acp:agent';

const acpCaps = AppCapabilities(
  provider: 'acp',
  fast: false,
  permissionPresets: false,
  guardian: false,
  rateLimits: false,
  takeover: false,
  externalWriterMonitor: false,
  localSessions: false,
  planMode: false,
  protocol: 'acp',
  providerName: 'Agent',
  negotiated: true,
  generation: 1,
  steer: true,
  sessionConfig: true,
  permissionOptions: true,
  sessionReopen: 'load',
  sessionList: 'agent',
  runningInventory: 'engine',
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

enum Ending { completed, failed, cancelled }

Future<void> frames(WidgetTester t) async {
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

/// [key] is shown, scrolled into view and reached by a pointer at its
/// centre: the hit-test path from there contains its render object.
Future<Finder> reachable(WidgetTester t, String key) async {
  final finder = find.byKey(Key(key));
  expect(finder, findsOneWidget, reason: '$key is shown');
  await t.ensureVisible(finder);
  await t.pump();
  final target = t.renderObject(finder);
  final path = t.hitTestOnBinding(t.getCenter(finder)).path;
  expect(
    path.any((entry) => identical(entry.target, target)),
    isTrue,
    reason: '$key gets the pointer',
  );
  return finder;
}

/// [finder] is an enabled button for accessibility, and its semantics tap
/// action is performed.
void semanticTap(WidgetTester t, Finder finder) {
  final node = t.getSemantics(finder);
  expect(
    node,
    isSemantics(isButton: true, isEnabled: true, hasTapAction: true),
  );
  t
      .renderObject(finder)
      .owner!
      .semanticsOwner!
      .performAction(node.id, SemanticsAction.tap);
}

/// Keyboard focus moves with Tab, from the composer, until it is on [key]'s
/// control (at most [limit] steps): the control takes part in focus
/// traversal.
Future<void> tabTo(WidgetTester t, String key, {int limit = 80}) async {
  final target = find.byKey(Key(key));
  expect(target, findsOneWidget);
  bool focused() {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null) return false;
    final element = t.element(target);
    if (identical(context, element)) return true;
    var inside = false;
    context.visitAncestorElements((ancestor) {
      inside = identical(ancestor, element);
      return !inside;
    });
    return inside;
  }

  await t.showKeyboard(find.byKey(const Key('composer-input')));
  await t.pump();
  for (var i = 0; i < limit && !focused(); i++) {
    await t.sendKeyEvent(LogicalKeyboardKey.tab);
    await t.pump();
  }
  expect(focused(), isTrue, reason: 'Tab reaches $key');
}

Future<void> type(WidgetTester t, String text) async {
  await t.enterText(find.byKey(const Key('composer-input')), text);
  await t.pump();
}

String composerText(WidgetTester t) => t
    .widget<TextField>(find.byKey(const Key('composer-input')))
    .controller!
    .text;

AppEvent turnEvent(String kind, String thread, String turn, [String? text]) =>
    AppEvent(
      kind: kind,
      threadId: thread,
      text: text,
      raw: '{"turnId":"$turn"}',
    );

/// The attachment menu opens on a pointer tap and Escape closes it (the
/// menu's route has the focus, so the composer's own Escape stays out).
Future<void> attachmentMenu(WidgetTester t) async {
  final attach = await reachable(t, 'attach-menu-btn');
  expect(t.widget<PopupMenuButton<void>>(attach).enabled, isTrue);
  await t.tap(attach);
  await frames(t);
  expect(find.byKey(const Key('attach-file-btn')), findsOneWidget);
  await t.sendKeyEvent(LogicalKeyboardKey.escape);
  await frames(t);
  expect(find.byKey(const Key('attach-file-btn')), findsNothing);
}

/// The expanded editor opens and hands back to the composer.
Future<void> expandedEditor(WidgetTester t) async {
  await t.tap(await reachable(t, 'composer-expand'));
  await frames(t);
  await t.tap(await reachable(t, 'composer-editor-done'));
  await frames(t);
  expect(find.byKey(const Key('composer-editor-done')), findsNothing);
}

/// Native turn settings. Touch: the model sheet opens and Escape dismisses
/// it. Desktop: the anchored model menu opens on its chip (choosing [pick]
/// when given) and closes on the chip again. Then the permission picker
/// changes the mode to [mode].
Future<void> nativeSettings(
  WidgetTester t, {
  required bool desktop,
  required String mode,
  String? pick,
}) async {
  await t.tap(await reachable(t, 'model-chip'));
  await frames(t);
  if (desktop) {
    expect(find.byKey(const Key('model-menu-item-gpt-5.5')), findsOneWidget);
    if (pick != null) {
      await t.tap(await reachable(t, 'model-menu-item-$pick'));
      await frames(t);
    }
    await t.tap(await reachable(t, 'model-chip'));
    await frames(t);
    expect(find.byKey(const Key('model-menu-item-gpt-5.5')), findsNothing);
  } else {
    expect(find.byKey(const ValueKey('opt-model')), findsOneWidget);
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await frames(t);
    expect(find.byKey(const ValueKey('opt-model')), findsNothing);
  }
  await t.tap(await reachable(t, 'permission-chip'));
  await frames(t);
  await t.tap(find.text(mode).last);
  await frames(t);
  expect(
    find.descendant(
      of: find.byKey(const Key('permission-chip')),
      matching: find.text(mode),
    ),
    findsOneWidget,
    reason: 'the chip shows the picked mode',
  );
}

void main() {
  setUp(AppSessionScreen.debugResetThreadMemory);

  for (final desktop in [false, true]) {
    for (final native in [true, false]) {
      for (final ending in Ending.values) {
        final form = desktop ? 'desktop' : 'touch';
        final engine = native ? 'Codex' : 'ACP';
        testWidgets('$form $engine: the whole composer works while a turn '
            'runs and after it is ${ending.name}', (t) async {
          if (desktop) {
            debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
            t.view.physicalSize = const Size(1400, 900);
            t.view.devicePixelRatio = 1;
            addTearDown(t.view.reset);
          }
          try {
            await composerRound(
              t,
              desktop: desktop,
              native: native,
              ending: ending,
            );
            // Unmount while still "desktop", so the key handler goes too.
            await t.pumpWidget(const SizedBox.shrink());
          } finally {
            debugDefaultTargetPlatformOverride = null;
          }
        });
      }
    }
  }
}

/// One conversation: a turn "a" runs, every control is used, "a" ends as
/// [ending], and every control is used again while idle.
Future<void> composerRound(
  WidgetTester t, {
  required bool desktop,
  required bool native,
  required Ending ending,
}) async {
  final service = native ? codex : acp;
  final thread = native ? 't1' : 'ses-1';
  final api = FakeBridgeApi()
    ..autoCompleteTurn = false
    ..announceTurnStart = false;
  if (!native) {
    api
      ..acpCapabilities[acp] = acpCaps
      ..sessionSettings['$acp|$thread'] = settings(running: true);
  }
  await api.appConnect(service, 28080);
  await t.pumpWidget(
    host(AppSessionScreen(serviceKey: service, threadId: thread), api),
  );
  await frames(t);

  // Idle with nothing typed: Send is legitimately disabled.
  expect(
    t.widget<IconButton>(find.byKey(const Key('send-btn'))).onPressed,
    isNull,
    reason: 'nothing to send yet',
  );
  await type(t, 'one');
  final first = await reachable(t, 'send-btn');
  expect(t.widget<IconButton>(first).onPressed, isNotNull);
  await t.tap(first);
  await frames(t);
  expect(api.turnStartCount, 1);
  expect(api.lastTurnText, 'one');
  api.pushEvent(service, turnEvent('turn/started', thread, 'a'));
  await frames(t);

  // ── While "a" runs ──────────────────────────────────────────────────
  final semantics = t.ensureSemantics();
  final stop = await reachable(t, 'stop-btn');
  expect(t.widget<IconButton>(stop).onPressed, isNotNull);
  expect(t.getSemantics(stop), isSemantics(isButton: true, isEnabled: true));
  await attachmentMenu(t);
  await expandedEditor(t);
  if (native) {
    await nativeSettings(t, desktop: desktop, mode: '只读');
  } else {
    // The agent's own state says a turn runs: its options are not offered
    // until it ends (an intentional gate, not a stale lock).
    await t.tap(await reachable(t, 'agent-config-model'));
    await frames(t);
    expect(find.text('Large'), findsNothing);
    expect(api.sessionConfigCalls, isEmpty);
  }
  expect(api.interrupted, isFalse, reason: 'no dismissal reached the turn');

  // Supplement goes to the running turn.
  await t.tap(await reachable(t, 'supplement-toggle'));
  await t.pump();
  await type(t, 'more context');
  await t.tap(await reachable(t, 'send-btn'));
  await frames(t);
  expect(api.supplementCalls.single.$2, 'a');
  expect(api.supplementCalls.single.$3, 'more context');
  expect(composerText(t), '', reason: 'the running turn took it');
  expect(api.turnStartCount, 1, reason: 'a supplement is no prompt');

  // Send queues the next turn — by keyboard on the desktop (Tab to Send,
  // Space), by the semantics tap action on touch.
  await type(t, 'queued');
  if (desktop) {
    await reachable(t, 'send-btn');
    await tabTo(t, 'send-btn');
    await t.sendKeyEvent(LogicalKeyboardKey.space);
  } else {
    semanticTap(t, await reachable(t, 'send-btn'));
  }
  await frames(t);
  expect(find.byKey(const Key('queued-0')), findsOneWidget);
  expect(composerText(t), '');
  // It is handed back for editing: the desktop's hardware Escape in the
  // composer, a tap on its chip on touch.
  if (desktop) {
    await t.showKeyboard(find.byKey(const Key('composer-input')));
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
  } else {
    await t.tap(await reachable(t, 'queued-0'));
  }
  await frames(t);
  expect(find.byKey(const Key('queued-0')), findsNothing);
  expect(composerText(t), 'queued', reason: 'back in the composer');
  expect(api.interrupted, isFalse, reason: 'the queue answered first');
  await t.tap(await reachable(t, 'send-btn'));
  await frames(t);
  expect(find.byKey(const Key('queued-1')), findsOneWidget);
  expect(api.turnStartCount, 1, reason: 'nothing raced the turn');

  // ── "a" ends, in the same session ───────────────────────────────────
  if (!native) {
    api.sessionSettings['$acp|$thread'] = settings(running: false);
  }
  switch (ending) {
    case Ending.completed:
      api.pushEvent(service, turnEvent('turn/completed', thread, 'a'));
    case Ending.failed:
      api.pushEvent(
        service,
        turnEvent('turn/failed', thread, 'a', 'model overloaded'),
      );
    case Ending.cancelled:
      // Desktop: Tab to Stop and Enter; touch: a pointer tap.
      if (desktop) {
        await reachable(t, 'stop-btn');
        await tabTo(t, 'stop-btn');
        await t.sendKeyEvent(LogicalKeyboardKey.enter);
      } else {
        await t.tap(await reachable(t, 'stop-btn'));
      }
      await frames(t);
      expect(api.interrupted, isTrue);
      expect(api.lastInterruptTurnId, 'a', reason: 'Stop names "a"');
      api.pushEvent(service, turnEvent('turn/completed', thread, 'a'));
  }
  await frames(t);
  expect(find.byKey(const Key('stop-btn')), findsNothing);
  // The queued message goes out once, as its own turn.
  expect(api.turnStartCount, 2);
  expect(api.lastTurnText, 'queued');
  expect(find.byKey(const Key('queued-1')), findsNothing);
  api
    ..pushEvent(service, turnEvent('turn/started', thread, 'b'))
    ..pushEvent(service, turnEvent('turn/completed', thread, 'b'));
  await frames(t);
  expect(api.turnStartCount, 2, reason: 'sent exactly once');

  // ── Idle again, in the same conversation ────────────────────────────
  expect(
    find.byKey(const Key('supplement-toggle')),
    findsNothing,
    reason: 'there is no running turn to supplement',
  );
  await attachmentMenu(t);
  await expandedEditor(t);
  if (native) {
    await nativeSettings(
      t,
      desktop: desktop,
      mode: '替我审批',
      pick: desktop ? 'gpt-5' : null,
    );
  } else {
    await t.tap(await reachable(t, 'agent-config-model'));
    await frames(t);
    await t.tap(find.text('Large').last);
    await frames(t);
    expect(api.sessionConfigCalls, [(thread, 'model', 'large-2')]);
  }
  // Send through the semantics tap action, then a pointer tap.
  await type(t, 'two');
  semanticTap(t, await reachable(t, 'send-btn'));
  await frames(t);
  expect(api.turnStartCount, 3, reason: 'sent without switching away');
  expect(api.lastTurnText, 'two');
  if (native) {
    expect(api.lastSandbox, 'workspace-write', reason: 'the picked mode');
    expect(api.lastApprovalsReviewer, 'auto_review');
    if (desktop) {
      expect(api.lastTurnModel, 'gpt-5', reason: 'the model menu pick');
    }
  }
  var turns = 3;
  Future<void> idleAgain(String id) async {
    api
      ..pushEvent(service, turnEvent('turn/started', thread, id))
      ..pushEvent(service, turnEvent('turn/completed', thread, id));
    await frames(t);
  }

  await idleAgain('c');
  await type(t, 'three');
  await t.tap(await reachable(t, 'send-btn'));
  await frames(t);
  expect(api.turnStartCount, ++turns);
  expect(api.lastTurnText, 'three');
  if (desktop) {
    // Keyboard only: Tab to Send and Enter, then Enter in the composer.
    await idleAgain('d');
    await type(t, 'four');
    await tabTo(t, 'send-btn');
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await frames(t);
    expect(api.turnStartCount, ++turns);
    expect(api.lastTurnText, 'four');
    await idleAgain('e');
    await type(t, 'five');
    await t.showKeyboard(find.byKey(const Key('composer-input')));
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await frames(t);
    expect(api.turnStartCount, ++turns);
    expect(api.lastTurnText, 'five');
  }
  semantics.dispose();
}
