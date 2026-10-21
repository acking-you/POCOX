import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocox/src/code_highlight.dart';
import 'package:pocox/src/syntax_highlighter.dart';

void main() {
  const base = TextStyle(fontFamily: 'monospace', fontSize: 12.5);
  tearDown(() => SyntaxHighlighter.shared = SyntaxHighlighter());

  test('fences keep explicit aliases, extras and plain fallback', () {
    for (final (input, expected) in [
      ('sh', 'bash'),
      ('ts', 'typescript'),
      ('toml', 'ini'),
      ('patch', 'diff'),
      (' Rust title="x"', 'rust'),
    ]) {
      expect(resolveLanguage(input), expected);
    }
    for (final input in ['', 'text', 'plaintext', 'brainfuck']) {
      expect(resolveLanguage(input), isNull);
    }
  });

  test('semantic runs preserve UTF-16 text, themes and upright rendering', () {
    const source = 'fn 😀中文';
    final runs = Uint32List.fromList([2, 1, source.length, 6 | 512]);
    TextSpan render(Brightness brightness) => highlightCode(
      code: source,
      language: 'rust',
      base: base,
      brightness: brightness,
      runs: runs,
      allowItalic: false,
    );
    final light = render(Brightness.light), dark = render(Brightness.dark);
    expect(light.toPlainText(), source);
    expect(dark.toPlainText(), source);
    expect(
      (light.children!.first as TextSpan).style!.color,
      isNot((dark.children!.first as TextSpan).style!.color),
    );
    expect(
      (light.children!.last as TextSpan).style!.fontStyle,
      FontStyle.normal,
    );
    expect(
      highlightCode(
        code: source,
        language: 'rust',
        base: base,
        brightness: Brightness.light,
        runs: Uint32List.fromList([999, 1]),
      ).text,
      source,
    );
  });

  test('batches deduplicate, release obsolete work and reuse tokens', () async {
    final calls = <List<HighlightSource>>[];
    final service = SyntaxHighlighter(
      loader: (inputs) async {
        calls.add(inputs);
        return [
          for (final input in inputs)
            Uint32List.fromList([input.code.length, 1]),
        ];
      },
    );
    final a = service.request('fn a', 'rust'),
        duplicate = service.request('fn a', 'rust');
    final removed = service.request('old prefix', 'rust')..release();
    final b = service.request('fn b', 'rust');
    await Future.wait([a.result, duplicate.result, b.result, removed.result]);
    expect(calls.single.map((i) => i.code), ['fn a', 'fn b']);
    expect(identical(await a.result, await duplicate.result), isTrue);
    final cached = service.request('fn a', 'rust');
    expect(identical(await a.result, await cached.result), isTrue);
    expect(calls, hasLength(1));
    for (final lease in [a, duplicate, b, cached]) {
      lease.release();
    }
  });

  test('admission is bounded and worker failures remain readable', () async {
    final done = Completer<List<Uint32List>>();
    var calls = 0;
    final service = SyntaxHighlighter(
      loader: (inputs) {
        calls++;
        return done.future;
      },
    );
    final leases = [
      for (var i = 0; i < 200; i++) service.request('${'x' * 19990}$i', 'rust'),
    ];
    await Future<void>.delayed(Duration.zero);
    expect(calls, 2);
    expect(await leases.last.result, isEmpty);
    for (final lease in leases) {
      lease.release();
    }
    done.completeError(StateError('unavailable'));
    expect(await leases.first.result, isEmpty);
    expect(service.peek('${'x' * 19990}0', 'rust'), isNull);
  });

  testWidgets(
    'late syntax cannot decorate new text and theme changes do not parse',
    (tester) async {
      final responses = <Completer<List<Uint32List>>>[];
      SyntaxHighlighter.shared = SyntaxHighlighter(
        loader: (_) {
          final response = Completer<List<Uint32List>>();
          responses.add(response);
          return response.future;
        },
      );
      Widget app(String code, Brightness brightness) => MaterialApp(
        home: HighlightedCode(
          code: code,
          language: 'rust',
          base: base,
          brightness: brightness,
        ),
      );
      await tester.pumpWidget(app('old', Brightness.light));
      await tester.pumpWidget(app('new 😀', Brightness.light));
      responses.first.complete([
        Uint32List.fromList([3, 1]),
      ]);
      await tester.pump();
      expect(find.text('new 😀', findRichText: true), findsOneWidget);
      responses.last.complete([
        Uint32List.fromList([3, 1, 6, 0]),
      ]);
      await tester.pump();
      await tester.pumpWidget(app('new 😀', Brightness.dark));
      expect(responses, hasLength(2));
      expect(find.text('new 😀', findRichText: true), findsOneWidget);
    },
  );
}
