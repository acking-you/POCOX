import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocox/src/widgets/turn_navigation_handle.dart';

void main() {
  testWidgets('the handle opens on touch and folds when the reader scrolls', (
    t,
  ) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    var steps = 0;
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              ListView.builder(
                controller: scroll,
                itemCount: 100,
                itemBuilder: (_, i) => SizedBox(height: 40, child: Text('$i')),
              ),
              Positioned(
                right: 12,
                bottom: 12,
                child: TurnNavigationHandle(
                  label: 'Show conversation controls',
                  scroll: scroll,
                  controls: [
                    IconButton(
                      key: const Key('step'),
                      onPressed: () => steps++,
                      icon: const Icon(Icons.keyboard_arrow_up),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.byKey(const Key('step')), findsNothing);
    await t.tap(find.byKey(const Key('turn-navigation-handle')));
    await t.pumpAndSettle();
    // Open, it stays open while it is being used.
    await t.tap(find.byKey(const Key('step')));
    await t.pump();
    expect(steps, 1);
    expect(find.byKey(const Key('step')), findsOneWidget);
    // A programmatic jump is not the reader scrolling on.
    scroll.jumpTo(400);
    await t.pumpAndSettle();
    expect(find.byKey(const Key('step')), findsOneWidget);
    // The reader scrolling on folds it.
    await t.drag(find.text('12'), const Offset(0, -200));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('step')), findsNothing);
    // Left alone, it folds by itself too.
    await t.tap(find.byKey(const Key('turn-navigation-handle')));
    await t.pumpAndSettle();
    await t.pump(TurnNavigationHandle.idle);
    await t.pumpAndSettle();
    expect(find.byKey(const Key('step')), findsNothing);
  });
}
