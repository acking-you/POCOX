/// Native syntax tokens with Flutter-owned colors, fonts and selection.
library;

import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'syntax_highlighter.dart';
export 'syntax_highlighter.dart' show SyntaxHighlighter, HighlightLease;

const Map<String, String> _aliases = {
  'sh': 'bash',
  'zsh': 'bash',
  'shell-session': 'shell',
  'console': 'shell',
  'ps1': 'powershell',
  'pwsh': 'powershell',
  'py': 'python',
  'py3': 'python',
  'js': 'javascript',
  'jsx': 'javascript',
  'mjs': 'javascript',
  'cjs': 'javascript',
  'ts': 'typescript',
  'tsx': 'typescript',
  'rs': 'rust',
  'yml': 'yaml',
  'html': 'xml',
  'svg': 'xml',
  'md': 'markdown',
  'c++': 'cpp',
  'cc': 'cpp',
  'h': 'cpp',
  'hpp': 'cpp',
  'cs': 'csharp',
  'rb': 'ruby',
  'kt': 'kotlin',
  'golang': 'go',
  'patch': 'diff',
  'make': 'makefile',
  'dockerfile': 'dockerfile',
  'docker': 'dockerfile',
  'toml': 'ini',
  'conf': 'ini',
  'cfg': 'ini',
};

const _languages = {
  'bash',
  'c',
  'cmake',
  'cpp',
  'csharp',
  'css',
  'dart',
  'diff',
  'dockerfile',
  'go',
  'ini',
  'java',
  'javascript',
  'json',
  'kotlin',
  'lua',
  'makefile',
  'markdown',
  'php',
  'powershell',
  'python',
  'ruby',
  'rust',
  'scala',
  'shell',
  'sql',
  'swift',
  'typescript',
  'xml',
  'yaml',
};

/// The explicit grammar selected by a fence. Unknown sources stay plain.
String? resolveLanguage(String info) {
  final head = info.trim().split(RegExp(r'[\s,:]')).first.toLowerCase();
  final name = _aliases[head] ?? head;
  return _languages.contains(name) ? name : null;
}

List<Color> _palette(Brightness brightness) => brightness == Brightness.dark
    ? const [
        Color(0x00000000),
        Color(0xFFF07A8A),
        Color(0xFFD9A054),
        Color(0xFF8EB0F0),
        Color(0xFF5BC4AF),
        Color(0xFFD9A054),
        Color(0xFF8A8177),
        Color(0xFF8FA3CE),
        Color(0xFF938D82),
      ]
    : const [
        Color(0x00000000),
        Color(0xFFAD3445),
        Color(0xFF96540A),
        Color(0xFF2B5CB8),
        Color(0xFF0E7264),
        Color(0xFF96540A),
        Color(0xFF8C8579),
        Color(0xFF5F6E8C),
        Color(0xFF6F6A60),
      ];

/// Apply native semantic runs without parsing source on the UI isolate.
/// Until tokens arrive, the exact source remains selectable and copyable.
TextSpan highlightCode({
  required String code,
  required String language,
  required TextStyle base,
  required Brightness brightness,
  bool allowItalic = true,
  Uint32List? runs,
}) {
  final lang = resolveLanguage(language);
  runs ??= lang == null ? null : SyntaxHighlighter.shared.peek(code, lang);
  if (runs == null ||
      runs.isEmpty ||
      runs.length.isOdd ||
      runs[runs.length - 2] != code.length) {
    return TextSpan(text: code, style: base);
  }
  final colors = _palette(brightness);
  final children = <TextSpan>[];
  var start = 0;
  for (var i = 0; i < runs.length; i += 2) {
    final end = runs[i], role = runs[i + 1], color = role & 255;
    if (end <= start || end > code.length || color >= colors.length) {
      return TextSpan(text: code, style: base);
    }
    children.add(
      TextSpan(
        text: code.substring(start, end),
        style: TextStyle(
          color: color == 0 ? null : colors[color],
          fontWeight: role & 256 == 0 ? null : FontWeight.w600,
          fontStyle: allowItalic && role & 512 != 0
              ? FontStyle.italic
              : FontStyle.normal,
        ),
      ),
    );
    start = end;
  }
  return TextSpan(style: base, children: children);
}

/// Shared code renderer for fences, file previews and both diff surfaces.
class HighlightedCode extends StatefulWidget {
  const HighlightedCode({
    super.key,
    required this.code,
    required this.language,
    required this.base,
    required this.brightness,
    this.allowItalic = true,
  });
  final String code;
  final String language;
  final TextStyle base;
  final Brightness brightness;
  final bool allowItalic;
  @override
  State<HighlightedCode> createState() => _HighlightedCodeState();
}

class _HighlightedCodeState extends State<HighlightedCode> {
  HighlightLease? _lease;
  Uint32List? _runs;
  TextSpan? _span;
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(HighlightedCode old) {
    super.didUpdateWidget(old);
    if (old.base != widget.base ||
        old.brightness != widget.brightness ||
        old.allowItalic != widget.allowItalic) {
      _span = null;
    }
    if (old.code != widget.code || old.language != widget.language) _load();
  }

  void _load() {
    _lease?.release();
    _span = null;
    final language = resolveLanguage(widget.language);
    _runs = language == null
        ? null
        : SyntaxHighlighter.shared.peek(widget.code, language);
    if (language == null || _runs != null) {
      _lease = null;
      return;
    }
    final lease = _lease = SyntaxHighlighter.shared.request(
      widget.code,
      language,
    );
    lease.result.then((runs) {
      if (mounted && identical(_lease, lease) && runs.isNotEmpty) {
        setState(() {
          _runs = runs;
          _span = null;
        });
      }
    });
  }

  @override
  void dispose() {
    _lease?.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Text.rich(
    _span ??= highlightCode(
      code: widget.code,
      language: widget.language,
      base: widget.base,
      brightness: widget.brightness,
      allowItalic: widget.allowItalic,
      runs: _runs,
    ),
  );
}
