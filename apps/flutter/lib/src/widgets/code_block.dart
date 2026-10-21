import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/code_highlight.dart';
import 'package:pocox/src/desktop_theme.dart';
import 'package:pocox/src/fonts.dart';
import 'package:pocox/src/theme.dart';
import 'package:pocox/src/widgets/app_toast.dart';
import 'package:pocox/src/app_icons.dart';

/// A framed, syntax-highlighted block of code with its language and a copy
/// button: one look for a fenced block in a reply, a tool call's command or
/// JSON in a step, and a file opened from the host.
///
/// Lines never wrap — code read sideways is code; wrapped, it is a different
/// program — so the body scrolls horizontally. [maxHeight] bounds a long body
/// with its own vertical scroll; null lays it all out (the caller scrolls).
class CodeBlock extends StatelessWidget {
  /// Shows [code] highlighted as [language] (a fence info string, a file
  /// extension, or empty for plain text).
  const CodeBlock({
    super.key,
    required this.code,
    this.language = '',
    this.label,
    this.maxHeight,
    this.fontSize = 12.5,
    this.margin = const EdgeInsets.symmetric(vertical: 6),
    this.trailing,
  });

  /// The source, shown as-is.
  final String code;

  /// Grammar to highlight with; unknown or empty renders plain.
  final String language;

  /// Header text; defaults to [language], or "text".
  final String? label;

  /// Bounds the body, which then scrolls vertically.
  final double? maxHeight;

  /// Body text size.
  final double fontSize;

  /// Space around the frame.
  final EdgeInsetsGeometry margin;

  /// Extra header controls, before the copy button.
  final List<Widget>? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final mono = TextStyle(
      fontFamily: monoFontFamily,
      fontFamilyFallback: monoCjkFallback,
      fontSize: fontSize,
      height: 1.5,
      color: scheme.onSurface,
    );
    final body = SingleChildScrollView(
      // Never the primary controller: a block sits inside the transcript's
      // scroll view, and borrowing its controller would tie both scrollbars
      // to one position.
      primary: false,
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 14),
      child: HighlightedCode(
        code: code,
        language: language,
        base: mono,
        brightness: Theme.of(context).brightness,
        // Upright: italic comments over a CJK fallback look distorted.
        allowItalic: false,
      ),
    );
    return Container(
      width: double.infinity,
      margin: margin,
      // A soft sunken plate: no outline, the tone alone separates code from
      // prose.
      decoration: BoxDecoration(
        color: codeSurface(scheme),
        borderRadius: BorderRadius.circular(kPanelRadius - 2),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 36,
            child: Row(
              children: [
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    label ?? (language.isEmpty ? 'text' : language),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                ...?trailing,
                CopyTextButton(text: code),
                const SizedBox(width: 4),
              ],
            ),
          ),
          SizedBox(
            width: double.infinity,
            child: maxHeight == null
                ? body
                : ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: maxHeight!),
                    child: _BoundedBody(child: body),
                  ),
          ),
        ],
      ),
    );
  }
}

/// A vertically scrolling body with a scrollbar that owns its controller.
///
/// A bare `Scrollbar` falls back to the PrimaryScrollController — on desktop,
/// the transcript's — and when that controller is detached (the page between
/// routes, a fold collapsing) every block threw "The Scrollbar's
/// ScrollController has no ScrollPosition attached".
class _BoundedBody extends StatefulWidget {
  const _BoundedBody({required this.child});
  final Widget child;

  @override
  State<_BoundedBody> createState() => _BoundedBodyState();
}

class _BoundedBodyState extends State<_BoundedBody> {
  final _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scrollbar(
    controller: _controller,
    child: SingleChildScrollView(controller: _controller, child: widget.child),
  );
}

/// Copies [text] and confirms it, without stealing focus.
class CopyTextButton extends StatelessWidget {
  /// Copies [text] when pressed.
  const CopyTextButton({super.key, required this.text});

  /// What to copy.
  final String text;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return IconButton(
      icon: const Icon(AppIcons.content_copy_outlined, size: 15),
      iconSize: 15,
      visualDensity: VisualDensity.compact,
      style: IconButton.styleFrom(
        minimumSize: const Size(30, 30),
        fixedSize: const Size(30, 30),
        padding: EdgeInsets.zero,
      ),
      tooltip: l10n.copy,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
      onPressed: () {
        Clipboard.setData(ClipboardData(text: text));
        showToastOk(context, l10n.copied);
      },
    );
  }
}
