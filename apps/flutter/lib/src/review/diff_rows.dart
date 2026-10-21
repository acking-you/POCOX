import 'package:flutter/material.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/app_icons.dart';
import 'package:pocox/src/code_highlight.dart';
import 'package:pocox/src/desktop_theme.dart';
import 'package:pocox/src/fonts.dart';
import 'package:pocox/src/git_diff.dart';
import 'package:pocox/src/theme.dart';

/// One row of a rendered file diff: a code line, or the run of unchanged
/// lines git elided between two hunks.
sealed class DiffRow {
  const DiffRow();
}

/// A code line, numbered in the file it belongs to: the old file for a
/// removed line, the new one otherwise.
class DiffCodeRow extends DiffRow {
  /// Creates a code row.
  const DiffCodeRow(this.line, this.number);

  /// The line.
  final DiffLine line;

  /// Its line number, when the hunk header gave one.
  final int? number;
}

/// Unchanged lines git left out between hunks, as a range of the new file,
/// so the review can splice exactly those lines in from the current file.
class DiffGapRow extends DiffRow {
  /// Creates a gap row.
  const DiffGapRow(this.count, this.newStart, this.newEnd);

  /// How many lines were left out.
  final int count;

  /// First left-out line of the new file, from 1.
  final int newStart;

  /// Last left-out line of the new file, inclusive.
  final int newEnd;
}

/// [file]'s rows, hunk by hunk, with a gap row wherever git elided
/// unchanged lines before a hunk.
List<DiffRow> diffRowsOf(DiffFile file) {
  final rows = <DiffRow>[];
  int? oldNo, newNo; // next old-/new-file line numbers
  for (final line in file.lines) {
    if (line.kind == DiffLineKind.hunk) {
      final ns = hunkNewStart(line.text);
      if (ns != null) {
        // The unchanged run git left out before this hunk, on the new side.
        final gapStart = newNo ?? 1;
        final gapEnd = ns - 1;
        if (gapEnd >= gapStart) {
          rows.add(DiffGapRow(gapEnd - gapStart + 1, gapStart, gapEnd));
        }
        newNo = ns;
      }
      final os = hunkOldStart(line.text);
      if (os != null) oldNo = os;
      continue;
    }
    switch (line.kind) {
      case DiffLineKind.removed:
        rows.add(
          DiffCodeRow(line, oldNo),
        ); // removed lines carry the old number
        if (oldNo != null) oldNo++;
      case DiffLineKind.added:
        rows.add(DiffCodeRow(line, newNo));
        if (newNo != null) newNo++;
      case DiffLineKind.context:
        rows.add(DiffCodeRow(line, newNo));
        if (oldNo != null) oldNo++;
        if (newNo != null) newNo++;
      case DiffLineKind.hunk:
        break;
    }
  }
  return rows;
}

/// The monospace style every diff and file line is set in.
TextStyle diffCodeStyle(ColorScheme scheme, {bool dimmed = false}) => TextStyle(
  fontFamily: monoFontFamily,
  fontFamilyFallback: monoCjkFallback,
  fontSize: 12.5,
  height: 1.4,
  color: dimmed ? scheme.onSurfaceVariant : scheme.onSurface,
);

/// One code line: its number, a +/− marker, and the highlighted text on a
/// tint of its kind. Long lines wrap rather than opening a second scroll
/// axis inside the review.
class DiffCodeLine extends StatelessWidget {
  /// Creates the line.
  const DiffCodeLine({
    super.key,
    required this.line,
    required this.number,
    required this.language,
    this.marked = false,
  });

  /// The line.
  final DiffLine line;

  /// Its line number.
  final int? number;

  /// The highlighter's language hint (see [languageHintForPath]).
  final String language;

  /// Whether a plain line is flagged anyway (a changed line of a whole file).
  final bool marked;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final addition = additionColor(scheme);
    final (Color bg, String marker, Color markerColor) = switch (line.kind) {
      DiffLineKind.added => (addition.withValues(alpha: 0.13), '+', addition),
      DiffLineKind.removed => (
        scheme.error.withValues(alpha: 0.10),
        '−',
        scheme.error,
      ),
      _ when marked => (addition.withValues(alpha: 0.10), '', addition),
      _ => (Colors.transparent, ' ', scheme.onSurfaceVariant),
    };
    final base = diffCodeStyle(
      scheme,
      dimmed: line.kind == DiffLineKind.removed,
    );
    final span = highlightCode(
      code: line.text,
      language: language,
      base: base,
      brightness: Theme.of(context).brightness,
      // Upright: italic comments over a CJK fallback read as distorted.
      allowItalic: false,
    );
    return Container(
      color: bg,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 44,
            child: Text(
              number?.toString() ?? '',
              textAlign: TextAlign.right,
              style: base.copyWith(
                fontSize: 11,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          SizedBox(
            width: 18,
            child: marked && line.kind == DiffLineKind.context
                ? Center(
                    child: Container(
                      width: 2,
                      height: 14,
                      margin: const EdgeInsets.only(top: 2),
                      color: markerColor,
                    ),
                  )
                : Text(
                    marker,
                    textAlign: TextAlign.center,
                    style: base.copyWith(color: markerColor),
                  ),
          ),
          Expanded(child: Text.rich(span)),
        ],
      ),
    );
  }
}

/// The marker for [count] elided unchanged lines. Tappable to reveal them
/// when [onTap] is given; [busy] while the file is being read and [failed]
/// once it could not be.
class DiffGapLine extends StatelessWidget {
  /// Creates the marker.
  const DiffGapLine({
    super.key,
    required this.count,
    this.onTap,
    this.busy = false,
    this.failed = false,
  });

  /// Lines left out.
  final int count;

  /// Reveal them; null leaves a plain marker.
  final VoidCallback? onTap;

  /// Whether the lines are being read.
  final bool busy;

  /// Whether reading them failed.
  final bool failed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    final canExpand = onTap != null && !failed;
    final color = canExpand ? scheme.primary : scheme.onSurfaceVariant;
    return InkWell(
      mouseCursor: canExpand ? clickable : MouseCursor.defer,
      onTap: canExpand ? onTap : null,
      child: Container(
        color: scheme.surfaceContainerLow,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            if (busy)
              const SizedBox(
                width: 15,
                height: 15,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              Icon(
                canExpand ? AppIcons.unfold_more : AppIcons.more_horiz,
                size: 15,
                color: color,
              ),
            const SizedBox(width: 8),
            Text(
              failed
                  ? l10n.diffExpandFailed(count)
                  : l10n.diffUnmodified(count),
              style: TextStyle(fontSize: 11.5, color: color),
            ),
          ],
        ),
      ),
    );
  }
}
