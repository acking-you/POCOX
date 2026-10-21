import 'package:pocket_codex/src/network/network_image.dart';
import 'dart:convert';

import 'package:pocket_codex/src/file_links.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

import 'package:pocket_codex/src/desktop_theme.dart';
import 'package:pocket_codex/src/fonts.dart';
import 'package:pocket_codex/src/lru_cache.dart';
import 'package:pocket_codex/src/markdown_cjk.dart';
import 'package:pocket_codex/src/theme.dart';
import 'package:pocket_codex/src/widgets/code_block.dart';
import 'package:pocket_codex/src/widgets/links.dart';
import 'package:pocket_codex/src/app_icons.dart';

/// One Markdown renderer for every agent-authored surface (replies, plan
/// proposals, plan explanations), so they share the CJK fixes, the table
/// treatment and the link presentation.
///
/// Selection is deliberately not enabled here: both transcripts wrap their
/// list in a `SelectionArea`, and a nested `SelectableText` opts itself *out*
/// of that unified selection instead of joining it.
class MarkdownView extends StatefulWidget {
  /// Renders [data] as Markdown.
  const MarkdownView({
    super.key,
    required this.data,
    this.muted = false,
    this.dense = false,
    this.keepLineBreaks = false,
  });

  /// Raw Markdown source, as written by the model.
  final String data;

  /// Keep every single line break as written, instead of CommonMark's
  /// joining of a paragraph's lines. For text a person typed (their own
  /// messages, a draft's preview), where a line break is meant.
  final bool keepLineBreaks;

  /// Secondary text colour, for prose that sits behind the main reply —
  /// reasoning summaries, an activity card's detail.
  final bool muted;

  /// Tighter spacing for Markdown inside a message bubble: no trailing
  /// paragraph gap, smaller headings.
  final bool dense;

  @override
  State<MarkdownView> createState() => _MarkdownViewState();
}

class _MarkdownViewState extends State<MarkdownView>
    implements MarkdownBuilderDelegate {
  // Stateful only to own the link builder's gesture recognizers: a streaming
  // reply rebuilds this widget on every token, and a recognizer allocated per
  // link per build is never disposed by anyone.
  late final _LinkBuilder _links = _LinkBuilder();
  final _recognizers = <GestureRecognizer>[];
  List<Widget> _children = const [];
  // This row's parse and the text it was made from.
  List<md.Node>? _nodes;
  String? _nodesFor;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _build();
  }

  @override
  void didUpdateWidget(MarkdownView old) {
    super.didUpdateWidget(old);
    if (old.data != widget.data ||
        old.keepLineBreaks != widget.keepLineBreaks ||
        old.muted != widget.muted ||
        old.dense != widget.dense) {
      _build();
    }
  }

  @override
  void dispose() {
    // A row leaving the viewport hands its parse on: if it comes back (or
    // the same text is shown elsewhere), the parse is still there. A reply
    // still streaming never stores the prefixes it passed through.
    final nodes = _nodes;
    final data = _nodesFor;
    if (nodes != null && data != null) _parses.put(data, nodes);
    _disposeRecognizers();
    _links.dispose();
    super.dispose();
  }

  /// Lay the (cached) parse out as widgets. Runs when the text, the variant
  /// or the theme changed — never on an unrelated rebuild, and a row that
  /// scrolls back into view reuses the parse instead of redoing it.
  void _build() {
    _disposeRecognizers();
    final builder = MarkdownBuilder(
      delegate: this,
      selectable: false,
      styleSheet: markdownStyle(
        context,
        muted: widget.muted,
        dense: widget.dense,
      ),
      imageDirectory: null,
      imageBuilder: null,
      checkboxBuilder: (checked) => _checkbox(context, checked),
      bulletBuilder: (p) => _bullet(context, p),
      builders: <String, MarkdownElementBuilder>{
        'a': _links,
        'pre': _CodeBlockBuilder(),
      },
      paddingBuilders: const {},
      fitContent: true,
      listItemCrossAxisAlignment: MarkdownListItemCrossAxisAlignment.baseline,
      onTapText: null,
      softLineBreak: widget.keepLineBreaks,
    );
    final data = widget.data;
    if (_nodesFor != data) {
      _nodes = _parses.get(data) ?? _parse(data);
      _nodesFor = data;
    }
    _children = builder.build(_nodes!);
  }

  void _disposeRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  @override
  GestureRecognizer createLink(String text, String? href, String title) {
    // Unreachable while the 'a' builder above owns links, but the builder
    // also routes image taps here — keep the handler wired.
    final recognizer = TapGestureRecognizer()
      ..onTap = () => onTapMarkdownLink(context, text, href, title);
    _recognizers.add(recognizer);
    return recognizer;
  }

  @override
  TextSpan formatText(MarkdownStyleSheet styleSheet, String code) => TextSpan(
    style: styleSheet.code,
    text: code.replaceAll(RegExp(r'\n$'), ''),
  );

  @override
  Widget build(BuildContext context) {
    // A theme change rebuilds through didChangeDependencies; this only
    // places what is already laid out.
    return _children.length == 1
        ? _children.single
        : Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: _children,
          );
  }
}

