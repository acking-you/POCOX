import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/screens/app_session_screen.dart';
import 'package:pocox/src/theme.dart';
import 'package:pocox/src/widgets/folding_panel.dart';

import '../fake_bridge_api.dart';
import '../support/screen_harness.dart';
import '../support/ui_preview.dart';

const _service = 'pcx:studio:app:default';
final _folded = find.byKey(const Key('composer-folded'));
final _viewport = find.byKey(const Key('chat-conversation-layer'));

/// A phone (or [size]) showing a conversation long enough to read through.
Future<FakeBridgeApi> _open(
  WidgetTester t, {
  Size size = const Size(393, 852),
}) async {
  AppSessionScreen.debugResetThreadMemory();
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = size;
  addTearDown(t.view.reset);
  final api = FakeBridgeApi();
  await api.appConnect(_service, 0);
  api.readResult = ThreadHistory(
    items: [
      for (var i = 0; i < 30; i++)
        ThreadItem(
          id: 'item-$i',
          turnId: 'turn-${i ~/ 2}',
          itemType: i.isEven ? 'userMessage' : 'agentMessage',
          title: '',
          text: 'Message $i\n\n${'Conversation history. ' * 10}',
        ),
    ],
    running: false,
  );
  await t.pumpWidget(
    RepaintBoundary(
      key: previewKey,
      child: host(
        const AppSessionScreen(serviceKey: _service, threadId: 'fold'),
        api,
        theme: darkTheme(),
      ),
    ),
  );
  await t.pumpAndSettle();
  return api;
}

double _composerHeight(WidgetTester t) =>
    t.getSize(find.byType(FoldingPanel)).height;

FocusNode _field(WidgetTester t) =>
    t.widget<TextField>(find.byKey(const Key('composer-input'))).focusNode!;

void main() {
  setUpAll(loadPreviewFonts);

  testWidgets('reading folds the phone composer; tapping it unfolds to type', (
    t,
  ) async {
    await _open(t);
    final open = _composerHeight(t);
    expect(_folded, findsNothing);

    // Reading back through the conversation.
    await t.drag(_viewport, const Offset(0, 400));
    await t.pumpAndSettle();
    expect(_folded, findsOneWidget);
    expect(
      _composerHeight(t),
      lessThan(open - 60),
      reason: 'the transcript gets the room',
    );
    await capturePreview(t, 'composer-folded-phone');

    await t.tap(_folded);
    await t.pumpAndSettle();
    expect(_folded, findsNothing);
    expect(_composerHeight(t), open);
    expect(_field(t).hasFocus, isTrue, reason: 'a tap on it means typing');

    // While someone is writing, reading never folds it away.
    await t.drag(_viewport, const Offset(0, 400));
    await t.pumpAndSettle();
    expect(_folded, findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('the latest message unfolds it, and the draft survives', (
    t,
  ) async {
    await _open(t);
    await t.enterText(find.byKey(const Key('composer-input')), 'Half a reply');
    FocusManager.instance.primaryFocus?.unfocus();
    await t.pumpAndSettle();

    await t.drag(_viewport, const Offset(0, 400));
    await t.pumpAndSettle();
    expect(
      find.descendant(of: _folded, matching: find.text('Half a reply')),
      findsOneWidget,
      reason: 'the capsule shows the draft',
    );

    // Reading on to the end: where a reply starts.
    await t.fling(_viewport, const Offset(0, -3000), 4000);
    await t.pumpAndSettle();
    expect(_folded, findsNothing);
    expect(find.text('Half a reply'), findsOneWidget);

    // Jumping to the latest message does the same.
    await t.drag(_viewport, const Offset(0, 400));
    await t.pumpAndSettle();
    expect(_folded, findsOneWidget);
    await t.tap(find.byKey(const Key('nav-to-bottom')));
    await t.pumpAndSettle();
    expect(_folded, findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('a running turn keeps Stop on the capsule', (t) async {
    final api = await _open(t);
    api.pushEvent(
      _service,
      const AppEvent(
        kind: 'turn/started',
        threadId: 'fold',
        raw: '{"turn":{"id":"live"}}',
      ),
    );
    await t.pump();
    await t.drag(_viewport, const Offset(0, 400));
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(_folded, findsOneWidget);
    await t.tap(find.byKey(const Key('folded-stop-btn')));
    await t.pump(const Duration(milliseconds: 100));
    expect(api.interrupted, isTrue);
    expect(_folded, findsOneWidget, reason: 'stopping is not typing');
  });

  testWidgets('a desktop window keeps its composer', (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      await _open(t, size: const Size(1200, 900));
      await t.drag(_viewport, const Offset(0, 400));
      await t.pumpAndSettle();
      expect(_folded, findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
