import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/voice/voice_controller.dart';
import 'package:pocox/src/voice/waveform.dart';
import 'package:pocox/src/app_icons.dart';

import 'package:pocox/src/motion.dart';
import 'package:pocox/src/theme.dart';
import 'package:pocox/src/widgets/glass.dart';

export 'package:pocox/src/voice/voice_start_sheet.dart';

/// What the call is doing, in one line: connection state first, then who
/// holds the floor. Shared by the panel above the composer and the sidebar
/// status entry so the two never disagree.
String voiceStatusLabel(AppLocalizations l, VoiceController c) =>
    switch (c.phase) {
      VoicePhase.connecting => l.voiceConnecting,
      VoicePhase.reconnecting => l.voiceReconnecting,
      VoicePhase.active when c.muted => l.voiceMuted,
      VoicePhase.active => switch (c.turn) {
        VoiceTurn.user => l.voiceUserSpeaking,
        VoiceTurn.assistant => l.voiceSpeaking,
        VoiceTurn.listening => l.voiceListening,
      },
      VoicePhase.stopping => l.voiceStopping,
      VoicePhase.failed => l.voiceFailedShort,
      VoicePhase.idle => switch (c.endedReason) {
        final reason? => l.voiceEndedReason(reason),
        null => c.endedByUser ? l.voiceEndedByUser : l.voiceSessionEnded,
      },
    };

/// A call's live waveform: the louder of the microphone and the assistant,
/// so the bars move with whoever is talking. Flat while muted.
class CallWaveform extends StatefulWidget {
  /// Draws [controller]'s levels.
  const CallWaveform({
    super.key,
    required this.controller,
    required this.color,
    this.bars = 12,
    this.height = 16,
    this.barWidth = 2,
    this.gap = 1.5,
  });

  /// The call.
  final VoiceController controller;

  /// Bar colour.
  final Color color;

  /// Bars of history.
  final int bars;

  /// Height of the tallest bar.
  final double height;

  /// Width of a bar.
  final double barWidth;

  /// Gap between bars.
  final double gap;

  @override
  State<CallWaveform> createState() => _CallWaveformState();
}

class _CallWaveformState extends State<CallWaveform> {
  final _level = ValueNotifier<double>(0);

  @override
  void initState() {
    super.initState();
    widget.controller.levels.addListener(_sync);
  }

  @override
  void didUpdateWidget(CallWaveform old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.levels.removeListener(_sync);
      widget.controller.levels.addListener(_sync);
    }
  }

  void _sync() {
    final l = widget.controller.levels.value;
    _level.value = math.max(l.input, l.output);
  }

  @override
  void dispose() {
    widget.controller.levels.removeListener(_sync);
    _level.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Waveform(
    key: const Key('voice-waveform'),
    level: _level,
    color: widget.color,
    bars: widget.bars,
    height: widget.height,
    barWidth: widget.barWidth,
    gap: widget.gap,
    active: !widget.controller.muted,
  );
}

/// A call's controls and live state, docked above the composer where the
/// eye and thumb already are, on a phone and a desktop alike: what the call
/// is (a voice conversation, or voice inside the typed one), who holds the
/// floor, what was just said, and mute and hang-up as large round buttons.
///
/// [owned] is whether the controller's call belongs to the conversation on
/// screen. A voice conversation keeps the dock at rest, ready to talk again;
/// in a typed one ([here]) it shows for the call and lingers briefly after
/// it ends, so the outcome registers — a failure until it is dismissed.
class VoiceCallDock extends StatefulWidget {
  /// Creates the dock for [controller].
  const VoiceCallDock({
    super.key,
    required this.controller,
    required this.owned,
    required this.here,
    required this.onHistory,
    required this.onStart,
  });

  /// The call.
  final VoiceController controller;

  /// Whether the call belongs to the conversation on screen.
  final bool owned;

  /// Whether that conversation is a typed one the call joined.
  final bool here;

  /// Open the spoken history.
  final VoidCallback onHistory;

  /// Start (again); null while that is not possible.
  final VoidCallback? onStart;

  @override
  State<VoiceCallDock> createState() => _VoiceCallDockState();
}

