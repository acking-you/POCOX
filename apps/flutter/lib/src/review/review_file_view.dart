import 'package:flutter/material.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/app_icons.dart';
import 'package:pocox/src/git_diff.dart';
import 'package:pocox/src/review/diff_rows.dart';
import 'package:super_sliver_list/super_sliver_list.dart';

/// The new-file numbers of the lines [file]'s diff added.
Set<int> addedLines(DiffFile file) => {
  for (final row in diffRowsOf(file))
    if (row is DiffCodeRow &&
        row.line.kind == DiffLineKind.added &&
        row.number != null)
      row.number!,
};

/// A file as it is on the host now, read-only: every line numbered and
/// highlighted, the lines the change added marked, opened at the first.
class ReviewFileView extends StatefulWidget {
  /// Creates the view of [path].
  const ReviewFileView({
    super.key,
    required this.path,
    required this.load,
    this.changed = const {},
    this.revision,
  });

  /// The file, as the review names it.
  final String path;

  /// Reads its lines from the host; null when it cannot.
  final Future<List<String>?> Function(String path) load;

  /// Line numbers to mark.
  final Set<int> changed;

  /// Moves whenever the file may hold something else; the view then reads it
  /// again, showing what it has until the new lines arrive.
  final Object? revision;

  @override
  State<ReviewFileView> createState() => _ReviewFileViewState();
}

class _ReviewFileViewState extends State<ReviewFileView> {
  final _list = ListController();
  final _scroll = ScrollController();
  List<String>? _lines;
  bool _failed = false;
  int _read = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(ReviewFileView old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path) {
      _load();
    } else if (old.revision != widget.revision) {
      _load(keep: true);
    }
  }

  @override
  void dispose() {
    _list.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Read the file; with [keep], the lines shown stay (and keep their scroll
  /// position) until the new ones arrive.
  Future<void> _load({bool keep = false}) async {
    final read = ++_read;
    if (!keep && (_lines != null || _failed)) {
      setState(() {
        _lines = null;
        _failed = false;
      });
    }
    final lines = await widget.load(widget.path);
    if (!mounted || read != _read) return;
    final shown = keep && _lines != null;
    setState(() {
      _lines = lines;
      _failed = lines == null;
    });
    if (shown) return;
    final first = widget.changed.isEmpty
        ? null
        : widget.changed.reduce((a, b) => a < b ? a : b);
    if (lines == null || first == null || first > lines.length) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_list.isAttached || !_scroll.hasClients) return;
      // A few lines of what leads up to it stay in view above.
      _list.jumpToItem(
        index: (first - 4).clamp(0, lines.length - 1),
        scrollController: _scroll,
        alignment: 0,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final lines = _lines;
    if (_failed) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(AppIcons.error_outline, color: muted),
              const SizedBox(height: 10),
              Text(
                l10n.reviewFileUnavailable,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(color: muted),
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                key: const Key('review-file-retry'),
                onPressed: _load,
                icon: const Icon(AppIcons.refresh, size: 16),
                label: Text(l10n.retry),
              ),
            ],
          ),
        ),
      );
    }
    if (lines == null) {
      return Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox.square(
              dimension: 14,
              child: CircularProgressIndicator(strokeWidth: 1.6, color: muted),
            ),
            const SizedBox(width: 10),
            Text(
              l10n.reviewFileLoading,
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
          ],
        ),
      );
    }
    final language = languageHintForPath(widget.path);
    return SelectionArea(
      child: SuperListView.builder(
        key: const Key('review-file-lines'),
        controller: _scroll,
        listController: _list,
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: lines.length,
        itemBuilder: (context, i) => DiffCodeLine(
          line: DiffLine(DiffLineKind.context, lines[i]),
          number: i + 1,
          language: language,
          marked: widget.changed.contains(i + 1),
        ),
      ),
    );
  }
}