/// Parsed Markdown by source text, from rows that left the viewport: one
/// scrolling back reuses its parse. Bounded by the characters parsed, about
/// a long session's worth of replies.
final _parses = LruCache<String, List<md.Node>>(
  maxWeight: 4 << 20,
  weigh: (data, _) => data.length,
);

md.Document _document() =>
    md.Document(extensionSet: markdownExtensionSet, encodeHtml: false);

List<md.Node> _parse(String data) => _document().parseLines(
  const LineSplitter().convert(autolinkifyMarkdown(data)),
);

// Stylesheets handed out so far, keyed by the theme they came from. Building
// one costs ~40 TextStyles, and every message in the transcript asks for it on
// every frame of a streaming turn; the theme only changes on a light/dark or
// platform switch, so memoising removes essentially all of that work.
ThemeData? _styleTheme;
final Map<(bool, bool), MarkdownStyleSheet> _styleCache = {};

/// Theme-derived Markdown styling: an airy reading measure, headings that
/// step down in weight rather than shouting, rounded tables with a tinted
/// header row, quiet quotes and rules. [muted] tints body text for prose that
/// sits behind the main reply; [dense] tightens it for a message bubble.
MarkdownStyleSheet markdownStyle(
  BuildContext context, {
  bool muted = false,
  bool dense = false,
}) {
  final theme = Theme.of(context);
  if (!identical(_styleTheme, theme)) {
    _styleTheme = theme;
    _styleCache.clear();
  }
  return _styleCache.putIfAbsent((
    muted,
    dense,
  ), () => _buildMarkdownStyle(context, muted, dense));
}

