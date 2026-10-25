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

  /// The keyboard's height at the last metrics change, to see it go away.
  double keyboard = 0;

  /// Confirms, a moment after the keyboard went away, that it stayed away.
  Timer? keyboardGone;

  void dispose() {
    keyboardGone?.cancel();
    overlay.dispose();
  }
}

extension _SessionComposerFoot on _AppSessionState {
  /// How long the keyboard must stay away before the field lets go: an input
  /// method switching layouts can hide it for a moment.
  static const _keyboardSettle = Duration(milliseconds: 250);

  ValueNotifier<double> get _composerOverlay => _foot.overlay;
  double get _composerBlock => _foot.block;

  /// Below this window height the conversation keeps its room, whatever the
  /// platform (a phone in landscape, a split screen, a short desktop window):
  /// the composer folds and the status line rides in the title row.
  static const _shortHeight = 560.0;

  /// Whether the window is too short for the composer and the status strip
  /// to stand open beside the conversation.
  bool get _shortWindow => MediaQuery.sizeOf(context).height < _shortHeight;

  /// The status line sits in the title row instead of a strip of its own: a
  /// short window, unless the title is being edited there.
  bool get _inlineStatus => _shortWindow && !_editingTitle;

  /// Measured room, not the platform, decides: a narrow window (a phone, a
  /// slim desktop window) or a short one folds the composer. A read-only
  /// view shows one action in its place, which never folds.
  bool get _composerFoldable =>
      (MediaQuery.sizeOf(context).width < 720 || _shortWindow) &&
      !_externalWriterMode;

  /// Whether the composer shows as its capsule: on a phone, whenever no one
  /// is writing — the field has no focus, no dictation take runs and the
  /// full editor is closed. Reaching the end of the conversation, jumping to
  /// it or a reply arriving leaves it folded; focusing the field (a tap on
  /// the capsule) unfolds it, and letting go folds it again.
  bool get _composerFolded =>
      _composerFoldable &&
      !_inputFocus.hasFocus &&
      !_editorOpen &&
      _dictationTake == DictationTake.idle;

  /// The window's metrics changed: keep the conversation's end in view as
  /// the keyboard opens, and when it is put away while the field keeps focus
  /// (Android's back button does that) let the field go, so the composer
  /// folds as it would after any other end of typing.
  void _onMetrics() {
    _repinForKeyboard();
    final view = View.maybeOf(context);
    if (view == null || isDesktop) return;
    final keyboard = view.viewInsets.bottom;
    final hidden = _foot.keyboard > 0 && keyboard == 0;
    _foot.keyboard = keyboard;
    if (!hidden || !_inputFocus.hasFocus) return;
    _foot.keyboardGone?.cancel();
    _foot.keyboardGone = Timer(_keyboardSettle, () {
      // Still away, in front, and nobody dictating: typing is over. Another
      // app in front (a photo picker) hides the keyboard without that.
      final lifecycle = WidgetsBinding.instance.lifecycleState;
      if (mounted &&
          _composerFoldable &&
          _inputFocus.hasFocus &&
          _dictationTake == DictationTake.idle &&
          (lifecycle == null || lifecycle == AppLifecycleState.resumed) &&
          View.maybeOf(context)?.viewInsets.bottom == 0) {
        _inputFocus.unfocus();
      }
    });
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
                // Talking needs no keyboard: the call starts from here.
                if (_caps.voice && !_streaming)
                  ListenableBuilder(
                    listenable: _voice,
                    builder: (context, _) => IconButton(
                      key: const Key('folded-voice-start'),
                      tooltip: l10n.voiceStart,
                      onPressed: _canStartVoice && !_dictation.taking
                          ? _startVoice
                          : null,
                      icon: Icon(
                        AppIcons.graphic_eq,
                        size: 20,
                        color: _canStartVoice
                            ? signalColor(scheme)
                            : scheme.onSurfaceVariant,
                      ),
                      style: IconButton.styleFrom(
                        fixedSize: const Size.square(40),
                        minimumSize: const Size.square(40),
                        padding: EdgeInsets.zero,
                      ),
                    ),
                  ),
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
