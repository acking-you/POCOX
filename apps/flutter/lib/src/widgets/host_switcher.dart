import 'package:flutter/material.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/desktop_theme.dart';
import 'package:pocket_codex/src/fonts.dart';
import 'package:pocket_codex/src/motion.dart';
import 'package:pocket_codex/src/service_key.dart';
import 'package:pocket_codex/src/theme.dart';
import 'package:pocket_codex/src/widgets/adaptive_sheet.dart';
import 'package:pocket_codex/src/widgets/agent_icon.dart';
import 'package:pocket_codex/src/widgets/layered_navigation.dart';
import 'package:pocket_codex/src/widgets/provider_badge.dart';
import 'package:pocket_codex/src/widgets/status_dots.dart';
import 'package:pocket_codex/src/app_icons.dart';

/// Where a host switch stands. Owned by the home, which does the switching,
/// and shown wherever the user is looking: the switcher row and the strip
/// above the conversation.
@immutable
class HostSwitch {
  /// A switch to [target] in [phase]; [error] explains a failure.
  const HostSwitch({required this.target, required this.phase, this.error});

  /// The service being switched to.
  final String target;

  /// What the switch is doing now.
  final HostSwitchPhase phase;

  /// Why the switch failed, already worded for the user.
  final String? error;
}

/// The stages a switch passes through, in order.
enum HostSwitchPhase {
  /// Asking the relay whether the host answers.
  probing,

  /// Opening the tunnel and the app-server session.
  connecting,

  /// Loading the host's conversations to land in.
  loading,

  /// The host could not be reached; the current one stays.
  failed,
}

/// `device · name` for [entry].
String hostLabel(ServiceEntry entry) =>
    '${deviceLabel(entry.device)} · ${entry.name}';

/// The sidebar's host row: the host this chat runs on, and the way to change
/// it.
///
/// One trigger for every width. Desktop opens an anchored menu under the row,
/// like the project menu; touch opens a sheet with full-height rows. While a
/// switch runs, the row names the host being reached and shows its progress,
/// so the user can see that something is happening.
///
/// Each host leads with its agent's mark ([identities]). With [onManage] set
/// the list ends in a "manage hosts" entry, so adding or hosting another
/// service is reachable from the conversation even with a single host.
class HostSwitcher extends StatefulWidget {
  /// Creates the switcher for [services], with [current] in effect.
  const HostSwitcher({
    super.key,
    required this.services,
    required this.current,
    required this.onPick,
    this.pending,
    this.identities = const {},
    this.onManage,
    this.onRefresh,
  });

  /// Connectable app services, in display order.
  final List<ServiceEntry> services;

  /// Key of the host serving the chat.
  final String current;

  /// A host was chosen.
  final ValueChanged<String> onPick;

  /// A switch in flight or just failed, if any.
  final HostSwitch? pending;

  /// Known agent identity per service key; unknown keys show the protocol's
  /// generic mark.
  final Map<String, AgentIdentity> identities;

  /// Opens host management (add, host, stop); null hides the entry.
  final VoidCallback? onManage;

  /// Re-discovers services (a host another device just started); the list
  /// updates in place. Null hides the entry.
  final Future<void> Function()? onRefresh;

  @override
  State<HostSwitcher> createState() => _HostSwitcherState();
}

class _HostSwitcherState extends State<HostSwitcher> {
  final MenuController _menu = MenuController();

  /// The services an open sheet shows: it follows discovery while open, so
  /// a refresh updates the list in place.
  late final _services = ValueNotifier(widget.services);

