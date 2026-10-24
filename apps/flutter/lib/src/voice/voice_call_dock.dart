import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/app_icons.dart';
import 'package:pocox/src/fonts.dart';
import 'package:pocox/src/motion.dart';
import 'package:pocox/src/theme.dart';
import 'package:pocox/src/voice/voice_controller.dart';
import 'package:pocox/src/widgets/app_dialog.dart';
import 'package:pocox/src/widgets/glass.dart';

/// What the call is doing, in one line: connection state first, then who
/// holds the floor. The dock's headline.
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
      VoicePhase.failed => l.voiceFailedShort,
      VoicePhase.idle => switch (c.endedReason) {
        final reason? => l.voiceEndedReason(reason),
        null => c.endedByUser ? l.voiceEndedByUser : l.voiceSessionEnded,
      },
    };

/// A call's controls and live state, docked above the composer where the
/// eye and thumb already are, on a phone and a desktop alike. One glass
/// capsule in the composer's shape: an orb that breathes while the line is
/// open and swells with whoever talks, what the call is doing and for how
/// long, the words being said, and mute and hang-up in thumb reach. The
/// call's colour washes in from behind the orb — blue while it is live,
/// violet while the user holds the floor, amber while the link recovers.
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
  static const _hangUpRed = Color(0xFFD93A3A);
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
      final live = widget.owned && c.busy;
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
    final scheme = Theme.of(context).colorScheme;
    final phase = widget.owned ? c.phase : VoicePhase.idle;
    final lit = (widget.owned && c.busy) || phase == VoicePhase.failed;
    final touch = !isDesktop;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: TweenAnimationBuilder<Color?>(
        tween: ColorTween(end: _tone(scheme, c, phase)),
        duration: Motion.of(context, Motion.medium),
        curve: Motion.move,
        builder: (context, tone, child) => Glass(
          key: const Key('voice-dock'),
          depth: GlassDepth.floating,
          // A capsule, like the composer under it.
          borderRadius: BorderRadius.circular(touch ? 34 : 30),
          edge: lit ? tone!.withValues(alpha: 0.42) : null,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  tone!.withValues(alpha: lit ? 0.18 : 0.08),
                  tone.withValues(alpha: 0),
                ],
                stops: const [0, 0.7],
              ),
            ),
            child: child,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: LayoutBuilder(
            builder: (context, box) => Row(
              children: [
                ExcludeSemantics(
                  child: _VoiceOrb(
                    controller: c,
                    mode: _orbMode(c, phase),
                    color: _tone(scheme, c, phase),
                    size: touch ? 52 : 44,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(child: _summary(context, l, c, phase)),
                const SizedBox(width: 8),
                ..._actions(
                  context,
                  l,
                  c,
                  phase,
                  touch: touch,
                  roomy: box.maxWidth >= 440,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The call's colour: the live blue, turned toward violet while the user
  /// holds the floor, grey while muted, amber while the link recovers and
  /// red once it failed. At rest, the blue that invites a call.
  static Color _tone(ColorScheme scheme, VoiceController c, VoicePhase p) =>
      switch (p) {
        VoicePhase.failed => scheme.error,
        VoicePhase.reconnecting => cautionColor(scheme),
        VoicePhase.active when c.muted => scheme.onSurfaceVariant,
        VoicePhase.active when c.turn == VoiceTurn.user => _userTone(scheme),
        _ => signalColor(scheme),
      };

  static Color _userTone(ColorScheme scheme) {
    final hsl = HSLColor.fromColor(signalColor(scheme));
    return hsl.withHue((hsl.hue + 38) % 360).toColor();
  }

  static _OrbMode _orbMode(VoiceController c, VoicePhase p) => switch (p) {
    VoicePhase.connecting || VoicePhase.reconnecting => _OrbMode.connecting,
    VoicePhase.active when c.muted => _OrbMode.muted,
    VoicePhase.active => _OrbMode.live,
    VoicePhase.failed => _OrbMode.failed,
    VoicePhase.idle => _OrbMode.rest,
  };

  /// What the call is doing and for how long, over the words being said
  /// (or what the call is, before anyone spoke). A tap opens the spoken
  /// history, or a failure's details.
  Widget _summary(
    BuildContext context,
    AppLocalizations l,
    VoiceController c,
    VoicePhase phase,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final owned = widget.owned;
    final quiet = scheme.onSurfaceVariant;
    final error = owned && phase == VoicePhase.failed ? c.error : null;
    final caption = owned ? _caption(l, c) : null;
    final since = owned ? c.connectedAt : null;
    final meta = theme.textTheme.labelMedium?.copyWith(color: quiet);
    final lineStyle = theme.textTheme.bodyMedium?.copyWith(color: quiet);
    final label = owned ? voiceStatusLabel(l, c) : l.voiceLive;
    final Widget line;
    final String lineKind;
    if (error != null) {
      lineKind = 'error';
      line = Text(
        error,
        key: const Key('voice-dock-error'),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: lineStyle,
      );
    } else if (caption != null) {
      lineKind = 'caption-${caption.who}';
      line = LayoutBuilder(
        key: const Key('voice-dock-caption'),
        builder: (context, box) => Row(
          children: [
            // The words keep most of the line at any text size.
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: box.maxWidth * 0.4),
              child: Text(
                caption.who,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: lineStyle?.copyWith(
                  color: scheme.onSurface,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(child: _TailText(caption.text, style: lineStyle)),
          ],
        ),
      );
    } else {
      lineKind = 'mode';
      line = Text(
        widget.here ? l.voiceModeHere : l.voiceModeConversation,
        key: const Key('voice-dock-mode'),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: lineStyle,
      );
    }
    return Tooltip(
      message: error != null ? l.voiceErrorDetails : l.voiceHistory,
      child: InkWell(
        onTap: error != null
            ? () => _showError(context, l, error)
            : widget.onHistory,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LayoutBuilder(
                builder: (context, box) => Row(
                  children: [
                    Flexible(
                      child: _Swap(
                        child: Text(
                          label,
                          key: ValueKey(label),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: error != null
                                ? scheme.error
                                : scheme.onSurface,
                          ),
                        ),
                      ),
                    ),
                    // The status takes what the clock leaves, and the clock
                    // never more than half: no text size overflows the line.
                    if (since != null)
                      ConstrainedBox(
                        constraints: BoxConstraints(maxWidth: box.maxWidth / 2),
                        child: _Elapsed(
                          key: const Key('voice-dock-elapsed'),
                          since: since,
                          until: c.endedAt,
                          style: meta,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 2),
              Row(
                children: [
                  // Which kind of call this is, at a glance, all along.
                  Icon(
                    widget.here
                        ? AppIcons.chat_bubble_outline
                        : AppIcons.graphic_eq,
                    size: 13,
                    color: quiet,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: _Swap(
                      child: KeyedSubtree(key: ValueKey(lineKind), child: line),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Mute and hang-up while the call is up; talking again (and dismissing,
  /// in a typed conversation) once it is over. History rides along where
  /// the capsule has room; elsewhere a tap on the summary opens it.
  List<Widget> _actions(
    BuildContext context,
    AppLocalizations l,
    VoiceController c,
    VoicePhase phase, {
    required bool touch,
    required bool roomy,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final small = touch ? 40.0 : 34.0;
    final history = [
      if (roomy) ...[
        _RoundButton(
          key: const Key('voice-history'),
          icon: AppIcons.history,
          tooltip: l.voiceHistory,
          size: small,
          foreground: scheme.onSurfaceVariant,
          background: Colors.transparent,
          onPressed: widget.onHistory,
        ),
        const SizedBox(width: 4),
      ],
    ];
    if (widget.owned && c.busy) {
      return [
        ...history,
        _RoundButton(
          key: const Key('voice-mute'),
          icon: c.muted ? AppIcons.mic_off : AppIcons.mic,
          tooltip: c.muted ? l.voiceUnmute : l.voiceMute,
          size: touch ? 44 : 36,
          foreground: c.muted ? scheme.error : scheme.onSurface,
          background: c.muted
              ? scheme.error.withValues(alpha: 0.14)
              : scheme.onSurface.withValues(alpha: 0.07),
          onPressed:
              phase == VoicePhase.active || phase == VoicePhase.reconnecting
              ? c.toggleMuted
              : null,
        ),
        SizedBox(width: touch ? 10 : 8),
        _RoundButton(
          key: const Key('voice-stop'),
          icon: AppIcons.call_end,
          tooltip: l.voiceHangUp,
          size: touch ? 52 : 40,
          foreground: Colors.white,
          background: _hangUpRed,
          onPressed: c.hangUp,
        ),
      ];
    }
    // "Again" once this conversation has had a call; "start" before.
    final again =
        widget.owned && (c.connectedAt != null || phase == VoicePhase.failed);
    final talk = again ? l.voiceTalkAgain : l.voiceStartTalking;
    return [
      ...history,
      // The call's own blue, lit like every primary action. A phone's row
      // keeps the room for what happened: the button is the voice icon
      // alone there, named by its tooltip, like the composer's.
      if (roomy)
        FilledButton.icon(
          key: const Key('voice-again'),
          onPressed: widget.onStart,
          style: FilledButton.styleFrom(
            minimumSize: Size(0, touch ? 44 : 36),
            padding: const EdgeInsets.symmetric(horizontal: 16),
            foregroundColor: scheme.onTertiary,
            backgroundColor: signalColor(scheme),
          ),
          icon: const Icon(AppIcons.graphic_eq, size: 18),
          label: Text(talk),
        )
      else
        _RoundButton(
          key: const Key('voice-again'),
          icon: AppIcons.graphic_eq,
          tooltip: talk,
          size: touch ? 44 : 36,
          foreground: scheme.onTertiary,
          background: signalColor(scheme),
          onPressed: widget.onStart,
        ),
      if (widget.here) ...[
        const SizedBox(width: 4),
        _RoundButton(
          key: const Key('voice-dock-dismiss'),
          icon: AppIcons.close_rounded,
          tooltip: MaterialLocalizations.of(context).closeButtonLabel,
          size: small,
          foreground: scheme.onSurfaceVariant,
          background: Colors.transparent,
          onPressed: () => setState(() => _showEnded = false),
        ),
      ],
    ];
  }

  void _showError(BuildContext context, AppLocalizations l, String error) =>
      unawaited(
        showAppDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(l.voiceErrorDetails),
            content: SelectableText(error),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(MaterialLocalizations.of(context).closeButtonLabel),
              ),
            ],
          ),
        ),
      );

  /// The last thing said, by whom: the line being spoken, else the last
  /// finished one.
  ({String who, String text})? _caption(AppLocalizations l, VoiceController c) {
    final last = c.partial.entries.lastOrNull;
    final text = (last?.value ?? c.transcript.lastOrNull?.text)?.trim();
    if (text == null || text.isEmpty) return null;
    final role = last?.key ?? c.transcript.lastOrNull?.role;
    return (who: role == 'user' ? l.voiceYou : l.voiceAgent, text: text);
  }
}

/// A quick cross-fade between lines, held to the start edge so a shorter
/// line does not drift to the middle while the longer one fades.
class _Swap extends StatelessWidget {
  const _Swap({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
    duration: Motion.of(context, Motion.fast),
    layoutBuilder: (current, previous) => Stack(
      alignment: AlignmentDirectional.centerStart,
      children: [...previous, ?current],
    ),
    child: child,
  );
}

/// One line that keeps its end in view: words still being spoken show the
/// newest ones, the start fading out behind the speaker's name.
class _TailText extends StatelessWidget {
  const _TailText(this.text, {this.style});

  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final style = DefaultTextStyle.of(context).style.merge(this.style);
      final line = Text(text, maxLines: 1, softWrap: false, style: style);
      final painter = TextPainter(
        text: TextSpan(text: text, style: style),
        maxLines: 1,
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
      )..layout();
      final fits = painter.width <= box.maxWidth;
      final height = painter.height;
      painter.dispose();
      if (fits) return line;
      return ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (rect) => LinearGradient(
          begin: AlignmentDirectional.centerStart.resolve(
            Directionality.of(context),
          ),
          end: AlignmentDirectional.centerEnd.resolve(
            Directionality.of(context),
          ),
          colors: const [Color(0x00000000), Color(0xFF000000)],
          stops: const [0, 0.18],
        ).createShader(rect),
        child: ClipRect(
          child: SizedBox(
            height: height,
            child: OverflowBox(
              alignment: AlignmentDirectional.centerEnd,
              maxWidth: double.infinity,
              child: line,
            ),
          ),
        ),
      );
    },
  );
}

/// How long a call has run, ticking each second, or how long it ran.
class _Elapsed extends StatefulWidget {
  const _Elapsed({
    super.key,
    required this.since,
    required this.until,
    this.style,
  });

  final DateTime since;
  final DateTime? until;
  final TextStyle? style;

  @override
  State<_Elapsed> createState() => _ElapsedState();
}

class _ElapsedState extends State<_Elapsed> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(_Elapsed old) {
    super.didUpdateWidget(old);
    if (old.until != widget.until) _sync();
  }

  void _sync() {
    _tick?.cancel();
    _tick = widget.until != null
        ? null
        : Timer.periodic(const Duration(seconds: 1), (_) {
            if (mounted) setState(() {});
          });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final run = (widget.until ?? DateTime.now()).difference(widget.since);
    final s = run.isNegative ? 0 : run.inSeconds;
    String two(int n) => n.toString().padLeft(2, '0');
    final clock = s >= 3600
        ? '${s ~/ 3600}:${two(s ~/ 60 % 60)}:${two(s % 60)}'
        : '${s ~/ 60}:${two(s % 60)}';
    // Yields to the status beside it before overflowing the line.
    return Text(
      ' · $clock',
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.clip,
      style: widget.style?.copyWith(
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}

/// A round call control: an icon in a filled circle, named by its tooltip.
class _RoundButton extends StatelessWidget {
  const _RoundButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.size,
    required this.foreground,
    required this.background,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final double size;
  final Color foreground;
  final Color background;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    onPressed: onPressed,
    icon: Icon(icon, size: size * 0.44),
    style: IconButton.styleFrom(
      fixedSize: Size.square(size),
      minimumSize: Size.square(size),
      padding: EdgeInsets.zero,
      foregroundColor: foreground,
      backgroundColor: background,
      disabledForegroundColor: foreground.withValues(alpha: 0.38),
      disabledBackgroundColor: background.withValues(alpha: background.a / 2),
    ),
  );
}

/// What the orb shows.
enum _OrbMode {
  /// Setting up or recovering the link: a ring turns around the core.
  connecting,

  /// Audio flowing: the core breathes, swells with the louder side and
  /// sends ripples out while anyone talks.
  live,

  /// The microphone is off.
  muted,

  /// The call failed.
  failed,

  /// No call: still, inviting one.
  rest,
}

/// The call's living mark: a lit core whose bars and ripples follow the
/// louder of the microphone and the assistant.
class _VoiceOrb extends StatefulWidget {
  const _VoiceOrb({
    required this.controller,
    required this.mode,
    required this.color,
    required this.size,
  });

  final VoiceController controller;
  final _OrbMode mode;
  final Color color;
  final double size;

  @override
  State<_VoiceOrb> createState() => _VoiceOrbState();
}

class _VoiceOrbState extends State<_VoiceOrb>
    with SingleTickerProviderStateMixin {
  // Ripples, bar wobble and the connecting ring all divide this evenly, so
  // the loop has no seam.
  late final AnimationController _loop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  )..addListener(_ease);
  final _level = ValueNotifier<double>(0);
  double _target = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.levels.addListener(_heard);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(_VoiceOrb old) {
    super.didUpdateWidget(old);
    if (!identical(old.controller, widget.controller)) {
      old.controller.levels.removeListener(_heard);
      widget.controller.levels.addListener(_heard);
    }
    _sync();
  }

  void _sync() {
    final moving =
        widget.mode == _OrbMode.live || widget.mode == _OrbMode.connecting;
    if (moving && Motion.ambientAllowed(context)) {
      if (!_loop.isAnimating) _loop.repeat();
    } else if (_loop.isAnimating || _loop.value != 0) {
      _loop
        ..stop()
        ..value = 0;
    }
  }

  void _heard() {
    final l = widget.controller.levels.value;
    _target = math.max(l.input, l.output);
    // Without the loop (reduced motion) the level still shows, unsmoothed.
    if (!_loop.isAnimating) _level.value = _target;
  }

  // Levels arrive about 16 times a second; the frames between glide.
  void _ease() => _level.value += (_target - _level.value) * 0.2;

  @override
  void dispose() {
    widget.controller.levels.removeListener(_heard);
    _loop.dispose();
    _level.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final icon = switch (widget.mode) {
      _OrbMode.live || _OrbMode.muted => null,
      _OrbMode.failed => AppIcons.error_outline,
      _OrbMode.connecting || _OrbMode.rest => AppIcons.graphic_eq,
    };
    // The colour glides with the floor changing hands, as the wash does.
    return TweenAnimationBuilder<Color?>(
      tween: ColorTween(end: widget.color),
      duration: Motion.of(context, Motion.medium),
      curve: Motion.move,
      builder: (context, color, _) => RepaintBoundary(
        child: SizedBox.square(
          dimension: widget.size,
          child: CustomPaint(
            painter: _OrbPainter(
              loop: _loop,
              level: _level,
              mode: widget.mode,
              color: color!,
              ink:
                  ThemeData.estimateBrightnessForColor(color) == Brightness.dark
                  ? Colors.white
                  : const Color(0xFF0E1526),
            ),
            child: icon == null
                ? null
                : Center(
                    child: AnimatedSwitcher(
                      duration: Motion.of(context, Motion.fast),
                      child: Icon(
                        icon,
                        key: ValueKey(icon),
                        size: widget.size * 0.36,
                        color: color,
                      ),
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

class _OrbPainter extends CustomPainter {
  _OrbPainter({
    required this.loop,
    required this.level,
    required this.mode,
    required this.color,
    required this.ink,
  }) : super(repaint: Listenable.merge([loop, level]));

  final Animation<double> loop;
  final ValueListenable<double> level;
  final _OrbMode mode;
  final Color color;
  final Color ink;

  // Bar heights relative to the tallest, so the bars read as a voice
  // rather than a level meter.
  static const _shape = [0.55, 1.0, 0.8, 0.5];

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final outer = size.shortestSide / 2;
    final core = outer * 0.68;
    final t = loop.value;
    final energy = level.value.clamp(0.0, 1.0);
    switch (mode) {
      case _OrbMode.live:
        // Two ripples leave the core in turn: faint while the line only
        // listens, strong while someone talks.
        for (var k = 0; k < 2; k++) {
          final p = (t * 2 + k / 2) % 1;
          final r = core + (outer - core) * Curves.easeOut.transform(p);
          canvas.drawCircle(
            center,
            r,
            Paint()
              ..color = color.withValues(
                alpha: (1 - p) * (0.12 + 0.34 * energy),
              ),
          );
        }
        final swell = core * (1 + 0.1 * energy);
        final body = Rect.fromCircle(center: center, radius: swell);
        canvas.drawCircle(
          center,
          swell,
          Paint()
            ..shader = RadialGradient(
              center: const Alignment(-0.4, -0.5),
              radius: 1.1,
              colors: [Color.lerp(color, Colors.white, 0.3)!, color],
            ).createShader(body),
        );
        _bars(canvas, center, core, ink, t: t, energy: energy, breathe: true);
      case _OrbMode.muted:
        // The voice held: the same bars, flat and grey.
        canvas.drawCircle(
          center,
          core,
          Paint()..color = color.withValues(alpha: 0.16),
        );
        _bars(canvas, center, core, color, t: 0, energy: 0, breathe: false);
      case _OrbMode.connecting:
        canvas.drawCircle(
          center,
          core,
          Paint()..color = color.withValues(alpha: 0.16),
        );
        canvas.drawArc(
          Rect.fromCircle(center: center, radius: (core + outer) / 2),
          t * 4 * math.pi,
          math.pi * 0.6,
          false,
          Paint()
            ..color = color
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.4
            ..strokeCap = StrokeCap.round,
        );
      case _OrbMode.failed || _OrbMode.rest:
        canvas.drawCircle(
          center,
          core,
          Paint()..color = color.withValues(alpha: 0.16),
        );
    }
  }

  /// The voice inside the core: four bars that wobble with [energy] and,
  /// when [breathe] is set, rise and fall a little even in silence.
  void _bars(
    Canvas canvas,
    Offset center,
    double core,
    Color ink, {
    required double t,
    required double energy,
    required bool breathe,
  }) {
    final w = core * 0.17;
    final gap = w * 0.8;
    final span = _shape.length * w + (_shape.length - 1) * gap;
    final bar = Paint()
      ..color = ink
      ..strokeWidth = w
      ..strokeCap = StrokeCap.round;
    // Speech sits around 0.15-0.55 after shaping; that spans the bars.
    final loud = math.min(1.0, energy * 1.4);
    for (var i = 0; i < _shape.length; i++) {
      final x = center.dx - span / 2 + w / 2 + i * (w + gap);
      final wobble = 0.6 + 0.4 * math.sin(2 * math.pi * (t * 3 + i * 0.29));
      final breath = breathe
          ? 0.5 + 0.5 * math.sin(2 * math.pi * (t + i * 0.18))
          : 0.0;
      final reach = core * (0.16 * breath + 1.25 * loud * wobble * _shape[i]);
      canvas.drawLine(
        Offset(x, center.dy - reach / 2),
        Offset(x, center.dy + reach / 2),
        bar,
      );
    }
  }

  @override
  bool shouldRepaint(_OrbPainter old) =>
      old.mode != mode || old.color != color || old.ink != ink;
}
