part of '../app_session_screen.dart';

extension _SessionKeyboard on _AppSessionState {
  /// Global key hook (desktop), active only while the composer is focused:
  ///   • Ctrl/Cmd+V → also attach a clipboard image/file (returns false so the
  ///     text field still handles ordinary text paste).
  ///   • Enter      → send/queue, unless Shift is held or the IME is composing.
  ///   • Esc        → the interrupt / undo / dequeue state machine (returns true
  ///     when it acts, consuming the key).
  /// Gating on composer focus keeps Esc from firing while a dialog/picker is
  /// open (those steal focus), so their own Esc-to-dismiss still works.
  bool _onHardwareKey(KeyEvent e) {
    if (e is KeyDownEvent && _onWindowShortcut(e.logicalKey)) return true;
    if (e is! KeyDownEvent ||
        (!_inputFocus.hasFocus && !_expandedInputFocus.hasFocus)) {
      return false;
    }
    final key = e.logicalKey;
    // During a take the keys answer the take: Enter is done (the draft is
    // reviewed before it is sent), Esc discards what the take wrote.
    if (_dictation.taking) {
      if (key == LogicalKeyboardKey.enter ||
          key == LogicalKeyboardKey.numpadEnter) {
        _finishDictation();
        return true;
      }
      if (key == LogicalKeyboardKey.escape) {
        _cancelDictation();
        return true;
      }
    }
    if (key == LogicalKeyboardKey.keyV && _isCtrlOrCmdDown()) {
      unawaited(_onClipboardPaste());
      return false; // never consume — text paste must still fire
    }
    if (_editorOpen) return false;
    if (_onPaletteKey(key)) return true;
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      if (_input.value.composing.isValid &&
          !_input.value.composing.isCollapsed) {
        return false;
      }
      if (HardwareKeyboard.instance.isShiftPressed) return false;
      _submit();
      return true;
    }
    if (key == LogicalKeyboardKey.escape) {
      return _onEscape();
    }
    return false;
  }

  /// Window-level desktop shortcuts, live wherever focus is while this screen
  /// is the top route (a dialog or a pushed page above it silences them):
  ///
  /// - ⌘N / Ctrl+N: new conversation in the current project
  /// - ⌘B / Ctrl+B (and ⌃⌘S, the macOS sidebar chord): toggle the sidebar
  /// - ⌘L / Ctrl+L: focus the composer
  /// - ⌘K / Ctrl+K: search conversations (opens the sidebar if hidden)
  /// - Ctrl+Tab / Ctrl+Shift+Tab: next / previous conversation in the list
  ///
  /// Returns whether the key was consumed.
  bool _onWindowShortcut(LogicalKeyboardKey key) {
    if (!mounted || !(ModalRoute.of(context)?.isCurrent ?? true)) return false;
    final keyboard = HardwareKeyboard.instance;
    final mac = defaultTargetPlatform == TargetPlatform.macOS;
    final primary = mac ? keyboard.isMetaPressed : keyboard.isControlPressed;
    // Ctrl+Tab cycles on both platforms, as in browsers and editors.
    if (key == LogicalKeyboardKey.tab &&
        keyboard.isControlPressed &&
        !keyboard.isAltPressed) {
      return _stepConversation(keyboard.isShiftPressed ? -1 : 1);
    }
    if (mac &&
        key == LogicalKeyboardKey.keyS &&
        keyboard.isMetaPressed &&
        keyboard.isControlPressed) {
      _setLeftOpen(!_leftOpen);
      return true;
    }
    // Ctrl+Shift+Space (Cmd+Shift+Space on macOS) toggles dictation from
    // anywhere in the window, like a push-to-talk key.
    // Without native dictation the shortcut is not claimed at all.
    if (key == LogicalKeyboardKey.space &&
        primary &&
        keyboard.isShiftPressed &&
        !keyboard.isAltPressed &&
        _caps.dictation &&
        !_externalWriterMode &&
        !_editorOpen) {
      if (_dictation.take == DictationTake.listening) {
        _finishDictation();
      } else if (!_dictation.taking) {
        _startDictation();
      }
      return true;
    }
    if (!primary || keyboard.isAltPressed || keyboard.isShiftPressed) {
      return false;
    }
    if (key == LogicalKeyboardKey.keyN) {
      _newConversationInProject(_cwd, context);
      return true;
    }
    if (key == LogicalKeyboardKey.keyB) {
      _setLeftOpen(!_leftOpen);
      return true;
    }
    if (key == LogicalKeyboardKey.keyL) {
      (_editorOpen ? _expandedInputFocus : _inputFocus).requestFocus();
      return true;
    }
    if (key == LogicalKeyboardKey.keyK) {
      if (!_leftOpen) _setLeftOpen(true);
      // The field mounts with the sidebar; focus it once it is built.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _convSearchFocus.requestFocus();
      });
      return true;
    }
    return false;
  }

  /// Open the conversation [delta] rows away from the current one, in the
  /// order the sidebar lists them. False when there is nowhere to go.
  bool _stepConversation(int delta) {
    final order = _visibleConversationOrder;
    if (order.isEmpty) return false;
    final at = order.indexWhere((t) => t.id == _threadId);
    final next = at < 0
        ? (delta > 0 ? 0 : order.length - 1)
        : (at + delta) % order.length;
    final target = order[next];
    if (target.id == _threadId) return false;
    _openThread(target.id, target.cwd);
    return true;
  }

  /// Whether a Ctrl (Win/Linux) or Cmd (macOS) modifier is currently held.
  bool _isCtrlOrCmdDown() {
    final pressed = HardwareKeyboard.instance.logicalKeysPressed;
    return pressed.contains(LogicalKeyboardKey.controlLeft) ||
        pressed.contains(LogicalKeyboardKey.controlRight) ||
        pressed.contains(LogicalKeyboardKey.metaLeft) ||
        pressed.contains(LogicalKeyboardKey.metaRight);
  }

  /// The command list of the shown view's project.
  ({String service, String? project}) get _commandsKey =>
      (service: widget.serviceKey, project: _catalogProject);

  /// The commands the `/` list offers for the draft now; empty when it is
  /// closed.
  List<AgentCommand> _paletteMatches() {
    if (!_caps.commands || _externalWriterMode || _guardianReadOnly) {
      return const [];
    }
    final text = _input.text;
    final query = commandQuery(text);
    if (query == null || text == _paletteDismissed) return const [];
    final commands = ref.read(agentCommandsProvider(_commandsKey)).valueOrNull;
    if (commands == null) return const [];
    return filterCommands(commands, query);
  }

  /// Write [command] into the draft as `/name `; the user adds its
  /// arguments and sends it like any message.
  void _pickCommand(AgentCommand command) {
    final text = '/${command.name} ';
    _input.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _updateState(() {
      _paletteIndex = 0;
      _paletteDismissed = null;
    });
    _inputFocus.requestFocus();
  }

  /// Arrows move through the open `/` list, Enter or Tab picks, Esc closes
  /// it; `true` when the key was the list's.
  bool _onPaletteKey(LogicalKeyboardKey key) {
    final matches = _paletteMatches();
    if (matches.isEmpty) return false;
    final last = matches.length - 1;
    if (key == LogicalKeyboardKey.arrowDown) {
      _updateState(
        () => _paletteIndex = _paletteIndex >= last ? 0 : _paletteIndex + 1,
      );
      return true;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _updateState(
        () => _paletteIndex = _paletteIndex <= 0 ? last : _paletteIndex - 1,
      );
      return true;
    }
    if (key == LogicalKeyboardKey.escape) {
      _updateState(() => _paletteDismissed = _input.text);
      return true;
    }
    final pick =
        key == LogicalKeyboardKey.tab ||
        ((key == LogicalKeyboardKey.enter ||
                key == LogicalKeyboardKey.numpadEnter) &&
            !HardwareKeyboard.instance.isShiftPressed &&
            // A full command name already typed sends with Enter.
            !matches.any((c) => '/${c.name}' == _input.text));
    if (!pick) return false;
    _pickCommand(matches[_paletteIndex.clamp(0, last)]);
    return true;
  }

  /// The `/` list above the composer, following the draft's text.
  Widget _commandPalette() {
    if (!_caps.commands) return const SizedBox.shrink();
    // Read once the list is wanted; kept while the view watches it.
    ref.watch(agentCommandsProvider(_commandsKey));
    return ListenableBuilder(
      listenable: _input,
      builder: (context, _) {
        final matches = _paletteMatches();
        if (matches.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: CommandPalette(
            commands: matches,
            highlighted: _paletteIndex.clamp(0, matches.length - 1),
            onSelect: _pickCommand,
          ),
        );
      },
    );
  }
}
