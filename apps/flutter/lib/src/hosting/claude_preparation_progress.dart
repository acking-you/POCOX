import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/hosting/claude_environment_group.dart';
import 'package:pocket_codex/src/hosting/editor_block.dart';
import 'package:pocket_codex/src/motion.dart';
import 'package:pocket_codex/src/theme.dart';
import 'package:pocket_codex/src/app_icons.dart';

/// [bytes] in decimal units, as Finder counts them: `0 B`, `840 B`,
/// `3.2 KB`, `12 MB`. One decimal below ten, whole numbers above.
String formatByteCount(int bytes) {
  if (bytes < 1000) return '${math.max(bytes, 0)} B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = bytes / 1000;
  var unit = 0;
  // 999.5 would print as "1000"; it belongs to the next unit.
  while (value >= 999.5 && unit < units.length - 1) {
    value /= 1000;
    unit++;
  }
  final digits = value < 9.95 ? 1 : 0;
  return '${value.toStringAsFixed(digits)} ${units[unit]}';
}

/// [ms] as a clock: `0:42`, `12:05`, `1:02:09`.
String formatElapsed(int ms) {
  final seconds = math.max(ms, 0) ~/ 1000;
  String two(int v) => v.toString().padLeft(2, '0');
  final h = seconds ~/ 3600;
  final m = seconds ~/ 60 % 60;
  final s = seconds % 60;
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
}

/// The preparation of Claude's ACP adapter, as it happens.
///
/// npm discovers dependencies as it goes, so there is no total: the bar is
/// honestly indeterminate, and what is known is shown beside it. That is the
/// stage, the elapsed time, the bytes actually received and the measured
/// speed. Nothing is estimated: no percentage, total or time left. A size
/// appears only once the bridge reports one. The speed shows only while
/// packages can still arrive, and "measuring" until its first sample. A
/// measured zero is shown as zero.
///
/// While downloading, a small trace draws the speeds this card has actually
/// polled during the run (the latest [speedSamples]), with nothing filled in
/// between or beyond them.
///
/// Only the step track is a live region, so assistive technology hears the
/// move to verification once rather than every poll. The bar's motion is
/// paint-only, follows [TickerMode], and holds still (as a hatch) with
/// reduced motion.
class ClaudePreparationProgress extends StatefulWidget {
  /// Creates the progress card for [setup].
  const ClaudePreparationProgress({
    super.key,
    required this.setup,
    this.joined = false,
  });

  /// The preparation as last polled.
  final AcpClaudeSetup setup;

  /// This page follows a run another caller started.
  final bool joined;

  /// How many polled speeds the trace keeps.
  static const speedSamples = 32;

  @override
  State<ClaudePreparationProgress> createState() =>
      _ClaudePreparationProgressState();
}

class _ClaudePreparationProgressState extends State<ClaudePreparationProgress> {
  /// Measured speeds of this run's downloading polls, oldest first.
  final List<int> _speeds = [];
  int? _run;

  AcpClaudeSetup get setup => widget.setup;
  bool get joined => widget.joined;

