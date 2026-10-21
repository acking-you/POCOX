/// Display-side handling of codex's IDE-context prompt wrapper.
///
/// A client with editor context (the IDE extension, the ChatGPT desktop app,
/// codex's own TUI) does not send the user's text alone: it serializes the
/// context — active file, selection, mentioned files — ahead of the request and
/// separates the two with a marker. Upstream states the contract at
/// `deps/codex/codex-rs/tui/src/ide_context/prompt.rs:12`:
///
/// > Match the desktop app and IDE extension delimiter exactly. IDE context is
/// > serialized into the raw prompt before this marker, then transcript
/// > rendering strips back to the request after the last marker.
///
/// So every surface that renders a transcript is expected to strip. Without it
/// a message that was typed as "为什么仍然黑屏" displays as a wall of wire text.
///
/// [kUserMessageBegin] is the protocol constant (`USER_MESSAGE_BEGIN`,
/// `deps/codex/codex-rs/protocol/src/protocol.rs:120`). The ChatGPT desktop
/// app writes its own shorter heading, [kDesktopRequestBegin], after the
/// context blocks it serializes (`# Files mentioned by the user:`,
/// `# Response annotations:`, an `<in-app-browser-context>` block). The shape
/// of the context ahead of either marker varies by client — the vendored
/// codex renders `## Active file:` — so [splitIdeContext] reads mentions and
/// annotations out of that prefix on a best-effort basis. A prefix it cannot
/// parse costs thumbnails, never the message text.
library;

import 'dart:convert';

/// The marker separating serialized IDE context from the user's own request.
/// Wire format: changing it orphans every transcript written by another client.
const String kUserMessageBegin = '## My request for Codex:';

/// The request heading the ChatGPT desktop app writes after its context
/// blocks. Only honoured after one of them ([_contextHeads]), so a message
/// that merely contains the heading keeps it.
const String kDesktopRequestBegin = '## My request:';

// Section headers the known context renderers open with. They gate
// [kDesktopRequestBegin] and recognise a preview the SERVER truncated before
// the marker; an unknown header degrades to the raw text rather than guessing.
const _contextHeads = [
  '# Files mentioned by the user:',
  '# Context from my IDE setup:',
  '# Response annotations:',
  '<in-app-browser-context',
];

final _desktopMarker = RegExp(
  '^${RegExp.escape(kDesktopRequestBegin)}[ \\t]*\$',
  multiLine: true,
);

/// A file the sending client named in its IDE context.
class IdeMentionedFile {
  /// Creates a mention of [path], labelled [name].
  const IdeMentionedFile({
    required this.name,
    required this.path,
    this.attachedImage = false,
  });

  /// Display label the client used (usually the basename).
  final String name;

  /// The path as written — absolute on the sending machine, or workspace
  /// relative. Not resolved here; the widget layer decides what it can read.
  final String path;

  /// The client marked it `Image attachment: true`: the same picture also
  /// rides the message as an image.
  final bool attachedImage;
}

/// A passage of an earlier reply the user selected, with their comment on
/// it (the desktop app's response annotations).
class IdeAnnotation {
  /// Creates an annotation of [quote].
  const IdeAnnotation({required this.quote, this.comment});

  /// The selected text.
  final String quote;

  /// What the user wrote about it, if anything.
  final String? comment;
}

/// What [splitIdeContext] reads out of a message.
typedef IdeSplit = ({
  String text,
  List<IdeMentionedFile> files,
  List<IdeAnnotation> annotations,
});

/// A message without any IDE context: [text] as it is.
IdeSplit plainIdeSplit(String text) =>
    (text: text, files: const [], annotations: const []);

// `## <label>: <path>` — the shape both known context renderers use for a
// file line. The label may contain spaces; the path runs to end of line.
final _mentionLine = RegExp(r'^##[ \t]+(.+?):[ \t]+(\S.*)$', multiLine: true);

// A mention worth showing: an absolute path (POSIX or Windows), or one that at
// least carries a directory separator. Prose like `## Active selection range:`
// has no value after the colon and never reaches here; a bare word would.
final _looksLikePath = RegExp(r'^(/|[A-Za-z]:[/\\]|\\\\)|[/\\]');

/// Split a raw user message into what the user actually typed and the files
/// and reply passages the sending client mentioned around it.
///
/// Mirrors upstream's `extract_prompt_request_with_offset`: the request is
/// everything after the LAST marker ([kUserMessageBegin], or the desktop
/// app's [kDesktopRequestBegin] on a line of its own after its context). A
/// message without one is returned unchanged with no mentions — the common
/// case, since our own composer never writes one.
IdeSplit splitIdeContext(String raw) {
  var at = raw.lastIndexOf(kUserMessageBegin);
  var marker = kUserMessageBegin.length;
  final desktop = _desktopRequestAt(raw);
  if (desktop != null && desktop > at) {
    at = desktop;
    marker = kDesktopRequestBegin.length;
  }
  if (at < 0) return plainIdeSplit(raw);
  final text = raw.substring(at + marker).trim();
  final prefix = raw.substring(0, at);
  final files = <IdeMentionedFile>[];
  for (final m in _mentionLine.allMatches(prefix)) {
    final path = m[2]!.trim();
    if (!_looksLikePath.hasMatch(path)) continue;
    final rest = prefix.substring(m.end).trimLeft();
    files.add(
      IdeMentionedFile(
        name: m[1]!.trim(),
        path: path,
        attachedImage: rest.startsWith('Image attachment: true'),
      ),
    );
  }
  return (text: text, files: files, annotations: _annotations(prefix));
}

