part of '../app_session_screen.dart';

/// The composer's toolbar: attach, permission and model (or an agent's own
/// options), dictation, voice, stop and send, reflowed by the room it has.
extension _SessionComposerToolbar on _AppSessionState {
  Widget _composerToolbar(
    AppLocalizations l10n, {
    required bool inlineModes,
    required List<Widget> modeChips,
    required _AgentTarget? agentTarget,
  }) {
    final touch = !isDesktop;
    // The toolbar's fixed-width members — attach, dictate, voice, send, the
    // stop button while streaming — plus the gaps between them.
    double fixedToolbarWidth(bool dictateInline) =>
        (touch ? 48.0 : 30.0) +
        (dictateInline ? (touch ? 40.0 : 32.0) + 2 : 0) +
        (_caps.voice ? (touch ? 40.0 : 32.0) : 0) +
        (touch ? 48.0 : 32.0) +
        (_streaming ? (touch ? 48.0 : 32.0) + 6 : 0) +
        10;
    return LayoutBuilder(
      // One row where it fits. Attachments collapse into a single `+` menu
      // and the config pills into two chips — no expand/collapse mode to get
      // stuck in. Where their labels would not fit beside the buttons (a
      // phone), an agent's options or the model chip (and then, if needed,
      // the permission chip) move to a line above.
      builder: (context, constraints) {
        // On a card too narrow for it beside the pills (a phone, the review
        // pane open) the microphone lives in the `+` menu; during a take it
        // always shows, since it is the done button.
        final dictateInline =
            _caps.dictation &&
            (constraints.maxWidth >= _AppSessionState._dictationInlineWidth ||
                _dictationTake != DictationTake.idle);
        final fixed = fixedToolbarWidth(dictateInline);
        final permissionRoom = _caps.permissionPresets
            ? math.max(
                touch ? 44.0 : 34.0,
                math.min(
                  constraints.maxWidth * 0.34,
                  constraints.maxWidth - fixed - 96,
                ),
              )
            : 0.0;
        // The height the keyboard leaves, read from the view because the
        // scaffold hides the keyboard from its body. Extra lines for the
        // options are only given where the conversation, and any pending
        // requests above the composer, keep room to spare.
        final openHeight = () {
          final view = MediaQueryData.fromView(View.of(context));
          return view.size.height - view.viewInsets.bottom;
        }();
        final agentOptions = _usesModelMenu
            ? null
            : AgentSessionOptions(
                key: _agentOptionsKey,
                settings: _agentSettings,
                enabled: _agentControlsEnabled,
                // Before the first send the agent's options exist once the
                // session opened ahead for this draft does; until then the
                // capsule says so.
                phase: _agentPhase,
                agentName: _caps.providerName,
                onRetry: _retryAgentSession,
                // Bound to this build's target: a menu opened now answers
                // to it, never to a later conversation.
                onSelectConfig: (id, value) =>
                    _setAgentConfig(agentTarget, id, value),
                onSelectMode: (mode) => _setAgentMode(agentTarget, mode),
                // Only on its own line (below) can it need a second one.
                wrap: openHeight >= 520,
              );
        // An agent's options that cannot all show beside the toolbar's
        // buttons (a phone) take their own line above them, rather than
        // squeezing every label to a fragment or scrolling one away.
        final optionsOwnLine =
            agentOptions != null &&
            openHeight >= 420 &&
            AgentSessionOptions.preferredWidth(context, _agentSettings) >
                constraints.maxWidth - fixed - permissionRoom - 6;
        // The room beside the buttons, less a little slack for rounding.
        final beside = constraints.maxWidth - fixed - 10;
        final permissionWidth = _caps.permissionPresets
            ? _pillWidth(_mode.label(l10n))
            : 0.0;
        // Likewise the model chip on a phone, whose label (model, effort,
        // Plan) would otherwise shrink to its icon beside the permission
        // chip and the buttons, or leave the permission label cut.
        final modelOwnLine =
            touch &&
            openHeight >= 420 &&
            agentOptions == null &&
            (_pillWidth(_modelChipLabel(l10n), chevron: true) >
                    beside - math.min(permissionRoom, permissionWidth) ||
                permissionWidth > permissionRoom);
        // And the permission chip goes up beside it when even the room the
        // model left cannot hold its label (a 320 px phone, large text).
        final permissionUp = modelOwnLine && permissionWidth > beside;
        final permissionInRow = _caps.permissionPresets && !permissionUp;
        final row = Row(
          children: [
            _attachMenu(l10n),
            const SizedBox(width: 2),
            // Bound long permission labels, and never so wide that the model
            // pill is left less than its icon-and-chevron minimum: on a narrow
            // card (the review pane open) both ellipsize instead of
            // overflowing.
            // With the model chip on its own line, the permission chip takes
            // the room it left.
            if (permissionInRow && modelOwnLine)
              Expanded(
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: _permissionChip(l10n),
                ),
              )
            else if (permissionInRow)
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: permissionRoom),
                child: _permissionChip(l10n),
              ),
            if (inlineModes)
              for (final chip in modeChips) ...[const SizedBox(width: 4), chip],
            const SizedBox(width: 4),
            // Right-aligned next to send, taking whatever is left.
            if (!(permissionInRow && modelOwnLine))
              Expanded(
                child: Align(
                  alignment: Alignment.centerRight,
                  // The model menu exists only where the protocol has a
                  // catalog and no per-session options; an agent's own
                  // options (ACP, native OpenCode) replace it.
                  child: optionsOwnLine || modelOwnLine
                      ? const SizedBox.shrink()
                      : agentOptions ?? _modelChip(l10n),
                ),
              ),
            // Speech to text into the draft. Teal and a microphone, where the
            // live voice call beside it is the blue waveform: two different
            // things, and they look it.
            if (dictateInline) ...[
              DictationButton(
                line: _dictation,
                onStart: _startDictation,
                onFinish: _finishDictation,
                // A live call already holds the microphone.
                enabled: !_voice.busy && !_externalWriterMode,
                size: touch ? 40 : 32,
                iconSize: touch ? 22 : 18,
              ),
              const SizedBox(width: 2),
            ],
            // Native live voice only; absent rather than disabled elsewhere.
            if (_caps.voice)
              IconButton(
                key: const Key('voice-start'),
                tooltip: _isVoiceThread
                    ? l10n.voiceStart
                    : l10n.voiceNewSession,
                // A take in progress finishes first; the call needs the mic.
                onPressed: _canStartVoice && !_dictation.taking
                    ? _startVoice
                    : null,
                icon: Icon(AppIcons.graphic_eq, size: touch ? 22 : 18),
                // 40 px on touch: two buttons beside send must still leave
                // the model pill room on a 320 px phone.
                style: IconButton.styleFrom(
                  minimumSize: Size.square(touch ? 40 : 32),
                  fixedSize: Size.square(touch ? 40 : 32),
                  padding: EdgeInsets.zero,
                ),
              ),
            const SizedBox(width: 4),
            if (_streaming) ...[_stopButton(l10n), const SizedBox(width: 6)],
            _sendButton(),
          ],
        );
        // Turn modes that do not ride in the row take the line above it,
        // shared with the model chip when that moved up too, so a phone's
        // composer spends one line on them, not two.
        final modes = !inlineModes && modeChips.isNotEmpty
            ? Wrap(spacing: 6, runSpacing: 4, children: modeChips)
            : null;
        if (!optionsOwnLine && !modelOwnLine) {
          if (modes == null) return row;
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [modes, const SizedBox(height: 6), row],
          );
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (agentOptions != null) ...[
              if (modes != null) ...[modes, const SizedBox(height: 6)],
              agentOptions,
            ] else
              Wrap(
                spacing: 6,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (!inlineModes) ...modeChips,
                  if (permissionUp) _permissionChip(l10n),
                  _modelChip(l10n),
                ],
              ),
            const SizedBox(height: 6),
            row,
          ],
        );
      },
    );
  }
}