MarkdownStyleSheet _buildMarkdownStyle(
  BuildContext context,
  bool muted,
  bool dense,
) {
  final theme = Theme.of(context);
  final scheme = theme.colorScheme;
  final text = theme.textTheme;
  // One reading measure: 15 px at a line height that suits Han and Latin
  // alike, no tracking (the theme's), and a paragraph gap of about two
  // thirds of a line.
  final body = muted
      ? text.bodyMedium?.copyWith(height: 1.6, color: scheme.onSurfaceVariant)
      : dense
      ? text.bodyLarge?.copyWith(height: 1.55)
      : text.bodyLarge?.copyWith(height: 1.7);
  // CJK text needs less weight than Latin to read as emphasised: at w700 a
  // bold Han glyph turns into a dark blob at body size.
  final strongWeight = isDesktop ? FontWeight.w600 : FontWeight.w700;
  final divider = scheme.outlineVariant;
  TextStyle? heading(double size, {double height = 1.35}) => body?.copyWith(
    fontSize: dense ? (size - 3).clamp(15, 18).toDouble() : size,
    height: height,
    fontWeight: FontWeight.w600,
    letterSpacing: size >= 20 ? -0.2 : 0,
    color: scheme.onSurface,
  );
  final cellPadding = const EdgeInsets.symmetric(horizontal: 14, vertical: 9);
  return MarkdownStyleSheet.fromTheme(theme).copyWith(
    p: body,
    listBullet: body?.copyWith(color: onSurfaceMuted(scheme)),
    checkbox: body,
    // Weight only: this style is *merged onto* the enclosing one, so carrying a
    // size or height here would blow up bold text inside a table cell or a
    // heading to body size.
    strong: TextStyle(fontWeight: strongWeight),
    em: const TextStyle(fontStyle: FontStyle.italic),
    del: TextStyle(
      decoration: TextDecoration.lineThrough,
      color: scheme.onSurfaceVariant,
    ),
    a: linkStyleOf(context),
    // Paragraphs carry most of the gap themselves, so the block spacing
    // (which also separates list items) stays tight: 16 px between
    // paragraphs, 8 between the items of a tight list.
    pPadding: dense ? EdgeInsets.zero : const EdgeInsets.only(bottom: 8),
    h1: heading(22, height: 1.3),
    h2: heading(19),
    h3: heading(16.5),
    h4: heading(15.5),
    h5: heading(15),
    h6: heading(14)?.copyWith(color: scheme.onSurfaceVariant),
    // More room above a heading than below it, so it binds to its section.
    h1Padding: EdgeInsets.only(top: dense ? 2 : 18, bottom: dense ? 0 : 4),
    h2Padding: EdgeInsets.only(top: dense ? 2 : 14, bottom: dense ? 0 : 2),
    h3Padding: EdgeInsets.only(top: dense ? 2 : 10, bottom: dense ? 0 : 2),
    h4Padding: EdgeInsets.only(top: dense ? 0 : 6),
    listIndent: 22,
    listBulletPadding: const EdgeInsets.only(right: 4),
    blockSpacing: dense ? 6 : 8,
    // `IntrinsicColumnWidth` is load-bearing, not cosmetic: flutter_markdown_plus
    // only wraps a table in a horizontal scroll view for intrinsic/fixed column
    // widths. With the default `FlexColumnWidth` a wide table is squeezed into
    // the viewport and its last columns are clipped off-screen.
    tableColumnWidth: const IntrinsicColumnWidth(),
    tableBorder: TableBorder(
      top: BorderSide(color: divider),
      bottom: BorderSide(color: divider),
      left: BorderSide(color: divider),
      right: BorderSide(color: divider),
      horizontalInside: BorderSide(color: divider),
      borderRadius: BorderRadius.circular(kControlRadius + 2),
    ),
    tableHeadCellsDecoration: BoxDecoration(color: scheme.surfaceContainerLow),
    tableCellsDecoration: const BoxDecoration(),
    tableHead: text.bodyMedium?.copyWith(
      fontWeight: FontWeight.w600,
      height: 1.4,
    ),
    tableBody: text.bodyMedium?.copyWith(height: 1.45),
    tableHeadAlign: TextAlign.left,
    tableCellsPadding: cellPadding,
    tableHeadCellsPadding: cellPadding,
    tableVerticalAlignment: TableCellVerticalAlignment.middle,
    tablePadding: const EdgeInsets.only(bottom: 4),
    code: text.bodyMedium?.copyWith(
      fontFamily: monoFontFamily,
      fontFamilyFallback: monoCjkFallback,
      color: inlineCodeColor(scheme),
      backgroundColor: inlineCodeWash(scheme),
      fontSize: (text.bodyMedium?.fontSize ?? 14) - 1,
    ),
    // `_CodeBlockBuilder` draws the block's own card; the stylesheet's
    // wrapper stays invisible so there is one outline, not two.
    codeblockDecoration: const BoxDecoration(),
    codeblockPadding: EdgeInsets.zero,
    blockquote: body?.copyWith(color: scheme.onSurfaceVariant),
    blockquotePadding: const EdgeInsets.fromLTRB(16, 2, 4, 2),
    blockquoteDecoration: BoxDecoration(
      border: Border(left: BorderSide(color: scheme.outline, width: 3)),
    ),
    horizontalRuleDecoration: BoxDecoration(
      border: Border(top: BorderSide(color: divider)),
    ),
  );
}