  @override
  void didUpdateWidget(HostSwitcher old) {
    super.didUpdateWidget(old);
    if (identical(old.services, widget.services)) return;
    // The open sheet is another route; it is told after this build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _services.value = widget.services;
    });
  }

  @override
  void dispose() {
    _services.dispose();
    super.dispose();
  }

  bool get _busy {
    final p = widget.pending;
    return p != null && p.phase != HostSwitchPhase.failed;
  }

  String _labelOf(String key) {
    for (final s in widget.services) {
      if (s.key == key) return hostLabel(s);
    }
    return serviceKeyLabel(key);
  }

  void _pick(String key) {
    _menu.close();
    if (key == widget.current || _busy) return;
    // On a phone this row lives in the sidebar, which would cover the
    // progress strip the switch shows above the conversation.
    _closeNavigation();
    widget.onPick(key);
  }

  void _manage() {
    _menu.close();
    _closeNavigation();
    widget.onManage?.call();
  }

  /// Close the phone sidebar (or a Scaffold drawer) this row sits in.
  void _closeNavigation() {
    final nav = LayeredNavigation.maybeOf(context);
    if (nav?.isOpen ?? false) {
      nav!.close();
      return;
    }
    final scaffold = Scaffold.maybeOf(context);
    if (scaffold?.isDrawerOpen ?? false) scaffold!.closeDrawer();
  }

  Future<void> _openSheet() => showAdaptivePanel<void>(
    context: context,
    anchored: true,
    builder: (c) => ValueListenableBuilder(
      valueListenable: _services,
      builder: (_, services, _) => _HostList(
        services: services,
        current: widget.current,
        pending: widget.pending,
        identities: widget.identities,
        touch: true,
        onPick: (key) {
          Navigator.of(c).pop();
          _pick(key);
        },
        onManage: widget.onManage == null
            ? null
            : () {
                Navigator.of(c).pop();
                _manage();
              },
        onRefresh: widget.onRefresh,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final multiple = widget.services.length > 1;
    // A single host still opens the list when it can lead to management.
    final opens = multiple || widget.onManage != null;
    final pending = widget.pending;
    final busy = _busy;
    final label = busy
        ? l10n.hostSwitchingTo(_labelOf(pending!.target))
        : _labelOf(widget.current);
    final touch = !isDesktop;

    Widget row(VoidCallback? onTap) => Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(kRowRadius),
      child: InkWell(
        key: const Key('sidebar-service-switcher'),
        mouseCursor: onTap == null ? SystemMouseCursors.basic : clickable,
        borderRadius: BorderRadius.circular(kRowRadius),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: touch ? 44 : 32),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                SizedBox(
                  width: 16,
                  child: Center(
                    child: busy
                        ? SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(
                              key: const Key('host-switch-progress'),
                              strokeWidth: 1.6,
                              color: signalColor(scheme),
                            ),
                          )
                        : _identityIcon(
                            widget.identities,
                            widget.current,
                            scheme.onSurfaceVariant,
                          ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: AnimatedSwitcher(
                    duration: Motion.of(context, Motion.fast),
                    layoutBuilder: (current, previous) => Stack(
                      alignment: AlignmentDirectional.centerStart,
                      children: [...previous, ?current],
                    ),
                    child: Text(
                      label,
                      key: ValueKey(label),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: busy ? signalColor(scheme) : scheme.onSurface,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                _badge(
                  widget.identities,
                  busy ? pending!.target : widget.current,
                ),
                if (opens && !busy)
                  Icon(
                    AppIcons.unfold_more_rounded,
                    size: 16,
                    color: scheme.onSurfaceVariant,
                  ),
              ],
            ),
          ),
        ),
      ),
    );

    final Widget trigger;
    if (!opens) {
      trigger = Semantics(
        label: l10n.hostCurrent(label),
        excludeSemantics: true,
        child: row(null),
      );
    } else if (touch) {
      trigger = Semantics(
        button: true,
        label: l10n.hostSwitchHint(label),
        excludeSemantics: true,
        child: row(busy ? null : _openSheet),
      );
    } else {
      trigger = MenuAnchor(
        controller: _menu,
        alignmentOffset: const Offset(0, 4),
        style: MenuStyle(
          padding: WidgetStateProperty.all(
            const EdgeInsets.symmetric(vertical: 6),
          ),
        ),
        menuChildren: [
          SizedBox(
            width: 280,
            child: _HostList(
              services: widget.services,
              current: widget.current,
              pending: pending,
              identities: widget.identities,
              touch: false,
              onPick: _pick,
              onManage: widget.onManage == null ? null : _manage,
              onRefresh: widget.onRefresh,
            ),
          ),
        ],
        builder: (context, controller, _) => Semantics(
          button: true,
          label: l10n.hostSwitchHint(label),
          excludeSemantics: true,
          child: row(
            busy
                ? null
                : () => controller.isOpen
                      ? controller.close()
                      : controller.open(),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      child: trigger,
    );
  }
}

/// The agent mark of [key]: its known identity, else its protocol's.
Widget _identityIcon(
  Map<String, AgentIdentity> identities,
  String key,
  Color color,
) {
  final known = identities[key];
  return AgentIcon.of(
    key: Key('host-agent-icon-$key'),
    provider:
        known?.provider ??
        switch (sessionProtocolOf(key)) {
          SessionProtocol.acp => 'acp',
          SessionProtocol.opencode => 'opencode',
          SessionProtocol.codexAppServer => 'codex',
        },
    profileId: known?.profileId,
    name: known?.name ?? '',
    color: color,
  );
}

/// The provider pill of [key], named from its known identity. The mark is
/// already beside the host, so the pill omits it.
Widget _badge(Map<String, AgentIdentity> identities, String key) {
  final known = identities[key];
  return ProviderBadge.forKey(
    key,
    name: known?.name,
    profileId: known?.profileId,
    showIcon: false,
  );
}

/// The hosts, the current one checked. Shared by the desktop menu and the
/// touch sheet so they cannot drift apart.
class _HostList extends StatelessWidget {
  const _HostList({
    required this.services,
    required this.current,
    required this.pending,
    required this.identities,
    required this.touch,
    required this.onPick,
    this.onManage,
    this.onRefresh,
  });

  final List<ServiceEntry> services;
  final String current;
  final HostSwitch? pending;
  final Map<String, AgentIdentity> identities;
  final bool touch;
  final ValueChanged<String> onPick;
  final VoidCallback? onManage;
  final Future<void> Function()? onRefresh;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final sameNamed = sameNamedDevices(services.map((s) => s.device));
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(touch ? 20 : 12, 2, 12, 6),
          child: Text(
            l10n.hostSwitchTitle,
            style: Theme.of(
              context,
            ).textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
        for (final s in services) _item(context, s, sameNamed),
        if (onRefresh != null || onManage != null) const Divider(height: 9),
        if (onRefresh case final refresh?)
          _RefreshServicesRow(onRefresh: refresh, touch: touch),
        if (onManage != null) ...[
          InkWell(
            key: const Key('host-switch-manage'),
            mouseCursor: clickable,
            onTap: onManage,
            child: Padding(
              padding: _rowPadding(touch),
              child: Row(
                children: [
                  Icon(AppIcons.add, size: 16, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      l10n.hostSwitchManage,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: touch ? 14 : 13),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
        if (touch) const SizedBox(height: 8),
      ],
    );
  }

  Widget _item(BuildContext context, ServiceEntry s, Set<String> sameNamed) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final isCurrent = s.key == current;
    final failed =
        pending?.target == s.key && pending?.phase == HostSwitchPhase.failed;
    return InkWell(
      key: Key('host-switch-item-${s.key}'),
      mouseCursor: clickable,
      onTap: () => onPick(s.key),
      child: Padding(
        padding: _rowPadding(touch),
        child: Row(
          children: [
            _identityIcon(identities, s.key, scheme.onSurfaceVariant),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Two lines on touch: a long device or instance name (or the
                  // failure) stays recognisable in a phone's sheet.
                  Text(
                    deviceLabel(s.device),
                    maxLines: touch ? 2 : 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: touch ? 14 : 13,
                      fontWeight: isCurrent ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                  Text(
                    [
                      if (failed)
                        l10n.hostSwitchLastFailed
                      else if (isCurrent)
                        l10n.hostInUse(s.name)
                      else
                        s.name,
                      // Same-name installations differ only by their ID.
                      if (sameNamed.contains(s.device))
                        ?deviceShortId(s.device),
                    ].join(' · '),
                    maxLines: touch ? 2 : 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: failed ? scheme.error : scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            _badge(identities, s.key),
            const SizedBox(width: 6),
            StatusDot(
              color: failed
                  ? scheme.error
                  : isCurrent
                  ? successColor(scheme)
                  : scheme.outline,
              size: 8,
            ),
            if (isCurrent)
              Icon(AppIcons.check, size: 16, color: signalColor(scheme)),
          ],
        ),
      ),
    );
  }
}

/// The strip above the conversation while a switch runs or after it fails:
/// which host, which step, and on failure why, with a retry.
///
/// The conversation underneath stays readable: a switch never tears the
/// current chat down until the new host has answered.
class HostSwitchBanner extends StatelessWidget {
  /// Shows [pending]; [onRetry] and [onDismiss] act on a failure.
  const HostSwitchBanner({
    super.key,
    required this.pending,
    required this.targetLabel,
    required this.onRetry,
    required this.onDismiss,
  });

  /// The switch to show.
  final HostSwitch pending;

  /// `device · name` of the target.
  final String targetLabel;

  /// Try the same switch again.
  final VoidCallback onRetry;

  /// Close a failure notice.
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final failed = pending.phase == HostSwitchPhase.failed;
    final step = switch (pending.phase) {
      HostSwitchPhase.probing => l10n.hostSwitchProbing,
      HostSwitchPhase.connecting => l10n.hostSwitchConnecting,
      HostSwitchPhase.loading => l10n.hostSwitchLoading,
      HostSwitchPhase.failed => pending.error ?? l10n.switchServiceFailed,
    };
    // Steps fill a third of the bar each: progress the eye can follow
    // without pretending to know how long a relay round trip takes.
    final progress = switch (pending.phase) {
      HostSwitchPhase.probing => 0.2,
      HostSwitchPhase.connecting => 0.55,
      HostSwitchPhase.loading => 0.85,
      HostSwitchPhase.failed => 1.0,
    };
    return Semantics(
      liveRegion: true,
      container: true,
      child: Container(
        key: const Key('host-switch-banner'),
        margin: const EdgeInsets.fromLTRB(12, 6, 12, 2),
        decoration: BoxDecoration(
          color: failed ? scheme.errorContainer : softWash(scheme),
          borderRadius: BorderRadius.circular(kPanelRadius),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(14, 8, failed ? 4 : 14, 8),
              child: Row(
                children: [
                  Icon(
                    failed
                        ? AppIcons.cloud_off_outlined
                        : AppIcons.sync_rounded,
                    size: 18,
                    color: failed
                        ? scheme.onErrorContainer
                        : signalColor(scheme),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          failed
                              ? l10n.hostSwitchFailedTitle(targetLabel)
                              : l10n.hostSwitchingTo(targetLabel),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: failed
                                ? scheme.onErrorContainer
                                : scheme.onSurface,
                          ),
                        ),
                        AnimatedSwitcher(
                          duration: Motion.of(context, Motion.fast),
                          layoutBuilder: (current, previous) => Stack(
                            alignment: AlignmentDirectional.topStart,
                            children: [...previous, ?current],
                          ),
                          child: Text(
                            step,
                            key: ValueKey(step),
                            maxLines: failed ? 3 : 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: failed
                                  ? scheme.onErrorContainer
                                  : scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (failed) ...[
                    TextButton(
                      key: const Key('host-switch-retry'),
                      onPressed: onRetry,
                      child: Text(l10n.retry),
                    ),
                    IconButton(
                      key: const Key('host-switch-dismiss'),
                      tooltip: MaterialLocalizations.of(
                        context,
                      ).closeButtonTooltip,
                      icon: const Icon(AppIcons.close, size: 18),
                      onPressed: onDismiss,
                    ),
                  ],
                ],
              ),
            ),
            if (!failed)
              TweenAnimationBuilder<double>(
                tween: Tween(end: progress),
                duration: Motion.of(context, Motion.medium),
                curve: Motion.move,
                builder: (context, v, _) => LinearProgressIndicator(
                  value: v,
                  minHeight: 2,
                  color: signalColor(scheme),
                  backgroundColor: Colors.transparent,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The inset of every row in the host switcher.
EdgeInsets _rowPadding(bool touch) =>
    EdgeInsets.symmetric(horizontal: touch ? 20 : 12, vertical: touch ? 12 : 8);

/// "Refresh services": re-discovers hosts in place, with progress while it
/// runs and a retryable note when it fails. The shown list stays until the
/// new one arrives.
class _RefreshServicesRow extends StatefulWidget {
  const _RefreshServicesRow({required this.onRefresh, required this.touch});

  final Future<void> Function() onRefresh;
  final bool touch;

  @override
  State<_RefreshServicesRow> createState() => _RefreshServicesRowState();
}

class _RefreshServicesRowState extends State<_RefreshServicesRow> {
  bool _busy = false;
  bool _failed = false;

  Future<void> _refresh() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _failed = false;
    });
    var failed = false;
    try {
      await widget.onRefresh();
    } catch (_) {
      failed = true;
    }
    if (mounted) {
      setState(() {
        _busy = false;
        _failed = failed;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final touch = widget.touch;
    return InkWell(
      key: const Key('host-switch-refresh'),
      mouseCursor: clickable,
      onTap: _busy ? null : _refresh,
      child: Padding(
        padding: _rowPadding(touch),
        child: Row(
          children: [
            SizedBox.square(
              dimension: 16,
              child: _busy
                  ? CircularProgressIndicator(
                      strokeWidth: 2,
                      color: scheme.tertiary,
                    )
                  : Icon(AppIcons.refresh, size: 16, color: scheme.tertiary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    l10n.refreshServices,
                    style: TextStyle(fontSize: touch ? 14 : 13),
                  ),
                  if (_failed)
                    Text(
                      l10n.refreshServicesFailed,
                      key: const Key('host-switch-refresh-error'),
                      style: TextStyle(fontSize: 12, color: scheme.error),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
