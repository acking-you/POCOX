/// The opening view of a new conversation, for every engine: which agent,
/// which project, and whether its session is ready — one calm card instead
/// of a setup step.
///
/// Everything it states comes from the screen: the agent's identity from the
/// host's explicit profile id, readiness from the draft-owned session
/// opening, the model label only when the agent reported one. Projects come
/// from the host's own session list, so they stay offered whatever folder is
/// chosen now.
library;

import 'package:flutter/material.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/desktop_theme.dart';
import 'package:pocox/src/fonts.dart';
import 'package:pocox/src/motion.dart';
import 'package:pocox/src/screens/app_session/agent_session_options.dart';
import 'package:pocox/src/theme.dart';
import 'package:pocox/src/widgets/agent_icon.dart';
import 'package:pocox/src/app_icons.dart';
import 'package:pocox/src/attachment_refs.dart';

/// The welcome card of a conversation that has not sent anything yet.
class AgentWelcome extends StatelessWidget {
  /// Creates the card.
  const AgentWelcome({
    super.key,
    required this.agentKind,
    required this.agentName,
    required this.project,
    required this.phase,
    this.cwd,
    this.failure,
    this.modelLabel,
    this.recent = const [],
    this.onPickRecent,
    this.onChooseFolder,
    this.onRetry,
    this.onHostSettings,
    this.connecting = false,
    this.opensOnFirstMessage = false,
  });

  /// Which mark to show.
  final AgentKind agentKind;

  /// The agent's display name.
  final String agentName;

  /// The project switcher (the headline control).
  final Widget project;

  /// The full project path, shown under the switcher.
  final String? cwd;

  /// Where the session stands.
  final AgentSessionPhase phase;

  /// The safe reason opening failed, with [AgentSessionPhase.failed].
  final String? failure;

  /// The model the agent reported for the open session, if any.
  final String? modelLabel;

  /// Other projects on this host, most recent first.
  final List<String> recent;

  /// Start the conversation in one of [recent].
  final ValueChanged<String>? onPickRecent;

  /// Open the folder chooser.
  final VoidCallback? onChooseFolder;

  /// Open the session again after a failure.
  final VoidCallback? onRetry;

  /// Open this host's settings (only where this device hosts the agent).
  final VoidCallback? onHostSettings;

  /// The view waits for its host connection.
  final bool connecting;

  /// The agent reports no per-session options: its session simply opens
  /// with the first message.
  final bool opensOnFirstMessage;

  /// [path]'s folder name, with its parent where another of [all] shares
  /// the name, so two checkouts of one repository stay distinguishable.
  static String _shortName(String path, List<String> all) {
    final leaf = folderName(path);
    if (all.where((p) => folderName(p) == leaf).length < 2) return leaf;
    final segs = path.split(RegExp(r'[\\/]'))..removeWhere((s) => s.isEmpty);
    return segs.length < 2 ? leaf : '${segs[segs.length - 2]}/$leaf';
  }

