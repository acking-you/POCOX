part of '../local_session_view_screen.dart';

/// One read-only transcript row: user bubble, agent markdown, a reasoning note,
/// or a command + output block.
class _TranscriptRow extends StatelessWidget {
  const _TranscriptRow({
    super.key,
    required this.item,
    this.images = const [],
    required this.hostImageLoader,
    required this.imageCacheScope,
  });

  final ThreadItem item;

  /// The item's attachments, resolved once by the screen (cached across the
  /// 3s transcript polls).
  final List<ResolvedImage> images;
  final HostImageLoader hostImageLoader;
  final Object imageCacheScope;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (item.itemType == 'autoApprovalReview') {
      return activityRow(
        TranscriptItem(
          id: item.id,
          type: item.itemType,
          title: item.title,
          text: item.text,
        ),
      );
    }
    final request = item.itemType == 'userMessage'
        ? ApprovalReviewRequest.parse(item.text)
        : null;
    final result = item.itemType == 'agentMessage'
        ? ApprovalReviewResult.parse(item.text)
        : null;
    if (request != null || result != null) {
      return ApprovalReviewCard(
        raw: item.text,
        request: request,
        result: result,
      );
    }
    switch (item.itemType) {
      case 'userMessage' when parseRealtimeDelegation(item.text) != null:
        // A Live voice handoff: spoken turns, not a typed message.
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: RealtimeHandoffCard(
            handoff: parseRealtimeDelegation(item.text)!,
          ),
        );
      case 'userMessage':
        // Document attachments ride the text as a trailing path-reference
        // block, and a client with editor context serializes that context
        // ahead of the request; show both as chips/thumbnails and only the
        // typed text (display-only — the rollout on disk is untouched).
        final ide = splitIdeContext(item.text);
        final refs = splitFileRefs(ide.text);
        final shown = [
          ...images,
          for (final f in ide.files)
            if (looksLikeImagePath(f.path)) ResolvedImage.hostFile(f.path),
        ];
        final paths = [
          for (final f in ide.files)
            if (!looksLikeImagePath(f.path)) f.path,
          ...refs.paths,
        ];
        // Cap the bubble to a fraction of the *content* width (the centred
        // column), not the whole screen — otherwise it stretches too wide on a
        // desktop window.
        return LayoutBuilder(
          builder: (context, c) => Align(
            alignment: Alignment.centerRight,
            child: Container(
              margin: const EdgeInsets.symmetric(vertical: 6),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              constraints: BoxConstraints(maxWidth: c.maxWidth * 0.82),
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                borderRadius: BorderRadius.circular(kPanelRadius),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (shown.isNotEmpty)
                    MessageImagesView(
                      images: shown,
                      hostImageLoader: hostImageLoader,
                      cacheScope: imageCacheScope,
                    ),
                  if (shown.isNotEmpty &&
                      (refs.text.isNotEmpty || paths.isNotEmpty))
                    const SizedBox(height: 8),
                  if (paths.isNotEmpty) FileRefChips(paths: paths),
                  if (paths.isNotEmpty && refs.text.isNotEmpty)
                    const SizedBox(height: 8),
                  if (refs.text.isNotEmpty)
                    MessageActions(
                      text: refs.text,
                      isUser: true,
                      child: Text(refs.text),
                    ),
                ],
              ),
            ),
          ),
        );
      case 'agentMessage':
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: MessageActions(
            text: item.text,
            isUser: false,
            child: MarkdownView(data: item.text),
          ),
        );
      case 'reasoning':
        // Reasoning summaries are Markdown prose (they open with a `**bold**`
        // header), so they render as Markdown in a secondary tint rather than
        // as literal text with the asterisks showing.
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: MarkdownView(data: item.text, muted: true),
        );
      case 'modelError':
        return ModelErrorCard(body: item.text);
      case 'reasoningOutput':
        return ReasoningOutputView(text: item.text);
      case 'turnContext':
        return _TurnContextCaption(item: item);
      case 'imageGeneration':
        return GeneratedImageCard(
          item: TranscriptItem(
            id: item.id,
            type: item.itemType,
            title: item.title,
            text: item.text,
            images: images,
            imageUrls: item.images,
          ),
          hostImageLoader: hostImageLoader,
          imageCacheScope: imageCacheScope,
        );
      default: // commandExecution / tool activity
        return _CommandBlock(title: item.title, output: item.text);
    }
  }
}

/// A subtle per-turn caption synthesized from the rollout's `turn_context`
/// record: which model (and effort / plan mode) actually handled the turn
/// that follows — the read-only analogue of the live conversation's per-turn
/// model stamp. The tooltip carries the recorded permissions. `title` is the
/// model id; `text` is a compact JSON object of the remaining settings
/// (parsed defensively — a caption is never worth an error row).
class _TurnContextCaption extends StatelessWidget {
  const _TurnContextCaption({required this.item});

  final ThreadItem item;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    Map<String, dynamic> details = const {};
    try {
      final decoded = jsonDecode(item.text);
      if (decoded is Map<String, dynamic>) details = decoded;
    } catch (_) {
      // Not JSON (e.g. a future host packing something else) — model-only.
    }
    String? str(String key) {
      final v = details[key];
      return (v is String && v.isNotEmpty) ? v : null;
    }

    final effort = ReasoningEffort.fromWire(str('effort'));
    final plan = str('collaborationMode') == 'plan';
    final caption = [
      item.title,
      if (effort != null) effort.label(l10n),
      if (plan) l10n.statePlanMode,
    ].join(' · ');
    // Permissions for the tooltip: the app's preset label when the recorded
    // approval+sandbox pair maps onto one, else the raw wire tokens.
    final approval = str('approvalPolicy');
    final sandbox = str('sandboxMode');
    final preset = PermissionMode.values
        .where((m) => m.approval == approval && m.sandbox == sandbox)
        .firstOrNull;
    final permText = preset?.label(l10n) ?? [?approval, ?sandbox].join(' · ');
    final tooltip = [
      l10n.turnHandledBy(item.title),
      if (permText.isNotEmpty) '${l10n.permissionLabel} · $permText',
    ].join('\n');
    return Align(
      alignment: Alignment.centerLeft,
      child: Tooltip(
        message: tooltip,
        child: Padding(
          // Attach visually to the turn BELOW (the record precedes its turn).
          padding: const EdgeInsets.only(left: 2, top: 10, bottom: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.auto_awesome, size: 11, color: muted),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  caption,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11.5, color: muted),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A monospace command line + its (optional) captured output.
class _CommandBlock extends StatelessWidget {
  const _CommandBlock({required this.title, required this.output});

  final String title;
  final String output;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final mono = TextStyle(
      fontFamily: monoFontFamily,
      fontFamilyFallback: monoCjkFallback,
      fontSize: 12.5,
      color: scheme.onSurface,
    );
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(kPanelRadius),
        border: Border.all(color: scheme.outlineVariant, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(12, 10, 12, output.isEmpty ? 10 : 6),
            child: Row(
              children: [
                Icon(Icons.terminal, size: 15, color: scheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title.isEmpty ? '—' : title,
                    style: mono,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          if (output.isNotEmpty)
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 220),
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
              child: SingleChildScrollView(
                child: Text(
                  output,
                  style: mono.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
