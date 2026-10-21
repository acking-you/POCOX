import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/theme.dart';
import 'package:pocox/src/widgets/jump_to_latest_button.dart';

import 'support/ui_preview.dart';

void main() {
  setUpAll(loadPreviewFonts);

  testWidgets('the running button animates without moving its target, rests '
      'with reduced motion or offstage, and stops when idle', (t) async {
    var presses = 0;
    Future<void> mount({
      bool running = true,
      bool reduced = false,
      bool ticking = true,
      bool light = false,
    }) async {
      await t.pumpWidget(
        MaterialApp(
          theme: light ? lightTheme() : darkTheme(),
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: reduced),
            child: TickerMode(
              enabled: ticking,
              child: Scaffold(
                body: Center(
                  child: RepaintBoundary(
                    key: previewKey,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: JumpToLatestButton(
                        running: running,
                        onPressed: () => presses++,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await t.pump();
    }

    Future<List<int>> pixels() async {
      final boundary = t.renderObject<RenderRepaintBoundary>(
        find.byKey(previewKey),
      );
      return (await t.runAsync(() async {
        final image = await boundary.toImage();
        try {
          final bytes = await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          return bytes!.buffer.asUint8List().toList();
        } finally {
          image.dispose();
        }
      }))!;
    }

    await mount();
    final button = find.byKey(const Key('nav-to-bottom'));
    final target = t.getRect(button);
    expect(target.shortestSide, greaterThanOrEqualTo(44));
    final before = await pixels();
    await t.pump(const Duration(milliseconds: 600));
    expect(await pixels(), isNot(before));
    expect(t.getRect(button), target);
    await capturePreview(t, 'jump-running-dark');
    await t.tap(button);
    expect(presses, 1, reason: 'the moving ring never intercepts a tap');

    await mount(running: false);
    await t.pumpAndSettle();
    final idle = await pixels();
    await t.pump(const Duration(seconds: 1));
    expect(await pixels(), idle);
    expect(t.binding.transientCallbackCount, 0);
    await capturePreview(t, 'jump-idle-dark');

    await mount(light: true);
    await t.pump(const Duration(milliseconds: 600));
    await capturePreview(t, 'jump-running-light');
    await mount(reduced: true);
    await t.pumpAndSettle();
    final reduced = await pixels();
    await t.pump(const Duration(seconds: 1));
    expect(await pixels(), reduced);
    expect(t.binding.transientCallbackCount, 0);
    expect(
      reduced,
      isNot(idle),
      reason: 'running remains visible without motion',
    );

    await mount(ticking: false);
    final muted = await pixels();
    await t.pump(const Duration(seconds: 1));
    expect(await pixels(), muted);
    expect(t.binding.transientCallbackCount, 0);
    await mount();
    await t.pumpWidget(const SizedBox());
    expect(t.binding.transientCallbackCount, 0);
    expect(t.takeException(), isNull);
  });
}