  /// The agent's own mark on a soft tile, [size] square.
  Widget _mark(ColorScheme scheme, double size) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: floatingSurface(scheme),
      borderRadius: BorderRadius.circular(size / 3),
      border: Border.all(color: floatingEdge(scheme)),
      boxShadow: floatingShadows(scheme, lift: 0.45),
    ),
    alignment: Alignment.center,
    child: AgentIcon(kind: agentKind, name: agentName, size: size * 0.46),
  );

  /// Who the conversation is with, the project switcher and its path.
  List<Widget> _identity(ThemeData theme, AppLocalizations l10n, String path) {
    final scheme = theme.colorScheme;
    return [
      Text(
        l10n.agentWelcomeTitle(agentName),
        textAlign: TextAlign.center,
        style: theme.textTheme.titleSmall?.copyWith(
          color: scheme.onSurfaceVariant,
          fontWeight: FontWeight.w500,
        ),
      ),
      const SizedBox(height: 2),
      project,
      if (path.isNotEmpty)
        Text(
          path,
          key: const Key('new-session-cwd'),
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontFamily: monoFontFamily,
            fontFamilyFallback: monoCjkFallback,
            fontSize: 12,
            color: scheme.onSurfaceVariant,
          ),
        ),
    ];
  }

  /// A phone's layout: the agent and project centred in the room the
  /// composer leaves, and the other projects as one row that swipes, just
  /// above the composer where a thumb reaches them. With little room (the
  /// keyboard up) the mark goes, never the project.
  Widget _phone(
    BuildContext context,
    AppLocalizations l10n,
    String path,
    List<String> shown,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final chooser =
        onChooseFolder != null && phase != AgentSessionPhase.needsProject;
    return LayoutBuilder(
      key: const Key('agent-welcome'),
      // The agent and project centred above the row while they fit; with
      // less room (large text, the keyboard up) both scroll as one column,
      // never one cut beneath the other.
      builder: (context, box) => CustomScrollView(
        slivers: [
          SliverFillRemaining(
            hasScrollBody: false,
            child: Column(
              children: [
                Expanded(
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (box.maxHeight >= 360) ...[
                            _mark(scheme, 52),
                            const SizedBox(height: 12),
                          ],
                          ..._identity(theme, l10n, path),
                          const SizedBox(height: 14),
                          _readiness(context, l10n, scheme),
                        ],
                      ),
                    ),
                  ),
                ),
                if (shown.isNotEmpty || chooser)
                  _recentRow(context, l10n, scheme, shown, chooser: chooser),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The other projects as one horizontally swiping row of pills, ending
  /// with the folder chooser.
  Widget _recentRow(
    BuildContext context,
    AppLocalizations l10n,
    ColorScheme scheme,
    List<String> projects, {
    required bool chooser,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (projects.isNotEmpty)
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(20, 0, 20, 8),
            child: Text(
              l10n.recentProjects,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        SingleChildScrollView(
          key: const Key('agent-welcome-recent-row'),
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            spacing: 8,
            children: _pills(context, l10n, scheme, projects, chooser: chooser),
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final path = cwd?.trim() ?? '';
    // A phone: the project row swipes, so it can offer a few more.
    final phone = !isDesktop && MediaQuery.sizeOf(context).width < 720;
    final shown = [
      for (final p in recent)
        if (p.trim() != path) p,
    ].take(phone ? 8 : 4).toList();
    if (phone) return _phone(context, l10n, path, shown);
    return Center(
      child: SingleChildScrollView(
        key: const Key('agent-welcome'),
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // The agent's own mark on a soft tile: who this conversation
              // is with, before anything else.
              _mark(scheme, 60),
              const SizedBox(height: 12),
              ..._identity(theme, l10n, path),
              const SizedBox(height: 16),
              _readiness(context, l10n, scheme),
              if (shown.isNotEmpty) ...[
                const SizedBox(height: 28),
                _recent(context, l10n, scheme, shown),
              ],
              if (shown.isEmpty &&
                  phase != AgentSessionPhase.needsProject &&
                  onChooseFolder != null) ...[
                const SizedBox(height: 14),
                TextButton.icon(
                  key: const Key('agent-welcome-choose-folder'),
                  onPressed: onChooseFolder,
                  icon: const Icon(AppIcons.add, size: 17),
                  label: Text(l10n.chooseFolder),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// One line that says where the session stands, and what to do about it.
  Widget _readiness(
    BuildContext context,
    AppLocalizations l10n,
    ColorScheme scheme,
  ) {
    final muted = TextStyle(fontSize: 13, color: scheme.onSurfaceVariant);
    final Widget body = switch (phase) {
      AgentSessionPhase.opening => _opening(context, l10n, muted),
      AgentSessionPhase.ready => _line(
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(
            color: successColor(scheme),
            shape: BoxShape.circle,
          ),
        ),
        modelLabel == null || modelLabel!.isEmpty
            ? l10n.agentWelcomeReady
            : l10n.agentWelcomeReadyModel(modelLabel!),
        muted,
      ),
      AgentSessionPhase.failed => _failed(l10n, scheme),
      AgentSessionPhase.needsProject => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            l10n.agentWelcomeNeedsProject(agentName),
            textAlign: TextAlign.center,
            style: muted,
          ),
          const SizedBox(height: 10),
          if (onChooseFolder != null)
            FilledButton.tonalIcon(
              key: const Key('agent-welcome-choose-folder'),
              onPressed: onChooseFolder,
              icon: const Icon(AppIcons.create_new_folder_outlined, size: 18),
              label: Text(l10n.chooseFolder),
            ),
        ],
      ),
      AgentSessionPhase.idle =>
        connecting
            ? _line(null, l10n.agentWelcomeConnecting, muted)
            : opensOnFirstMessage
            ? _line(null, l10n.agentWelcomeLater, muted)
            : const SizedBox.shrink(),
    };
    return Semantics(
      container: true,
      liveRegion: true,
      child: AnimatedSwitcher(
        duration: Motion.of(context, Motion.medium),
        switchInCurve: Motion.enter,
        child: KeyedSubtree(
          key: ValueKey('agent-welcome-phase-${phase.name}'),
          child: body,
        ),
      ),
    );
  }

  Widget _line(Widget? icon, String text, TextStyle style) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (icon != null) ...[icon, const SizedBox(width: 6)],
      Flexible(
        child: Text(text, textAlign: TextAlign.center, style: style),
      ),
    ],
  );

  /// Opening: the text says what happens; a thin indeterminate bar shows it
  /// is happening (no bar under reduced motion — it would not move).
  Widget _opening(BuildContext context, AppLocalizations l10n, TextStyle s) {
    final ambient = Motion.ambientAllowed(context);
    return Column(
      key: const Key('agent-welcome-opening'),
      mainAxisSize: MainAxisSize.min,
      children: [
        _line(
          ambient
              ? null
              : Icon(AppIcons.hourglass_empty, size: 15, color: s.color),
          l10n.agentWelcomeOpening(agentName),
          s,
        ),
        if (ambient) ...[
          const SizedBox(height: 10),
          SizedBox(
            width: 160,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: const LinearProgressIndicator(minHeight: 2),
            ),
          ),
        ],
      ],
    );
  }

  /// A failed opening: the safe reason, then the ways forward. Never a
  /// sign-in flow — the agent uses its host's environment.
  Widget _failed(AppLocalizations l10n, ColorScheme scheme) => Container(
    key: const Key('agent-welcome-failed'),
    padding: const EdgeInsets.fromLTRB(14, 10, 8, 6),
    decoration: BoxDecoration(
      color: scheme.errorContainer.withValues(alpha: 0.5),
      borderRadius: BorderRadius.circular(kPanelRadius),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.agentWelcomeFailed(failure ?? ''),
          maxLines: 4,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 13, color: scheme.onErrorContainer),
        ),
        const SizedBox(height: 2),
        Text(
          l10n.agentErrorHint,
          style: TextStyle(fontSize: 12, color: scheme.onErrorContainer),
        ),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: 4,
          children: [
            if (onHostSettings != null)
              TextButton(
                key: const Key('agent-welcome-host-settings'),
                onPressed: onHostSettings,
                child: Text(l10n.agentHostSettings),
              ),
            if (onRetry != null)
              TextButton(
                key: const Key('agent-welcome-retry'),
                onPressed: onRetry,
                child: Text(l10n.retry),
              ),
          ],
        ),
      ],
    ),
  );

  /// Other projects as one-tap pills (the folder name; the full path in
  /// the tooltip), ending with the folder chooser: picking one starts the
  /// new conversation there.
  Widget _recent(
    BuildContext context,
    AppLocalizations l10n,
    ColorScheme scheme,
    List<String> projects,
  ) {
    return Column(
      children: [
        Text(
          l10n.recentProjects,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: _pills(
            context,
            l10n,
            scheme,
            projects,
            chooser:
                onChooseFolder != null &&
                phase != AgentSessionPhase.needsProject,
          ),
        ),
      ],
    );
  }

  /// One pill per project (the folder name; the full path in the tooltip),
  /// then the folder [chooser].
  List<Widget> _pills(
    BuildContext context,
    AppLocalizations l10n,
    ColorScheme scheme,
    List<String> projects, {
    required bool chooser,
  }) => [
    for (final p in projects)
      Tooltip(
        message: p,
        child: _pill(
          context,
          scheme,
          key: Key('agent-welcome-recent-$p'),
          label: _shortName(p, projects),
          onTap: onPickRecent == null ? null : () => onPickRecent!(p),
        ),
      ),
    if (chooser)
      _pill(
        context,
        scheme,
        key: const Key('agent-welcome-choose-folder'),
        icon: AppIcons.add,
        label: l10n.chooseFolder,
        onTap: onChooseFolder,
      ),
  ];

  Widget _pill(
    BuildContext context,
    ColorScheme scheme, {
    required Key key,
    required String label,
    IconData? icon,
    VoidCallback? onTap,
  }) {
    return Material(
      color: fieldFill(scheme),
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: key,
        mouseCursor: clickable,
        onTap: onTap,
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: isDesktop ? 34 : 44),
          child: Padding(
            padding: EdgeInsets.fromLTRB(icon == null ? 16 : 12, 0, 16, 0),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 16, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 6),
                ],
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 200),
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, color: scheme.onSurface),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
