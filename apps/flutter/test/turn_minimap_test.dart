// The turn rail: mark geometry and ink, the hover preview, click-to-jump,
// press-and-drag scrubbing, keyboard navigation, and the gutter rules that
// decide whether it renders at all.

import 'package:flutter/gestures.dart'
    show PointerDeviceKind, PointerScrollEvent;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:pocox/src/widgets/turn_minimap.dart';

List<TurnMinimapItem> _items(int count, {bool Function(int)? loaded}) => [
  for (var i = 0; i < count; i++)
    TurnMinimapItem(
      rowIndex: loaded == null || loaded(i) ? i * 3 : -1,
      turnId: 'turn-$i',
      userText: 'question $i',
      assistantText: 'answer $i',
    ),
];

/// Mount the rail at a fixed size, with [gutter] standing in for the space
/// beside the conversation column.
Future<List<TurnMinimapItem>> _pump(
  WidgetTester t, {
  required List<TurnMinimapItem> items,
  double gutter = 120,
  (int, int)? visible,
  double height = 600,
}) async {
  final selected = <TurnMinimapItem>[];
  await t.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 400,
          height: height,
          child: TurnMinimap(
            items: items,
            visibleRange: ValueNotifier<(int, int)?>(visible),
            gutterWidth: gutter,
            onSelect: selected.add,
            onOpenOutline: () {},
          ),
        ),
      ),
    ),
  );
  await t.pumpAndSettle();
  return selected;
}

Finder _tick(int index) => find.byKey(ValueKey('turn-minimap-tick-$index'));

/// The built marks' indices, in transcript order.
List<int> _built(WidgetTester t) =>
    t
        .widgetList(
          find.byWidgetPredicate(
            (widget) =>
                widget.key is ValueKey<String> &&
                (widget.key! as ValueKey<String>).value.startsWith(
                  'turn-minimap-tick-',
                ),
          ),
        )
        .map(
          (widget) => int.parse(
            (widget.key! as ValueKey<String>).value.split('-').last,
          ),
        )
        .toList()
      ..sort();

double _width(WidgetTester t, int index) => t.getSize(_tick(index)).width;

/// The opacity of a mark's ink.
double _ink(WidgetTester t, int index) =>
    ((t.widget<DecoratedBox>(_tick(index)).decoration as BoxDecoration).color!)
        .a;

final _preview = find.byKey(const Key('turn-minimap-preview'));

Future<TestGesture> _mouse(WidgetTester t) async {
  final gesture = await t.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: Offset.zero);
  addTearDown(gesture.removePointer);
  return gesture;
}

/// Hover mark [index] and wait out the preview's opening delay.
Future<TestGesture> _hoverTick(WidgetTester t, int index) async {
  final gesture = await _mouse(t);
  await gesture.moveTo(t.getCenter(_tick(index)));
  await t.pump(const Duration(milliseconds: 250));
  await t.pumpAndSettle();
  return gesture;
}

