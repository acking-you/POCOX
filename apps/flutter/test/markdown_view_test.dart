import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/widgets/markdown_view.dart';
import 'package:pocox/src/app_icons.dart';

/// Everything [MarkdownView] actually painted, concatenated. `includePlaceholders`
/// keeps `WidgetSpan`s (the favicons) out of the string.
String renderedText(WidgetTester tester) => tester
    .widgetList<RichText>(find.byType(RichText))
    .map((w) => w.text.toPlainText(includePlaceholders: false))
    .join('\n');

Future<void> pumpMarkdown(WidgetTester tester, String data) async {
  await tester.pumpWidget(
    MaterialApp(
      // Code blocks reach for AppLocalizations (the copy button's tooltip), so
      // the harness has to supply the delegates a real app would.
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: SelectionArea(
          child: SingleChildScrollView(child: MarkdownView(data: data)),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// The painted span whose text contains [needle].
InlineSpan spanContaining(WidgetTester tester, String needle) => tester
    .widgetList<RichText>(find.byType(RichText))
    .map((w) => w.text)
    .firstWhere((s) => s.toPlainText().contains(needle));

/// Every colour [span] and its children paint text in.
Set<Color> spanColours(InlineSpan span) {
  final colours = <Color>{};
  span.visitChildren((child) {
    if (child.style?.color case final colour?) colours.add(colour);
    return true;
  });
  return colours;
}

void main() {
  testWidgets('bolds CJK text that CommonMark leaves literal', (tester) async {
    await pumpMarkdown(tester, '**重点是印度：**苹果页面同时列出 ₹700。');

    final text = renderedText(tester);
    expect(text, contains('重点是印度：苹果页面'));
    expect(text, isNot(contains('*')));
  });

  testWidgets('a wide table scrolls horizontally instead of clipping', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await pumpMarkdown(
      tester,
      '| 地区 | App Store 标价 | 约合人民币 | 结论 |\n'
      '| --- | --- | --- | --- |\n'
      '| 印度 | ₹700 或 ₹2,900 | 约 ¥49 / ¥204 | ₹700 可能只对旧订阅开放 |\n',
    );

    final scrollables = tester
        .widgetList<SingleChildScrollView>(find.byType(SingleChildScrollView))
        .where((s) => s.scrollDirection == Axis.horizontal);
    expect(scrollables, isNotEmpty);
    // The last column survived the narrow viewport.
    expect(renderedText(tester), contains('结论'));
    // The table scrolls *inside* the message; it must not widen it, or every
    // paragraph in the transcript would wrap past the right edge of the window.
    expect(tester.getSize(find.byType(MarkdownView)).width, 360);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a web link gets a favicon slot, a non-web one none', (
    tester,
  ) async {
    await pumpMarkdown(
      tester,
      '价格见 [苹果官网](https://www.apple.com/cn/) 与 [第二节](#section-2) 页面。',
    );

    // The network favicon can't load in a test binding, so the generic globe
    // stands in — that is the same fallback a blocked or 404ing host gets.
    // The in-page anchor has no site to represent.
    expect(find.byIcon(AppIcons.public), findsOneWidget);
    final text = renderedText(tester);
    expect(text, contains('苹果官网'));
    expect(text, contains('第二节'));
    expect(text, isNot(contains('https://')));
  });

  testWidgets('keeps formatting inside a link label', (tester) async {
    await pumpMarkdown(tester, '见 [**苹果**官网](https://www.apple.com/cn/)。');

    final span = spanContaining(tester, '苹果');
    final weights = <FontWeight?>[];
    span.visitChildren((child) {
      if (child is TextSpan && child.text == '苹果') {
        weights.add(child.style?.fontWeight);
      }
      return true;
    });
    expect(weights, [FontWeight.w600]);
  });

  testWidgets('a link alone in a list item shows its label once', (
    tester,
  ) async {
    // The parser splits this label in two before the Latin word; the link
    // builder once kept the second half beside its own copy.
    await pumpMarkdown(
      tester,
      '- [通过 POCOX 在其他设备打开](pocox://open?service=pcx:a:port:8080&path=/)\n'
      '- [**苹果**官网](https://www.apple.com/cn/)',
    );

    final text = renderedText(tester);
    expect(text, contains('通过 POCOX 在其他设备打开'));
    expect('POCOX'.allMatches(text), hasLength(1));
    expect('官网'.allMatches(text), hasLength(1));
  });

  testWidgets('a fenced block is syntax-highlighted, with its text intact', (
    tester,
  ) async {
    await pumpMarkdown(
      tester,
      '```rust\nfn main() {\n    let x = 1; // note\n}\n```',
    );

    // Find the block's own RichText (the header carries the language name).
    final span = spanContaining(tester, 'fn main()');
    // More than one colour is the whole point; one would mean the highlighter
    // never ran and the fallback plain span was rendered.
    expect(spanColours(span).length, greaterThan(1));
    // And highlighting must not rewrite what the agent wrote.
    expect(span.toPlainText(), contains('fn main() {\n    let x = 1; // note'));
  });

  testWidgets('an unfenced block stays plain rather than guessing', (
    tester,
  ) async {
    await pumpMarkdown(tester, '```\nsome free-form output\n```');

    final span = spanContaining(tester, 'free-form');
    expect(span.toPlainText(), contains('some free-form output'));
    // No info string → no grammar → one uniform colour, not a mis-guess.
    expect(spanColours(span).length, lessThanOrEqualTo(1));
  });
}
