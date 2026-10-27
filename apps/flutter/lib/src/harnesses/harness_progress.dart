import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/harnesses/harness_text.dart';
import 'package:pocox/src/theme.dart';
import 'package:pocox/src/transfer_format.dart';
import 'package:pocox/src/widgets/progress_track.dart';

/// An agent's requested or running update, under its name: a track and one
/// state line.
///
/// The track fills only with a download percentage its installer reported;
/// every other phase, and every silent installer, is indeterminate. The
/// line holds the phase (the live region, so assistive technology hears each
/// move once rather than every reading) and, at the end, what the installer
/// measured: percentage, bytes and speed. Nothing is estimated.
class HarnessProgress extends StatelessWidget {
  /// Creates the progress of [kind]'s update.
  const HarnessProgress({super.key, required this.kind, this.job});

  /// The harness being updated.
  final String kind;

  /// The running update as last read; null while the request starting it is
  /// on its way.
  final HarnessJob? job;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final job = this.job;
    final stage = job == null
        ? l10n.harnessStageUpdating
        : harnessStageText(l10n, job);
    // Measurements describe the current download only.
    final download = job?.stage == 'downloading' ? job?.download : null;
    final bytes = download?.downloadedBytes;
    final total = switch (download?.totalBytes) {
      final total? when total > 0 => total,
      _ => null,
    };
    final rate = download?.bytesPerSecond;
    final double? fraction = switch ((download?.percent, bytes, total)) {
      (final percent?, _, _) => percent / 100,
      (null, final bytes?, final total?) => bytes / total,
      _ => null,
    }?.clamp(0.0, 1.0);
    final measured = [
      if (fraction != null) '${(fraction * 100).floor()}%',
      if (bytes != null)
        total == null
            ? formatByteCount(bytes)
            : '${formatByteCount(bytes)} / ${formatByteCount(total)}',
      if (rate != null) '${formatByteCount(rate)}/s',
    ];
    final small = (theme.textTheme.bodySmall ?? const TextStyle()).copyWith(
      color: scheme.onSurfaceVariant,
    );
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ProgressTrack(
            key: Key('harness-progress-bar-$kind'),
            value: fraction,
            color: signalColor(scheme),
            height: 4,
          ),
          const SizedBox(height: 7),
          Row(
            children: [
              Expanded(
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    stage,
                    key: Key('harness-stage-$kind'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: small.copyWith(
                      color: scheme.onSurface,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
              if (measured.isNotEmpty) ...[
                const SizedBox(width: 12),
                Text(
                  measured.join(' · '),
                  key: Key('harness-progress-metrics-$kind'),
                  style: small.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// How long [job] has run, as a clock (`0:42`) that keeps ticking between
/// reads, on the second.
///
/// It counts from the host's own sample, so the two devices' clocks never
/// meet; an older host without one counts from when this card first saw the
/// run. A late reading never sets it back.
class HarnessElapsed extends StatefulWidget {
  /// Creates the clock of [job].
  const HarnessElapsed({super.key, required this.job});

  /// The running update as last read.
  final HarnessJob job;

  @override
  State<HarnessElapsed> createState() => _HarnessElapsedState();
}

class _HarnessElapsedState extends State<HarnessElapsed> {
  /// The elapsed time when [_since] last restarted.
  late int _base = widget.job.elapsedMs ?? 0;
  final _since = Stopwatch()..start();
  Timer? _tick;

  int get _elapsed => _base + _since.elapsedMilliseconds;

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  /// Tick on the next whole second, so each one shows for a full second.
  void _schedule() {
    _tick?.cancel();
    _tick = Timer(Duration(milliseconds: 1000 - _elapsed % 1000), () {
      if (!mounted) return;
      setState(() {});
      _schedule();
    });
  }

  @override
  void didUpdateWidget(HarnessElapsed old) {
    super.didUpdateWidget(old);
    final sample = widget.job.elapsedMs;
    if (widget.job.run != old.job.run) {
      _base = sample ?? 0;
    } else if (sample != null && sample != old.job.elapsedMs) {
      // Never below the second already shown.
      _base = math.max(sample, _elapsed ~/ 1000 * 1000);
    } else {
      return;
    }
    _since.reset();
    _schedule();
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final time = formatElapsed(_elapsed);
    return Semantics(
      container: true,
      label: AppLocalizations.of(context).harnessElapsed(time),
      child: ExcludeSemantics(
        child: Text(
          time,
          key: Key('harness-elapsed-${widget.job.kind}'),
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ),
    );
  }
}
