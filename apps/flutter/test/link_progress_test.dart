import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/providers.dart';
import 'package:pocox/src/theme.dart';
import 'package:pocox/src/widgets/link_progress.dart';

import 'fake_bridge_api.dart';
import 'support/ui_preview.dart';

const _service = 'pcx:studio:app:default';

/// A tunnel that came up through the relay after a direct attempt fell
/// back, and is punching through again for a new connection.
const _tunnel = SubInfo(
  key: _service,
  localAddr: '127.0.0.1:28080',
  alive: true,
  path: TunnelPath.relay,
  activeRelay: 1,
  relaySessions: 2,
  fallbacks: 1,
  setupLatencyMs: 64,
  attempt: DirectAttempt(stage: DirectStage.punching, elapsedMs: 700),
  events: [
    LinkEvent(
      seq: 1,
      ageMs: 64000,
      kind: LinkEventKind.relayFailed,
      failure: TunnelFailure.timeout,
      repeats: 3,
      ms: 4000,
    ),
    LinkEvent(seq: 4, ageMs: 30000, kind: LinkEventKind.networkChanged),
    LinkEvent(seq: 5, ageMs: 20000, kind: LinkEventKind.relayReady, ms: 64),
    LinkEvent(
      seq: 6,
      ageMs: 1500,
      kind: LinkEventKind.directFallback,
      stage: DirectStage.punching,
    ),
  ],
);

void main() {
  setUpAll(loadPreviewFonts);

  Future<void> mount(
    WidgetTester t,
    ReconnectState state, {
    bool light = false,
    double width = 393,
    VoidCallback? onRetry,
  }) async {
    t.view.physicalSize = Size(width, 760);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'relay:7666', hasKey: true),
    )..putSubscription(_tunnel);
    await t.pumpWidget(
      ProviderScope(
        overrides: [bridgeApiProvider.overrideWithValue(api)],
        child: MaterialApp(
          theme: light ? lightTheme() : darkTheme(),
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: RepaintBoundary(
                key: previewKey,
                child: Material(
                  child: SizedBox(
                    width: width.clamp(0, 420),
                    child: LinkSheet(
                      serviceKey: _service,
                      reconnect: ValueNotifier(state),
                      connected: () => false,
                      onRetry: onRetry,
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
    // The first sample, then its steps settled in.
    await t.pump(const Duration(milliseconds: 50));
    await t.pump(const Duration(milliseconds: 300));
  }

  testWidgets('the connection sheet shows each step, the wait and the '
      'history, and retries at once', (t) async {
    final zh = await AppLocalizations.delegate.load(const Locale('zh'));
    var retried = 0;
    await mount(
      t,
      ReconnectState(
        active: true,
        attempt: 5,
        retryAt: DateTime.now().add(const Duration(seconds: 8)),
        lastError: 'relay down',
      ),
      onRetry: () => retried++,
    );
    expect(find.byKey(const Key('link-pipeline')), findsOneWidget);
    expect(find.byKey(const Key('link-sheet-headline')), findsOneWidget);
    expect(find.text(zh.linkAttempt(5)), findsOneWidget);
    expect(find.text('relay down'), findsOneWidget);
    // The punch in flight, and the history newest first.
    expect(find.text(zh.linkDirectPunching), findsWidgets);
    expect(find.byKey(const Key('link-timeline')), findsOneWidget);
    expect(
      find.text(zh.linkEventFallback(zh.linkStagePunching)),
      findsOneWidget,
    );
    expect(find.textContaining('×3'), findsOneWidget);
    await capturePreview(t, 'link-sheet-retrying-dark');
    await t.tap(find.byKey(const Key('link-retry-now')));
    expect(retried, 1);

    await mount(
      t,
      ReconnectState(
        active: true,
        attempt: 2,
        startedAt: DateTime.now().subtract(const Duration(seconds: 3)),
      ),
      light: true,
      width: 1100,
    );
    expect(find.byKey(const Key('link-retry-now')), findsNothing);
    await capturePreview(t, 'link-sheet-attempt-light');
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 1));
    expect(t.takeException(), isNull);
  });
}
