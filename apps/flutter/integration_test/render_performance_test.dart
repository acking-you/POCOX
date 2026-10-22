// Opt-in production-widget and highlighting measurements; no host or model access.
// Run with flutter drive --profile -d macos and POCOX_RENDER_PERF=true.
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/code_highlight.dart';
import 'package:pocox/src/rust/frb_generated.dart';
import 'fixtures/legacy_highlight.dart' as legacy;
import 'package:pocox/src/theme.dart';
import 'package:pocox/src/widgets/markdown_view.dart';
import 'package:window_manager/window_manager.dart';

Map<String, num> stats(List<int> input) {
  final sorted = [...input]..sort();
  if (sorted.isEmpty) return {};
  int p(double q) => sorted[((sorted.length - 1) * q).round()];
  return {'p50': p(.5), 'p95': p(.95), 'max': sorted.last};
}

String document(int paragraphs) => List.generate(
  paragraphs,
  (i) =>
      '## Result $i\n\n**重点是印度：**苹果页面与 *English* 文本。'
      ' A response with `inline_code` and [source](https://example.com/file).\n\n'
      '- list entry $i\n- [x] completed task\n\n'
      '| Name | Value |\n| --- | ---: |\n| field | $i |\n\n'
      '```rust\nfn item_$i(value: usize) -> usize {\n    value + 1 // 中文 comment\n}\n```\n',
).join('\n');

Widget app(String source) => MaterialApp(
  theme: lightTheme(),
  locale: const Locale('en'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(
    body: SingleChildScrollView(child: MarkdownView(data: source)),
  ),
);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets('render cost profile', (tester) async {
    if (!const bool.fromEnvironment('POCOX_RENDER_PERF')) {
      markTestSkipped('set POCOX_RENDER_PERF=true');
      return;
    }
    await RustLib.init();
    await windowManager.ensureInitialized();
    await windowManager.setSize(const Size(1200, 900));
    await windowManager.setPosition(const Offset(80, 80));
    await windowManager.setAlwaysOnTop(true);
    await windowManager.show();
    await windowManager.focus();
    await windowManager.show();
    await tester.pumpWidget(app('warm up'));
    await tester.pump(const Duration(seconds: 2));
    final previewTimes = <int>[];
    const preview =
        '**完成：**修复 `src/main.rs` 与 [测试](https://example.com/test)，保持状态。';
    for (var i = 0; i < 110; i++) {
      final watch = Stopwatch()..start();
      final text = markdownPlainPreview('$preview $i');
      if (i >= 10) previewTimes.add(watch.elapsedMicroseconds);
      expect(text, contains('src/main.rs'));
    }
    debugPrint(
      'RENDER_PERF ${jsonEncode({'stage': 'inline_preview', 'chars': preview.length, 'us': stats(previewTimes)})}',
    );
    for (final (language, line) in [
      ('rust', 'fn compute(value: usize) -> usize { value + 1 } // 中文\n'),
      (
        'typescript',
        'export function compute(value: number): number { return value + 1; }\n',
      ),
      ('dart', 'String hello(int n) => "value: \$n"; // 中文\n'),
    ]) {
      for (final count in [20, 240]) {
        final code = line * count;
        final cold = <int>[],
            warm = <int>[],
            nativeCold = <int>[],
            tokensWarm = <int>[];
        for (var i = 0; i < 60; i++) {
          final source = '$code// sample $i';
          final watch = Stopwatch()..start();
          final span = legacy.highlightCode(
            code: source,
            language: language,
            base: const TextStyle(fontSize: 12.5),
            brightness: Brightness.light,
          );
          if (i >= 10) cold.add(watch.elapsedMicroseconds);
          watch.reset();
          legacy.highlightCode(
            code: source,
            language: language,
            base: const TextStyle(fontSize: 12.5),
            brightness: Brightness.light,
          );
          if (i >= 10) warm.add(watch.elapsedMicroseconds);
          expect(span.toPlainText(), source);
          watch.reset();
          final lease = SyntaxHighlighter.shared.request(source, language);
          final tokens = await lease.result;
          final nativeSpan = highlightCode(
            code: source,
            language: language,
            base: const TextStyle(fontSize: 12.5),
            brightness: Brightness.light,
            runs: tokens,
          );
          if (i >= 10) nativeCold.add(watch.elapsedMicroseconds);
          lease.release();
          expect(tokens, isNotEmpty);
          expect(nativeSpan.toPlainText(), source);
          watch.reset();
          final cached = SyntaxHighlighter.shared.request(source, language);
          await cached.result;
          if (i >= 10) tokensWarm.add(watch.elapsedMicroseconds);
          cached.release();
        }
        debugPrint(
          'RENDER_PERF ${jsonEncode({'stage': 'highlight', 'language': language, 'chars': code.length, 'cold_us': stats(cold), 'warm_us': stats(warm), 'native_roundtrip_span_us': stats(nativeCold), 'native_cached_tokens_us': stats(tokensWarm)})}',
        );
      }
    }
    for (final paragraphs in [6, 30]) {
      final timings = <FrameTiming>[], updates = <int>[];
      void record(List<FrameTiming> batch) => timings.addAll(batch);
      final source = document(paragraphs);
      for (var i = 0; i < 65; i++) {
        if (i == 5) SchedulerBinding.instance.addTimingsCallback(record);
        final watch = Stopwatch()..start();
        // Same stateful row, changed streamed suffix and an incomplete fence.
        await tester.pumpWidget(app('$source\n```rust\n${'let n = 1;\n' * i}'));
        if (i >= 5) updates.add(watch.elapsedMicroseconds);
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pump(const Duration(milliseconds: 400));
      SchedulerBinding.instance.removeTimingsCallback(record);
      debugPrint(
        'RENDER_PERF ${jsonEncode({
          'stage': 'streaming_widget',
          'build_work_per_update_us': timings.fold<int>(0, (sum, t) => sum + t.buildDuration.inMicroseconds) ~/ 60,
          'chars': source.length,
          'frames': timings.length,
          'update_us': stats(updates),
          'build_us': stats([for (final t in timings) t.buildDuration.inMicroseconds]),
          'raster_us': stats([for (final t in timings) t.rasterDuration.inMicroseconds]),
          'rss_bytes': ProcessInfo.currentRss,
          'ratio': tester.view.devicePixelRatio,
        })}',
      );
      expect(
        timings.any((t) => t.rasterDuration.inMicroseconds > 100),
        isTrue,
        reason: 'profile window must actually rasterize',
      );
      expect(tester.takeException(), isNull);
    }
  });
}
