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

  testWidgets('a phone composer starts folded, unfolds while the field has '
      'focus and folds when it lets go', (t) async {
    await _open(t);
    expect(_folded, findsOneWidget, reason: 'folded until someone writes');
    final folded = _composerHeight(t);
    await capturePreview(t, 'composer-folded-phone');

    await t.tap(_folded);
    // Mid-unfold: the full form arrives as the pane grows into it.
    await t.pump();
    await t.pump(const Duration(milliseconds: 110));
    await capturePreview(t, 'composer-unfolding-phone');
    await t.pumpAndSettle();
    expect(_folded, findsNothing);
    expect(_field(t).hasFocus, isTrue, reason: 'a tap on it means typing');
    final open = _composerHeight(t);
    expect(open, greaterThan(folded + 60), reason: 'the field gets its room');
    await capturePreview(t, 'composer-open-phone');

    // While someone is writing, reading never folds it away.
    await t.drag(_viewport, const Offset(0, 400));
    await t.pumpAndSettle();
    expect(_folded, findsNothing);

    FocusManager.instance.primaryFocus?.unfocus();
    await t.pumpAndSettle();
    expect(_folded, findsOneWidget, reason: 'done writing, it folds again');
    expect(_composerHeight(t), folded);
    expect(t.takeException(), isNull);
  });

  testWidgets('the end of the conversation, jumping to it or a reply leave '
      'it folded, with the draft on the capsule', (t) async {
    final api = await _open(t);
    await t.enterText(find.byKey(const Key('composer-input')), 'Half a reply');
    await t.pumpAndSettle();
    expect(_folded, findsNothing);
    FocusManager.instance.primaryFocus?.unfocus();
    await t.pumpAndSettle();
    expect(
      find.descendant(of: _folded, matching: find.text('Half a reply')),
      findsOneWidget,
      reason: 'the capsule shows the draft',
    );

    // Reading on to the end is still reading.
    await t.drag(_viewport, const Offset(0, 400));
    await t.pumpAndSettle();
    await t.fling(_viewport, const Offset(0, -3000), 4000);
    await t.pumpAndSettle();
    expect(_folded, findsOneWidget);

    // So is jumping to the latest message.
    await t.drag(_viewport, const Offset(0, 400));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('nav-to-bottom')));
    await t.pumpAndSettle();
    expect(_folded, findsOneWidget);

    // And a reply arriving.
    api.pushEvent(
      _service,
      const AppEvent(
        kind: 'turn/started',
        threadId: 'fold',
        raw: '{"turn":{"id":"reply"}}',
      ),
    );
    await t.pump(const Duration(milliseconds: 400));
    expect(_folded, findsOneWidget);
    expect(_field(t).hasFocus, isFalse);
    expect(t.takeException(), isNull);
  });

  testWidgets('putting the keyboard away folds it; a keyboard that only '
      'blinks does not', (t) async {
    await _open(t);
    await t.tap(_folded);
    await t.pumpAndSettle();
    t.view.viewInsets = const FakeViewPadding(bottom: 300);
    await t.pumpAndSettle();
    expect(_folded, findsNothing);

    // An input method switching layouts hides the keyboard for a moment.
    t.view.viewInsets = FakeViewPadding.zero;
    await t.pump(const Duration(milliseconds: 100));
    t.view.viewInsets = const FakeViewPadding(bottom: 300);
    await t.pump(const Duration(milliseconds: 400));
    expect(_field(t).hasFocus, isTrue);
    expect(_folded, findsNothing);

    // Android's back button hides it and leaves the field focused.
    t.view.viewInsets = FakeViewPadding.zero;
    await t.pump(const Duration(milliseconds: 400));
    await t.pumpAndSettle();
    expect(_field(t).hasFocus, isFalse, reason: 'typing is over');
    expect(_folded, findsOneWidget);
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
      expect(_folded, findsNothing);
      await t.drag(_viewport, const Offset(0, 400));
      await t.pumpAndSettle();
      expect(_folded, findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
