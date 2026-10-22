import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;
import 'package:pocox/src/code_highlight.dart';
import 'package:pocox/src/rust/frb_generated.dart';

void main() {
  final library = Platform.environment['POCOX_NATIVE_TEST_LIB'];
  group(
    'native text rendering',
    () {
      setUpAll(() async {
        await RustLib.init(externalLibrary: ExternalLibrary.open(library!));
      });
      test(
        'highlight tokens cross FRB and preserve Unicode in the painted spans',
        () async {
          const source = 'fn main() { let text = "中文 😀"; } // comment\n';
          final service = SyntaxHighlighter();
          final lease = service.request(source, 'rust');
          final tokens = await lease.result;
          expect(tokens, isNotEmpty);
          final span = highlightCode(
            code: source,
            language: 'rust',
            base: const TextStyle(),
            brightness: Brightness.light,
            runs: tokens,
          );
          expect(span.toPlainText(), source);
          expect(
            span.children!
                .whereType<TextSpan>()
                .map((s) => s.style?.color)
                .toSet()
                .length,
            greaterThan(2),
          );
          lease.release();
        },
      );
    },
    skip: library == null
        ? 'set POCOX_NATIVE_TEST_LIB to the freshly built bridge'
        : false,
  );
}
