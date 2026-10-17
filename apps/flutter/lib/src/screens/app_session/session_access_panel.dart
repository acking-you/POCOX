/// The panel a host-access session (ACP agents, native OpenCode) shows in
/// place of its composer while this view cannot write it: who holds the
/// session, whether a turn runs, what happens next by itself, and only the
/// actions that really exist.
library;

import 'package:flutter/material.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/desktop_theme.dart';
import 'package:pocket_codex/src/fonts.dart';
import 'package:pocket_codex/src/theme.dart';
import 'package:pocket_codex/src/app_icons.dart';

/// How a non-writable state reads.
enum AccessTone {
  /// Someone else runs a turn now.
  running,

  /// Someone else holds the session, or it is changing hands.
  waiting,

  /// Nothing can write it until something outside this view changes.
  blocked,
}

/// The words and mark of one access state.
typedef AccessView = ({
  String status,
  String title,
  String? detail,
  String? next,
  IconData icon,
  AccessTone tone,
});

/// The client named by [holder], in words.
String accessClientName(
  AppLocalizations l10n,
  AccessHolder? holder,
  String providerName,
) => switch (holder?.client) {
  'claude_code' => l10n.accessClientClaude,
  'opencode' => l10n.accessClientOpenCode,
  'pocket_host' => holder?.hostName ?? l10n.accessClientPocketHost,
  _ => providerName.isEmpty ? l10n.accessClientOther : providerName,
};

/// What [reason] (see [SessionAccess.reason]) says for [access]. Every code
/// has its own sentence; an unknown code reads as "cannot tell" with the
/// host's detail.
AccessView accessView(
  AppLocalizations l10n,
  SessionAccess? access,
  String reason,
  String providerName,
) {
  final client = accessClientName(l10n, access?.holder, providerName);
  final recheck = access?.recheck ?? false;
  final running = access?.running ?? false;
  final agent = providerName.isEmpty ? l10n.accessClientOther : providerName;
  return switch (reason) {
    'owned' || 'released' => (
      status: l10n.accessStatusOpening,
      title: l10n.accessOpening,
      detail: null,
      next: null,
      icon: AppIcons.lock_open_outlined,
      tone: AccessTone.waiting,
    ),
    'released_here' => (
      status: l10n.accessStatusHandedBack,
      title: l10n.accessHandedBackTitle,
      detail: l10n.accessHandedBackDetail,
      next: null,
      icon: AppIcons.output_rounded,
      tone: AccessTone.blocked,
    ),
    'not_opened' => (
      status: l10n.accessStatusNotOpen,
      title: l10n.accessNotOpenedTitle,
      detail: l10n.accessNotOpenedDetail,
      next: null,
      icon: AppIcons.inventory_2_outlined,
      tone: AccessTone.blocked,
    ),
    'transition' => (
      status: l10n.accessStatusChanging,
      title: l10n.accessTransitionTitle,
      detail: l10n.accessTransitionDetail,
      next: l10n.accessNextAutomatic,
      icon: AppIcons.sync,
      tone: AccessTone.waiting,
    ),
    'host_stopped' => (
      status: l10n.accessStatusUnavailable,
      title: l10n.accessHostStoppedTitle(agent),
      detail: l10n.accessHostStoppedDetail,
      next: null,
      icon: AppIcons.power_settings_new,
      tone: AccessTone.blocked,
    ),
    'external_running' => (
      status: l10n.sessionRunningElsewhere,
      title: l10n.accessExternalRunningTitle(client),
      detail: l10n.accessExternalRunningDetail,
      next: recheck ? l10n.accessNextWhenClosed : null,
      icon: AppIcons.lock_clock_outlined,
      tone: AccessTone.running,
    ),
    'external_idle' => (
      status: l10n.sessionInUseElsewhere,
      title: l10n.accessExternalIdleTitle(client),
      detail: l10n.accessExternalIdleDetail,
      next: recheck ? l10n.accessNextWhenClosed : null,
      icon: AppIcons.lock_outline,
      tone: AccessTone.waiting,
    ),
    'external_source_open' => (
      status: l10n.sessionInUseElsewhere,
      title: l10n.accessSourceOpenTitle,
      detail: l10n.accessSourceOpenDetail,
      next: null,
      icon: AppIcons.folder_shared_outlined,
      tone: AccessTone.waiting,
    ),
    'pocket_host' => (
      status: running
          ? l10n.sessionRunningElsewhere
          : l10n.sessionInUseElsewhere,
      title: l10n.accessPocketHostTitle(client),
      detail: running
          ? l10n.accessPocketHostRunning
          : l10n.accessPocketHostIdle,
      next: recheck ? l10n.accessNextAutomatic : null,
      icon: AppIcons.devices_other_outlined,
      tone: running ? AccessTone.running : AccessTone.waiting,
    ),
    'unsupported' => (
      status: l10n.accessStatusUnavailable,
      title: l10n.accessUnsupportedTitle(agent),
      detail: access?.detail,
      next: null,
      icon: AppIcons.block,
      tone: AccessTone.blocked,
    ),
    'not_found' => (
      status: l10n.accessStatusUnavailable,
      title: l10n.accessNotFoundTitle,
      detail: access?.detail,
      next: null,
      icon: AppIcons.search_off,
      tone: AccessTone.blocked,
    ),
    _ => (
      status: l10n.accessStatusUnknown,
      title: l10n.accessUnknownTitle,
      detail: access?.detail ?? l10n.accessUnknownDetail,
      next: null,
      icon: AppIcons.help_outline,
      tone: AccessTone.waiting,
    ),
  };
}

