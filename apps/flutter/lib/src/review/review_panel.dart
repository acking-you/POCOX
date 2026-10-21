import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/app_icons.dart';
import 'package:pocox/src/git_diff.dart';
import 'package:pocox/src/motion.dart';
import 'package:pocox/src/review/review_file_diff.dart';
import 'package:pocox/src/review/review_file_list.dart';
import 'package:pocox/src/review/review_file_view.dart';
import 'package:pocox/src/review/session_changes.dart';
import 'package:pocox/src/theme.dart';
import 'package:pocox/src/widgets/app_toast.dart';
import 'package:pocox/src/widgets/glass.dart';
import 'package:pocox/src/widgets/change_counts.dart';

/// Where the review reads its changes from.
enum ReviewSource {
  /// The edits this conversation made, as its transcript recorded them.
  session,

  /// The project's working tree against its upstream branch.
  workspace,
}

/// The working tree's records by path, in diff order. A diff can name one
/// path twice (staged and unstaged hunks); both records belong to that file.
Map<String, List<DiffFile>> workspaceFiles(DiffModel? diff) {
  final byPath = <String, List<DiffFile>>{};
  for (final file in diff?.files ?? const <DiffFile>[]) {
    (byPath[file.path] ??= []).add(file);
  }
  return byPath;
}

/// Where the review opens: a source, narrowed to one edit and opened on one
/// file when given. A new target (by identity) is applied however the review
/// was left, so every request must pass a fresh instance ([ReviewTarget.of]).
class ReviewTarget {
  /// Creates a target.
  const ReviewTarget({this.source, this.edit, this.path});

  /// A fresh copy of [target]: a repeated const target is one instance, which
  /// the review would otherwise take for the request it already applied.
  factory ReviewTarget.of(ReviewTarget target) =>
      ReviewTarget(source: target.source, edit: target.edit, path: target.path);

  /// The source to show; null keeps the current one.
  final ReviewSource? source;

  /// The edit (a `fileChange` item id) to narrow the session to.
  final String? edit;

  /// The file to open.
  final String? path;
}

/// The review: what changed, file by file, beside or instead of the
/// conversation.
///
/// It reads from two sources: the edits this conversation made (every
/// engine) and, where the host can tell, the project's working tree against
/// its upstream branch. A list of files opens each one's diff, edit by edit,
/// and any file can be read whole as it is on the host now. Wide enough, the
/// list stays beside the open file; narrower, the file replaces the list
/// with a way back.
class ReviewPanel extends StatefulWidget {
  /// Creates the review.
  const ReviewPanel({
    super.key,
    required this.session,
    required this.onClose,
    this.workspace,
    this.workspaceAvailable = false,
    this.workspaceLoading = false,
    this.onRefreshWorkspace,
    this.onCancelRefresh,
    this.branch,
    this.root,
    this.target,
    this.onLoadFile,
    this.page = false,
  });

  /// The conversation's own edits.
  final SessionChanges session;

  /// The working tree's diff, once read.
  final DiffModel? workspace;

  /// Whether the host can diff the working tree at all.
  final bool workspaceAvailable;

  /// Whether a read of the working tree's diff is under way.
  final bool workspaceLoading;

  /// Read the working tree's diff again.
  final VoidCallback? onRefreshWorkspace;

  /// Give up on the read under way.
  final VoidCallback? onCancelRefresh;

  /// The branch the working tree is on.
  final String? branch;

  /// The project folder, which paths are shown relative to.
  final String? root;

  /// Where to open; see [ReviewTarget].
  final ReviewTarget? target;

  /// Reads a file's current lines from the host; null when it cannot.
  final Future<List<String>?> Function(String path)? onLoadFile;

  /// Close the review.
  final VoidCallback onClose;

  /// Whether the review is a page of its own (a phone), closed by going back.
  final bool page;

  @override
  State<ReviewPanel> createState() => _ReviewPanelState();
}

class _ReviewPanelState extends State<ReviewPanel> {
  late ReviewSource _source = _initialSource();
  String? _edit;
  String? _path;
  bool _whole = false;

  /// Whether the reader went back to the list, which then stays open even
  /// where a single file or a wide panel would open one by itself.
  bool _browsing = false;

  @override
  void initState() {
    super.initState();
    _apply(widget.target);
  }