void main() {
  testWidgets('ten thousand turns build lazily around the turn on screen', (
    t,
  ) async {
    await _pump(t, items: _items(10000), visible: (15003, 15005));
    expect(_built(t).length, lessThan(150));
    // The rail scrolled itself to the turn being read, and marks it.
    expect(_ink(t, 5001), closeTo(0.6, 0.001));
    expect(find.text('5002 / 10000'), findsOneWidget);
  });

  testWidgets('one mark per turn at a fixed pitch, from four turns', (t) async {
    await _pump(t, items: _items(3));
    expect(_built(t), isEmpty);
    await _pump(t, items: _items(kTurnMinimapMinItems));
    expect(_built(t), hasLength(kTurnMinimapMinItems));
    await _pump(t, items: _items(6));
    expect(_built(t), hasLength(6));
    for (var i = 1; i < 6; i++) {
      expect(t.getCenter(_tick(i)).dy - t.getCenter(_tick(i - 1)).dy, 10);
    }
    // Rather than reach over the centred column — where it would swallow text
    // selection — the rail stands down entirely without a gutter.
    await _pump(t, items: _items(6), gutter: 0);
    expect(_built(t), isEmpty);
  });

  testWidgets('hover grows the mark and its neighbours, then previews', (
    t,
  ) async {
    await _pump(t, items: _items(9));
    final mouse = await _mouse(t);
    await mouse.moveTo(t.getCenter(_tick(4)));
    await t.pump();
    // The pointed-at mark takes full ink at once; its length springs.
    expect(_ink(t, 4), 1);
    expect(_width(t, 4), lessThan(26));
    // The card waits a moment, so sweeping past the rail doesn't flash one.
    await t.pump(const Duration(milliseconds: 150));
    expect(_preview, findsNothing);
    await t.pump(const Duration(milliseconds: 100));
    await t.pumpAndSettle();
    expect(
      [for (var i = 0; i < 9; i++) _width(t, i)],
      [6, 10, 14, 20, 26, 20, 14, 10, 6],
    );
    expect(find.text('question 4'), findsOneWidget);
    expect(find.text('answer 4'), findsOneWidget);
    // Once open, it follows the pointer without waiting again.
    await mouse.moveTo(t.getCenter(_tick(6)));
    await t.pump();
    expect(find.text('question 6'), findsOneWidget);
  });

  testWidgets('the turns on screen are marked until the pointer takes over', (
    t,
  ) async {
    final items = _items(8);
    final visible = ValueNotifier<(int, int)?>((
      items[2].rowIndex,
      items[4].rowIndex + 1,
    ));
    addTearDown(visible.dispose);
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 600,
            child: TurnMinimap(
              items: items,
              visibleRange: visible,
              gutterWidth: 120,
              onSelect: (_) {},
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    List<double> inks() => [for (var i = 0; i < 8; i++) _ink(t, i)];
    const rest = 0.28, current = 0.6;
    expect(inks(), [rest, rest, current, current, current, rest, rest, rest]);
    expect([for (var i = 0; i < 8; i++) _width(t, i)], everyElement(6));

    final mouse = await _hoverTick(t, 6);
    expect(inks(), [rest, rest, rest, rest, rest, rest, 1, rest]);
    await mouse.moveTo(const Offset(2000, 2000));
    await t.pumpAndSettle();
    expect(inks(), [rest, rest, current, current, current, rest, rest, rest]);
    expect(_preview, findsNothing);

    // Scrolling the transcript moves the marked span; a reply read past its
    // question keeps its own turn marked.
    visible.value = (items[5].rowIndex + 1, items[5].rowIndex + 2);
    await t.pump();
    expect(inks(), [rest, rest, rest, rest, rest, current, rest, rest]);
  });

  testWidgets('a click jumps by row index and the preview stays while hovered', (
    t,
  ) async {
    final items = _items(6);
    final selected = await _pump(t, items: items);
    final mouse = await _hoverTick(t, 5);
    await mouse.down(t.getCenter(_tick(5)));
    await mouse.up();
    await t.pumpAndSettle();
    // Row index, not tick index: a turn's user message sits several rows apart
    // from the previous one's, and the transcript scrolls by row.
    expect(selected.single.rowIndex, items.last.rowIndex);
    expect(find.text('question 5'), findsOneWidget);

    await mouse.moveTo(const Offset(399, 599));
    await t.pumpAndSettle();
    expect(_preview, findsNothing);
    expect(_width(t, 5), 6);
  });

  testWidgets('press and drag scrubs through the loaded turns', (t) async {
    // Turn 3 has not been loaded: crossing it must not queue a page.
    final items = _items(8, loaded: (i) => i != 3 && i != 6);
    final selected = await _pump(t, items: items);
    final mouse = await _hoverTick(t, 0);
    await mouse.down(t.getCenter(_tick(0)));
    for (final i in [1, 2, 3, 4, 5, 6]) {
      await mouse.moveTo(t.getCenter(_tick(i)) + const Offset(40, 0));
      await t.pump();
      // The mark under the press follows at once, preview and all.
      expect(_width(t, i), 26);
      expect(find.text('question $i'), findsOneWidget);
    }
    expect(
      [for (final item in selected) item.turnId],
      ['turn-1', 'turn-2', 'turn-4', 'turn-5'],
    );
    // Released on a turn not loaded yet, the scrub fetches that one; the
    // release is not also a click on where the press began.
    await mouse.up();
    await t.pumpAndSettle();
    expect(selected.last.turnId, 'turn-6');
    expect(selected, hasLength(5));
  });

  testWidgets('a long conversation scrolls the rail instead of packing it', (
    t,
  ) async {
    final items = _items(200);
    await _pump(
      t,
      items: items,
      height: 300,
      visible: (items[150].rowIndex, items[151].rowIndex),
    );
    final rail = t.getRect(find.byKey(const Key('turn-minimap-rail')));
    expect(rail.height, 210, reason: '70% of the height');
    expect(t.getRect(_tick(150)).top, inInclusiveRange(rail.top, rail.bottom));
    expect(_built(t), isNot(contains(0)));

    // The wheel over the rail scrolls the marks, not the conversation.
    final before = t.getCenter(_tick(150)).dy;
    final mouse = await _mouse(t);
    await mouse.moveTo(rail.center);
    await t.sendEventToBinding(
      const PointerScrollEvent(
        kind: PointerDeviceKind.mouse,
        position: Offset(20, 150),
        scrollDelta: Offset(0, -30),
      ),
    );
    await t.pumpAndSettle();
    expect(t.getCenter(_tick(150)).dy, before + 30);
  });

  for (final count in [4, 12]) {
    testWidgets('$count turns: padded rail ends remain clickable', (t) async {
      final items = _items(count);
      final selected = await _pump(t, items: items, height: 300);
      final rail = t.getRect(find.byKey(const Key('turn-minimap-rail')));
      final mouse = await _hoverTick(t, 0);
      for (final (point, index) in [
        (Offset(rail.left - 8, rail.top - 8), 0),
        (Offset(rail.left - 8, rail.bottom + 8), count - 1),
      ]) {
        await mouse.moveTo(point);
        await t.pumpAndSettle();
        expect(find.text('question $index'), findsOneWidget);
        await mouse.down(point);
        await mouse.up();
        await t.pumpAndSettle();
        expect(selected.last, same(items[index]));
      }
      expect(selected, hasLength(2));
    });

    testWidgets('$count turns: crossing the gap keeps the preview target', (
      t,
    ) async {
      final items = _items(count);
      final selected = await _pump(t, items: items, height: 300);
      final index = count ~/ 2;
      final mouse = await _hoverTick(t, index);
      final tick = t.getRect(_tick(index));
      // Up to the longest mark's end, then diagonally into the gap.
      final gap = Offset(tick.right + 5, tick.center.dy + 8);
      await mouse.moveTo(gap);
      await t.pumpAndSettle();
      expect(find.text('question $index'), findsOneWidget);
      expect(_width(t, index), 26);
      await mouse.down(gap);
      await mouse.up();
      await t.pumpAndSettle();
      expect(selected.single, same(items[index]));
    });

    for (final index in [0, count - 1]) {
      testWidgets(
        '$count turns: end preview $index accepts an imprecise click',
        (t) async {
          final items = _items(count);
          final selected = await _pump(t, items: items, height: 300);
          final rail = t.getRect(find.byKey(const Key('turn-minimap-rail')));
          final mouse = await _hoverTick(t, index);
          final card = t.getRect(_preview);
          final point = index == 0
              ? Offset(card.right + 4, card.bottom + 4)
              : Offset(card.right + 4, card.top - 4);
          if (count == 4) {
            expect(rail.contains(point), isFalse);
          }
          await mouse.moveTo(point);
          await t.pumpAndSettle();
          expect(find.text('question $index'), findsOneWidget);
          await mouse.down(point);
          await mouse.up();
          await t.pumpAndSettle();
          expect(selected.single, same(items[index]));
        },
      );
    }
  }

  testWidgets('leaving the preview for empty space restores the rail', (
    t,
  ) async {
    await _pump(t, items: _items(20));
    final mouse = await _hoverTick(t, 0);
    await mouse.moveTo(t.getCenter(_preview));
    await t.pumpAndSettle();
    expect(_preview, findsOneWidget);
    expect(_width(t, 0), 26);

    final rail = t.getRect(find.byKey(const Key('turn-minimap-rail')));
    await mouse.moveTo(Offset(rail.left + 200, rail.bottom - 2));
    await t.pumpAndSettle();
    expect(_preview, findsNothing);
    expect(_width(t, 0), 6);
  });

  for (final hasTurnId in [true, false]) {
    testWidgets(
      'a preview keeps its target across row updates, turn id: $hasTurnId',
      (t) async {
        var items = [
          for (var i = 0; i < 12; i++)
            TurnMinimapItem(
              rowIndex: i * 3,
              userText: i == 0 ? 'question 5' : 'question $i',
              assistantText: 'answer $i',
              turnId: hasTurnId ? 'turn-$i' : '',
              messageId: 'user-$i',
            ),
        ];
        late StateSetter rebuild;
        final selected = <TurnMinimapItem>[];
        final visible = ValueNotifier<(int, int)?>(null);
        addTearDown(visible.dispose);
        await t.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 400,
                height: 300,
                child: StatefulBuilder(
                  builder: (context, setState) {
                    rebuild = setState;
                    return TurnMinimap(
                      items: items,
                      visibleRange: visible,
                      gutterWidth: 120,
                      onSelect: selected.add,
                      onOpenOutline: () {},
                    );
                  },
                ),
              ),
            ),
          ),
        );
        final mouse = await _hoverTick(t, 5);
        final card = t.getCenter(_preview);
        await mouse.moveTo(card);
        await t.pumpAndSettle();
        await mouse.down(card);
        await t.pump(const Duration(milliseconds: 150));
        rebuild(() {
          items = [
            const TurnMinimapItem(
              rowIndex: 0,
              userText: 'older',
              turnId: 'older',
            ),
            for (final item in items)
              TurnMinimapItem(
                rowIndex: item.rowIndex + 20,
                userText: item.userText,
                assistantText: item.assistantText,
                turnId: item.turnId,
                messageId: item.messageId,
              ),
          ];
        });
        await t.pumpAndSettle();
        expect(find.text('question 5'), findsOneWidget);
        await mouse.up();
        await t.pumpAndSettle();
        expect(selected.single.turnId, hasTurnId ? 'turn-5' : '');
        expect(selected.single.messageId, 'user-5');
        expect(selected.single.rowIndex, 35);
      },
    );
  }

  testWidgets('a cancelled press does not jump', (t) async {
    final selected = await _pump(t, items: _items(12), height: 300);
    final mouse = await _hoverTick(t, 6);
    final card = t.getCenter(_preview);
    await mouse.down(card);
    await t.pump(const Duration(milliseconds: 150));
    await mouse.moveBy(const Offset(60, 0));
    await mouse.up();
    await t.pumpAndSettle();
    expect(selected, isEmpty);
  });

  testWidgets('empty space beside a preview passes clicks to the transcript', (
    t,
  ) async {
    var backgroundClicks = 0;
    final selected = <TurnMinimapItem>[];
    final visible = ValueNotifier<(int, int)?>(null);
    addTearDown(visible.dispose);
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 300,
            child: Stack(
              children: [
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => backgroundClicks++,
                  ),
                ),
                Positioned.fill(
                  child: TurnMinimap(
                    items: _items(400),
                    visibleRange: visible,
                    gutterWidth: 120,
                    onSelect: selected.add,
                    onOpenOutline: () {},
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await _hoverTick(t, 0);
    final rail = t.getRect(find.byKey(const Key('turn-minimap-rail')));
    await t.tapAt(Offset(rail.left + 200, rail.bottom - 2));
    await t.pumpAndSettle();
    expect(backgroundClicks, 1);
    expect(selected, isEmpty);
  });

  testWidgets('keyboard walks the turns and enter jumps', (t) async {
    final items = _items(5);
    final selected = await _pump(t, items: items);

    // Focus the rail: the first turn becomes active, so tabbing in shows where
    // the keyboard will act rather than nothing at all. Reached through the
    // rail's own Focus widget — an ancestor scope would take the key events.
    final focus = t
        .widget<Focus>(
          find
              .descendant(
                of: find.byType(TurnMinimap),
                matching: find.byType(Focus),
              )
              .first,
        )
        .focusNode!;
    focus.requestFocus();
    await t.pumpAndSettle();
    expect(find.text('question 0'), findsOneWidget);

    await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await t.pumpAndSettle();
    expect(find.text('question 1'), findsOneWidget);

    await t.sendKeyEvent(LogicalKeyboardKey.end);
    await t.pumpAndSettle();
    expect(find.text('question 4'), findsOneWidget);

    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.pumpAndSettle();
    expect(selected.single.rowIndex, items.last.rowIndex);
  });

  testWidgets('the rail rests at the window edge, not against the column', (
    t,
  ) async {
    // It used to be placed relative to the conversation column, so it drifted
    // outward with the gutter and floated in the middle of empty margin on a wide
    // window. An index of the whole conversation belongs where a scrollbar is.
    // Asserted across two gutter widths, since the bug was precisely that the
    // position tracked the gutter.
    await _pump(t, items: _items(5), gutter: 60);
    final narrow = t.getTopLeft(find.byKey(const Key('turn-minimap-rail'))).dx;
    await _pump(t, items: _items(5), gutter: 300);
    final wide = t.getTopLeft(find.byKey(const Key('turn-minimap-rail'))).dx;

    expect(narrow, wide, reason: 'the rail must not move with the gutter');
    expect(
      wide,
      lessThanOrEqualTo(kTurnMinimapRailInset),
      reason: 'it sits at the frame, not out beside the prose',
    );
  });

  testWidgets('a tight gutter narrows the card instead of burying the text', (
    t,
  ) async {
    // Some overhang is unavoidable — a readable card does not fit a 60 px
    // margin — but it is budgeted, so the card shrinks rather than covering the
    // column it floats beside.
    await _pump(t, items: _items(4), gutter: 60);
    await _hoverTick(t, 0);
    expect(t.getSize(_preview).width, lessThan(320));
  });

  testWidgets('the card shows what a turn has, and nothing for none', (
    t,
  ) async {
    // The sidebar renders an attachment-only message as "[file]" because a
    // row must say something. Heading a preview card with the word "file"
    // names the attachment rather than the turn, so the caller passes no
    // placeholder and the reply carries the card alone. A turn with neither
    // gets no card: an empty one would only occlude the conversation. Its
    // mark stays — it is still a turn you can jump to.
    await _pump(
      t,
      items: const [
        TurnMinimapItem(rowIndex: 0, userText: '', assistantText: 'read it'),
        TurnMinimapItem(rowIndex: 4, userText: 'unanswered'),
        TurnMinimapItem(rowIndex: 8, userText: ''),
        TurnMinimapItem(rowIndex: 12, userText: 'fourth', assistantText: 'ok'),
      ],
    );
    final mouse = await _hoverTick(t, 0);
    expect(find.text('read it'), findsOneWidget);
    await mouse.moveTo(t.getCenter(_tick(1)));
    await t.pumpAndSettle();
    expect(find.text('unanswered'), findsOneWidget);
    await mouse.moveTo(t.getCenter(_tick(2)));
    await t.pumpAndSettle();
    expect(_preview, findsNothing);
    expect(_built(t), hasLength(4));
  });
}
