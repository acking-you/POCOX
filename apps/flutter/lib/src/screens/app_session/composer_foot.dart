part of '../app_session_screen.dart';

/// Layout state of what floats over the transcript's foot, and whether the
/// phone composer is folded into its capsule.
class _ComposerFoot {
  /// The height of the composer and the cards above it, which the transcript
  /// reserves as end padding so its last message rests above them. A
  /// notifier: it changes every frame the composer grows, folds or is
  /// dragged, and only the spacer and the overlays placed above it follow.
  final overlay = ValueNotifier<double>(0);

  /// The composer block's own height, inside [overlay].
  double block = 0;

  /// The conversation the composer was folded in; any other opens unfolded.
  String? foldedThread;
  bool folded = false;

  /// How far the current drag has read through the transcript.
  double travel = 0;

  void dispose() => overlay.dispose();
}

extension _SessionComposerFoot on _AppSessionState {
  /// How far a reader drags before the composer folds away. Below a finger's
  /// jitter, above a nudge.
  static const double _foldTravel = 56;

  /// How close to the end still counts as "at the latest message": no fold.
  static const double _foldMargin = 96;

  ValueNotifier<double> get _composerOverlay => _foot.overlay;
  double get _composerBlock => _foot.block;

  /// Phones only: a tablet or desktop window has room for the composer. A
  /// read-only view shows one action in its place, which never folds.
  bool get _composerFoldable =>
      !isDesktop &&
      MediaQuery.sizeOf(context).width < 720 &&
      !_externalWriterMode;

  /// Whether the composer shows as its capsule now.
  bool get _composerFolded =>
      _foot.folded && _foot.foldedThread == _threadId && _composerFoldable;

  /// Fold the composer away for reading, or unfold it for writing. Folding
  /// waits while someone is writing: a focused field, a dictation take or
  /// the full editor.
  void _foldComposer(bool fold) {
    if (!mounted || fold == _composerFolded) return;
    if (fold &&
        (!_composerFoldable ||
            _inputFocus.hasFocus ||
            _editorOpen ||
            _dictationTake != DictationTake.idle)) {
      return;
    }
    _updateState(() {
      _foot
        ..folded = fold
        ..foldedThread = _threadId;
    });
  }

  /// Read the reader's intent from a transcript scroll: dragging through the
  /// conversation away from its end folds the composer; coming to rest at the
  /// end unfolds it, since that is where a reply starts.
  void _foldForScroll(ScrollNotification event) {
    if (!_composerFoldable) return;
    final metrics = event.metrics;
    final fromEnd = metrics.maxScrollExtent - metrics.pixels;
    switch (event) {
      case ScrollStartNotification():
        _foot.travel = 0;
      case ScrollUpdateNotification(:final scrollDelta?, dragDetails: _?):
        _foot.travel += scrollDelta.abs();
        if (_foot.travel >= _foldTravel && fromEnd > _foldMargin) {
          _foldComposer(true);
        }
      case ScrollEndNotification() when fromEnd <= 1:
        _foldComposer(false);
      default:
    }
  }

  /// The capsule the composer folds into: the draft's first line (or what
  /// the field would invite), and Stop while a turn runs. Tapping it anywhere
  /// but Stop focuses the field, which unfolds the composer.
  Widget _foldedComposer(AppLocalizations l10n) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final style = theme.textTheme.bodyLarge!;
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: _input,
      builder: (context, value, _) {
        final draft = value.text.trim().split('\n').first;
        final label = draft.isNotEmpty ? draft : _composerHint(l10n);
        return Semantics(
          key: const Key('composer-folded'),
          button: true,
          label: label,
          hint: l10n.expandComposer,
          onTap: _inputFocus.requestFocus,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 6, 6, 6),
            child: Row(
              children: [
                Expanded(
                  child: ExcludeSemantics(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: style.copyWith(
                        color: draft.isNotEmpty
                            ? scheme.onSurface
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
                if (_attachments.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Icon(
                    AppIcons.attach_file,
                    size: 16,
                    color: scheme.onSurfaceVariant,
                  ),
                  Text(
                    '${_attachments.length}',
                    style: TextStyle(
                      fontSize: 13,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
                const SizedBox(width: 6),
                if (_streaming)
                  _stopButton(l10n, key: const Key('folded-stop-btn'))
                else
                  SizedBox.square(
                    dimension: 40,
                    child: Icon(
                      AppIcons.keyboard_arrow_up,
                      size: 20,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
