part of '../app_session_screen.dart';

extension _SessionModelPicker on _AppSessionState {
  /// Whether the composer's own model menu (model, effort, Plan) applies:
  /// a service-wide model catalog whose sessions have no options of their
  /// own (Codex). Where the session's options carry the model (native
  /// OpenCode: model, agent, variant), those options replace the menu, and
  /// nothing of it is sent.
  bool get _usesModelMenu => _caps.modelCatalog && !_caps.sessionConfig;

  /// The project the shown view's catalog (models, commands) is read for:
  /// native OpenCode offers each project its own. Null for engines whose
  /// catalog is the same everywhere, and outside a project.
  String? get _catalogProject {
    if (!_caps.isOpenCode) return null;
    final cwd = _cwd;
    return cwd == null || cwd.trim().isEmpty ? null : cwd;
  }

  /// The host connection a model list belongs to: the link (lost, replaced,
  /// another generation) and the subscription a reconnect opens on it, and
  /// the project it was read for. A list read before a reconnect may be the
  /// previous host's catalog; one read for another project, that project's.
  Object get _modelsLinkKey =>
      (widget.serviceKey, _linkEpoch, _subscriptionEpoch, _catalogProject);

  /// Whether [_models] was read from the current host connection.
  bool get _modelsCurrent => _modelsKey == _modelsLinkKey;

  Future<List<ModelInfo>> _ensureModels() async {
    final key = _modelsLinkKey;
    if (_models.isNotEmpty && _modelsKey == key) return _models;
    final pending = _modelsLoading;
    if (pending != null && _modelsLoadingKey == key) return pending;
    final request = _fetchModels(key, _catalogProject);
    _modelsLoading = request;
    _modelsLoadingKey = key;
    try {
      return await request;
    } finally {
      if (identical(_modelsLoading, request)) {
        _modelsLoading = null;
        _modelsLoadingKey = null;
      }
    }
  }

  Future<List<ModelInfo>> _fetchModels(Object key, String? project) async {
    // No model menu (ACP, or session options that carry the model): nothing
    // to fetch, and nothing invented.
    if (!_usesModelMenu) {
      if (mounted) _openLoadDone(_kModelsLoad);
      return _models;
    }
    try {
      final models = await ref
          .read(bridgeApiProvider)
          .appModelListForProject(widget.serviceKey, project);
      // An answer of a connection that moved meanwhile may describe the
      // previous host, and one for the project the view left, that project:
      // the next read (the reconnect's, the new project's) asks again.
      if (mounted && key == _modelsLinkKey) {
        _adoptModels(models, key);
        _openLoadDone(_kModelsLoad);
      }
    } catch (_) {
      if (mounted && key == _modelsLinkKey) _retryOpenLoad(_kModelsLoad);
    }
    return _models;
  }

  /// Install [models], read from connection [key]. When they differ from the
  /// catalog last seen for this service (the host now runs another
  /// configuration), a model it no longer offers is no longer selected —
  /// neither here nor as the default new conversations inherit — and the
  /// effort chosen for it goes with it. Nothing is sent: the composer keeps
  /// its text, attachments and queue, and shows the host's default instead.
  void _adoptModels(List<ModelInfo> models, Object key) {
    final service = widget.serviceKey;
    final ids = {for (final m in models) m.id};
    final previous = _AppSessionState._catalogByService[service];
    _AppSessionState._catalogByService[service] = ids;
    final changed = previous != null && !setEquals(previous, ids);
    _updateState(() {
      _models = models;
      _modelsKey = key;
      if (!changed) return;
      _catalogChanges++;
      final picked = _model;
      if (picked != null && !ids.contains(picked.id)) {
        _model = null;
        _modelPickPending = false;
        _effort = null;
      }
    });
    if (!changed) return;
    final defaults = ref.read(sessionDefaultsProvider(service).notifier);
    final inherited = defaults.state.model;
    if (inherited != null && !ids.contains(inherited.id)) {
      defaults.state = SessionDefaults(
        mode: defaults.state.mode,
        plan: defaults.state.plan,
        serviceTier: defaults.state.serviceTier,
      );
    }
  }

