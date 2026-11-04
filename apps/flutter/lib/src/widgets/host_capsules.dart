part of 'host_switcher.dart';

/// The devices as capsules that scroll sideways and, when the one in use hosts
/// several agents, those agents in a row under them: a phone's drawer is too
/// narrow to repeat a device's name for each. Grouping, identity and
/// retained-connection marks are the full list's, which the current device's
/// capsule and, when they overflow, a control at the row's end open.
class _HostCapsules extends StatefulWidget {
  const _HostCapsules({
    required this.services,
    required this.current,
    required this.pending,
    required this.identities,
    required this.localKeys,
    required this.connectedKeys,
    required this.onPick,
    required this.onOpenList,
  });

  final List<ServiceEntry> services;
  final String current;
  final HostSwitch? pending;
  final Map<String, AgentIdentity> identities;
  final Set<String> localKeys;
  final Set<String> connectedKeys;
  final ValueChanged<String> onPick;
  final VoidCallback onOpenList;

  @override
  State<_HostCapsules> createState() => _HostCapsulesState();
}

class _HostCapsulesState extends State<_HostCapsules> {
  /// The agent last used on each device this run, which going back to the
  /// device returns to. Every host switch rebuilds this widget.
  static final _lastOnDevice = <String, String>{};

  bool _overflows = false;

  /// Keep what is in use in view, wherever the order puts it.
  final _currentKey = GlobalKey();
  final _currentAgentKey = GlobalKey();
  String? _revealed;