class _VoiceCallDockState extends State<VoiceCallDock> {
  // An ended call in a typed conversation lingers this long.
  static const _linger = Duration(seconds: 6);
  Timer? _hide;
  bool _showEnded = false;
  VoicePhase? _last;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_phase);
  }

  @override
  void didUpdateWidget(VoiceCallDock old) {
    super.didUpdateWidget(old);
    if (!identical(old.controller, widget.controller)) {
      old.controller.removeListener(_phase);
      widget.controller.addListener(_phase);
    }
  }

  @override
  void dispose() {
    _hide?.cancel();
    widget.controller.removeListener(_phase);
    super.dispose();
  }

  void _phase() {
    final phase = widget.controller.phase;
    if (phase == _last) return;
    final wasLive = _last != null && _last != VoicePhase.idle;
    _last = phase;
    _hide?.cancel();
    final ended = phase == VoicePhase.idle || phase == VoicePhase.failed;
    if (ended && wasLive) {
      setState(() => _showEnded = true);
      if (phase == VoicePhase.idle) {
        _hide = Timer(_linger, () {
          if (mounted) setState(() => _showEnded = false);
        });
      }
    } else if (!ended) {
      setState(() => _showEnded = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final c = widget.controller;
      final live = widget.owned && (c.busy || c.phase == VoicePhase.stopping);
      final visible =
          live ||
          (widget.owned && _showEnded) ||
          // A voice conversation always offers to talk.
          !widget.here;
      return AnimatedSize(
        duration: Motion.of(context, Motion.medium),
        curve: Motion.emphasized,
        alignment: Alignment.bottomCenter,
        child: visible
            ? _body(context, c)
            : const SizedBox(width: double.infinity),
      );
    },
  );

  Widget _body(BuildContext context, VoiceController c) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final owned = widget.owned;
    final phase = owned ? c.phase : VoicePhase.idle;
    final failed = phase == VoicePhase.failed;
    final connecting =
        phase == VoicePhase.connecting || phase == VoicePhase.reconnecting;
    final busy = owned && c.busy;
    final tone = failed
        ? scheme.error
        : phase == VoicePhase.reconnecting
        ? cautionColor(scheme)
        : busy
        ? signalColor(scheme)
        : scheme.onSurfaceVariant;
    // A voice conversation opened from the list has had no call here yet.
    final label = owned ? voiceStatusLabel(l, c) : l.voiceLive;
    final caption = owned ? _caption(l, c) : null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
      child: Glass(
        key: const Key('voice-dock'),
        depth: GlassDepth.floating,
        borderRadius: BorderRadius.circular(24),
        edge: busy || failed ? tone.withValues(alpha: 0.45) : null,
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(
                  widget.here
                      ? AppIcons.chat_bubble_outline
                      : AppIcons.graphic_eq,
                  size: 14,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    widget.here ? l.voiceModeHere : l.voiceModeConversation,
                    key: const Key('voice-dock-mode'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                IconButton(
                  key: const Key('voice-history'),
                  tooltip: l.voiceHistory,
                  onPressed: widget.onHistory,
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    AppIcons.history,
                    size: 18,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                if (!busy && widget.here)
                  IconButton(
                    key: const Key('voice-dock-dismiss'),
                    tooltip: MaterialLocalizations.of(context).closeButtonLabel,
                    onPressed: () => setState(() => _showEnded = false),
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      AppIcons.close_rounded,
                      size: 18,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Column(
                children: [
                  const SizedBox(height: 2),
                  SizedBox(
                    height: 40,
                    child: Center(
                      child: connecting
                          ? SizedBox.square(
                              dimension: 22,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: tone,
                              ),
                            )
                          : CallWaveform(
                              controller: c,
                              color: tone,
                              bars: 28,
                              height: 36,
                              barWidth: 3,
                              gap: 3,
                            ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  AnimatedSwitcher(
                    duration: Motion.of(context, Motion.fast),
                    child: Text(
                      label,
                      key: ValueKey(label),
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: failed ? scheme.error : scheme.onSurface,
                      ),
                    ),
                  ),
                  if (caption != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      caption,
                      key: const Key('voice-dock-caption'),
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  if (owned && c.error != null)
                    Theme(
                      data: theme.copyWith(dividerColor: Colors.transparent),
                      child: ExpansionTile(
                        title: Text(
                          l.voiceErrorDetails,
                          style: theme.textTheme.bodySmall,
                        ),
                        tilePadding: EdgeInsets.zero,
                        dense: true,
                        children: [SelectableText(c.error!)],
                      ),
                    ),
                  const SizedBox(height: 12),
                  if (busy)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _RoundAction(
                          key: const Key('voice-mute'),
                          icon: c.muted ? AppIcons.mic_off : AppIcons.mic,
                          label: c.muted ? l.voiceUnmute : l.voiceMute,
                          size: 52,
                          foreground: c.muted ? scheme.error : scheme.onSurface,
                          background: c.muted
                              ? scheme.error.withValues(alpha: 0.14)
                              : scheme.onSurface.withValues(alpha: 0.08),
                          onPressed:
                              phase == VoicePhase.active ||
                                  phase == VoicePhase.reconnecting
                              ? c.toggleMuted
                              : null,
                        ),
                        const SizedBox(width: 28),
                        _RoundAction(
                          key: const Key('voice-stop'),
                          icon: AppIcons.call_end,
                          label: l.voiceHangUp,
                          size: 60,
                          foreground: Colors.white,
                          background: const Color(0xFFD93A3A),
                          onPressed: c.hangUp,
                        ),
                      ],
                    )
                  else if (phase != VoicePhase.stopping)
                    FilledButton.icon(
                      key: const Key('voice-again'),
                      onPressed: widget.onStart,
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(200, 46),
                      ),
                      icon: const Icon(AppIcons.mic, size: 20),
                      label: Text(
                        owned && phase != VoicePhase.idle || _showEnded
                            ? l.voiceTalkAgain
                            : l.voiceStartTalking,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The last thing said, by whom: the line being spoken, else the last
  /// finished one.
  String? _caption(AppLocalizations l, VoiceController c) {
    final last = c.partial.entries.lastOrNull;
    final text = (last?.value ?? c.transcript.lastOrNull?.text)?.trim();
    if (text == null || text.isEmpty) return null;
    final role = last?.key ?? c.transcript.lastOrNull?.role;
    final who = role == 'user' ? l.voiceYou : l.voiceAgent;
    return '$who · $text';
  }
}

/// A large round call button with its name under it, as on a phone call.
class _RoundAction extends StatelessWidget {
  const _RoundAction({
    super.key,
    required this.icon,
    required this.label,
    required this.size,
    required this.foreground,
    required this.background,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final double size;
  final Color foreground;
  final Color background;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: label,
          onPressed: onPressed,
          icon: Icon(icon, size: size * 0.42),
          style: IconButton.styleFrom(
            fixedSize: Size.square(size),
            minimumSize: Size.square(size),
            padding: EdgeInsets.zero,
            foregroundColor: foreground,
            backgroundColor: background,
            disabledBackgroundColor: background.withValues(alpha: 0.4),
          ),
        ),
        const SizedBox(height: 6),
        ExcludeSemantics(
          child: Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

/// Canonical persisted speech history, loaded in bounded upstream pages.
class VoiceHistoryDialog extends StatefulWidget {
  const VoiceHistoryDialog({
    super.key,
    required this.api,
    required this.serviceKey,
    required this.threadId,
  });
  final BridgeApi api;
  final String serviceKey;
  final String threadId;
  @override
  State<VoiceHistoryDialog> createState() => _VoiceHistoryDialogState();
}

class _VoiceHistoryDialogState extends State<VoiceHistoryDialog> {
  final _entries = <Map<String, dynamic>>[];
  final _entryIds = <String>{};
  String? _cursor;
  bool _loading = false;
  bool _more = true;
  String? _error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_loading || !_more) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final raw = await widget.api.appRealtimeRequest(
        widget.serviceKey,
        'thread/timeline/list',
        jsonEncode({
          'threadId': widget.threadId,
          'limit': 100,
          if (_cursor != null) 'cursor': _cursor,
        }),
      );
      final page = jsonDecode(raw) as Map;
      if (!mounted) return;
      setState(() {
        for (final entry in page['data'] as List) {
          if (entry['type'] != 'realtime') continue;
          final item = Map<String, dynamic>.from(entry['item'] as Map);
          if (item['type'] == 'transcriptSegment' &&
              item['id'] is String &&
              _entryIds.add(item['id'] as String)) {
            _entries.add(item);
          }
        }
        _cursor = page['nextCursor'] as String?;
        _more = _cursor != null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l.voiceHistory),
      content: SizedBox(
        width: 560,
        height: MediaQuery.sizeOf(context).height * .55,
        child: ListView.builder(
          itemCount: _entries.length + 1,
          itemBuilder: (context, index) {
            if (index < _entries.length) {
              final item = _entries[index];
              return ListTile(
                title: Text(item['role'] == 'user' ? l.voiceYou : l.voiceAgent),
                subtitle: SelectableText(item['text'] as String? ?? ''),
              );
            }
            return Column(
              children: [
                if (_entries.isEmpty && !_loading && _error == null)
                  Text(l.voiceHistoryEmpty),
                if (_error != null) Text(_error!),
                if (_loading)
                  const LinearProgressIndicator()
                else if (_more)
                  TextButton(
                    onPressed: _load,
                    child: Text(_error == null ? l.voiceHistoryMore : l.retry),
                  ),
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(MaterialLocalizations.of(context).closeButtonLabel),
        ),
      ],
    );
  }
}