  /// Record one poll; a rebuild with the same answer records nothing.
  void _record(AcpClaudeSetup s) {
    if (s.run != _run) {
      _run = s.run;
      _speeds.clear();
    }
    final rate = s.downloadBytesPerSecond;
    if (s.running && s.stage == 'downloading' && rate != null) {
      _speeds.add(rate);
      if (_speeds.length > ClaudePreparationProgress.speedSamples) {
        _speeds.removeAt(0);
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _record(widget.setup);
  }

  @override
  void didUpdateWidget(ClaudePreparationProgress old) {
    super.didUpdateWidget(old);
    if (!identical(old.setup, widget.setup)) _record(widget.setup);
  }

  bool get _verifying => setup.running && setup.stage == 'verifying';

  (IconData, String) _heading(AppLocalizations l10n) => switch (setup.state) {
    'done' => (AppIcons.check_circle_outline, l10n.claudePrepareStageDone),
    'failed' => (AppIcons.error_outline, l10n.claudePrepareStageFailed),
    'cancelled' => (AppIcons.block, l10n.claudePrepareStageCancelled),
    _ => switch (setup.stage) {
      'downloading' => (
        AppIcons.downloading,
        l10n.claudePrepareStageDownloading,
      ),
      'verifying' => (
        AppIcons.verified_outlined,
        l10n.claudePrepareStageVerifying,
      ),
      'installing' => (
        AppIcons.inventory_2_outlined,
        l10n.claudePrepareStageInstalling,
      ),
      _ => (AppIcons.hourglass_empty, l10n.claudePrepareStageWorking),
    },
  };

  Color _accent(ColorScheme scheme) => switch (setup.state) {
    'running' => signalColor(scheme),
    'done' => successColor(scheme),
    'failed' => scheme.error,
    _ => scheme.onSurfaceVariant,
  };

  List<Widget> _metrics(AppLocalizations l10n, ColorScheme scheme) {
    final bytes = setup.downloadedBytes;
    final rate = setup.downloadBytesPerSecond;
    // Packages can still arrive: not while verifying, never once it ended.
    final arriving = setup.running && setup.stage == 'downloading';
    return [
      if (bytes != null)
        _Metric(
          key: const Key('claude-prepare-downloaded'),
          icon: AppIcons.download,
          text: l10n.claudePrepareDownloaded(formatByteCount(bytes)),
        ),
      if (arriving && rate != null)
        _Metric(
          key: const Key('claude-prepare-speed'),
          icon: AppIcons.speed,
          text: '${formatByteCount(rate)}/s',
          label: l10n.claudePrepareSpeed('${formatByteCount(rate)}/s'),
          // A stalled transfer reads quieter, but still says zero.
          color: rate == 0 ? scheme.onSurfaceVariant : null,
        )
      else if (arriving && bytes != null)
        _Metric(
          key: const Key('claude-prepare-speed-measuring'),
          icon: AppIcons.speed,
          text: l10n.claudePrepareSpeedMeasuring,
          color: scheme.onSurfaceVariant,
        ),
      if (arriving && _speeds.length >= 2)
        ExcludeSemantics(
          child: SizedBox(
            key: const Key('claude-prepare-speed-trace'),
            width: 96,
            height: 20,
            child: CustomPaint(
              painter: _TracePainter(
                List.of(_speeds),
                line: signalColor(scheme),
                base: scheme.outlineVariant,
                rtl: Directionality.of(context) == TextDirection.rtl,
              ),
            ),
          ),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (icon, title) = _heading(l10n);
    final elapsed = formatElapsed(setup.elapsedMs);
    final metrics = _metrics(l10n, scheme);
    return DecoratedBox(
      decoration: claudePanelDecoration(scheme),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                AnimatedSwitcher(
                  duration: Motion.of(context, Motion.fast),
                  child: Icon(
                    icon,
                    key: ValueKey(icon),
                    size: 18,
                    color: _accent(scheme),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    key: const Key('claude-prepare-title'),
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                const SizedBox(width: 12),
                Semantics(
                  container: true,
                  label: l10n.claudePrepareElapsed(elapsed),
                  child: ExcludeSemantics(
                    child: Text(
                      elapsed,
                      key: const Key('claude-prepare-elapsed'),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _PreparationBar(state: setup.state),
            if (metrics.isNotEmpty) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 16,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: metrics,
              ),
            ],
            if (setup.running) ...[
              const SizedBox(height: 14),
              _Steps(verifying: _verifying),
            ],
            if (joined) ...[
              const SizedBox(height: 10),
              EditorNote(
                l10n.claudePrepareJoined,
                key: const Key('claude-prepare-joined'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// One measured fact: a glyph and a value in steady figures.
class _Metric extends StatelessWidget {
  const _Metric({
    super.key,
    required this.icon,
    required this.text,
    this.label,
    this.color,
  });

  final IconData icon;
  final String text;

  /// What assistive technology reads, when the visible text is terse.
  final String? label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ink = color ?? theme.colorScheme.onSurface;
    return Semantics(
      container: true,
      label: label ?? text,
      child: ExcludeSemantics(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                text,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: ink,
                  fontWeight: FontWeight.w500,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The two honest phases: fetching (resolving, downloading and unpacking
/// interleave, so they are one step) and verifying.
class _Steps extends StatelessWidget {
  const _Steps({required this.verifying});

  final bool verifying;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final fetch = l10n.claudePrepareStepFetch;
    final verify = l10n.claudePrepareStepVerify;
    return Semantics(
      key: const Key('claude-prepare-steps'),
      container: true,
      liveRegion: true,
      label: verifying
          ? l10n.claudePrepareStep(2, 2, verify)
          : l10n.claudePrepareStep(1, 2, fetch),
      child: ExcludeSemantics(
        child: Wrap(
          spacing: 20,
          runSpacing: 8,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _StepMark(verifying ? _Step.done : _Step.active),
                const SizedBox(width: 8),
                Flexible(child: _stepLabel(context, fetch, active: !verifying)),
              ],
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _StepMark(verifying ? _Step.active : _Step.pending),
                const SizedBox(width: 8),
                Flexible(child: _stepLabel(context, verify, active: verifying)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _stepLabel(BuildContext context, String text, {required bool active}) {
    final theme = Theme.of(context);
    return Text(
      text,
      style: theme.textTheme.bodySmall?.copyWith(
        color: active
            ? theme.colorScheme.onSurface
            : theme.colorScheme.onSurfaceVariant,
        fontWeight: active ? FontWeight.w600 : FontWeight.w400,
      ),
    );
  }
}

enum _Step { pending, active, done }

class _StepMark extends StatelessWidget {
  const _StepMark(this.step);

  final _Step step;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (step == _Step.done) {
      return Icon(AppIcons.check_circle, size: 14, color: successColor(scheme));
    }
    final active = step == _Step.active;
    final ring = active ? signalColor(scheme) : scheme.outline;
    return Container(
      width: 14,
      height: 14,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: ring, width: 1.5),
      ),
      child: active
          ? Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(shape: BoxShape.circle, color: ring),
            )
          : null,
    );
  }
}

enum _BarMode { sweep, hatch, full, empty }

/// An indeterminate track: a soft band easing across it while running, a
/// still hatch with reduced motion, and a settled fill once it ends.
class _PreparationBar extends StatefulWidget {
  const _PreparationBar({required this.state});

  final String state;

  @override
  State<_PreparationBar> createState() => _PreparationBarState();
}

class _PreparationBarState extends State<_PreparationBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  );

  void _sync() {
    if (widget.state == 'running' && Motion.ambientAllowed(context)) {
      if (!_c.isAnimating) _c.repeat();
    } else {
      _c.stop();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(_PreparationBar old) {
    super.didUpdateWidget(old);
    if (old.state != widget.state) _sync();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (mode, fill) = switch (widget.state) {
      'running' => (
        Motion.ambientAllowed(context) ? _BarMode.sweep : _BarMode.hatch,
        signalColor(scheme),
      ),
      'done' => (_BarMode.full, successColor(scheme)),
      'failed' => (_BarMode.full, scheme.error),
      _ => (_BarMode.empty, scheme.onSurfaceVariant),
    };
    return ExcludeSemantics(
      child: RepaintBoundary(
        child: SizedBox(
          key: const Key('claude-prepare-bar'),
          height: 6,
          width: double.infinity,
          child: CustomPaint(
            painter: _BarPainter(
              _c,
              mode: mode,
              fill: fill,
              track: scheme.surfaceContainerHighest,
              rtl: Directionality.of(context) == TextDirection.rtl,
            ),
          ),
        ),
      ),
    );
  }
}

class _BarPainter extends CustomPainter {
  _BarPainter(
    this.cycle, {
    required this.mode,
    required this.fill,
    required this.track,
    required this.rtl,
  }) : super(repaint: mode == _BarMode.sweep ? cycle : null);

  final Animation<double> cycle;
  final _BarMode mode;
  final Color fill;
  final Color track;
  final bool rtl;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final radius = Radius.circular(size.height / 2);
    final whole = RRect.fromRectAndRadius(Offset.zero & size, radius);
    canvas.drawRRect(whole, Paint()..color = track);
    switch (mode) {
      case _BarMode.empty:
        return;
      case _BarMode.full:
        canvas.drawRRect(whole, Paint()..color = fill);
        return;
      case _BarMode.hatch:
        canvas
          ..save()
          ..clipRRect(whole);
        final stripe = Paint()
          ..color = fill.withValues(alpha: 0.4)
          ..strokeWidth = 2;
        for (var x = -size.height; x < size.width + size.height; x += 7) {
          canvas.drawLine(
            Offset(x, size.height),
            Offset(x + size.height, 0),
            stripe,
          );
        }
        canvas.restore();
        return;
      case _BarMode.sweep:
        canvas
          ..save()
          ..clipRRect(whole)
          // A faint steady wash keeps the track reading as live between
          // passes of the band.
          ..drawRRect(whole, Paint()..color = fill.withValues(alpha: 0.12));
        final band = math.max(size.width * 0.32, 24.0);
        final travelled =
            (size.width + band) * Curves.easeInOut.transform(cycle.value);
        final left = rtl ? size.width - travelled : travelled - band;
        final rect = Rect.fromLTWH(left, 0, band, size.height);
        canvas
          ..drawRRect(
            RRect.fromRectAndRadius(rect, radius),
            Paint()
              ..shader = LinearGradient(
                colors: [
                  fill.withValues(alpha: 0.2),
                  fill,
                  fill.withValues(alpha: 0.2),
                ],
              ).createShader(rect),
          )
          ..restore();
    }
  }

  @override
  bool shouldRepaint(_BarPainter old) =>
      old.cycle != cycle ||
      old.mode != mode ||
      old.fill != fill ||
      old.track != track ||
      old.rtl != rtl;
}

/// The polled speeds as a line over a hairline baseline, scaled to their own
/// peak; newest at the trailing edge. Static: it changes only with a poll.
class _TracePainter extends CustomPainter {
  _TracePainter(
    this.speeds, {
    required this.line,
    required this.base,
    required this.rtl,
  });

  final List<int> speeds;
  final Color line;
  final Color base;
  final bool rtl;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || speeds.length < 2) return;
    final bottom = size.height - 0.5;
    canvas.drawLine(
      Offset(0, bottom),
      Offset(size.width, bottom),
      Paint()
        ..color = base
        ..strokeWidth = 1,
    );
    final peak = speeds.reduce(math.max);
    final step = size.width / (ClaudePreparationProgress.speedSamples - 1);
    final first = ClaudePreparationProgress.speedSamples - speeds.length;
    Offset point(int i) {
      final x = (first + i) * step;
      final y = peak == 0
          ? bottom
          : bottom - (speeds[i] / peak) * (size.height - 2);
      return Offset(rtl ? size.width - x : x, y);
    }

    final path = Path()..moveTo(point(0).dx, point(0).dy);
    for (var i = 1; i < speeds.length; i++) {
      path.lineTo(point(i).dx, point(i).dy);
    }
    final area = Path.from(path)
      ..lineTo(point(speeds.length - 1).dx, bottom)
      ..lineTo(point(0).dx, bottom)
      ..close();
    canvas
      ..drawPath(area, Paint()..color = line.withValues(alpha: 0.12))
      ..drawPath(
        path,
        Paint()
          ..color = line
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..strokeJoin = StrokeJoin.round
          ..strokeCap = StrokeCap.round,
      );
  }

  @override
  bool shouldRepaint(_TracePainter old) =>
      !listEquals(old.speeds, speeds) ||
      old.line != line ||
      old.base != base ||
      old.rtl != rtl;
}
