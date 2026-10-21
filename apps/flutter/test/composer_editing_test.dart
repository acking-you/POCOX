import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/screens/app_session_screen.dart';

import 'fake_bridge_api.dart';
import 'support/composer_harness.dart';

/// Editing in the composer: its keyboard, its growth and its expanded editor.
void main() {
  setUp(AppSessionScreen.debugResetThreadMemory);

  testWidgets('growing the composer preserves the message being read', (
    t,
  ) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(390, 844);
    addTearDown(t.view.reset);
    final api = FakeBridgeApi()
      ..readResult = ThreadHistory(
        items: List.generate(
          80,
          (i) => ThreadItem(
            id: 'u$i',
            itemType: 'userMessage',
            title: '',
            text: 'History message $i',
          ),
        ),
        running: false,
      );
    await mountComposer(t, api);
    final layer = find.byKey(const Key('chat-conversation-layer'));
    await t.drag(layer, const Offset(0, 400));
    await t.pumpAndSettle();
    final viewport = t.getRect(layer);
    final visible = find
        .textContaining('History message')
        .evaluate()
        .where((e) {
          final rect = t.getRect(find.byWidget(e.widget));
          return rect.top > viewport.top && rect.bottom < viewport.bottom;
        })
        .first
        .widget;
    final text = visible as Text;
    final anchorText = text.data ?? text.textSpan!.toPlainText();
    final anchor = find.byWidgetPredicate(
      (w) => w is Text && (w.data ?? w.textSpan?.toPlainText()) == anchorText,
    );
    final top = t.getTopLeft(anchor).dy;
    await t.enterText(
      composerInput,
      List.filled(20, 'A growing draft').join('\n'),
    );
    await t.pumpAndSettle();
    expect(t.getTopLeft(anchor).dy, closeTo(top, 1));
    expect(t.takeException(), isNull);
  });

  testWidgets(
    'desktop Enter sends, Shift+Enter adds a line, IME Enter never sends',
    (t) async {
      final api = FakeBridgeApi();
      await mountComposer(t, api);
      await t.enterText(composerInput, 'First line');
      await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await t.pump();
      // The engine/IME, absent from widget tests, delivers newline text.
      expect(
        t.widget<TextField>(composerInput).textInputAction,
        TextInputAction.newline,
      );
      t.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'First line\n',
          selection: TextSelection.collapsed(offset: 11),
        ),
      );
      expect(composerController(t).text, 'First line\n');
      expect(api.lastTurnText, isNull);
      t.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'ni',
          selection: TextSelection.collapsed(offset: 2),
          composing: TextRange(start: 0, end: 2),
        ),
      );
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pump();
      expect(api.lastTurnText, isNull);
      await t.enterText(composerInput, 'Confirmed 你好');
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pumpAndSettle();
      expect(api.lastTurnText, 'Confirmed 你好');
      expect(composerController(t).text, isEmpty);
    },
    variant: const TargetPlatformVariant({TargetPlatform.windows}),
  );

  testWidgets(
    'mobile keyboard uses newline and the button sends',
    (t) async {
      final api = FakeBridgeApi();
      await mountComposer(t, api);
      expect(
        t.widget<TextField>(composerInput).textInputAction,
        TextInputAction.newline,
      );
      await t.enterText(composerInput, 'First\nSecond');
      await t.testTextInput.receiveAction(TextInputAction.newline);
      await t.pump();
      expect(api.lastTurnText, isNull);
      await t.tap(find.byKey(const Key('send-btn')));
      await t.pumpAndSettle();
      expect(api.lastTurnText, 'First\nSecond');
    },
    variant: const TargetPlatformVariant({TargetPlatform.android}),
  );

  testWidgets(
    'expanded editor preserves selection and edits without sending',
    (t) async {
      final api = FakeBridgeApi();
      await mountComposer(t, api);
      await t.enterText(composerInput, 'A longer message');
      const selection = TextSelection(baseOffset: 2, extentOffset: 8);
      composerController(t).selection = selection;
      await t.tap(find.byKey(const Key('composer-expand')));
      await t.pumpAndSettle();
      final expanded = find.byKey(const Key('composer-expanded-input'));
      final controller = t.widget<TextField>(expanded).controller!;
      expect(controller.selection, selection);
      await t.enterText(expanded, 'Edited in a bigger space');
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pump();
      expect(api.lastTurnText, isNull);
      expect(
        t.widget<TextField>(expanded).textInputAction,
        TextInputAction.newline,
      );
      t.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'Edited in a bigger space\n',
          selection: TextSelection.collapsed(offset: 24),
        ),
      );
      final editedSelection = controller.selection;
      await t.tap(find.byKey(const Key('composer-editor-done')));
      await t.pumpAndSettle();
      expect(composerController(t).text, 'Edited in a bigger space\n');
      expect(composerController(t).selection, editedSelection);
      expect(t.widget<TextField>(composerInput).focusNode!.hasFocus, isTrue);
      expect(t.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({TargetPlatform.windows}),
  );

  testWidgets(
    'the expanded editor previews the draft live and never sends it',
    (t) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(1280, 900);
      addTearDown(t.view.reset);
      final api = FakeBridgeApi();
      await mountComposer(t, api);
      await t.tap(find.byKey(const Key('composer-expand')));
      await t.pumpAndSettle();
      // A wide window opens with the rendered draft beside its source.
      final expanded = find.byKey(const Key('composer-expanded-input'));
      final preview = find.byKey(const Key('composer-preview'));
      expect(expanded, findsOneWidget);
      expect(find.byKey(const Key('composer-preview-empty')), findsOneWidget);
      await t.enterText(expanded, 'Ship **it**\nafter the build');
      await t.pump();
      // Rendered as its message will read: emphasis, and the typed break.
      expect(
        find.descendant(
          of: preview,
          matching: find.text('Ship it\nafter the build', findRichText: true),
        ),
        findsOneWidget,
      );
      await t.tap(find.byKey(const Key('composer-editor-preview')));
      await t.pumpAndSettle();
      expect(expanded, findsNothing);
      expect(preview, findsOneWidget);
      // A narrow window offers no split; the source comes back alone.
      await t.tap(find.byKey(const Key('composer-editor-write')));
      t.view.physicalSize = const Size(640, 900);
      await t.pumpAndSettle();
      expect(find.byKey(const Key('composer-editor-split')), findsNothing);
      expect(expanded, findsOneWidget);
      expect(preview, findsNothing);
      await t.tap(find.byKey(const Key('composer-editor-done')));
      await t.pumpAndSettle();
      expect(composerController(t).text, 'Ship **it**\nafter the build');
      expect(api.lastTurnText, isNull);
      expect(t.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({TargetPlatform.windows}),
  );

  testWidgets(
    'visible height reset keeps the draft and resumes compact automatic sizing',
    (t) async {
      final api = FakeBridgeApi();
      await mountComposer(t, api);
      final area = find.byKey(const Key('composer-input-area'));
      final initialHeight = t.getSize(area).height;
      await t.drag(
        find.byKey(const Key('composer-resize-handle')),
        const Offset(0, -100),
      );
      await t.pumpAndSettle();
      expect(t.getSize(area).height, greaterThan(initialHeight));
      await t.enterText(composerInput, 'Keep this');
      await t.tap(find.byKey(const Key('composer-reset-height')));
      await t.pumpAndSettle();
      expect(t.getSize(area).height, initialHeight);
      expect(composerController(t).text, 'Keep this');
      expect(find.byKey(const Key('composer-reset-height')), findsNothing);
    },
  );
}
