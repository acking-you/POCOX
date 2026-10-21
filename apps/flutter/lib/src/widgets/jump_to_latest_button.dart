import 'package:flutter/material.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/app_icons.dart';
import 'package:pocox/src/fonts.dart';
import 'package:pocox/src/motion.dart';
import 'package:pocox/src/theme.dart';
import 'package:pocox/src/widgets/glass.dart';

/// Return to the conversation's end, with a moving ring while work continues.
/// The arrow and touch target stay still; reduced motion keeps a steady ring.
class JumpToLatestButton extends StatelessWidget {
  /// Creates a button whose action stays available even while [running].
  const JumpToLatestButton({
    super.key,
    required this.running,
    required this.onPressed,
  });

  /// Whether the conversation is running here or through a followed writer.
  final bool running;

  /// Return to the latest message and resume following new output.
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final signal = signalColor(scheme);
    return Glass(
      depth: GlassDepth.floating,
      borderRadius: BorderRadius.circular(24),
      lift: 0.6,
      edge: running ? signal.withValues(alpha: 0.3) : null,
      padding: const EdgeInsets.all(2),
      child: Stack(
        alignment: Alignment.center,
        children: [
          IconButton(
            key: const Key('nav-to-bottom'),
            tooltip: running
                ? '${l10n.stateWorking} · ${l10n.jumpToLatest}'
                : l10n.jumpToLatest,
            visualDensity: isDesktop
                ? VisualDensity.compact
                : VisualDensity.standard,
            iconSize: 20,
            padding: const EdgeInsets.all(6),
            constraints: BoxConstraints(
              minWidth: isDesktop ? 34 : 44,
              minHeight: isDesktop ? 34 : 44,
            ),
            color: running ? signal : scheme.onSurfaceVariant,
            onPressed: onPressed,
            icon: const Icon(AppIcons.vertical_align_bottom),
          ),
          if (running)
            Positioned.fill(
              child: IgnorePointer(
                child: ExcludeSemantics(
                  child: Padding(
                    padding: const EdgeInsets.all(2),
                    child: RepaintBoundary(
                      child: CircularProgressIndicator(
                        value: Motion.ambientAllowed(context) ? null : 1,
                        color: signal,
                        strokeWidth: 1.5,
                        strokeCap: StrokeCap.round,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
