part of '../app_session_screen.dart';

extension _SessionStatus on _AppSessionState {
  /// One colored status descriptor for the current session state. Reflects the
  /// REAL state — plan mode is driven by `_planActive` (server-side), so the
  /// indicator never disagrees with how the agent is actually behaving.
  ({Color color, String label, IconData icon, bool nominal}) _sessionState(
    AppLocalizations l10n,
  ) {
    final scheme = Theme.of(context).colorScheme;
    if (_guardianReadOnly) {
      return (
        color: infoColor(scheme),
        label: l10n.guardianReadOnly,
        icon: AppIcons.policy_outlined,
        nominal: false,
      );
    }
    if (_externalWriterMode) {
      if (_caps.hostAccess) {
        final view = accessView(
          l10n,
          _access,
          _accessReason,
          _caps.providerName,
        );
        return (
          color: view.tone == AccessTone.running
              ? cautionColor(scheme)
              : infoColor(scheme),
          label: view.status,
          icon: view.icon,
          nominal: false,
        );
      }
      final resumable = _externalWriterLiveness?.allowsResume ?? false;
      return (
        color: cautionColor(scheme),
        label: resumable
            ? l10n.sessionInUseElsewhere
            : l10n.sessionRunningElsewhere,
        icon: resumable
            ? AppIcons.lock_open_outlined
            : AppIcons.lock_clock_outlined,
        nominal: false,
      );
    }
    if (_reconnecting) {
      return (
        color: cautionColor(scheme),
        label: l10n.stateReconnecting,
        icon: AppIcons.autorenew,
        nominal: false,
      );
    }
    if (_connectionLost) {
      return (
        color: scheme.error,
        label: l10n.stateDisconnected,
        icon: AppIcons.cloud_off,
        nominal: false,
      );
    }
    if (_streaming) {
      return (
        color: signalColor(scheme),
        label: _planActive ? l10n.statePlanning : l10n.stateWorking,
        icon: AppIcons.autorenew,
        nominal: false,
      );
    }
    if (_planActive) {
      return (
        color: cautionColor(scheme),
        label: l10n.statePlanMode,
        icon: AppIcons.checklist_rtl,
        nominal: false,
      );
    }
    // At rest, and therefore drawn in ink rather than a hue: this is the state
    // the bar sits in nearly all the time, so tinting it would make the least
    // urgent thing on screen the loudest. Colour escalates from here —
    // accent while working, amber while degraded, error when disconnected.
    return (
      color: scheme.onSurfaceVariant,
      label: l10n.stateReady,
      icon: AppIcons.check_circle_outline,
      nominal: true,
    );
  }

  /// Display name for a model id, falling back to the raw id when it isn't in
  /// the cached list (e.g. an unlisted config default). Null for null/empty.
  String? _modelDisplayLabel(String? id) {
    if (id == null || id.isEmpty) return null;
    return _models.where((m) => m.id == id).firstOrNull?.displayName ?? id;
  }

  /// The model actively serving this thread, per the best truth available:
  /// a server-confirmed runtime first; else what the app last sent (turn
  /// params override thread defaults, so on servers that never notify the
  /// sent value IS the effective one); else the server's start/resume
  /// snapshot. Deliberately NOT the user's unsent selection — that's the
  /// composer pill's job; this indicator only ever claims engaged state.
  /// `confirmed` is true only when the shown id matches the server's report.
  ({String id, bool confirmed})? _activeModelStatus() {
    final rt = _runtime;
    final String? id;
    if (rt != null && rt.confirmedByUpdate) {
      id = rt.model ?? _sentModel;
    } else {
      id = _sentModel ?? rt?.model;
    }
    if (id == null || id.isEmpty) return null;
    final rtModel = rt?.model;
    return (id: id, confirmed: rtModel != null && id == rtModel);
  }