/// A list marker: a muted dot (hollow, then square as lists nest) or a
/// tabular number, so the marker column lines up without competing with the
/// items.
Widget _bullet(BuildContext context, MarkdownBulletParameters p) {
  final scheme = Theme.of(context).colorScheme;
  final style = markdownStyle(context).listBullet;
  if (p.style == BulletStyle.orderedList) {
    return Text(
      '${p.index + 1}.',
      textAlign: TextAlign.right,
      style: style?.copyWith(
        fontWeight: FontWeight.w500,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
  const glyphs = ['•', '◦', '–'];
  return Text(
    glyphs[p.nestLevel % glyphs.length],
    textAlign: TextAlign.center,
    style: style?.copyWith(color: scheme.onSurfaceVariant),
  );
}

/// A task-list box in the app's own stroke icons.
Widget _checkbox(BuildContext context, bool checked) {
  final scheme = Theme.of(context).colorScheme;
  final size = (markdownStyle(context).p?.fontSize ?? 15) + 1;
  return Padding(
    padding: const EdgeInsets.only(right: 6),
    child: Icon(
      checked ? AppIcons.check_box : AppIcons.check_box_outline_blank,
      size: size,
      color: checked ? scheme.onSurface : onSurfaceMuted(scheme),
    ),
  );
}

/// A fenced code block with a header: the language on the left, a copy button
/// on the right.
///
/// This is the affordance a coding agent's transcript is mostly made of —
/// without it a block of code is an anonymous tinted rectangle you have to
/// select by hand.
class _CodeBlockBuilder extends MarkdownElementBuilder {
  @override
  bool isBlockElement() => true;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final code = element.textContent.trimRight();
    // The parser puts the fence's info string on the inner `<code>` as
    // `language-<name>`; an unfenced block has none.
    final child = element.children?.whereType<md.Element>().firstOrNull;
    final classes = child?.attributes['class'] ?? '';
    final language = classes.startsWith('language-')
        ? classes.substring('language-'.length)
        : '';
    return CodeBlock(code: code, language: language);
  }
}

/// [source] with its Markdown syntax removed, for a place that can only show
/// one line of plain text — an activity card's collapsed peek. Uses the real
/// parser rather than a strip-the-asterisks regex, so `**Planning restart**`
/// reads as `Planning restart` and a stray `*` in prose survives intact.
String markdownPlainPreview(String source) =>
    _document().parseInline(source).map((n) => n.textContent).join();

/// Renders `<a>` as `favicon + underlined text`, tappable.
///
/// Registering a builder for `a` takes link handling away from MarkdownBody
/// (see its `builders.containsKey('a')` checks), so the tap recognizer is ours
/// to attach. Returning a `Text.rich` — rather than a bare widget — keeps the
/// link inline: the builder merges neighbouring text widgets into one span, so
/// the link still wraps mid-paragraph like ordinary text.
class _LinkBuilder extends MarkdownElementBuilder {
  // One recognizer per destination, reused across rebuilds. Allocating per
  // build would leak one per link per streamed token; the pool is bounded by
  // the number of distinct links in a single message.
  final Map<String, TapGestureRecognizer> _taps = {};

  /// Releases every pooled recognizer. Call from the owning State's `dispose`.
  void dispose() {
    for (final r in _taps.values) {
      r.dispose();
    }
    _taps.clear();
  }

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final href = element.attributes['href'];
    final style = (parentStyle ?? const TextStyle()).merge(preferredStyle);
    final host = _faviconHost(href);
    final recognizer = _taps.putIfAbsent(href ?? '', TapGestureRecognizer.new)
      // Re-point every build: `context` is fresh each time, and the old
      // closure would hold the previous element alive.
      ..onTap = () => openUrl(context, href);
    return Text.rich(
      TextSpan(
        children: <InlineSpan>[
          if (host != null)
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Padding(
                padding: const EdgeInsets.only(right: 4),
                child: _Favicon(host: host),
              ),
            ),
          ..._linkLabel(element.children, style, recognizer),
        ],
      ),
    );
  }
}

