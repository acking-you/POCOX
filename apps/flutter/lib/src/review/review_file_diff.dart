import 'package:flutter/material.dart';
import 'package:pocox/src/git_diff.dart';
import 'package:pocox/src/review/diff_rows.dart';
import 'package:super_sliver_list/super_sliver_list.dart';
import 'package:pocox/src/widgets/change_counts.dart';

/// One block of a file's changes in the review: an edit of the conversation,
/// or the workspace's whole diff of the file.
class ReviewDiffSection {
  /// Creates a section.
  const ReviewDiffSection({
    required this.file,
    this.label,
    this.detail,
    this.expandable = false,
  });

  /// The diff of the file it shows.
  final DiffFile file;

  /// What it is ("Edit 3"); null shows no heading.
  final String? label;

  /// When it happened, beside the label.
  final String? detail;

  /// Whether its elided lines can be read from the file as it is now, which
  /// holds them verbatim only for the workspace's own diff.
  final bool expandable;
}

/// A file's changes, section by section, in one lazy list: each section's
/// hunks with numbered, highlighted lines, and its elided unchanged runs as
/// markers that read the lines in from the host when the section allows.
class ReviewFileDiff extends StatefulWidget {
  /// Creates the view of [path]'s [sections].
  const ReviewFileDiff({
    super.key,
    required this.path,
    required this.sections,
    this.onLoadFile,
  });

  /// The file.
  final String path;

  /// Its changes, in order.
  final List<ReviewDiffSection> sections;

  /// Reads the file's current lines; null leaves gaps as plain markers.
  final Future<List<String>?> Function(String path)? onLoadFile;

  @override
  State<ReviewFileDiff> createState() => _ReviewFileDiffState();
}

sealed class _Entry {
  const _Entry();
}

class _Heading extends _Entry {
  const _Heading(this.section);
  final ReviewDiffSection section;
}

class _Line extends _Entry {
  const _Line(this.row);
  final DiffCodeRow row;
}

class _Gap extends _Entry {
  const _Gap(this.section, this.row, this.id);
  final ReviewDiffSection section;
  final DiffGapRow row;
  final (int, int) id;
}

class _ReviewFileDiffState extends State<ReviewFileDiff> {
  late List<List<DiffRow>> _rows = _computeRows();
  final Set<(int, int)> _expanded = {};
  List<String>? _lines;
  bool _loading = false;
  bool _failed = false;

  @override
  void didUpdateWidget(ReviewFileDiff old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path) {
      _expanded.clear();
      _lines = null;
      _loading = false;
      _failed = false;
    }
    if (old.path != widget.path || !_sameSections(old.sections)) {
      _rows = _computeRows();
    }
  }

  bool _sameSections(List<ReviewDiffSection> old) {
    if (old.length != widget.sections.length) return false;
    for (var i = 0; i < old.length; i++) {
      if (!identical(old[i].file, widget.sections[i].file)) return false;
    }
    return true;
  }

  List<List<DiffRow>> _computeRows() => [
    for (final section in widget.sections) diffRowsOf(section.file),
  ];

  Future<void> _ensureLoaded() async {
    final load = widget.onLoadFile;
    if (_lines != null || _loading || _failed || load == null) return;
    setState(() => _loading = true);
    final lines = await load(widget.path);
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (lines == null) {
        _failed = true;
      } else {
        _lines = lines;
      }
    });
  }

  void _toggle((int, int) id) {
    setState(() {
      if (!_expanded.remove(id)) _expanded.add(id);
    });
    _ensureLoaded();
  }

  /// The rows to paint: an expanded gap (once the file is read) becomes its
  /// unchanged lines; every other gap stays a marker.
  List<_Entry> _entries() {
    final out = <_Entry>[];
    for (var s = 0; s < widget.sections.length; s++) {
      final section = widget.sections[s];
      if (section.label != null) out.add(_Heading(section));
      final rows = _rows[s];
      for (var r = 0; r < rows.length; r++) {
        final row = rows[r];
        final lines = _lines;
        if (row is DiffGapRow &&
            section.expandable &&
            _expanded.contains((s, r)) &&
            lines != null) {
          for (var n = row.newStart; n <= row.newEnd; n++) {
            final text = n - 1 < lines.length ? lines[n - 1] : '';
            out.add(
              _Line(DiffCodeRow(DiffLine(DiffLineKind.context, text), n)),
            );
          }
        } else if (row is DiffGapRow) {
          out.add(_Gap(section, row, (s, r)));
        } else {
          out.add(_Line(row as DiffCodeRow));
        }
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries();
    final language = languageHintForPath(widget.path);
    // Selectable so a reviewer can lift a snippet; lazy so a long file
    // doesn't lay out every line up front.
    return SelectionArea(
      child: SuperListView.builder(
        padding: const EdgeInsets.only(bottom: 24),
        itemCount: entries.length,
        itemBuilder: (context, i) => switch (entries[i]) {
          _Heading(:final section) => _heading(context, section),
          _Line(:final row) => DiffCodeLine(
            line: row.line,
            number: row.number,
            language: language,
          ),
          _Gap(:final section, :final row, :final id) => DiffGapLine(
            key: Key('gap-${id.$1}-${id.$2}'),
            count: row.count,
            busy: _loading && _expanded.contains(id),
            failed: section.expandable && _failed,
            onTap: section.expandable && widget.onLoadFile != null
                ? () => _toggle(id)
                : null,
          ),
        },
      ),
    );
  }

  Widget _heading(BuildContext context, ReviewDiffSection section) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = scheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 14, 6),
      child: Row(
        children: [
          Text(
            section.label!,
            style: theme.textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          if (section.detail case final detail?) ...[
            const SizedBox(width: 8),
            Text(
              detail,
              style: theme.textTheme.labelSmall?.copyWith(color: muted),
            ),
          ],
          const Spacer(),
          ChangeCounts(
            added: section.file.added,
            removed: section.file.removed,
          ),
        ],
      ),
    );
  }
}
