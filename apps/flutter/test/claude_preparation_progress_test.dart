// The Claude adapter preparation card says only what it knows. It shows the
// stage, the elapsed time, and the bytes received and measured speed once the
// bridge reports them. It never shows a percentage, total or time left. The
// speed is hidden while verifying and after the end. "No sample yet" stays
// distinct from a measured zero. Only the move to verification is announced.
// The bar moves only while running with motion allowed and ticking.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/hosting/claude_preparation_progress.dart';
import 'package:pocox/src/theme.dart';

Future<void> _mount(
  WidgetTester t,
  AcpClaudeSetup setup, {
  Locale locale = const Locale('en'),
  ThemeData? theme,
  bool reduceMotion = false,
  bool tickers = true,
  double textScale = 1,
  TextDirection? direction,
  double width = 420,
  bool joined = false,
}) async {
  await t.pumpWidget(
    MaterialApp(
      locale: locale,
      theme: theme,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            disableAnimations: reduceMotion,
            textScaler: TextScaler.linear(textScale),
          ),
          child: Directionality(
            textDirection: direction ?? Directionality.of(context),
            child: TickerMode(
              enabled: tickers,
              child: Scaffold(
                body: Align(
                  alignment: Alignment.topCenter,
                  child: SizedBox(
                    width: width,
                    child: ClaudePreparationProgress(
                      setup: setup,
                      joined: joined,
                    ),
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

const _downloading = AcpClaudeSetup(
  state: 'running',
  stage: 'downloading',
  run: 1,
  elapsedMs: 42500,
  downloadedBytes: 3400000,
  downloadBytesPerSecond: 1800000,
);

Finder _key(String key) => find.byKey(Key(key));

void main() {
  test('sizes and clocks read plainly and never round up into a lie', () {
    expect(formatByteCount(0), '0 B');
    expect(formatByteCount(999), '999 B');
    expect(formatByteCount(1000), '1.0 KB');
    expect(formatByteCount(9940), '9.9 KB');
    expect(formatByteCount(640000), '640 KB');
    expect(formatByteCount(999600), '1.0 MB');
    expect(formatByteCount(3400000), '3.4 MB');
    expect(formatByteCount(12400000), '12 MB');
    expect(formatByteCount(2100000000), '2.1 GB');
    expect(formatElapsed(0), '0:00');
    expect(formatElapsed(42999), '0:42');
    expect(formatElapsed(725000), '12:05');
    expect(formatElapsed(3725000), '1:02:05');
  });

  testWidgets('a download shows its stage, clock, size and speed, and the '
      'bar moves', (t) async {
    final semantics = t.ensureSemantics();
    await _mount(t, _downloading);
    expect(find.text('Downloading packages…'), findsOneWidget);
    expect(find.text('0:42'), findsOneWidget);
    expect(find.bySemanticsLabel('0:42 elapsed'), findsOneWidget);
    expect(find.text('3.4 MB downloaded'), findsOneWidget);
    expect(find.text('1.8 MB/s'), findsOneWidget);
    expect(find.bySemanticsLabel('Download speed 1.8 MB/s'), findsOneWidget);
    expect(find.textContaining('%'), findsNothing, reason: 'no total exists');
    expect(
      t.getSemantics(_key('claude-prepare-steps')),
      isSemantics(
        isLiveRegion: true,
        label: 'Step 1 of 2: Download and install',
      ),
    );
    expect(t.binding.transientCallbackCount, greaterThan(0));
    await t.pump(const Duration(milliseconds: 900));
    expect(t.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('no sample yet is not a measured zero', (t) async {
    await _mount(
      t,
      const AcpClaudeSetup(
        state: 'running',
        stage: 'downloading',
        run: 1,
        downloadedBytes: 0,
      ),
    );
    expect(_key('claude-prepare-speed-measuring'), findsOneWidget);
    expect(find.text('Measuring speed…'), findsOneWidget);
    expect(_key('claude-prepare-speed'), findsNothing);
    expect(find.text('0 B downloaded'), findsOneWidget);

    await _mount(
      t,
      const AcpClaudeSetup(
        state: 'running',
        stage: 'downloading',
        run: 1,
        downloadedBytes: 5200000,
        downloadBytesPerSecond: 0,
      ),
    );
    expect(find.text('0 B/s'), findsOneWidget, reason: 'a stall says zero');
    expect(_key('claude-prepare-speed-measuring'), findsNothing);
    expect(find.text('5.2 MB downloaded'), findsOneWidget);
  });

  testWidgets('without telemetry nothing is invented', (t) async {
    await _mount(
      t,
      const AcpClaudeSetup(
        state: 'running',
        stage: 'installing',
        run: 1,
        elapsedMs: 7000,
      ),
    );
    expect(find.text('Resolving and installing packages…'), findsOneWidget);
    expect(find.text('0:07'), findsOneWidget);
    expect(_key('claude-prepare-downloaded'), findsNothing);
    expect(_key('claude-prepare-speed'), findsNothing);
    expect(_key('claude-prepare-speed-measuring'), findsNothing);
    expect(_key('claude-prepare-bar'), findsOneWidget);
  });

  testWidgets('verifying keeps the size, drops the speed and announces the '
      'second step', (t) async {
    final semantics = t.ensureSemantics();
    await _mount(t, _downloading);
    await _mount(
      t,
      const AcpClaudeSetup(
        state: 'running',
        stage: 'verifying',
        run: 1,
        elapsedMs: 61000,
        downloadedBytes: 4100000,
        downloadBytesPerSecond: 900000,
      ),
    );
    expect(find.text('Checking the downloaded adapter…'), findsOneWidget);
    expect(find.text('1:01'), findsOneWidget);
    expect(find.text('4.1 MB downloaded'), findsOneWidget);
    expect(_key('claude-prepare-speed'), findsNothing);
    expect(_key('claude-prepare-speed-measuring'), findsNothing);
    expect(
      t.getSemantics(_key('claude-prepare-steps')),
      isSemantics(isLiveRegion: true, label: 'Step 2 of 2: Verify'),
    );
    semantics.dispose();
  });

  for (final (state, title) in [
    ('done', 'The Claude ACP adapter is ready'),
    ('failed', 'Preparation failed'),
    ('cancelled', 'Preparation stopped'),
  ]) {
    testWidgets('$state: settled, still and without a live speed', (t) async {
      await _mount(
        t,
        AcpClaudeSetup(
          state: state,
          stage: 'downloading',
          run: 1,
          downloadedBytes: 3400000,
          downloadBytesPerSecond: 1800000,
        ),
      );
      expect(find.text(title), findsOneWidget);
      expect(_key('claude-prepare-speed'), findsNothing);
      expect(_key('claude-prepare-steps'), findsNothing);
      expect(find.text('3.4 MB downloaded'), findsOneWidget);
      await t.pumpAndSettle();
      expect(t.binding.transientCallbackCount, 0);
    });
  }

  testWidgets('reduced motion and a muted ticker hold the bar still', (
    t,
  ) async {
    await _mount(t, _downloading, reduceMotion: true);
    await t.pumpAndSettle();
    expect(t.binding.transientCallbackCount, 0);
    expect(find.text('1.8 MB/s'), findsOneWidget, reason: 'facts stay');

    await _mount(t, _downloading, tickers: false);
    await t.pump(const Duration(milliseconds: 100));
    expect(t.binding.transientCallbackCount, 0);

    await _mount(t, _downloading);
    expect(t.binding.transientCallbackCount, greaterThan(0));
    await t.pumpWidget(const SizedBox());
    expect(t.binding.transientCallbackCount, 0, reason: 'disposed');
  });

  for (final (name, locale, theme, direction) in [
    ('zh dark', const Locale('zh'), darkTheme(), TextDirection.ltr),
    ('en light RTL', const Locale('en'), lightTheme(), TextDirection.rtl),
  ]) {
    testWidgets('$name on a narrow phone at 2× text stays whole', (t) async {
      t.view.physicalSize = const Size(360, 780);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await _mount(
        t,
        _downloading,
        locale: locale,
        theme: theme,
        direction: direction,
        textScale: 2,
        width: 320,
        joined: true,
      );
      expect(t.takeException(), isNull);
      expect(_key('claude-prepare-joined'), findsOneWidget);
      if (locale.languageCode == 'zh') {
        expect(find.text('正在下载依赖包…'), findsOneWidget);
        expect(find.text('已下载 3.4 MB'), findsOneWidget);
        expect(find.text('下载并安装'), findsOneWidget);
      }
      final card = t.getRect(find.byType(ClaudePreparationProgress));
      expect(card.width, 320);
      expect(t.getRect(_key('claude-prepare-bar')).width, lessThan(320));
      await t.pump(const Duration(milliseconds: 600));
      expect(t.takeException(), isNull);
    });
  }

  testWidgets('the speed trace draws only polled speeds of this run while '
      'downloading', (t) async {
    AcpClaudeSetup poll(int run, int rate, {String stage = 'downloading'}) =>
        AcpClaudeSetup(
          state: 'running',
          stage: stage,
          run: run,
          downloadedBytes: 1000000,
          downloadBytesPerSecond: rate,
        );
    final first = poll(1, 1800000);
    await _mount(t, first);
    expect(
      _key('claude-prepare-speed-trace'),
      findsNothing,
      reason: 'one sample is not a trace',
    );
    // A rebuild with the same answer is not another sample.
    await _mount(t, first);
    expect(_key('claude-prepare-speed-trace'), findsNothing);
    await _mount(t, poll(1, 0));
    expect(_key('claude-prepare-speed-trace'), findsOneWidget);
    expect(find.text('0 B/s'), findsOneWidget);
    await _mount(t, poll(1, 900000, stage: 'verifying'));
    expect(_key('claude-prepare-speed-trace'), findsNothing);
    // Another run starts from nothing.
    await _mount(t, poll(2, 700000));
    expect(_key('claude-prepare-speed-trace'), findsNothing);
    await _mount(t, poll(2, 650000));
    expect(_key('claude-prepare-speed-trace'), findsOneWidget);
    expect(t.binding.transientCallbackCount, greaterThan(0));
    await _mount(t, poll(2, 650000), reduceMotion: true);
    await t.pumpAndSettle();
    expect(
      _key('claude-prepare-speed-trace'),
      findsOneWidget,
      reason: 'the trace is static and stays with reduced motion',
    );
    expect(t.takeException(), isNull);
  });
}