/// The panel. Callbacks that are null are not offered: there is no generic
/// disabled state.
class SessionAccessPanel extends StatelessWidget {
  /// Creates the panel for [access] showing [reason].
  const SessionAccessPanel({
    super.key,
    required this.access,
    required this.reason,
    required this.providerName,
    this.busy = false,
    this.onCheck,
    this.onContinue,
    this.onOpenHolder,
    this.onStartHost,
  });

  /// The host's answer, or null while it is being asked.
  final SessionAccess? access;

  /// The reason shown (see [SessionAccess.reason]).
  final String reason;

  /// The engine's display name.
  final String providerName;

  /// A check or an opening is under way.
  final bool busy;

  /// Ask the host again now.
  final VoidCallback? onCheck;

  /// Continue a session this view handed back.
  final VoidCallback? onContinue;

  /// Open the conversation on the Pocket host holding it.
  final VoidCallback? onOpenHolder;

  /// Open the stopped host's editor.
  final VoidCallback? onStartHost;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final view = accessView(l10n, access, reason, providerName);
    final tint = switch (view.tone) {
      AccessTone.running => cautionColor(scheme),
      AccessTone.waiting => infoColor(scheme),
      AccessTone.blocked => scheme.onSurfaceVariant,
    };
    final small = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final holder = _holderLine(context, l10n);
    final buttonStyle = ButtonStyle(
      minimumSize: WidgetStatePropertyAll(Size(0, isDesktop ? 36 : 44)),
    );
    final actions = <Widget>[
      if (onOpenHolder case final open?)
        OutlinedButton.icon(
          key: const Key('access-open-holder'),
          style: buttonStyle,
          onPressed: busy ? null : open,
          icon: const Icon(AppIcons.open_in_new, size: 18),
          label: Text(
            l10n.accessOpenIn(
              accessClientName(l10n, access?.holder, providerName),
            ),
          ),
        ),
      if (onStartHost case final start?)
        OutlinedButton.icon(
          key: const Key('access-start-host'),
          style: buttonStyle,
          onPressed: busy ? null : start,
          icon: const Icon(AppIcons.play_arrow_rounded, size: 18),
          label: Text(l10n.accessStartHost),
        ),
      if (onCheck case final check?)
        OutlinedButton.icon(
          key: const Key('access-check'),
          style: buttonStyle,
          onPressed: busy ? null : check,
          icon: const Icon(AppIcons.refresh, size: 18),
          label: Text(l10n.accessCheckNow),
        ),
      if (onContinue case final resume?)
        FilledButton.icon(
          key: const Key('access-continue'),
          style: buttonStyle,
          onPressed: busy ? null : resume,
          icon: const Icon(AppIcons.edit_outlined, size: 18),
          label: Text(l10n.accessContinueHere),
        ),
    ];
    return Semantics(
      container: true,
      liveRegion: true,
      label: view.title,
      child: DecoratedBox(
        key: Key('access-panel-$reason'),
        decoration: BoxDecoration(
          color: scheme.surfaceContainer,
          borderRadius: BorderRadius.circular(kPanelRadius),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: busy
                        ? SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: tint,
                            ),
                          )
                        : Icon(view.icon, size: 18, color: tint),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          view.title,
                          key: const Key('access-title'),
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (holder != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            holder,
                            key: const Key('access-holder'),
                            style: small,
                          ),
                        ],
                        if (view.detail case final detail?) ...[
                          const SizedBox(height: 4),
                          Text(
                            detail,
                            key: const Key('access-detail'),
                            style: small,
                          ),
                        ],
                        if (view.next case final next?) ...[
                          const SizedBox(height: 4),
                          Text(
                            next,
                            key: const Key('access-next'),
                            style: small?.copyWith(fontStyle: FontStyle.italic),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
              if (actions.isNotEmpty) ...[
                const SizedBox(height: 10),
                // Wraps (and stacks on a narrow phone) rather than clipping.
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  runSpacing: 8,
                  children: actions,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// "pid 4312 · since 10:42", when the holder's process is known.
  String? _holderLine(BuildContext context, AppLocalizations l10n) {
    final holder = access?.holder;
    if (holder == null) return null;
    final parts = <String>[
      if (holder.pid case final pid?) l10n.accessHolderPid(pid),
      if (holder.startedAt case final at?)
        l10n.accessHolderSince(
          MaterialLocalizations.of(context).formatTimeOfDay(
            TimeOfDay.fromDateTime(DateTime.fromMillisecondsSinceEpoch(at)),
          ),
        ),
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }
}
