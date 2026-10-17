part of '../activity_cards.dart';

/// A reviewable file-change card: a low-chrome header (edited file(s) + ±counts)
/// that expands to the colored per-file diff (reusing [DiffFileTile]), so the
/// agent's edits can be reviewed inline. Falls back to copyable path rows when
/// no diff text is present.
class FileChangeCard extends StatefulWidget {
  const FileChangeCard({super.key, required this.item});
  final TranscriptItem item;

  @override
  State<FileChangeCard> createState() => _FileChangeCardState();
}

class _FileChangeCardState extends State<FileChangeCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final muted = scheme.onSurfaceVariant;
    final diff = DiffModel.cached(widget.item.text);
    final hasDiff = !diff.isEmpty;
    final title = widget.item.title.trim();
    final expandable = hasDiff || widget.item.text.trim().isNotEmpty;
    final review = SessionFeatureScope.maybeOf(context)?.onReviewChange;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 3),
      decoration: stepCardDecoration(scheme),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            mouseCursor: clickable,
            onTap: expandable
                ? () => setState(() => _expanded = !_expanded)
                : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Icon(
                    AppIcons.edit_document,
                    size: 17,
                    color: activityTint('fileChange', scheme),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    l10n.toolEdited,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurface,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: monoFontFamily,
                        fontFamilyFallback: monoCjkFallback,
                        fontSize: 12,
                        color: muted,
                      ),
                    ),
                  ),
                  if (hasDiff) ...[
                    ChangeCounts(
                      added: diff.added,
                      removed: diff.removed,
                      gap: 3,
                    ),
                    const SizedBox(width: 4),
                  ],
                  if (hasDiff && review != null)
                    IconButton(
                      key: Key('file-change-review-${widget.item.id}'),
                      tooltip: l10n.openInReview,
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints(
                        minWidth: 30,
                        minHeight: 30,
                      ),
                      padding: EdgeInsets.zero,
                      iconSize: 16,
                      color: muted,
                      icon: const Icon(AppIcons.panel_right_open),
                      onPressed: () => review(widget.item.id),
                    ),
                  if (expandable)
                    Icon(
                      _expanded ? AppIcons.expand_less : AppIcons.expand_more,
                      size: 18,
                      color: muted.withValues(alpha: 0.7),
                    ),
                ],
              ),
            ),
          ),
          if (_expanded)
            DecoratedBox(
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(color: scheme.outlineVariant, width: 0.5),
                ),
              ),
              // Color goes on a Material (not the box) so the diff's
              // ListTile-based tiles paint their ink/background correctly —
              // which also means it has to be opaque, blended over the page.
              child: Material(
                color: Color.alphaBlend(
                  scheme.surfaceContainerLow,
                  scheme.surface,
                ),
                child: hasDiff
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final f in diff.files) DiffFileTile(file: f),
                        ],
                      )
                    : Padding(
                        padding: const EdgeInsets.all(10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            for (final p
                                in widget.item.text
                                    .split('\n')
                                    .map((s) => s.trim())
                                    .where((s) => s.isNotEmpty))
                              _CopyablePath(path: p),
                          ],
                        ),
                      ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A monospace file path with a copy button.
class _CopyablePath extends StatelessWidget {
  const _CopyablePath({required this.path});
  final String path;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: SelectableText(
            path,
            style: const TextStyle(
              fontFamily: monoFontFamily,
              fontFamilyFallback: monoCjkFallback,
              fontSize: 12,
            ),
          ),
        ),
        Tooltip(
          message: AppLocalizations.of(context).copy,
          child: InkResponse(
            mouseCursor: clickable,
            radius: 16,
            onTap: () {
              Clipboard.setData(ClipboardData(text: path));
              showToastOk(context, AppLocalizations.of(context).copied);
            },
            child: Padding(
              padding: const EdgeInsets.all(2),
              child: Icon(AppIcons.copy_outlined, size: 14, color: muted),
            ),
          ),
        ),
      ],
    );
  }
}
