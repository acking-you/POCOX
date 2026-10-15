import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_codex/src/widgets/layered_navigation.dart';

const _width = 400.0;
final _nav = find.byType(LayeredNavigation);
final _sideList = find.byKey(const Key('side-list'), skipOffstage: false);

LayeredNavigationState _state(WidgetTester t) =>
    t.state<LayeredNavigationState>(_nav);

/// Haptic calls the widget made, by `HapticFeedbackType` name.
List<String> _recordHaptics(WidgetTester t) {
  final calls = <String>[];
  t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'HapticFeedback.vibrate') {
        calls.add((call.arguments as String).split('.').last);
      }
      return null;
    },
  );
  addTearDown(
    () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
  return calls;
}

Future<List<bool>> _mount(
  WidgetTester t, {
  bool reduceMotion = false,
  double keyboard = 0,
}) async {
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = const Size(_width, 800);
  addTearDown(t.view.reset);
  final changes = <bool>[];
  await t.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            disableAnimations: reduceMotion,
            viewInsets: EdgeInsets.only(bottom: keyboard),
          ),
          child: LayeredNavigation(
            sidebarLabel: 'Sessions',
            onOpenChanged: changes.add,
            sidebar: Material(
              child: Column(
                children: [
                  Builder(
                    builder: (c) => IconButton(
                      key: const Key('close'),
                      icon: const Icon(Icons.close),
                      onPressed: () => LayeredNavigation.maybeOf(c)!.close(),
                    ),
                  ),
                  Expanded(
                    child: ListView(
                      key: const Key('side-list'),
                      children: [
                        const ExpansionTile(
                          key: Key('group'),
                          title: Text('Group'),
                          children: [Text('Nested row')],
                        ),
                        for (var i = 0; i < 60; i++)
                          ListTile(title: Text('row $i')),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            body: Scaffold(
              appBar: AppBar(
                leading: Builder(
                  builder: (c) => IconButton(
                    key: const Key('menu'),
                    icon: const Icon(Icons.menu),
                    onPressed: () => LayeredNavigation.maybeOf(c)!.open(),
                  ),
                ),
              ),
              body: Column(
                children: [
                  const TextField(key: Key('draft')),
                  Expanded(
                    child: ListView(
                      key: const Key('body-list'),
                      children: [
                        for (var i = 0; i < 80; i++)
                          SizedBox(height: 60, child: Text('item $i')),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
  return changes;
}

/// Start a drag at [from] and move it to [fraction] of the width beyond it,
/// in small steps.
Future<TestGesture> _dragTo(
  WidgetTester t,
  double fraction, {
  double from = 8,
}) async {
  final g = await t.startGesture(Offset(from, 400));
  await _moveBy(t, g, fraction * _width);
  return g;
}

Future<void> _moveBy(WidgetTester t, TestGesture g, double dx) async {
  const steps = 8;
  for (var i = 0; i < steps; i++) {
    await g.moveBy(Offset(dx / steps, 0));
    await t.pump(const Duration(milliseconds: 16));
  }
}

void main() {
  testWidgets('a short swipe from mid-page follows the finger, holds where '
      'it is, and opens on release', (t) async {
    final haptics = _recordHaptics(t);
    final changes = await _mount(t);
    final g = await _dragTo(t, 0.15, from: 200);
    expect(_state(t).progress, closeTo(0.15, 0.01));
    // The page moved aside by the same distance; the sidebar is onstage.
    expect(t.getTopLeft(find.byType(Scaffold)).dx, closeTo(0.15 * _width, 1));
    expect(find.text('row 0'), findsOneWidget);
    expect(haptics, ['lightImpact']);
    // Held still, nothing settles.
    await t.pump(const Duration(seconds: 2));
    expect(_state(t).progress, closeTo(0.15, 0.01));
    expect(changes, isEmpty);
    await g.up();
    await t.pumpAndSettle();
    expect(_state(t).progress, 1);
    expect(_state(t).isOpen, isTrue);
    expect(haptics, ['lightImpact', 'mediumImpact']);
    expect(changes, [true]);
    // Full screen: the page has left entirely.
    expect(
      t.getTopLeft(find.byType(Scaffold, skipOffstage: false)).dx,
      closeTo(_width, 1),
    );
  });

  testWidgets('held at the far end it waits for release; tremor keeps the '
      'direction, a clear reversal cancels without a completion haptic', (
    t,
  ) async {
    final haptics = _recordHaptics(t);
    final changes = await _mount(t);
    final g = await _dragTo(t, 1.2, from: 100);
    await t.pump(const Duration(seconds: 2));
    expect(_state(t).progress, 1);
    expect(changes, isEmpty);
    // Tremor inside the hysteresis, then a clear move back.
    await g.moveBy(const Offset(-10, 0));
    await t.pump(const Duration(milliseconds: 16));
    await g.moveBy(const Offset(10, 0));
    await t.pump(const Duration(milliseconds: 16));
    await _moveBy(t, g, -0.5 * _width);
    expect(_state(t).progress, greaterThan(0.4));
    await g.up();
    await t.pumpAndSettle();
    expect(_state(t).progress, 0);
    expect(_state(t).isOpen, isFalse);
    expect(haptics, ['lightImpact']);
    expect(changes, isEmpty);
  });

  testWidgets('a system-cancelled opening returns closed, owing no '
      'completion haptic, and leaves the page usable', (t) async {
    final haptics = _recordHaptics(t);
    final changes = await _mount(t);
    // Recognized as an opening: an ordinary release here would open.
    final g = await _dragTo(t, 0.7);
    expect(haptics, ['lightImpact']);
    await g.cancel();
    await t.pumpAndSettle();
    expect(_state(t).progress, 0);
    expect(_state(t).isOpen, isFalse);
    expect(haptics, ['lightImpact']);
    expect(changes, isEmpty);
    expect(find.text('row 0'), findsNothing);
    // The page takes input again, and the next gesture behaves normally.
    await t.enterText(find.byKey(const Key('draft')), 'after cancel');
    expect(find.text('after cancel'), findsOneWidget);
    final again = await _dragTo(t, 0.6);
    await t.pump(const Duration(milliseconds: 200));
    await again.up();
    await t.pumpAndSettle();
    expect(_state(t).isOpen, isTrue);
    expect(haptics, ['lightImpact', 'lightImpact', 'mediumImpact']);
    expect(changes, [true]);
  });

  testWidgets('a system-cancelled closing drag returns open, silently, with '
      'the sidebar still usable', (t) async {
    final haptics = _recordHaptics(t);
    final changes = await _mount(t);
    await t.tap(find.byKey(const Key('menu')));
    await t.pumpAndSettle();
    final g = await t.startGesture(const Offset(320, 400));
    for (var i = 0; i < 8; i++) {
      await g.moveBy(const Offset(-36, 0));
      await t.pump(const Duration(milliseconds: 16));
    }
    expect(_state(t).progress, lessThan(0.4));
    // A release here would close; the system cancel must not.
    await g.cancel();
    await t.pumpAndSettle();
    expect(_state(t).progress, 1);
    expect(_state(t).isOpen, isTrue);
    expect(haptics, isEmpty);
    expect(changes, [true]);
    // Still the interactive layer: its own control works.
    await t.tap(find.byKey(const Key('close')));
    await t.pumpAndSettle();
    expect(_state(t).isOpen, isFalse);
  });

  testWidgets('a leftward drag on the open sidebar closes it, silently', (
    t,
  ) async {
    final haptics = _recordHaptics(t);
    final changes = await _mount(t);
    await t.tap(find.byKey(const Key('menu')));
    await t.pumpAndSettle();
    expect(_state(t).isOpen, isTrue);
    // The menu control opens without a gesture haptic.
    expect(haptics, isEmpty);
    // A drag that turns back before release stays open.
    final back = await t.startGesture(const Offset(300, 400));
    for (var i = 0; i < 5; i++) {
      await back.moveBy(const Offset(-20, 0));
      await t.pump(const Duration(milliseconds: 16));
    }
    for (var i = 0; i < 5; i++) {
      await back.moveBy(const Offset(20, 0));
      await t.pump(const Duration(milliseconds: 16));
    }
    await t.pump(const Duration(milliseconds: 200));
    await back.up();
    await t.pumpAndSettle();
    expect(_state(t).progress, 1);
    expect(haptics, isEmpty);
    // A short closing swipe, held, closes on release.
    final close = await t.startGesture(const Offset(300, 400));
    await _moveBy(t, close, -60);
    await t.pump(const Duration(seconds: 1));
    expect(_state(t).progress, closeTo(1 - 60 / _width, 0.01));
    await close.up();
    await t.pumpAndSettle();
    expect(_state(t).isOpen, isFalse);
    expect(_state(t).progress, 0);
    expect(haptics, isEmpty);
    expect(changes, [true, false]);
  });

  testWidgets('system back and Escape close the open sidebar, not the page', (
    t,
  ) async {
    final changes = await _mount(t);
    await t.tap(find.byKey(const Key('menu')));
    await t.pumpAndSettle();
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    expect(_state(t).isOpen, isFalse);
    expect(find.byKey(const Key('menu')), findsOneWidget);

    await t.tap(find.byKey(const Key('menu')));
    await t.pumpAndSettle();
    // Focus moved into the sidebar, so Escape reaches it.
    final scope = FocusManager.instance.primaryFocus!;
    expect(
      find.descendant(
        of: _nav,
        matching: find.byWidgetPredicate(
          (w) => w is FocusScope && w.focusNode == scope,
        ),
      ),
      findsOneWidget,
    );
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pumpAndSettle();
    expect(_state(t).isOpen, isFalse);
    expect(changes, [true, false, true, false]);
  });

  testWidgets('while open, the page is out of semantics, input and focus', (
    t,
  ) async {
    final semantics = t.ensureSemantics();
    await _mount(t);
    expect(find.semantics.byLabel('item 0'), findsOneWidget);
    await t.tap(find.byKey(const Key('menu')));
    await t.pumpAndSettle();
    expect(find.semantics.byLabel('item 0'), findsNothing);
    expect(find.semantics.byLabel('Sessions'), findsOneWidget);
    expect(find.semantics.byLabel('row 0'), findsOneWidget);
    await t.tap(find.byKey(const Key('close')));
    await t.pumpAndSettle();
    expect(find.semantics.byLabel('item 0'), findsOneWidget);
    expect(find.semantics.byLabel('row 0'), findsNothing);
    semantics.dispose();
  });

  testWidgets('sidebar scroll and expansion, and the page draft, survive', (
    t,
  ) async {
    await _mount(t);
    await t.enterText(find.byKey(const Key('draft')), 'unsent words');
    await t.tap(find.byKey(const Key('menu')));
    await t.pumpAndSettle();
    await t.tap(find.text('Group'));
    await t.pumpAndSettle();
    expect(find.text('Nested row'), findsOneWidget);
    await t.tap(find.byKey(const Key('close')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('menu')));
    await t.pumpAndSettle();
    expect(find.text('Nested row'), findsOneWidget);
    // A vertical drag on the open sidebar scrolls it; it does not close.
    await t.drag(_sideList, const Offset(0, -600));
    await t.pumpAndSettle();
    expect(_state(t).isOpen, isTrue);
    double offset() => t
        .state<ScrollableState>(
          find.descendant(
            of: _sideList,
            matching: find.byType(Scrollable, skipOffstage: false),
          ),
        )
        .position
        .pixels;
    final scrolled = offset();
    expect(scrolled, greaterThan(400));

    await t.tap(find.byKey(const Key('close')));
    await t.pumpAndSettle();
    expect(find.text('unsent words'), findsOneWidget);
    await t.tap(find.byKey(const Key('menu')));
    await t.pumpAndSettle();
    expect(offset(), scrolled);
  });

  testWidgets('what the page drag must not take: taps, jitter, vertical '
      'scrolls, mouse selections', (t) async {
    final haptics = _recordHaptics(t);
    await _mount(t);
    double bodyOffset() => t
        .state<ScrollableState>(
          find.descendant(
            of: find.byKey(const Key('body-list')),
            matching: find.byType(Scrollable),
          ),
        )
        .position
        .pixels;
    // A tap and a jitter inside touch slop do not navigate.
    await t.tapAt(const Offset(200, 500));
    final jitter = await t.startGesture(const Offset(200, 500));
    await jitter.moveBy(const Offset(6, 0));
    await jitter.moveBy(const Offset(-6, 0));
    await jitter.up();
    await t.pumpAndSettle();
    expect(_state(t).progress, 0);
    // A vertical scroll still scrolls.
    await t.dragFrom(const Offset(20, 600), const Offset(0, -300));
    await t.pumpAndSettle();
    expect(bodyOffset(), greaterThan(200));
    expect(_state(t).progress, 0);
    // A mouse drag is not navigation.
    await t.dragFrom(
      const Offset(8, 500),
      const Offset(300, 0),
      kind: PointerDeviceKind.mouse,
    );
    await t.pumpAndSettle();
    expect(_state(t).progress, 0);
    expect(haptics, isEmpty);
  });

  testWidgets('with the keyboard up, the page drag leaves the composer alone', (
    t,
  ) async {
    await _mount(t, keyboard: 300);
    await t.dragFrom(const Offset(8, 300), const Offset(300, 0));
    await t.pumpAndSettle();
    expect(_state(t).progress, 0);
    // The explicit control still works.
    await t.tap(find.byKey(const Key('menu')));
    await t.pumpAndSettle();
    expect(_state(t).isOpen, isTrue);
  });

  testWidgets('reduced motion settles without travelling', (t) async {
    final changes = await _mount(t, reduceMotion: true);
    await t.tap(find.byKey(const Key('menu')));
    await t.pump();
    expect(_state(t).progress, 1);
    expect(changes, [true]);
    await t.tap(find.byKey(const Key('close')));
    await t.pump();
    expect(_state(t).progress, 0);
    expect(changes, [true, false]);
    // A drag still tracks the finger: direct manipulation is not decoration.
    final g = await _dragTo(t, 0.3);
    expect(_state(t).progress, closeTo(0.3, 0.01));
    await g.up();
    await t.pump();
    expect(_state(t).progress, 1);
  });
}