int? _desktopRequestAt(String raw) {
  final head = raw.trimLeft();
  if (!_contextHeads.any(head.startsWith)) return null;
  final matches = _desktopMarker.allMatches(raw);
  return matches.isEmpty ? null : matches.last.start;
}

final _annotationBlock = RegExp(
  r'<response-annotations>([\s\S]*?)</response-annotations>',
);

/// The `[{"text", "annotation"}]` list inside `<response-annotations>`;
/// empty when there is none or it does not parse.
List<IdeAnnotation> _annotations(String prefix) {
  final block = _annotationBlock.firstMatch(prefix);
  if (block == null) return const [];
  try {
    final list = jsonDecode(block[1]!.trim());
    if (list is! List) return const [];
    return [
      for (final e in list)
        if (e is Map && e['text'] is String && (e['text'] as String).isNotEmpty)
          IdeAnnotation(
            quote: e['text'] as String,
            comment: switch (e['annotation']) {
              final String c when c.trim().isNotEmpty => c.trim(),
              _ => null,
            },
          ),
    ];
  } on FormatException {
    return const [];
  }
}

/// [request] as Markdown to display after its [annotations]: each annotated
/// passage as a quote (long ones cut short) with the comment under it.
String ideDisplayText(String request, List<IdeAnnotation> annotations) {
  if (annotations.isEmpty) return request;
  final out = StringBuffer();
  for (final a in annotations) {
    final quote = a.quote.trim();
    final cut = quote.length > 280
        ? '${quote.substring(0, 280).trimRight()}…'
        : quote;
    for (final line in cut.split('\n')) {
      out.writeln('> $line');
    }
    out.writeln();
    if (a.comment != null) {
      out
        ..writeln(a.comment)
        ..writeln();
    }
  }
  out.write(request);
  return out.toString().trim();
}

/// Whether [preview] is the start of an IDE-context block with no request in
/// it yet — i.e. a server-truncated preview whose visible part is all wire.
bool isTruncatedIdeContext(String preview) {
  final t = preview.trimLeft();
  if (t.contains(kUserMessageBegin) || _desktopRequestAt(t) != null) {
    return false;
  }
  return _contextHeads.any(t.startsWith);
}

// Marker pairs codex wraps an injected contextual user fragment in — a message
// that carries the user role but that codex wrote. Mirrors the wire constants
// in `codex-rs/protocol/src/protocol.rs` and the fragments declaring their own
// `type_markers()` under `codex-rs/core/src/context/`. The same list lives in
// `crates/pocox-codex/src/rollout.rs`, which filters rollouts we read
// ourselves; this copy covers previews that come from codex's app-server.
//
// Most fragments are `<tag>…</tag>`; the project's AGENTS.md is marked by prose
// instead (`UserInstructions::type_markers`), so it needs an explicit pair.
const _fragmentPairs = [('# AGENTS.md instructions', '</INSTRUCTIONS>')];

const _fragmentTags = [
  'user_instructions',
  'environment_context',
  'apps_instructions',
  'skills_instructions',
  'plugins_instructions',
  'collaboration_mode',
  'multi_agent_mode',
  'realtime_conversation',
  'context_window',
  'context_window_guidance',
  'recommended_plugins',
  'model_switch',
  'personality_spec',
  'subagent_notification',
  'turn_aborted',
  'user_shell_command',
];

/// Whether [text] is entirely one injected context fragment, and so is
/// machinery rather than anything the user said.
///
/// Mirrors upstream `matches_marked_text`
/// (`codex-rs/context-fragments/src/fragment.rs:116`): the trimmed text must
/// both open and close with the pair, case-insensitively. Text that merely
/// *contains* a marker is left alone — someone asking about `<turn_aborted>`
/// is still writing their own message.
/// A preview the server cut short counts too: it opened a fragment and the
/// close marker fell off the end, which still leaves nothing but wire.
bool isContextFragment(String text) {
  final trimmed = text.trim().toLowerCase();
  bool bounded(String open, String close) {
    if (!trimmed.startsWith(open)) return false;
    return trimmed.endsWith(close)
        ? trimmed.length >= open.length + close.length
        : !trimmed.contains(close);
  }

  return _fragmentTags.any((tag) => bounded('<$tag>', '</$tag>')) ||
      _fragmentPairs.any(
        (p) => bounded(p.$1.toLowerCase(), p.$2.toLowerCase()),
      );
}

/// Extensions the image pipeline can decode, for deciding whether a mention
/// renders as a thumbnail or as a filename chip.
const _imageExtensions = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'};

/// Whether [path] names a file we could show as a picture.
bool looksLikeImagePath(String path) {
  final dot = path.lastIndexOf('.');
  if (dot < 0 || dot == path.length - 1) return false;
  return _imageExtensions.contains(path.substring(dot + 1).toLowerCase());
}
