/// Settings › Updates: the running version, what the last check found, and
/// the one-click update with its progress on the button itself.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/app_icons.dart';
import 'package:pocket_codex/src/theme.dart';
import 'package:pocket_codex/src/time_ago.dart';
import 'package:pocket_codex/src/updates/update_api.dart';
import 'package:pocket_codex/src/updates/update_controller.dart';
import 'package:pocket_codex/src/widgets/action_row.dart';
import 'package:pocket_codex/src/widgets/busy_label.dart';
import 'package:pocket_codex/src/widgets/field_help.dart';
import 'package:pocket_codex/src/widgets/group_card.dart';
import 'package:pocket_codex/src/widgets/icon_badge.dart';

/// The Updates settings group.
class UpdateSettings extends StatelessWidget {
  /// Creates the group.
  const UpdateSettings({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return GroupCard(
      title: l10n.updatesTitle,
      info: l10n.updatesInfo,
      children: const [UpdateRow()],
    );
  }
}

/// The update row: version and state, with the action at its end.
class UpdateRow extends ConsumerWidget {
  /// Creates the row.
  const UpdateRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final state =
        ref.watch(updateStateProvider).valueOrNull ??
        ref.read(updateApiProvider).updateState();
    final actions = ref.read(updateActionsProvider);
    final line = _line(l10n, state);
    final failed = state.phase == 'failed';
    final lead = Row(
      children: [
        IconBadge(
          icon: state.newer ? AppIcons.download : AppIcons.verified_outlined,
          accent: state.newer,
        ),
        const SizedBox(width: 11),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.updateVersion(state.current),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              InfoTitle(
                key: const Key('update-state'),
                title: Text(
                  line,
                  style: helpTextStyle(
                    theme,
                  ).copyWith(color: failed ? cautionColor(scheme) : null),
                ),
                // The underlying error, for a report, behind the mark.
                info: failed || state.failure != null
                    ? state.failureDetail
                    : null,
              ),
            ],
          ),
        ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(13, 10, 12, 10),
      child: ActionRow(
        lead: lead,
        action: Wrap(
          spacing: 8,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: _actions(l10n, scheme, state, actions),
        ),
      ),
    );
  }

  static String _line(AppLocalizations l10n, UpdateState state) {
    final checked = state.checkedAtMs;
    final ago = checked == null
        ? null
        : relativeTime(checked ~/ 1000, DateTime.now(), l10n);
    String withAgo(String text) => ago == null || ago.isEmpty
        ? text
        : '$text · ${l10n.updateCheckedAgo(ago)}';
    final size = state.size;
    final available = [
      l10n.updateAvailable(state.latest ?? ''),
      if (size != null) _megabytes(size),
    ].join(' · ');
    return switch (state.phase) {
      'checking' => l10n.updateChecking,
      'up_to_date' => withAgo(l10n.updateUpToDate),
      'available' || 'ready' || 'installing' => available,
      'downloading' => available,
      'verifying' => available,
      'verified_only' => l10n.updateVerifiedOnly,
      'opened' => l10n.updateOpened,
      'saved' => l10n.updateSaved(state.path ?? ''),
      'failed' => failureText(l10n, state.failure),
      // A background check that failed leaves nothing found: say so,
      // quietly; a known answer stays.
      _ when state.failure != null => l10n.updateCheckFailed,
      _ => l10n.updateNotChecked,
    };
  }

  /// The words for a failure [kind].
  static String failureText(AppLocalizations l10n, String? kind) =>
      switch (kind) {
        'network' => l10n.updateFailedNetwork,
        'signature' => l10n.updateFailedSignature,
        'checksum' => l10n.updateFailedChecksum,
        'verification' => l10n.updateFailedVerification,
        'permission' => l10n.updateFailedPermission,
        'quit' => l10n.updateFailedQuit,
        _ => l10n.updateFailedInstall,
      };

  static String _megabytes(int bytes) =>
      '${(bytes / 1000000).toStringAsFixed(1)} MB';

  /// The primary action's idle label for this installation.
  static String updateLabel(AppLocalizations l10n, UpdateState state) =>
      switch (state.method) {
        'release_page' => l10n.updateReleasePage,
        'save_download' => l10n.updateDownload,
        _ when state.restarts => l10n.updateAndRestart,
        _ => l10n.updateInstall,
      };

  /// What the primary button says while the update runs.
  static String busyLabel(AppLocalizations l10n, UpdateState state) {
    final size = state.size ?? 0;
    return switch (state.phase) {
      'downloading' => l10n.updateDownloading(
        size == 0 ? 0 : (state.received * 100 ~/ size).clamp(0, 100),
      ),
      'verifying' => l10n.updateVerifying,
      _ when state.restarts => l10n.updateRestarting,
      _ => l10n.updateOpening,
    };
  }

  List<Widget> _actions(
    AppLocalizations l10n,
    ColorScheme scheme,
    UpdateState state,
    UpdateActions actions,
  ) {
    final working = const {
      'downloading',
      'verifying',
      'installing',
    }.contains(state.phase);
    // A newer release is offered from the check that found it until it is
    // handed over; a failed attempt is retried the same way.
    if (state.newer || working) {
      final primary = FilledButton(
        key: const Key('update-now'),
        style: FilledButton.styleFrom(
          // Its working colours while it runs (see [BusyLabel]).
          disabledBackgroundColor: working ? scheme.primary : null,
          disabledForegroundColor: working ? scheme.onPrimary : null,
        ),
        onPressed: working ? null : actions.updateNow,
        child: BusyLabel(
          busy: working,
          label: state.phase == 'failed'
              ? _retry(l10n)
              : updateLabel(l10n, state),
          busyLabel: busyLabel(l10n, state),
        ),
      );
      return [
        if (state.phase == 'downloading')
          TextButton(
            key: const Key('update-cancel'),
            onPressed: actions.cancel,
            child: Text(l10n.cancel),
          )
        else if (state.method != 'release_page')
          TextButton(
            key: const Key('update-release-page'),
            onPressed: actions.openPage,
            child: Text(l10n.updateReleasePage),
          ),
        primary,
      ];
    }
    final checking = state.phase == 'checking';
    return [
      OutlinedButton(
        key: const Key('update-check'),
        style: OutlinedButton.styleFrom(
          disabledForegroundColor: checking ? scheme.onSurface : null,
        ),
        onPressed: checking ? null : actions.checkNow,
        child: BusyLabel(
          busy: checking,
          label: state.phase == 'failed' ? _retry(l10n) : l10n.updateCheckNow,
          busyLabel: l10n.updateChecking,
        ),
      ),
    ];
  }

  static String _retry(AppLocalizations l10n) => l10n.retry;
}