  @override
  void didUpdateWidget(ReviewPanel old) {
    super.didUpdateWidget(old);
    if (!identical(old.target, widget.target)) _apply(widget.target);
    if (!widget.workspaceAvailable && _source == ReviewSource.workspace) {
      _source = ReviewSource.session;
    }
  }

  ReviewSource _initialSource() {
    final workspace = widget.workspace;
    if (widget.workspaceAvailable &&
        (widget.session.isEmpty || (workspace != null && !workspace.isEmpty))) {
      return ReviewSource.workspace;
    }
    return ReviewSource.session;
  }

  void _apply(ReviewTarget? target) {
    if (target == null) return;
    _source =
        target.source ?? (target.edit != null ? ReviewSource.session : _source);
    if (_source == ReviewSource.workspace && !widget.workspaceAvailable) {
      _source = ReviewSource.session;
    }
    _edit = _source == ReviewSource.session ? target.edit : null;
    _whole = false;
    _browsing = false;
    _path = target.path;
    // An edit of one file opens on it.
    final edit = _edit == null ? null : widget.session.edit(_edit!);
    if (_path == null && edit != null && edit.diff.files.length == 1) {
      _path = edit.diff.files.single.path;
    }
  }

  List<ReviewFileEntry> _entries() {
    ReviewFileEntry entry(List<DiffFile> records, {int edits = 0}) {
      final first = records.first.lines
          .where((l) => l.kind == DiffLineKind.hunk)
          .firstOrNull
          ?.text;
      return ReviewFileEntry(
        path: records.first.path,
        added: records.fold(0, (n, f) => n + f.added),
        removed: records.fold(0, (n, f) => n + f.removed),
        edits: edits,
        created: first != null && hunkOldStart(first) == 0,
        deleted: first != null && hunkNewStart(first) == 0,
      );
    }

    if (_source == ReviewSource.workspace) {
      return [
        for (final records in workspaceFiles(widget.workspace).values)
          entry(records),
      ];
    }
    final edit = _edit == null ? null : widget.session.edit(_edit!);
    if (edit != null) {
      return [
        for (final file in edit.diff.files) entry([file]),
      ];
    }
    return [
      for (final file in widget.session.files)
        ReviewFileEntry(
          path: file.path,
          added: file.added,
          removed: file.removed,
          edits: file.edits.length,
          created: entry([file.edits.first.$2]).created,
          deleted: entry([file.edits.last.$2]).deleted,
        ),
    ];
  }

  String _time(int? seconds) {
    if (seconds == null) return '';
    final at = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
    return DateFormat.Hm(
      Localizations.localeOf(context).toLanguageTag(),
    ).format(at);
  }