  void _revealCurrent() {
    if (_revealed == widget.current) return;
    _revealed = widget.current;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      for (final key in [_currentKey, _currentAgentKey]) {
        final context = key.currentContext;
        if (context != null) Scrollable.ensureVisible(context, alignment: 0.5);
      }
    });
  }

  /// Which of a device's agents its capsule leads to: the one last used, else
  /// one still connected, else the first.
  String _target(MapEntry<String, List<ServiceEntry>> group) {
    final keys = [for (final service in group.value) service.key];
    final last = _lastOnDevice[group.key];
    if (last != null && keys.contains(last)) return last;
    return keys.firstWhere(
      widget.connectedKeys.contains,
      orElse: () => keys.first,
    );
  }

  /// What names [service] among its device's: the agent, and its service name
  /// when the device has two of that agent.
  String _agentLabel(
    ServiceEntry service,
    List<ServiceEntry> siblings,
    AppLocalizations l10n,
  ) {
    final kind = parseServiceKey(service.key).kind;
    final known = widget.identities[service.key]?.name?.trim() ?? '';
    final agent = switch (sessionProtocolOf(service.key)) {
      SessionProtocol.acp => known.isNotEmpty ? known : l10n.providerAcpAgent,
      SessionProtocol.opencode => l10n.providerOpenCode,
      SessionProtocol.codexAppServer => l10n.providerCodex,
    };
    final twins = siblings.where(
      (other) => parseServiceKey(other.key).kind == kind,
    );
    return twins.length > 1 ? '$agent · ${service.name}' : agent;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final ordered = _hostGroups(widget.services, widget.localKeys);
    final inUse = ordered
        .where((g) => g.value.any((s) => s.key == widget.current))
        .firstOrNull;
    if (inUse != null) _lastOnDevice[inUse.key] = widget.current;
    // Once it can be seen: a hidden drawer has nothing to bring into view.
    if (TickerMode.valuesOf(context).enabled) _revealCurrent();
    final pending = widget.pending;
    final busy = pending != null && pending.phase != HostSwitchPhase.failed;
    bool failedAt(Iterable<String> keys) =>
        pending?.phase == HostSwitchPhase.failed &&
        keys.contains(pending?.target);
    bool reachingAt(Iterable<String> keys) =>
        busy && keys.contains(pending.target);

    Widget deviceCapsule(MapEntry<String, List<ServiceEntry>> group) {
      final keys = [for (final service in group.value) service.key];
      final current = identical(group, inUse);
      final target = current ? widget.current : _target(group);
      final retained = current
          ? null
          : keys.where(widget.connectedKeys.contains).firstOrNull;
      final capsule = _HostCapsule(
        key: current
            ? const Key('sidebar-service-switcher')
            : Key('host-capsule-$target'),
        serviceKeys: keys,
        label: [
          deviceLabel(group.value.first.device),
          ?_groupDistinction(group, ordered),
        ].join(' · '),
        semanticLabel: group.value.length == 1
            ? hostLabel(group.value.single)
            : [
                deviceLabel(group.value.first.device),
                for (final service in group.value)
                  _agentLabel(service, group.value, l10n),
              ].join(' · '),
        identities: widget.identities,
        current: current,
        retainedKey: retained,
        failed: failedAt(keys),
        reaching: reachingAt(keys),
        onTap: current
            ? widget.onOpenList
            : busy
            ? null
            : () => widget.onPick(target),
      );
      return current ? KeyedSubtree(key: _currentKey, child: capsule) : capsule;
    }

    final row = NotificationListener<ScrollMetricsNotification>(
      onNotification: (note) {
        final overflows = note.metrics.maxScrollExtent > 0;
        if (overflows != _overflows) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() => _overflows = overflows);
          });
        }
        return false;
      },
      child: SingleChildScrollView(
        key: const Key('host-capsules'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsetsDirectional.fromSTEB(12, 0, 12, 0),
        child: Row(
          children: [
            // The service in use before anything is listed: it still has its
            // capsule.
            if (inUse == null)
              _HostCapsule(
                key: const Key('sidebar-service-switcher'),
                serviceKeys: [widget.current],
                label: serviceKeyLabel(widget.current),
                semanticLabel: serviceKeyLabel(widget.current),
                identities: widget.identities,
                current: true,
                retainedKey: null,
                failed: false,
                reaching: false,
                onTap: widget.onOpenList,
              ),
            for (final (index, group) in ordered.indexed) ...[
              if (index > 0 || inUse == null) const SizedBox(width: 8),
              deviceCapsule(group),
            ],
          ],
        ),
      ),
    );
    final devices = Row(
      children: [
        Expanded(
          child: _overflows
              // The row fades out at its end, so it reads as going on.
              ? ShaderMask(
                  shaderCallback: (bounds) =>
                      const LinearGradient(
                        begin: AlignmentDirectional.centerStart,
                        end: AlignmentDirectional.centerEnd,
                        colors: [
                          Colors.black,
                          Colors.black,
                          Colors.transparent,
                        ],
                        stops: [0, 0.88, 1],
                      ).createShader(
                        bounds,
                        textDirection: Directionality.of(context),
                      ),
                  blendMode: BlendMode.dstIn,
                  child: row,
                )
              : row,
        ),
        if (_overflows)
          IconButton(
            key: const Key('host-capsules-all'),
            tooltip: l10n.hostSwitchTitle,
            icon: const Icon(AppIcons.unfold_more_rounded, size: 18),
            onPressed: widget.onOpenList,
          ),
      ],
    );
    final agents = inUse?.value ?? const <ServiceEntry>[];
    if (agents.length < 2) return devices;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        devices,
        const SizedBox(height: 2),
        SingleChildScrollView(
          key: const Key('host-agents'),
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsetsDirectional.fromSTEB(12, 0, 12, 0),
          child: Row(
            children: [
              for (final service in agents)
                _AgentChip(
                  key: service.key == widget.current
                      ? _currentAgentKey
                      : Key('host-capsule-${service.key}'),
                  serviceKey: service.key,
                  label: _agentLabel(service, agents, l10n),
                  identities: widget.identities,
                  current: service.key == widget.current,
                  retained:
                      service.key != widget.current &&
                      widget.connectedKeys.contains(service.key),
                  failed: failedAt([service.key]),
                  reaching: reachingAt([service.key]),
                  onTap: service.key == widget.current || busy
                      ? null
                      : () => widget.onPick(service.key),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// A round ground for an agent's mark, or a switch's progress in its place.
class _AgentMark extends StatelessWidget {
  const _AgentMark({
    required this.serviceKey,
    required this.identities,
    required this.current,
    this.reaching = false,
    this.edge,
  });

  final String serviceKey;
  final Map<String, AgentIdentity> identities;
  final bool current;
  final bool reaching;

  /// A ring that parts this mark from the one it overlaps.
  final Color? edge;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox.square(
      dimension: 26,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: current
              ? scheme.surfaceContainer
              : scheme.surfaceContainerHighest,
          border: edge == null ? null : Border.all(color: edge!, width: 1.5),
        ),
        child: Center(
          child: reaching
              ? SizedBox.square(
                  dimension: 12,
                  child: CircularProgressIndicator(
                    key: const Key('host-switch-progress'),
                    strokeWidth: 1.6,
                    color: signalColor(scheme),
                  ),
                )
              : _identityIcon(identities, serviceKey, scheme.onSurface),
        ),
      ),
    );
  }
}

/// One of the device-in-use's agents: its mark and its name, the one in use on
/// a plate.
class _AgentChip extends StatelessWidget {
  const _AgentChip({
    super.key,
    required this.serviceKey,
    required this.label,
    required this.identities,
    required this.current,
    required this.retained,
    required this.failed,
    required this.reaching,
    required this.onTap,
  });

  final String serviceKey;
  final String label;
  final Map<String, AgentIdentity> identities;
  final bool current;
  final bool retained;
  final bool failed;
  final bool reaching;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    const radius = BorderRadius.all(Radius.circular(22));
    return Semantics(
      button: true,
      selected: current,
      label: label,
      value: failed
          ? l10n.hostSwitchLastFailed
          : current
          ? l10n.hostConnectionCurrent
          : retained
          ? l10n.hostConnectionRetained
          : null,
      excludeSemantics: true,
      child: Material(
        color: current ? softWash(scheme) : Colors.transparent,
        borderRadius: radius,
        child: InkWell(
          mouseCursor: clickable,
          borderRadius: radius,
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(6, 4, 12, 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _AgentMark(
                    serviceKey: serviceKey,
                    identities: identities,
                    current: current,
                    reaching: reaching,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    label,
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: current ? FontWeight.w500 : FontWeight.w400,
                      color: current
                          ? scheme.onSurface
                          : scheme.onSurfaceVariant,
                    ),
                  ),
                  if (retained) ...[
                    const SizedBox(width: 7),
                    StatusDot(
                      key: Key('host-switch-retained-$serviceKey'),
                      color: successColor(scheme),
                      size: 7,
                    ),
                  ] else if (failed) ...[
                    const SizedBox(width: 7),
                    StatusDot(color: scheme.error, size: 7),
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

/// One device's capsule: its agents' marks, its name, and one mark for its
/// connection, as in the full list.
class _HostCapsule extends StatelessWidget {
  const _HostCapsule({
    super.key,
    required this.serviceKeys,
    required this.label,
    required this.semanticLabel,
    required this.identities,
    required this.current,
    required this.retainedKey,
    required this.failed,
    required this.reaching,
    required this.onTap,
  });

  /// The device's agents; up to three show their marks, overlapping.
  final List<String> serviceKeys;
  final String label;
  final String semanticLabel;
  final Map<String, AgentIdentity> identities;
  final bool current;

  /// A connection this device keeps from earlier, for its mark.
  final String? retainedKey;
  final bool failed;
  final bool reaching;
  final VoidCallback? onTap;

  /// How far each further agent's mark sits from the one before it.
  static const double _markStep = 15;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    const radius = BorderRadius.all(Radius.circular(22));
    // Each overlapping mark is parted from the next by the capsule's own ground.
    final ground = current ? scheme.surfaceContainerHighest : scheme.surface;
    final shown = serviceKeys.take(3).toList(growable: false);
    return Semantics(
      button: true,
      selected: current,
      label: semanticLabel,
      value: failed
          ? l10n.hostSwitchLastFailed
          : current
          ? l10n.hostConnectionCurrent
          : retainedKey != null
          ? l10n.hostConnectionRetained
          : null,
      excludeSemantics: true,
      child: Material(
        color: current ? scheme.surfaceContainerHighest : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: current
              ? BorderSide.none
              : BorderSide(color: scheme.outlineVariant),
        ),
        child: InkWell(
          mouseCursor: clickable,
          borderRadius: radius,
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(9, 4, 14, 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 26 + (shown.length - 1) * _markStep,
                    height: 26,
                    child: Stack(
                      children: [
                        for (final (index, key) in shown.indexed)
                          PositionedDirectional(
                            start: index * _markStep,
                            child: _AgentMark(
                              serviceKey: key,
                              identities: identities,
                              current: current,
                              reaching: reaching && index == 0,
                              edge: shown.length > 1 ? ground : null,
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 7),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 180),
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w500,
                        color: current
                            ? scheme.onSurface
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  if (retainedKey case final key?) ...[
                    const SizedBox(width: 7),
                    StatusDot(
                      key: Key('host-switch-retained-$key'),
                      color: successColor(scheme),
                      size: 7,
                    ),
                  ] else if (failed) ...[
                    const SizedBox(width: 7),
                    StatusDot(color: scheme.error, size: 7),
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
