import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocox/src/widgets/running_sheen.dart';
import 'package:pocox/src/widgets/status_dots.dart';

Future<List<int>> pixels(WidgetTester t, GlobalKey key) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  return (await t.runAsync(() async {
    final image = await boundary.toImage();
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      return bytes!.buffer.asUint8List().toList();
    } finally {
      image.dispose();
    }
  }))!;
}

void main() {
  testWidgets('running marks repaint without rebuilding content, stop under '
      'reduced motion or TickerMode, and release their tickers', (t) async {
    final orbit = GlobalKey();
    final sheen = GlobalKey();
    var contentBuilds = 0;
    final content = Builder(
      builder: (_) {
        contentBuilds++;
        return const SizedBox(width: 200, height: 44);
      },
    );
    Future<void> mount({bool reduce = false, bool ticking = true}) async {
      await t.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: reduce),
            child: TickerMode(
              enabled: ticking,
              child: Column(
                children: [
                  RepaintBoundary(
                    key: orbit,
                    child: const PulsingDot.orbit(color: Colors.blue),
                  ),
                  RepaintBoundary(
                    key: sheen,
                    child: RunningSheen(color: Colors.blue, child: content),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await t.pump();
    }

    await mount();
    final built = contentBuilds;
    final orbitBefore = await pixels(t, orbit);
    final sheenBefore = await pixels(t, sheen);
    await t.pump(const Duration(milliseconds: 600));
    expect(await pixels(t, orbit), isNot(orbitBefore));
    expect(await pixels(t, sheen), isNot(sheenBefore));
    expect(contentBuilds, built, reason: 'paint frames do not rebuild the row');

    for (final reduced in [true, false]) {
      await mount(reduce: reduced, ticking: reduced);
      final stillOrbit = await pixels(t, orbit);
      final stillSheen = await pixels(t, sheen);
      await t.pump(const Duration(milliseconds: 700));
      expect(await pixels(t, orbit), stillOrbit);
      expect(await pixels(t, sheen), stillSheen);
      expect(t.binding.transientCallbackCount, 0);
    }
    await mount();
    expect(t.binding.transientCallbackCount, 2);
    await t.pumpWidget(const SizedBox());
    expect(t.binding.transientCallbackCount, 0);
    expect(t.takeException(), isNull);
  });

  testWidgets('a reused dot switches between breathing and continuous orbit', (
    t,
  ) async {
    final key = GlobalKey();
    Future<void> mount(bool orbit) async {
      await t.pumpWidget(
        MaterialApp(
          home: Center(
            child: RepaintBoundary(
              key: key,
              child: orbit
                  ? const PulsingDot.orbit(color: Colors.blue)
                  : const PulsingDot(color: Colors.blue, size: 12),
            ),
          ),
        ),
      );
      await t.pump();
    }

    await mount(false);
    await t.pump(const Duration(milliseconds: 200));
    await mount(true);
    final first = await pixels(t, key);
    await t.pump(const Duration(milliseconds: 1000));
    expect(
      await pixels(t, key),
      first,
      reason: 'an orbit completes in one second',
    );
    await mount(false);
    final pulse = await pixels(t, key);
    await t.pump(const Duration(milliseconds: 550));
    expect(await pixels(t, key), isNot(pulse));
    await t.pumpWidget(const SizedBox());
    expect(t.binding.transientCallbackCount, 0);
  });
}
