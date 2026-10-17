import 'package:flutter/material.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/app_icons.dart';
import 'package:pocket_codex/src/desktop_theme.dart';
import 'package:pocket_codex/src/theme.dart';
import 'package:pocket_codex/src/widgets/search_field.dart';
import 'package:pocket_codex/src/widgets/change_counts.dart';

/// One file in the review's list.
class ReviewFileEntry {
  /// Creates an entry.
  const ReviewFileEntry({
    required this.path,
    required this.added,
    required this.removed,
    this.edits = 0,
    this.created = false,
    this.deleted = false,
  });

  /// The file's path, as the change names it.
  final String path;

  /// Lines added.
  final int added;

  /// Lines removed.
  final int removed;

  /// How many of the conversation's edits touched it; 0 leaves no count.
  final int edits;

  /// Whether the change created it.
  final bool created;

  /// Whether the change deleted it.
  final bool deleted;
}

/// [path] split for display: the file's name, and the folder it is in
/// relative to [root] (empty at the root).
({String name, String folder}) splitReviewPath(String path, String? root) {
  var shown = path;
  final base = root?.replaceAll(RegExp(r'[\\/]+$'), '');
  if (base != null &&
      base.isNotEmpty &&
      shown.length > base.length + 1 &&
      shown.startsWith(base) &&
      (shown[base.length] == '/' || shown[base.length] == '\\')) {
    shown = shown.substring(base.length + 1);
  }
  final cut = shown.lastIndexOf(RegExp(r'[\\/]'));
  return cut < 0
      ? (name: shown, folder: '')
      : (name: shown.substring(cut + 1), folder: shown.substring(0, cut));
}

/// The changed files: each one's name over its folder, with its counts. A
/// filter field appears once the list is long enough to need one.
class ReviewFileList extends StatefulWidget {
  /// Creates the list.
  const ReviewFileList({
    super.key,
    required this.files,
    required this.selected,
    required this.onSelect,
    this.root,
    this.empty,
  });

  /// The files, in order.
  final List<ReviewFileEntry> files;

  /// The file shown beside the list, if any.
  final String? selected;

  /// Called with the path of a file picked.
  final ValueChanged<String> onSelect;

  /// The project folder paths are shown relative to.
  final String? root;

  /// What to say when there are no files.
  final String? empty;

  @override
  State<ReviewFileList> createState() => _ReviewFileListState();
}

class _ReviewFileListState extends State<ReviewFileList> {
  final _filter = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    if (widget.files.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            widget.empty ?? l10n.reviewNoFiles,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(color: muted),
          ),
        ),
      );
    }
    final query = _query.trim().toLowerCase();
    final shown = query.isEmpty
        ? widget.files
        : widget.files
              .where((f) => f.path.toLowerCase().contains(query))
              .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.files.length > 8)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
            child: SearchField(
              key: const Key('review-file-filter'),
              controller: _filter,
              hintText: l10n.reviewFilterFiles,
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 6),
            itemCount: shown.length,
            itemBuilder: (context, i) => _row(context, shown[i]),
          ),
        ),
      ],
    );
  }

  Widget _row(BuildContext context, ReviewFileEntry file) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = scheme.onSurfaceVariant;
    final selected = file.path == widget.selected;
    final parts = splitReviewPath(file.path, widget.root);
    final icon = file.created
        ? AppIcons.file_plus
        : file.deleted
        ? AppIcons.file_minus
        : AppIcons.file_diff;
    final iconColor = file.created
        ? additionColor(scheme)
        : file.deleted
        ? scheme.error
        : muted;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      child: Material(
        color: selected ? scheme.onSurface.withValues(alpha: 0.07) : null,
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          mouseCursor: clickable,
          key: Key('review-file-${file.path}'),
          onTap: () => widget.onSelect(file.path),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 7, 10, 7),
            child: Row(
              children: [
                Icon(icon, size: 16, color: iconColor),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        parts.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: selected
                              ? FontWeight.w600
                              : FontWeight.w500,
                          height: 1.3,
                        ),
                      ),
                      if (parts.folder.isNotEmpty)
                        Text(
                          parts.folder,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: muted,
                            height: 1.3,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (file.edits > 1) ...[
                  Text(
                    AppLocalizations.of(context).reviewEditCount(file.edits),
                    style: theme.textTheme.labelSmall?.copyWith(color: muted),
                  ),
                  const SizedBox(width: 8),
                ],
                ChangeCounts(added: file.added, removed: file.removed),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
