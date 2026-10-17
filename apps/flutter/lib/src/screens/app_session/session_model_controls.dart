part of '../app_session_screen.dart';

extension _SessionModelControls on _AppSessionState {
  Widget _menuRow(IconData icon, String label) => Row(
    children: [
      Icon(
        icon,
        size: 17,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      const SizedBox(width: 12),
      Text(label),
    ],
  );

  /// Permission stays a chip of its own rather than moving into the model
  /// menu: "full access" (no sandbox, never ask) must be readable without
  /// opening anything, which is also why it carries the amber icon.
  Widget _permissionChip(AppLocalizations l10n) => _pill(
    pillKey: const Key('permission-chip'),
    icon: _modeIcon(),
    label: _mode.label(l10n),
    warn: _mode == PermissionMode.full,
    onTap: _pickMode,
  );

  /// What this turn will run with — model, and effort/plan when they differ
  /// from the default — plus the settings it fronts.
  ///
  /// Desktop opens them as an anchored popover with everything on one surface;
  /// a phone keeps the sheet flow, because a popover pinned to a chip that sits
  /// right above the on-screen keyboard has nowhere to go.
  Widget _modelChip(AppLocalizations l10n) {
    Widget pill(VoidCallback onTap) => _pill(
      pillKey: const Key('model-chip'),
      icon: AppIcons.auto_awesome,
      label: _modelChipLabel(l10n),
      // Plan is the one setting here that changes what a turn *does*, and a
      // long model name can ellipsize its label away — so it tints the chip.
      active: _plan,
      trailing: AppIcons.expand_more,
      onTap: onTap,
    );
    if (!_isDesktop) return pill(() => _showConfigSheet(l10n));
    return MenuAnchor(
      controller: _modelMenu,
      alignmentOffset: const Offset(0, 6),
      menuChildren: [_turnSettingsPanel(l10n)],
      builder: (ctx, ctrl, _) => pill(() {
        if (ctrl.isOpen) {
          ctrl.close();
          return;
        }
        // The list is cached after the first read, so this only round-trips
        // once; the panel renders with whatever it has and fills in.
        _ensureModels().then((_) {
          if (mounted) _updateState(() {});
        });
        ctrl.open();
      }),
    );
  }

  /// The model chip's label. With no explicit pick it shows the model the
  /// server actually runs (the thread default) rather than an opaque
  /// "default".
  String _modelChipLabel(AppLocalizations l10n) => [
    _model?.displayName ??
        _modelDisplayLabel(_runtime?.model) ??
        l10n.modelDefault,
    if (_effectiveEffort != null) _effectiveEffort!.label(l10n),
    if (_plan) l10n.planMode,
  ].join(' · ');

  /// A [_pill]'s width with [label] whole: padding, icon, gap, label and
  /// the [chevron] when it has one.
  double _pillWidth(String label, {bool chevron = false}) =>
      (isDesktop ? 16 : 20) +
      20 +
      (chevron ? 18 : 0) +
      measureTextLine(
        context,
        label,
        const TextStyle(fontSize: 12.5),
      ).width.ceilToDouble();

  /// The desktop model/effort picker, with uncommon modes in a secondary sheet.
  Widget _turnSettingsPanel(AppLocalizations l10n) {
    final scheme = Theme.of(context).colorScheme;
    final selectedId = _model?.id ?? _runtime?.model ?? _sentModel;
    // Always show the model the thread actually runs — even one the host's list
    // doesn't advertise (e.g. a newer `gpt-5.6-*` the server picked). Without
    // this it wasn't selectable and looked absent though it was the live model.
    final models = <ModelInfo>[..._models];
    final activeId = _activeModelStatus()?.id ?? selectedId;
    if (activeId != null && !models.any((m) => m.id == activeId)) {
      models.insert(
        0,
        ModelInfo(
          id: activeId,
          displayName: _modelDisplayLabel(activeId) ?? activeId,
          description: '',
        ),
      );
    }
    return SizedBox(
      width: 320,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _menuHeading(l10n.model),
          if (models.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 2, 14, 8),
              child: Text(
                l10n.modelDefault,
                style: TextStyle(
                  fontSize: 12.5,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            )
          else
            // Not a lazy ListView: a menu panel measures its intrinsic width,
            // which a shrink-wrapped viewport refuses to report.
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 190),
              // `primary: false`: the menu panel already owns the primary
              // scroll controller, and a second attach breaks its scrollbar.
              child: SingleChildScrollView(
                primary: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final m in models)
                      InkWell(
                        mouseCursor: clickable,
                        key: Key('model-menu-item-${m.id}'),
                        onTap: () => _applyModel(m),
                        child: AnimatedContainer(
                          duration: Motion.of(context, Motion.medium),
                          curve: Motion.move,
                          color: m.id == selectedId
                              ? softWash(scheme)
                              : softWash(scheme).withValues(alpha: 0),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 8,
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    m.displayName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                ),
                                if (m.id == selectedId)
                                  Icon(
                                    AppIcons.check,
                                    size: 16,
                                    color: scheme.tertiary,
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          const Divider(height: 9),
          _effortSlider(l10n),
          const Divider(height: 9),
          ListTile(
            key: const Key('advanced-turn-settings'),
            dense: true,
            leading: const Icon(AppIcons.tune, size: 16),
            title: Text(l10n.advancedSettings),
            trailing: const Icon(AppIcons.chevron_right, size: 16),
            onTap: () {
              _modelMenu.close();
              _showAdvancedSettings(l10n);
            },
          ),
        ],
      ),
    );
  }

  /// Reasoning effort as a stepped selector over the levels the active model
  /// advertises (ordered least→most thinking). Falls back to a static label for
  /// a model that offers exactly one level.
  Widget _effortSlider(AppLocalizations l10n) {
    final scheme = Theme.of(context).colorScheme;
    final model = _model ?? (_models.isNotEmpty ? _models.first : null);
    final supported = model?.supportedReasoningEfforts ?? const <String>[];
    final efforts = supported.isEmpty
        ? ReasoningEffort.known
        : [for (final w in supported) ReasoningEffort(w)];
    final current = _effectiveEffort;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 2, 14, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                AppIcons.psychology_outlined,
                size: 16,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l10n.effort,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.5,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              // Fixed-width so the longest label (极高) can't reflow — let alone
              // widen — the panel as the level changes.
              SizedBox(
                width: 52,
                child: AnimatedLabel(
                  current?.label(l10n) ?? l10n.runtimeEffortModelDefault,
                  textAlign: TextAlign.right,
                  alignment: AlignmentDirectional.centerEnd,
                  resize: false,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: scheme.primary,
                  ),
                ),
              ),
            ],
          ),
          if (efforts.length > 1)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: EffortSteps(
                key: const Key('effort-steps'),
                levels: efforts,
                current: current,
                onChanged: _applyEffort,
              ),
            ),
        ],
      ),
    );
  }

  /// Small all-caps heading inside a popover panel.
  Widget _menuHeading(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(14, 8, 14, 6),
    child: Text(
      text.toUpperCase(),
      style: TextStyle(
        fontSize: 10.5,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.7,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );

  /// Select [m] for the next turn, mirroring [_pickModel]'s bookkeeping: hold
  /// the pick against server syncs until it's sent, and drop an effort the new
  /// model doesn't support so we never ship a level it would reject.
  void _applyModel(ModelInfo m) {
    _updateState(() {
      _model = m;
      if (!m.supportsFast) {
        _serviceTier = 'default';
        _serviceTierPickPending = true;
      }
      _modelPickPending = true;
      final eff = _effectiveEffort;
      if (eff != null && !m.supportedReasoningEfforts.contains(eff.wire)) {
        _effort = ReasoningEffort.fromWire(m.defaultReasoningEffort);
        _effortActive = null;
      }
    });
    _rememberDefaults();
    _persistThreadConfig();
  }

  void _applyEffort(ReasoningEffort e) {
    if (e == _effectiveEffort) return;
    _updateState(() => _effort = e);
    _rememberDefaults();
    _persistThreadConfig();
  }

  void _togglePlan() {
    _updateState(() {
      _plan = !_plan;
      _planToggledByUser = true;
    });
    _rememberDefaults();
    _persistThreadConfig();
  }

  /// The settings the model chip fronts: model, effort, project, advanced. A sheet
  /// rather than a popover because every picker it opens is already a sheet,
  /// and a popover anchored to a chip near the keyboard is awkward on a phone.
  Future<void> _showConfigSheet(AppLocalizations l10n) async {
    final model =
        _model?.displayName ??
        _modelDisplayLabel(_runtime?.model) ??
        l10n.modelDefault;
    final choice = await _optionSheet<String>(
      title: l10n.turnSettings,
      isSelected: (_) => false,
      options: [
        _PickerOption(
          value: 'model',
          icon: AppIcons.auto_awesome,
          label: l10n.model,
          description: model,
        ),
        _PickerOption(
          value: 'effort',
          icon: AppIcons.psychology_outlined,
          label: l10n.effort,
          description: _effectiveEffort?.label(l10n),
        ),
        _PickerOption(
          value: 'advanced',
          icon: AppIcons.tune,
          label: l10n.advancedSettings,
        ),
        // The working directory is fixed once the thread exists, so offer it
        // only before the first turn.
        if (_threadId == null)
          _PickerOption(
            value: 'project',
            icon: AppIcons.folder_outlined,
            label: l10n.projectsSection,
            description: _projectName(),
          ),
      ],
    );
    if (!mounted) return;
    switch (choice) {
      case 'model':
        await _pickModel();
      case 'effort':
        await _pickEffort();
      case 'project':
        await _pickProject();
      case 'advanced':
        await _showAdvancedSettings(l10n);
    }
  }

  Future<void> _showAdvancedSettings(AppLocalizations l10n) async {
    final choice = await _optionSheet<String>(
      title: l10n.advancedSettings,
      isSelected: (value) => value == 'plan' && _plan,
      options: [
        _PickerOption(
          value: 'plan',
          icon: AppIcons.checklist_rtl,
          label: l10n.planMode,
          description: l10n.planModeDescription,
        ),
      ],
    );
    if (mounted && choice == 'plan') _togglePlan();
  }

  IconData _modeIcon() => _modeIconFor(_mode);

  IconData _modeIconFor(PermissionMode m) => switch (m) {
    PermissionMode.full => AppIcons.lock_open,
    PermissionMode.readOnly => AppIcons.lock_outline,
    PermissionMode.auto => AppIcons.person_outline,
    PermissionMode.autoReview => AppIcons.verified_user_outlined,
  };

  ModelInfo? get _effectiveModel {
    if (_model != null) return _model;
    final activeId = _modelPickPending ? null : _runtime?.model;
    if (activeId != null) {
      return _models.where((model) => model.id == activeId).firstOrNull;
    }
    return _models.where((model) => model.isDefault).firstOrNull;
  }

  bool get _fastAvailable =>
      _caps.fast && _effectiveModel?.supportsFast == true;

  String? get _effectiveServiceTier =>
      _serviceTier ??
      _runtime?.serviceTier ??
      _effectiveModel?.defaultServiceTier;

  String? get _requestedServiceTier =>
      _effectiveServiceTier == 'priority' &&
          _effectiveModel?.supportsFast == false
      ? 'default'
      : _serviceTier;

  /// A compact, low-chrome setting pill (permission / model). [active]
  /// highlights a toggled-on pill; [warn] flags a risky setting (no-sandbox
  /// "full access"); [trailing] adds a chevron for a pill that opens a menu.
  ///
  /// On touch platforms the pill is grown to a 44 px tap target — the desktop
  /// height reads as a hairline chip under a thumb.
  Widget _pill({
    required IconData icon,
    required String label,
    required VoidCallback? onTap,
    Key? pillKey,
    bool active = false,
    bool warn = false,
    IconData? trailing,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = onTap != null;
    final fg = active
        ? scheme.onTertiaryContainer
        : enabled
        ? scheme.onSurfaceVariant
        : scheme.onSurfaceVariant.withValues(alpha: 0.5);
    final touch = !isDesktop;
    // The tint fades in and out (plan mode on/off) rather than snapping.
    return AnimatedContainer(
      duration: Motion.of(context, Motion.medium),
      curve: Motion.move,
      decoration: BoxDecoration(
        color: active
            ? scheme.tertiaryContainer
            : scheme.tertiaryContainer.withValues(alpha: 0),
        borderRadius: BorderRadius.circular(kControlRadius),
      ),
      child: Material(
        type: MaterialType.transparency,
        borderRadius: BorderRadius.circular(kControlRadius),
        child: InkWell(
          mouseCursor: clickable,
          key: pillKey,
          borderRadius: BorderRadius.circular(kControlRadius),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: touch ? 44 : 30),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: touch ? 10 : 8,
                vertical: 5,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 15, color: warn ? cautionColor(scheme) : fg),
                  const SizedBox(width: 5),
                  Flexible(
                    child: AnimatedLabel(
                      label,
                      style: TextStyle(fontSize: 12.5, color: fg),
                    ),
                  ),
                  if (trailing != null) ...[
                    const SizedBox(width: 2),
                    Icon(trailing, size: 16, color: fg),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
