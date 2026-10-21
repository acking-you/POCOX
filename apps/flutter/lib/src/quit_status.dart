import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/error_format.dart';

/// Where an app quit stands while hosted services are being stopped.
@immutable
class QuitStatus {
  /// Hosted services are being stopped; the app exits once they are.
  const QuitStatus.stopping() : stopping = true, error = null;

  /// Stopping could not finish, so the app stayed open; [error] says what
  /// may still run.
  const QuitStatus.blocked(String this.error) : stopping = false;

  /// Still stopping.
  final bool stopping;

  /// Why the quit was not completed.
  final String? error;
}

/// Stop every hosted service for a quit through [stopAll] (the bridge, which
/// bounds its own work and fails when an owned process may still run).
/// `true` only when the app may exit; on failure [status] says why and the
/// app must stay open (a later quit retries).
Future<bool> stopHostingForQuit(
  Future<void> Function() stopAll,
  ValueNotifier<QuitStatus?> status,
) async {
  status.value = const QuitStatus.stopping();
  try {
    await stopAll();
  } catch (e) {
    status.value = QuitStatus.blocked(friendlyError(e));
    return false;
  }
  status.value = null;
  return true;
}

/// Shows a quit in progress, or why it did not complete with a way to try
/// again; nothing otherwise.
class QuitStatusBanner extends StatelessWidget {
  /// Creates the banner for [status]; [onRetry] quits again.
  const QuitStatusBanner({
    super.key,
    required this.status,
    required this.onRetry,
  });

  /// The quit's state.
  final ValueListenable<QuitStatus?> status;

  /// Quit again.
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<QuitStatus?>(
    valueListenable: status,
    builder: (context, value, _) {
      if (value == null) return const SizedBox.shrink();
      final l10n = AppLocalizations.of(context);
      final scheme = Theme.of(context).colorScheme;
      return Material(
        key: const Key('quit-status'),
        color: value.stopping
            ? scheme.surfaceContainerHigh
            : scheme.errorContainer,
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
            child: Row(
              children: [
                if (value.stopping)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                if (value.stopping) const SizedBox(width: 12),
                Expanded(
                  child: Semantics(
                    liveRegion: true,
                    child: Text(
                      value.stopping
                          ? l10n.quitStopping
                          : l10n.quitBlocked(value.error ?? ''),
                      style: TextStyle(
                        color: value.stopping
                            ? scheme.onSurface
                            : scheme.onErrorContainer,
                      ),
                    ),
                  ),
                ),
                if (!value.stopping)
                  TextButton(
                    key: const Key('quit-retry'),
                    onPressed: onRetry,
                    child: Text(l10n.quitRetry),
                  ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
