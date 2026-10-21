import 'dart:async';
import 'dart:convert';
import 'package:markdown/markdown.dart' as md;
import 'package:pocox/src/markdown_cjk.dart';
import 'package:pocox/src/native_markdown.dart';
import 'package:pocox/src/widgets/links.dart';

/// Widget tests exercise layout without loading a host library. The opt-in
/// native/profile tests separately verify the actual parser and FRB contract.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  MarkdownParsing.parse = (source) => md.Document(
    extensionSet: markdownExtensionSet,
    encodeHtml: false,
  ).parseLines(const LineSplitter().convert(autolinkifyMarkdown(source)));
  await testMain();
}
