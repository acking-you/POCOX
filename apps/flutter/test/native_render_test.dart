import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;
import 'package:markdown/markdown.dart' as md;
import 'package:pocox/src/markdown_cjk.dart';
import 'package:pocox/src/native_markdown.dart';
import 'package:pocox/src/code_highlight.dart';
import 'package:pocox/src/rust/frb_generated.dart';
import 'package:pocox/src/widgets/links.dart';

List<Object> semantic(List<md.Node> nodes) {
  final result = <Object>[];
  for (final node in nodes) {
    if (node is md.Text) {
      if (result.isNotEmpty && result.last is String) {
        result[result.length - 1] = '${result.last}${node.text}';
      } else {
        result.add(node.text);
      }
    } else if (node is md.Element) {
      final attributes = <String, String>{};
      for (final key in [
        'href',
        'src',
        'title',
        'align',
        'start',
        'type',
        'checked',
        'class',
      ]) {
        final value = node.attributes[key];
        if (value == null ||
            value.isEmpty ||
            (key == 'start' && value == '1')) {
          continue;
        }
        if (key == 'class' && !value.startsWith('language-')) continue;
        attributes[key] = value;
      }
      result.add([node.tag, attributes, semantic(node.children ?? [])]);
    }
  }
  return result;
}

void main() {
  final library = Platform.environment['POCOX_NATIVE_TEST_LIB'];
  group(
    'native text rendering',
    () {
      setUpAll(() async {
        await RustLib.init(externalLibrary: ExternalLibrary.open(library!));
      });
      test(
        'GFM, CJK, links and incomplete streams retain rendering semantics',
        () async {
          final differences = <Object>[];
          for (final source in [
            '**重点是印度：**苹果页面。 注意**「重点」**这里。',
            '**参见 [文档](https://x.dev)：**详见上文。 **行内 `code`：**说明。',
            '文字***强调***文字。 \\*\\*不加粗：\\*\\*文字。',
            '# Heading\n\nfirst\nsecond  \nthird\n\n---\n\n> quote',
            '- [x] done\n- [ ] pending\n- normal\n  - nested',
            '3. first\n\n4. second\n\n   paragraph',
            '- [x] first\n\n  next paragraph\n\n- [ ] second',
            '| a | b |\n| :--- | ---: |\n| x | ~~y~~ |',
            '![中文 image](https://x.dev/a.png "title") [file](../a.rs:12)',
            '仓库https://example.com/path [ref][id]\n\n[id]: https://example.com "title"',
            '```dart title="x"\nString x = "😀";\n',
            '    indented **code**\n\n`**重点：**中文`',
            '<script>alert(1)</script>\n\ntext <b>literal</b>',
          ]) {
            final expected =
                md.Document(
                  extensionSet: markdownExtensionSet,
                  encodeHtml: false,
                ).parseLines(
                  const LineSplitter().convert(autolinkifyMarkdown(source)),
                );
            final actual = await parseNativeMarkdown(source);
            if (jsonEncode(semantic(actual)) !=
                jsonEncode(semantic(expected))) {
              differences.add({
                'source': source,
                'actual': semantic(actual),
                'expected': semantic(expected),
              });
            }
          }
          expect(differences, isEmpty);
        },
      );
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