  /// The open file's diff, section by section, and the lines to mark when it
  /// is read whole.
  ({List<ReviewDiffSection> sections, Set<int> changed})? _open(
    AppLocalizations l10n,
  ) {
    final path = _path;
    if (path == null) return null;
    if (_source == ReviewSource.workspace) {
      final records = workspaceFiles(widget.workspace)[path];
      if (records == null) return null;
      return (
        sections: [
          for (final file in records)
            ReviewDiffSection(file: file, expandable: true),
        ],
        changed: {for (final file in records) ...addedLines(file)},
      );
    }
    final file = widget.session.files.where((f) => f.path == path).firstOrNull;
    if (file == null) return null;
    final edits = _edit == null
        ? file.edits
        : file.edits.where((e) => e.$1.id == _edit).toList();
    if (edits.isEmpty) return null;
    return (
      sections: [
        for (final (edit, diff) in edits)
          ReviewDiffSection(
            file: diff,
            label: l10n.reviewEdit(edit.index),
            detail: _time(edit.completedAt),
          ),
      ],
      // The latest edit is the one the file on the host still reflects.
      changed: addedLines(file.edits.last.$2),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final entries = _entries();
    if (_path != null && !entries.any((e) => e.path == _path)) _path = null;
    return LayoutBuilder(
      builder: (context, box) {
        final wide = box.maxWidth >= 760;
        // Beside a list there is room to show a file straight away; alone,
        // only when there is a single one to show.
        if (_path == null &&
            !_browsing &&
            entries.isNotEmpty &&
            (wide || entries.length == 1)) {
          _path = entries.first.path;
        }
        final open = _open(l10n);
        final list = ReviewFileList(
          key: ValueKey(('review-files', _source, _edit)),
          files: entries,
          selected: _path,
          root: widget.root,
          empty: _source == ReviewSource.session
              ? l10n.reviewNoSessionChanges
              : l10n.noChanges,
          onSelect: (path) => setState(() {
            _path = path;
            _whole = false;
          }),
        );
        final detail = open == null
            ? null
            : _fileDetail(context, l10n, open, showBack: !wide);
        final body = wide
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(width: 280, child: list),
                  const VerticalDivider(width: 1),
                  Expanded(
                    child:
                        detail ??
                        Center(
                          child: Text(
                            l10n.reviewPickFile,
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                  ),
                ],
              )
            : AnimatedSwitcher(
                duration: Motion.of(context, Motion.medium),
                switchInCurve: Motion.enter,
                switchOutCurve: Curves.easeIn,
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation,
                  child: SlideTransition(
                    position: Tween(
                      begin: const Offset(0.04, 0),
                      end: Offset.zero,
                    ).animate(animation),
                    child: child,
                  ),
                ),
                child: KeyedSubtree(
                  key: ValueKey(detail == null ? 'list' : 'file:$_path'),
                  child: detail ?? list,
                ),
              );
        // A working tree never read yet is not one without changes: it is
        // being read, or the read failed and can be asked for again.
        final unread =
            _source == ReviewSource.workspace && widget.workspace == null;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(context, l10n, entries, unread: unread),
            const Divider(height: 1),
            Expanded(child: unread ? _unreadWorkspace(context, l10n) : body),
          ],
        );
      },
    );
  }

  Widget _unreadWorkspace(BuildContext context, AppLocalizations l10n) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final loading = widget.workspaceLoading;
    return Center(
      key: const Key('review-workspace-unread'),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (loading)
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              Icon(AppIcons.error_outline, size: 20, color: muted),
            const SizedBox(height: 10),
            Text(
              loading
                  ? l10n.reviewWorkspaceLoading
                  : l10n.reviewWorkspaceUnavailable,
              textAlign: TextAlign.center,
              style: TextStyle(color: muted),
            ),
            if (!loading && widget.onRefreshWorkspace != null) ...[
              const SizedBox(height: 8),
              TextButton.icon(
                key: const Key('review-workspace-retry'),
                onPressed: widget.onRefreshWorkspace,
                icon: const Icon(AppIcons.refresh, size: 16),
                label: Text(l10n.retry),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _header(
    BuildContext context,
    AppLocalizations l10n,
    List<ReviewFileEntry> entries, {
    bool unread = false,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = scheme.onSurfaceVariant;
    final added = entries.fold(0, (n, e) => n + e.added);
    final removed = entries.fold(0, (n, e) => n + e.removed);
    final edit = _edit == null ? null : widget.session.edit(_edit!);
    final workspace = _source == ReviewSource.workspace;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (widget.page)
                IconButton(
                  key: const Key('review-close'),
                  tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                  icon: const Icon(AppIcons.arrow_back, size: 20),
                  onPressed: widget.onClose,
                )
              else
                Icon(AppIcons.file_diff, size: 18, color: muted),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  l10n.reviewTitle,
                  style: theme.textTheme.titleSmall,
                ),
              ),
              if (workspace && widget.workspaceLoading)
                IconButton(
                  key: const Key('review-refresh-cancel'),
                  tooltip: l10n.cancelDiffLoad,
                  visualDensity: VisualDensity.compact,
                  onPressed: widget.onCancelRefresh,
                  icon: SizedBox.square(
                    dimension: 15,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.6,
                      color: signalColor(scheme),
                    ),
                  ),
                )
              else if (workspace && widget.onRefreshWorkspace != null)
                IconButton(
                  key: const Key('review-refresh'),
                  tooltip: l10n.envRefresh,
                  visualDensity: VisualDensity.compact,
                  onPressed: widget.onRefreshWorkspace,
                  icon: const Icon(AppIcons.refresh, size: 17),
                ),
              if (!widget.page)
                IconButton(
                  key: const Key('review-close'),
                  tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                  visualDensity: VisualDensity.compact,
                  onPressed: widget.onClose,
                  icon: const Icon(AppIcons.panel_right_close, size: 18),
                ),
            ],
          ),
          if (widget.workspaceAvailable) ...[
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: GlassSegmented<ReviewSource>(
                key: const Key('review-source'),
                height: 32,
                selected: _source,
                onChanged: (source) => setState(() {
                  _source = source;
                  _edit = null;
                  _path = null;
                  _whole = false;
                  _browsing = false;
                }),
                segments: [
                  GlassSegment(
                    key: const Key('review-source-session'),
                    value: ReviewSource.session,
                    label: l10n.reviewSessionSource,
                  ),
                  GlassSegment(
                    key: const Key('review-source-workspace'),
                    value: ReviewSource.workspace,
                    label: l10n.reviewWorkspaceSource,
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (!unread)
                  Text(
                    l10n.envFilesChanged(entries.length),
                    style: theme.textTheme.labelMedium?.copyWith(color: muted),
                  ),
                if (entries.isNotEmpty)
                  ChangeCounts(
                    added: added,
                    removed: removed,
                    fontSize: theme.textTheme.labelMedium?.fontSize ?? 12,
                    fontWeight: theme.textTheme.labelMedium?.fontWeight,
                    gap: 6,
                  ),
                if (workspace && widget.branch != null)
                  Text(
                    '${widget.branch} → origin/${widget.branch}',
                    style: theme.textTheme.labelSmall?.copyWith(color: muted),
                  ),
                if (edit != null)
                  InputChip(
                    key: const Key('review-edit-filter'),
                    label: Text(l10n.reviewEdit(edit.index)),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    deleteIcon: const Icon(AppIcons.close, size: 14),
                    onDeleted: () => setState(() {
                      _edit = null;
                      _whole = false;
                      _browsing = false;
                    }),
                    deleteButtonTooltipMessage: l10n.reviewAllEdits,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _fileDetail(
    BuildContext context,
    AppLocalizations l10n,
    ({List<ReviewDiffSection> sections, Set<int> changed}) open, {
    required bool showBack,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = scheme.onSurfaceVariant;
    final path = _path!;
    final parts = splitReviewPath(path, widget.root);
    final added = open.sections.fold(0, (n, s) => n + s.file.added);
    final removed = open.sections.fold(0, (n, s) => n + s.file.removed);
    final load = widget.onLoadFile;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(showBack ? 4 : 14, 6, 6, 6),
          child: Row(
            children: [
              if (showBack || _whole)
                IconButton(
                  key: const Key('review-file-back'),
                  tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(AppIcons.arrow_back, size: 18),
                  onPressed: () => setState(() {
                    if (_whole) {
                      _whole = false;
                    } else {
                      _path = null;
                      _browsing = true;
                    }
                  }),
                ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      parts.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall,
                    ),
                    if (parts.folder.isNotEmpty)
                      Text(
                        parts.folder,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: muted,
                        ),
                      ),
                  ],
                ),
              ),
              if (!_whole) ...[
                ChangeCounts(added: added, removed: removed, fontSize: 12),
                const SizedBox(width: 4),
              ],
              IconButton(
                tooltip: l10n.copyPath,
                visualDensity: VisualDensity.compact,
                icon: const Icon(AppIcons.content_copy_outlined, size: 16),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: path));
                  showToastOk(context, l10n.copied);
                },
              ),
              if (load != null)
                IconButton(
                  key: const Key('review-open-file'),
                  tooltip: _whole
                      ? l10n.reviewShowChanges
                      : l10n.reviewOpenFile,
                  visualDensity: VisualDensity.compact,
                  isSelected: _whole,
                  icon: const Icon(AppIcons.file_code, size: 17),
                  onPressed: () => setState(() => _whole = !_whole),
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: _whole && load != null
              ? ReviewFileView(
                  key: ValueKey(('review-whole', path)),
                  path: path,
                  load: load,
                  changed: open.changed,
                  // A refreshed diff of this file means its content moved on.
                  revision: Object.hashAll([
                    for (final section in open.sections)
                      for (final line in section.file.lines) line.text,
                  ]),
                )
              : ReviewFileDiff(
                  key: ValueKey(('review-diff', _source, path)),
                  path: path,
                  sections: open.sections,
                  onLoadFile: _source == ReviewSource.workspace ? load : null,
                ),
        ),
      ],
    );
  }
}