  /// A thin, always-visible status bar: a colored state chip (plan / working /
  /// ready / disconnected) + the active model + the git branch, so the
  /// session's true state is glanceable and consistent with the chat.
  Widget _statusBar(AppLocalizations l10n) {
    final scheme = Theme.of(context).colorScheme;
    final st = _sessionState(l10n);
    final activeModel = _activeModelStatus();
    final running = _streaming || _externalWriterRunning;
    return AnimatedContainer(
      duration: Motion.of(context, Motion.medium),
      curve: Motion.move,
      width: double.infinity,
      // At rest the bar is part of the page — the header's own ground, with
      // no rule under it. A state that needs attention tints the whole strip,
      // so colour arriving here means something actually changed.
      decoration: BoxDecoration(
        color: st.nominal
            ? surfaceBackground(scheme)
            : Color.alphaBlend(
                st.color.withValues(alpha: 0.08),
                surfaceBackground(scheme),
              ),
      ),
      padding: EdgeInsets.fromLTRB(isDesktop ? 18 : 14, 3, 14, 5),
      child: LayoutBuilder(
        builder: (context, box) {
          final labelStyle = TextStyle(
            fontSize: 12,
            color: st.color,
            // Resting state reads as a label, not an alert.
            fontWeight: st.nominal ? FontWeight.w500 : FontWeight.w600,
          );
          final fit = _statusFit(
            box.maxWidth,
            label: st.label,
            labelStyle: labelStyle,
            model: activeModel == null
                ? null
                : _modelDisplayLabel(activeModel.id),
            running: running,
            branch: _branch,
          );
          return Row(
            children: [
              if (_externalWriterRunning || (_streaming && !st.nominal))
                PulsingDot(
                  key: _externalWriterRunning
                      ? const Key('chat-status-running-pulse')
                      : null,
                  color: st.color,
                  size: 7,
                )
              else
                Icon(st.icon, size: 13, color: st.color),
              const SizedBox(width: 6),
              // The state takes what the right side leaves, so the line
              // never overflows; [_statusFit] keeps it whole when it can.
              Expanded(
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: _withAccessScope(
                    l10n,
                    Text(
                      st.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: labelStyle,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              // The model actively handling this thread's requests — server
              // truth when confirmed, else the best-known effective value.
              // Tap for the full runtime configuration, so a model switch is
              // verifiable.
              if (activeModel != null && fit.model != null) ...[
                _activeModelChip(
                  l10n,
                  scheme,
                  activeModel,
                  nameWidth: fit.model!,
                ),
                const SizedBox(width: 10),
              ],
              // Live elapsed clock for the running turn. A local turn freezes
              // this into its transcript footnote; an external turn counts
              // from when this read-only observer attached and disappears
              // when it finishes.
              if (running && fit.clock) ...[
                Icon(AppIcons.schedule, size: 12, color: st.color),
                const SizedBox(width: 4),
                ValueListenableBuilder<int>(
                  valueListenable: _elapsed,
                  builder: (context, secs, _) => Text(
                    _fmtElapsed(secs),
                    style: TextStyle(
                      fontSize: 12,
                      color: st.color,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                const SizedBox(width: 10),
              ],
              // Branch + working-tree change counts, tappable to open the
              // diff. This is the single, unified place the git state lives
              // (no separate app-bar chip), so the status bar is the one
              // source of truth.
              if (_branch case final branch?)
                _branchChip(l10n, scheme, branch, nameWidth: fit.branch),
            ],
          );
        },
      ),
    );
  }

  /// How much of the status bar's right side fits in [width]: the widths
  /// for the model and branch names, and whether the model chip and clock
  /// show at all. Mirrors the chips' own paddings and glyphs.
  ///
  /// The state label and the change counts always show. When the line is too
  /// short the model name shortens first, then the branch name; then the
  /// model chip (the composer names the model too) and the clock give way,
  /// and last the branch name.
  ({double? model, bool clock, double branch}) _statusFit(
    double width, {
    required String label,
    required TextStyle labelStyle,
    required String? model,
    required bool running,
    required String? branch,
  }) {
    const name = TextStyle(fontSize: 12);
    const figures = [FontFeature.tabularFigures()];
    const minName = 48.0;
    double line(String text, TextStyle style) =>
        measureTextLine(context, text, style).width.ceilToDouble();
    final d = _diff;
    final counts = d == null || d.isEmpty
        ? 0.0
        : 6 +
              line(
                '+${d.added} −${d.removed}',
                const TextStyle(fontSize: 11.5, fontFeatures: figures),
              );
    // Icon, gap, label, gap.
    final state = 13 + 6 + line(label, labelStyle) + 12;
    // Padding, glyph, gap, counts.
    final branchChip = branch == null ? 0.0 : 12 + 12 + 4 + counts;
    // Padding, gap, dot, gap after.
    const modelChip = 12 + 6 + 6 + 10.0;
    final clockWidth = running
        ? 12 +
              4 +
              line(
                '88:88',
                const TextStyle(fontSize: 12, fontFeatures: figures),
              ) +
              10
        : 0.0;
    var branchName = branch == null ? 0.0 : math.min(160.0, line(branch, name));
    double? modelName = model == null
        ? null
        : math.min(180.0, line(model, name));
    var clock = running;
    double over() =>
        state +
        branchChip +
        branchName +
        (modelName == null ? 0 : modelChip + modelName) +
        (clock ? clockWidth : 0) -
        width;
    if (over() > 0 && modelName != null) {
      modelName = math.max(minName, modelName - over());
    }
    if (over() > 0 && branch != null) {
      branchName = math.max(minName, branchName - over());
    }
    if (over() > 0) modelName = null;
    if (over() > 0) clock = false;
    if (over() > 0) branchName = math.max(0, branchName - over());
    return (model: modelName, clock: clock, branch: branchName);
  }

  /// The model handling this thread's requests, marked solid once the
  /// server confirmed it; tap for the full runtime configuration.
  Widget _activeModelChip(
    AppLocalizations l10n,
    ColorScheme scheme,
    ({String id, bool confirmed}) model, {
    required double nameWidth,
  }) => Tooltip(
    message: l10n.activeModelTooltip,
    child: InkWell(
      mouseCursor: clickable,
      key: const Key('active-model-chip'),
      onTap: _showRuntimeSheet,
      borderRadius: BorderRadius.circular(kControlRadius),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: nameWidth),
              child: Text(
                _modelDisplayLabel(model.id)!,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ),
            const SizedBox(width: 6),
            // Confirmed by the server: a solid dot; still pending: a hollow
            // one.
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: model.confirmed ? additionColor(scheme) : null,
                border: model.confirmed
                    ? null
                    : Border.all(color: scheme.onSurfaceVariant, width: 1.2),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  /// The [branch] with its working-tree change counts, tappable to open the
  /// diff.
  Widget _branchChip(
    AppLocalizations l10n,
    ColorScheme scheme,
    String branch, {
    required double nameWidth,
  }) {
    final d = _diff;
    final changed = d != null && !d.isEmpty;
    return Tooltip(
      message: _diffLoading
          ? l10n.cancelDiffLoad
          : changed
          ? l10n.viewDiff
          : branch,
      child: InkWell(
        mouseCursor: clickable,
        key: const Key('status-branch-chip'),
        onTap: _showDiff,
        borderRadius: BorderRadius.circular(kControlRadius),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // While the diff is loading the badge IS the cancel control: a
              // spinner in place of the branch glyph, so the press that
              // started it can also stop it.
              if (_diffLoading)
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.6,
                    color: signalColor(scheme),
                  ),
                )
              else
                Icon(
                  AppIcons.account_tree_outlined,
                  size: 12,
                  color: scheme.onSurfaceVariant,
                ),
              if (nameWidth > 0) ...[
                const SizedBox(width: 4),
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: nameWidth),
                  child: Text(
                    branch,
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
              if (changed) ...[
                const SizedBox(width: 6),
                ChangeCounts(added: d.added, removed: d.removed, gap: 3),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// Agent identity per service key, from explicit sources only: this
  /// device's hosts report their provider and profile, and the connected
  /// ACP host reports its profile. Other remote hosts stay generic.
  Map<String, AgentIdentity> _hostIdentities() {
    final out = <String, AgentIdentity>{};
    for (final host
        in ref.watch(localServeListProvider).valueOrNull ??
            const <AppServeStatus>[]) {
      if (host.appServiceKey.isEmpty) continue;
      out[host.appServiceKey] = AgentIdentity(
        provider: host.provider,
        profileId: host.profileId,
        name: host.providerName.isEmpty ? null : host.providerName,
      );
    }
    final caps = _caps;
    if (caps.isOpenCode) {
      out[widget.serviceKey] ??= AgentIdentity(
        provider: 'opencode',
        name: caps.providerName,
      );
    } else if (caps.isAcp && caps.profileId.isNotEmpty) {
      out[widget.serviceKey] ??= AgentIdentity(
        provider: 'acp',
        profileId: caps.profileId,
        name: caps.providerName,
      );
    }
    return out;
  }

  /// The switch strip above the conversation, while one runs or after it
  /// fails. Null otherwise.
  Widget? _hostSwitchBanner() {
    final pending = widget.home ? widget.hostSwitch : null;
    if (pending == null) return null;
    final match = widget.services.where((s) => s.key == pending.target);
    return HostSwitchBanner(
      pending: pending,
      targetLabel: match.isEmpty
          ? serviceKeyLabel(pending.target)
          : hostLabel(match.first),
      onRetry: () => widget.onSwitchService?.call(pending.target),
      onDismiss: () => widget.onDismissHostSwitch?.call(),
    );
  }
}
