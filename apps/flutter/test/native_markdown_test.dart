import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:pocox/src/native_markdown.dart';
import 'package:pocox/src/widgets/markdown_view.dart';

void main() {
  testWidgets('streaming coalesces work and rejects stale or disposed parses', (
    tester,
  ) async {
    final original = MarkdownParsing.parse;
    addTearDown(() => MarkdownParsing.parse = original);
    final calls = <String>[], results = <Completer<List<md.Node>>>[];
    MarkdownParsing.parse = (source) {
      calls.add(source);
      final result = Completer<List<md.Node>>();
      results.add(result);
      return result.future;
    };
    Widget app(String data) => MaterialApp(home: MarkdownView(data: data));
    await tester.pumpWidget(app('first'));
    expect(find.text('first', findRichText: true), findsOneWidget);
    await tester.pumpWidget(app('second'));
    await tester.pumpWidget(app('latest'));
    expect(calls, ['first']);
    results.first.complete([
      md.Element('p', [md.Text('obsolete output')]),
    ]);
    await tester.pumpAndSettle();
    expect(calls, ['first', 'latest']);
    expect(find.text('obsolete output', findRichText: true), findsNothing);
    results.last.complete([
      md.Element('p', [md.Text('parsed latest')]),
    ]);
    await tester.pumpAndSettle();
    expect(find.text('parsed latest', findRichText: true), findsOneWidget);
    await tester.pumpWidget(app('next'));
    await tester.pumpWidget(const SizedBox());
    results.last.completeError(StateError('native worker unavailable'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('parser failure keeps the complete source visible', (
    tester,
  ) async {
    final original = MarkdownParsing.parse;
    addTearDown(() => MarkdownParsing.parse = original);
    MarkdownParsing.parse = (_) => Future.error(StateError('too large'));
    await tester.pumpWidget(
      const MaterialApp(home: MarkdownView(data: '**readable source**')),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('**readable source**', findRichText: true),
      findsOneWidget,
    );
  });
}
