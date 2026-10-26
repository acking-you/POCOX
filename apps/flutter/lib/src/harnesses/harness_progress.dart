import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/harnesses/harness_text.dart';
import 'package:pocox/src/motion.dart';
import 'package:pocox/src/theme.dart';
import 'package:pocox/src/transfer_format.dart';

/// Progress for every managed harness, including silent installers. Only
/// installer measurements produce percentages or speeds; elapsed time uses
/// the host's sample plus time since receipt, never the two devices' clocks.
class HarnessProgress extends StatefulWidget {
  /// Creates the running job's status bar.
  const HarnessProgress({super.key, required this.job});

  /// The running update as last read from its host.
  final HarnessJob job;

  @override
  State<HarnessProgress> createState() => _HarnessProgressState();
}

class _HarnessProgressState extends State<HarnessProgress> {
  late int _elapsed = widget.job.elapsedMs ?? 0;
  late final Stopwatch _since = Stopwatch()..start();
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void didUpdateWidget(HarnessProgress old) {
    super.didUpdateWidget(old);
    if (widget.job.run != old.job.run ||
        widget.job.elapsedMs != old.job.elapsedMs) {
      _elapsed = widget.job.elapsedMs ?? 0;
      _since.reset();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _since.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final job = widget.job;
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final download = job.stage == 'downloading' ? job.download : null;
    final bytes = download?.downloadedBytes;
    final total = download?.totalBytes;
    final rate = download?.bytesPerSecond;
    final percent = download?.percent;
    final double? fraction = percent != null
        ? (percent / 100).clamp(0.0, 1.0)
        : bytes != null && total != null && total > 0
        ? (bytes / total).clamp(0.0, 1.0)
        : null;
    final metrics = <String>[
      if (fraction != null) '${(fraction * 100).floor()}%',
      if (bytes != null)
        total != null && total > 0
            ? '${formatByteCount(bytes)} / ${formatByteCount(total)}'
            : formatByteCount(bytes),
      if (rate != null) '${formatByteCount(rate)}/s',
      l10n.harnessElapsed(formatElapsed(_elapsed + _since.elapsedMilliseconds)),
    ];
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            liveRegion: true,
            child: Text(
              harnessStageText(l10n, job),
              style: theme.textTheme.bodySmall,
            ),
          ),
          const SizedBox(height: 8),
          if (fraction == null && !Motion.ambientAllowed(context))
            Container(height: 4, color: scheme.surfaceContainerHighest)
          else
            LinearProgressIndicator(
              key: Key('harness-progress-bar-${job.kind}'),
              value: fraction,
              minHeight: 4,
              borderRadius: BorderRadius.circular(2),
              color: signalColor(scheme),
              backgroundColor: scheme.surfaceContainerHighest,
              semanticsLabel: harnessStageText(l10n, job),
            ),
          const SizedBox(height: 8),
          Text(
            metrics.join(' · '),
            key: Key('harness-progress-metrics-${job.kind}'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