/// Link label as a FLAT list of leaf spans. Building the child nodes ourselves
/// (instead of flattening to `textContent`) is what keeps `[**粗体**说明](url)`
/// bold — replacing the `a` builder discards the spans MarkdownBody had already
/// built for it. Flat is not a style choice: MarkdownBuilder re-creates every
/// child span as `TextSpan(text: …)` when it merges inline widgets, dropping
/// any `children`, so a nested span would render as nothing at all.
List<InlineSpan> _linkLabel(
  List<md.Node>? nodes,
  TextStyle style,
  GestureRecognizer recognizer,
) => [
  for (final node in nodes ?? const <md.Node>[])
    if (node is md.Element)
      ..._linkLabel(node.children, switch (node.tag) {
        'strong' => style.copyWith(fontWeight: FontWeight.w600),
        'em' => style.copyWith(fontStyle: FontStyle.italic),
        'del' => style.copyWith(decoration: TextDecoration.lineThrough),
        _ => style,
      }, recognizer)
    else
      TextSpan(text: node.textContent, style: style, recognizer: recognizer),
];

/// Host to fetch a favicon from, or null when the link isn't a plain web URL
/// (relative paths, `mailto:`, the `#anchor` links a model writes for its own
/// headings — none of which have a site to represent).
String? _faviconHost(String? href) {
  final uri = Uri.tryParse(href?.trim() ?? '');
  if (uri == null || !uri.hasAuthority || isHostLocalWebUrl(uri)) return null;
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;
  return uri.host.isEmpty ? null : uri.host;
}

/// When a host's favicon fetch last failed. Flutter's image cache does not
/// remember failures, so without this a site that 404s its `/favicon.ico` is
/// re-requested on every rebuild — and transcripts rebuild constantly while a
/// turn streams. Entries expire because the app runs on phones and flaky
/// networks: one bad moment must not strand a host's icon for the session.
final Map<String, DateTime> _faviconMisses = {};
const _faviconRetryAfter = Duration(minutes: 2);

/// A site's favicon, sized to sit on a text line.
///
/// Fetched straight from the site (`https://<host>/favicon.ico`) rather than
/// through a favicon proxy: no third party learns which links the user reads,
/// and nothing depends on a service that may be unreachable. The generic globe
/// shows immediately and stays put if the fetch is slow or fails, so a dead or
/// blocked host never holds up the text.
class _Favicon extends StatelessWidget {
  const _Favicon({required this.host});

  final String host;

  static const double _size = 15;

  @override
  Widget build(BuildContext context) {
    final fallback = Icon(
      AppIcons.public,
      size: _size,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    final dark = Theme.of(context).brightness == Brightness.dark;
    final missedAt = _faviconMisses[host];
    if (missedAt != null) {
      if (DateTime.now().difference(missedAt) < _faviconRetryAfter) {
        return fallback;
      }
      _faviconMisses.remove(host);
    }
    return SizedBox(
      width: _size,
      height: _size,
      child: Image(
        image: ResizeImage.resizeIfNeeded(
          (_size * MediaQuery.devicePixelRatioOf(context)).round(),
          null,
          AppNetworkImage('https://$host/favicon.ico'),
        ),
        width: _size,
        height: _size,
        fit: BoxFit.contain,
        // Sites routinely serve a 256 px (or larger) .ico. Without a decode
        // bound each one is held in the image cache at full size for a 15 px
        // slot — a transcript citing a dozen hosts would pin several MB.
        errorBuilder: (context, error, stack) {
          _faviconMisses[host] = DateTime.now();
          return fallback;
        },
        frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
          if (frame == null && !wasSynchronouslyLoaded) return fallback;
          if (!dark) return child;
          // Most favicons are drawn for a light tab strip (GitHub's is a
          // black mark), so on a dark page they sit on a small light plate.
          return DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0xFFF2F2F2),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Padding(padding: const EdgeInsets.all(1.5), child: child),
          );
        },
      ),
    );
  }
}
