import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/screens/app_session_screen.dart';
import 'package:pocket_codex/src/theme.dart';
import 'package:pocket_codex/src/widgets/middle_click_scroll.dart';
import 'package:pocket_codex/src/widgets/jump_to_latest_button.dart';

import '../fake_bridge_api.dart';
import '../support/screen_harness.dart';
import '../support/ui_preview.dart';

void main() {
  setUpAll(loadPreviewFonts);

  testWidgets('the phone jump button follows turn state and still returns '
      'to the latest message while running', (t) async {
    AppSessionScreen.debugResetThreadMemory();
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(393, 852);
    addTearDown(t.view.reset);
    final api = FakeBridgeApi();
    const service = 'pcx:studio:app:default';
    await api.appConnect(service, 0);
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
          const AppSessionScreen(serviceKey: service, threadId: 'jump-history'),
          api,
          theme: darkTheme(),
        ),
      ),
    );
    await t.pumpAndSettle();
    final controller = t
        .widget<MiddleClickScroll>(find.byType(MiddleClickScroll))
        .controller;
    final viewport = find.byKey(const Key('chat-conversation-layer'));
    await t.drag(viewport, const Offset(0, 500));
    await t.pumpAndSettle();
    expect(
      t.widget<JumpToLatestButton>(find.byType(JumpToLatestButton)).running,
      isFalse,
    );

    api.pushEvent(
      service,
      const AppEvent(
        kind: 'turn/started',
        threadId: 'jump-history',
        raw: '{"turn":{"id":"live"}}',
      ),
    );
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    expect(
      t.widget<JumpToLatestButton>(find.byType(JumpToLatestButton)).running,
      isTrue,
    );
    await t.pump(const Duration(milliseconds: 350));
    await capturePreview(t, 'jump-running-phone');
    await t.tap(find.byKey(const Key('nav-to-bottom')));
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(controller.position.extentAfter, lessThan(1));
    expect(find.byType(JumpToLatestButton), findsNothing);

    await t.drag(viewport, const Offset(0, 500));
    await t.pump(const Duration(milliseconds: 300));
    api.pushEvent(
      service,
      const AppEvent(
        kind: 'turn/completed',
        threadId: 'jump-history',
        raw: '{"turn":{"id":"live","status":"completed"}}',
      ),
    );
    await t.pumpAndSettle();
    expect(
      t.widget<JumpToLatestButton>(find.byType(JumpToLatestButton)).running,
      isFalse,
    );
    expect(t.takeException(), isNull);
  });

  testWidgets('middle-click reads back through the real transcript viewport', (
    t,
  ) async {
    AppSessionScreen.debugResetThreadMemory();
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(1200, 900);
    addTearDown(t.view.reset);
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
    );
    const service = 'pcx:lb7666:app:default';
    await api.appConnect(service, 28080);
    api.readResult = ThreadHistory(
      items: [
        for (var i = 0; i < 80; i++)
          ThreadItem(
            id: 'item-$i',
            turnId: 'turn-${i ~/ 2}',
            itemType: i.isEven ? 'userMessage' : 'agentMessage',
            title: '',
            text: 'Message $i\n\n${'Conversation history for reading. ' * 15}',
          ),
      ],
      running: false,
    );
    await t.pumpWidget(
      host(
        const AppSessionScreen(serviceKey: service, threadId: 'scroll-history'),
        api,
      ),
    );
    await t.pumpAndSettle();
    final viewport = t.getRect(
      find.byKey(const Key('chat-conversation-layer')),
    );
    final controller = t
        .widget<MiddleClickScroll>(find.byType(MiddleClickScroll))
        .controller;
    final before = controller.offset;
    // Opened at the end, far below the conversation's start.
    expect(controller.position.extentBefore, greaterThan(500));
    final mouse = await t.createGesture(
      kind: PointerDeviceKind.mouse,
      buttons: kMiddleMouseButton,
    );
    await mouse.addPointer(location: viewport.center);
    addTearDown(mouse.removePointer);
    await mouse.down(viewport.center);
    await mouse.up();
    await t.pump();
    expect(find.byKey(const Key('middle-click-scroll-anchor')), findsOneWidget);
    await mouse.moveTo(viewport.center - const Offset(0, 100));
    for (var i = 0; i < 15; i++) {
      await t.pump(const Duration(milliseconds: 16));
    }
    expect(controller.offset, lessThan(before));
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pumpAndSettle();
    expect(find.byKey(const Key('middle-click-scroll-anchor')), findsNothing);
    expect(t.takeException(), isNull);
  });
}