  /// Shared bottom-sheet picker: a titled list of soft option rows (icon +
  /// label + description); the selected one is filled and checked. Returns the
  /// chosen value, or null if dismissed. Used by the model/mode/effort pickers.
  Future<T?> _optionSheet<T>({
    required String title,
    required List<_PickerOption<T>> options,
    required bool Function(T value) isSelected,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return showAdaptivePanel<T>(
      context: context,
      anchored: true,
      // The body ends in a ListView of options; it scrolls itself.
      scrollable: false,
      // It also draws its own grab bar, which is its top edge.
      insetTop: false,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(top: 10, bottom: 8),
                decoration: BoxDecoration(
                  color: scheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Text(title, style: Theme.of(context).textTheme.titleSmall),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                children: [
                  for (final o in options)
                    _optionRow(
                      o,
                      isSelected(o.value),
                      () => Navigator.pop(c, o.value),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// One soft option row inside [_optionSheet].
  Widget _optionRow<T>(_PickerOption<T> o, bool selected, VoidCallback onTap) {
    final scheme = Theme.of(context).colorScheme;
    final fg = scheme.onSurface;
    final accent = scheme.tertiary;
    final duration = Motion.of(context, Motion.medium);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: AnimatedContainer(
        duration: duration,
        curve: Motion.move,
        decoration: BoxDecoration(
          color: selected
              ? selectedRowColor(scheme)
              : selectedRowColor(scheme).withValues(alpha: 0),
          borderRadius: BorderRadius.circular(kControlRadius),
        ),
        child: Material(
          type: MaterialType.transparency,
          borderRadius: BorderRadius.circular(kControlRadius),
          child: InkWell(
            mouseCursor: clickable,
            // Stable handle for tests: the label is localised and, for the turn
            // settings, repeated by the chip that opened the sheet. Values that
            // are not scalars fall back to the label — a model row's DTO has no
            // `toString`, so keying on it would give every model the same key.
            key: ValueKey(
              'opt-${switch (o.value) {
                final String s => s,
                final Enum e => e.name,
                _ => o.label,
              }}',
            ),
            borderRadius: BorderRadius.circular(12),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              child: Row(
                children: [
                  TweenAnimationBuilder<Color?>(
                    tween: ColorTween(
                      end: selected ? accent : scheme.onSurfaceVariant,
                    ),
                    duration: duration,
                    builder: (_, color, _) =>
                        Icon(o.icon, size: 20, color: color),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          o.label,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: fg,
                          ),
                        ),
                        if (o.description != null &&
                            o.description!.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            o.description!,
                            style: TextStyle(
                              fontSize: 12,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  // Always laid out, so picking a row doesn't shift its text;
                  // the check grows in on the new row as it fades from the old.
                  const SizedBox(width: 8),
                  AnimatedScale(
                    scale: selected ? 1 : 0.6,
                    duration: duration,
                    curve: Motion.enter,
                    child: AnimatedOpacity(
                      opacity: selected ? 1 : 0,
                      duration: duration,
                      child: Icon(AppIcons.check, size: 18, color: accent),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _pickModel() async {
    final l10n = AppLocalizations.of(context);
    final startTid = _threadId;
    final models = await _ensureModels();
    if (!mounted) return;
    final chosen = await _optionSheet<ModelInfo?>(
      title: l10n.modelLabel,
      isSelected: (v) => v?.id == _model?.id,
      options: [
        _PickerOption(
          value: null,
          icon: AppIcons.star_outline,
          label: l10n.modelDefault,
        ),
        for (final m in models)
          _PickerOption(
            value: m,
            icon: AppIcons.auto_awesome,
            label: m.displayName,
            description: m.description.isEmpty ? null : m.description,
          ),
      ],
    );
    // Guard a thread switch during the sheet, so the pick + persist target the
    // thread the user was actually looking at.
    if (!mounted || _threadId != startTid) return;
    if (chosen != null || models.isNotEmpty) {
      _updateState(() {
        _model = chosen;
        // Capability must resolve the new default, not the old runtime model.
        _modelPickPending = true;
        if (_effectiveModel?.supportsFast != true) {
          _serviceTier = 'default';
          _serviceTierPickPending = true;
        }
        // If the new model doesn't support the current effort, fall back to its
        // default (or unset) so we never send a level the model rejects.
        final eff = _effectiveEffort;
        if (chosen != null &&
            eff != null &&
            !chosen.supportedReasoningEfforts.contains(eff.wire)) {
          _effort = ReasoningEffort.fromWire(chosen.defaultReasoningEffort);
          _effortActive = null;
        }
      });
      _rememberDefaults();
      _persistThreadConfig();
    }
  }

  Future<void> _pickMode() async {
    if (!_caps.permissionPresets) return;
    final l10n = AppLocalizations.of(context);
    final startTid = _threadId;
    final chosen = await _optionSheet<PermissionMode>(
      title: l10n.permissionLabel,
      isSelected: (v) => v == _mode,
      options: [
        for (final m in PermissionMode.values)
          _PickerOption(
            value: m,
            icon: _modeIconFor(m),
            label: m.label(l10n),
            description: m.describe(l10n),
          ),
      ],
    );
    if (!mounted || _threadId != startTid) return;
    if (chosen != null) {
      _updateState(() {
        _mode = chosen;
        _modePickPending = true;
      });
      _rememberDefaults();
      _persistThreadConfig();
    }
  }

  IconData _effortIcon(ReasoningEffort e) => switch (e.wire) {
    'none' => AppIcons.battery_0_bar,
    'minimal' => AppIcons.battery_2_bar,
    'low' => AppIcons.battery_3_bar,
    'medium' => AppIcons.battery_4_bar,
    'high' => AppIcons.battery_5_bar,
    'xhigh' => AppIcons.battery_full,
    _ => AppIcons.bolt, // unknown / custom level the model advertised
  };

  Future<void> _pickEffort() async {
    final l10n = AppLocalizations.of(context);
    final startTid = _threadId;
    // Offer only the levels the active model supports (the selected model, else
    // the default/first) — codex models differ (some support xhigh/minimal but
    // not low/high). Fall back to all known levels if the model lists none.
    // Effort is sticky server-side with no "model default" reset on the wire, so
    // there's no Auto entry; null result == dismissed.
    final models = await _ensureModels();
    if (!mounted) return;
    final model = _model ?? (models.isNotEmpty ? models.first : null);
    final supported = model?.supportedReasoningEfforts ?? const [];
    // Offer exactly what the model advertises (open string list — may include
    // `none`/`xhigh`/custom tokens beyond the classic levels). Fall back to the
    // common levels only when a model lists none.
    final efforts = supported.isEmpty
        ? ReasoningEffort.known
        : [for (final w in supported) ReasoningEffort(w)];
    final chosen = await _optionSheet<ReasoningEffort>(
      title: l10n.effort,
      isSelected: (v) => v == _effectiveEffort,
      options: [
        for (final e in efforts)
          _PickerOption(
            value: e,
            icon: _effortIcon(e),
            label: e.label(l10n),
            description: e.describe(l10n),
          ),
      ],
    );
    if (!mounted || _threadId != startTid) return;
    if (chosen != null) {
      _updateState(() => _effort = chosen);
      _rememberDefaults();
      _persistThreadConfig();
    }
  }

  /// The full runtime configuration, opened from the status-bar model chip: a
  /// read-only sheet of what this thread's turns actually run with — model,
  /// reasoning effort, permissions, plan mode — with a provenance line saying
  /// whether the server confirmed it (thread/settings/updated), it came from
  /// the session's start/resume snapshot, or the server never reported and
  /// the values shown are what this app sends.
  void _showRuntimeSheet() {
    final l10n = AppLocalizations.of(context);
    final rt = _runtime;
    final active = _activeModelStatus();
    // Effort mirrors _activeModelStatus's precedence: confirmed server value
    // (null = the model's default), else the app's effective pick, else the
    // snapshot value.
    final String effortText;
    if (rt != null && rt.confirmedByUpdate) {
      effortText = rt.reasoningEffort == null
          ? l10n.runtimeEffortModelDefault
          : ReasoningEffort(rt.reasoningEffort!).label(l10n);
    } else {
      final eff = _effectiveEffort?.wire ?? rt?.reasoningEffort;
      effortText = eff == null
          ? l10n.runtimeEffortModelDefault
          : ReasoningEffort(eff).label(l10n);
    }
    // Permissions: the server-reported approval+sandbox pair (as a preset
    // label when it maps onto one), else the mode the app sends every turn.
    final String permText;
    final approval = rt?.approvalPolicy;
    final sandbox = rt?.sandboxMode;
    if (approval != null || sandbox != null) {
      final preset = PermissionMode.values
          .where(
            (m) =>
                m.approval == approval &&
                m.sandbox == sandbox &&
                m.reviewer == (rt?.approvalsReviewer ?? 'user'),
          )
          .firstOrNull;
      permText =
          preset?.label(l10n) ?? '${approval ?? '—'} · ${sandbox ?? '—'}';
    } else {
      permText = _mode.label(l10n);
    }
    final collab = rt?.collaborationMode;
    final planText = (collab ?? (_planActive ? 'plan' : 'default')) == 'plan'
        ? l10n.statePlanMode
        : l10n.runtimeCollabDefault;
    final String provenance;
    if (rt == null) {
      provenance = l10n.runtimeUnavailable;
    } else {
      final at = _runtimeAt;
      final time = at == null ? '' : _fmtClock(at);
      provenance = rt.confirmedByUpdate
          ? l10n.runtimeConfirmedAt(time)
          : l10n.runtimeFromSnapshot(time);
    }
    final modelLabel = active == null ? '—' : _modelDisplayLabel(active.id)!;
    final modelSub = <String>[
      if (active != null && modelLabel != active.id) active.id,
      if (rt?.modelProvider != null) rt!.modelProvider!,
    ].join(' · ');
    showAdaptivePanel<void>(
      context: context,
      anchored: true,
      builder: (c) {
        final scheme = Theme.of(c).colorScheme;
        Widget row(IconData icon, String label, String value, {String? sub}) =>
            ListTile(
              dense: true,
              leading: Icon(icon, size: 20, color: scheme.primary),
              title: Text(label, style: const TextStyle(fontSize: 12)),
              subtitle: Text(
                sub == null || sub.isEmpty ? value : '$value\n$sub',
                style: TextStyle(fontSize: 14, color: scheme.onSurface),
              ),
            );
        return SafeArea(
          // Scrollable so the rows never overflow a short sheet (small phones,
          // landscape). Selectable so the model id / provider can be copied.
          child: SelectionArea(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
                    child: Text(
                      l10n.runtimeSheetTitle,
                      style: Theme.of(c).textTheme.titleMedium,
                    ),
                  ),
                  row(
                    AppIcons.auto_awesome,
                    l10n.modelLabel,
                    modelLabel,
                    sub: modelSub,
                  ),
                  row(AppIcons.psychology_outlined, l10n.effort, effortText),
                  if (_caps.permissionPresets)
                    row(_modeIcon(), l10n.permissionLabel, permText),
                  row(AppIcons.checklist_rtl, l10n.planMode, planText),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                    child: Row(
                      children: [
                        Icon(
                          rt != null && rt.confirmedByUpdate
                              ? AppIcons.verified_outlined
                              : AppIcons.info_outline,
                          size: 14,
                          color: rt != null && rt.confirmedByUpdate
                              ? additionColor(scheme)
                              : scheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            provenance,
                            style: TextStyle(
                              fontSize: 12,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
