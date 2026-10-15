part of '../services_screen.dart';

/// The service inventory, organized around devices rather than protocol tabs.
/// App/API remain the real discovered services; session sharing is presented
/// as a capability derived from an account-mode app host, because meta is
/// intentionally not returned by service discovery.
///
/// Wide lays the device column beside the selected device's detail. Narrow can't
/// hold both, so it becomes two levels: the device list, then that device's
/// capabilities with the title bar's `Services / <device>` origin leading back.
class _DeviceFirstServices extends ConsumerWidget {
  const _DeviceFirstServices({
    required this.services,
    required this.relay,
    required this.accountLogin,
    required this.accountId,
    required this.selectedDevice,
    required this.onSelectDevice,
    required this.onClearDevice,
  });

  final List<ServiceEntry> services;
  final String? relay;
  final String? accountLogin;
  final String? accountId;

  /// The device whose detail is shown. On narrow this doubles as the level:
  /// null is the device list, set is that device's capabilities.
  final String? selectedDevice;
  final ValueChanged<String> onSelectDevice;

  /// Return to the device list (narrow only).
  final VoidCallback onClearDevice;

  /// Below this the device column and the detail can't sit side by side. Matches
  /// the conversation's own document-layout breakpoint so the whole app changes
  /// idiom at one width rather than each screen picking its own.
  static const double _splitWidth = 720;

  /// The device column's width beside the detail.
  static const double _columnWidth = 260;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final account = accountLogin != null;
    final pending = ref.watch(pendingRemovalProvider);
    final dismissed =
        ref.watch(dismissedServicesProvider).valueOrNull ?? const <String>{};
    final localHosts =
        ref.watch(localServeListProvider).valueOrNull ??
        const <AppServeStatus>[];
    ref.listen(servicesProvider, (_, next) {
      final data = next.valueOrNull;
      if (data == null) return;
      final present = {for (final service in data) service.key};
      final current = ref.read(pendingRemovalProvider);
      final stillHidden = current.intersection(present);
      if (stillHidden.length != current.length) {
        ref.read(pendingRemovalProvider.notifier).state = stillHidden;
      }
    });

    final visible = <ServiceEntry>[
      for (final service in services)
        if (!pending.contains(service.key) && !dismissed.contains(service.key))
          service,
    ];
    // A freshly-started host can precede the next relay discovery refresh, so
    // synthesize its entries rather than waiting for discovery.
    //
    // Deregistered tunnels are listed too, as offline rows: the capability list
    // is now the only place a tunnel can be published again, so hiding a
    // deregistered one would strand it with no route back. `pending` is still
    // honoured — it now means only "this whole host is being stopped".
    final offlineTunnels = <String>{};
    for (final host in localHosts) {
      void synthesize(String kind, String key, {required bool registered}) {
        // A host listed only because its codex did not exit has no tunnels.
        if (key.isEmpty || pending.contains(key)) return;
        if (!registered) offlineTunnels.add(key);
        if (visible.any((service) => service.key == key)) return;
        visible.add(
          ServiceEntry(
            device: host.device,
            kind: kind,
            name: host.name,
            key: key,
          ),
        );
      }

      synthesize(
        host.sessionKind,
        host.appServiceKey,
        registered: host.appRegistered,
      );
      // Only a Codex host publishes a Responses API proxy.
      if (host.isCodex) {
        synthesize('api', host.apiServiceKey, registered: host.apiRegistered);
      }
    }

    // A dismissed orphan should reappear if its backend later recovers. This
    // mirrors the compact layout's recovery contract.
    if (dismissed.isNotEmpty) {
      final recovered = <String>[
        for (final service in services)
          if (dismissed.contains(service.key) &&
              service.kind != 'host' &&
              (isSessionKind(service.kind)
                          ? ref.watch(appReachableProvider(service.key))
                          : ref.watch(apiReachableProvider(service.key)))
                      .valueOrNull ==
                  true)
            service.key,
      ];
      if (recovered.isNotEmpty) {
        final notifier = ref.read(dismissedServicesProvider.notifier);
        Future.microtask(() => notifier.restore(recovered));
      }
    }

    // A computer's management entry (`host:`) is never a chat or model
    // service: it only keeps its device listed, even with no services left,
    // and opens that computer's management panel.
    final managementKeys = <String, String>{
      for (final service in visible)
        if (service.kind == 'host') service.device: service.key,
    };
    final ownManagementKey = _hostingSupported
        ? ref.watch(deviceManagementProvider).valueOrNull?.serviceKey
        : null;
    final ownDevice = ownManagementKey == null
        ? null
        : serviceKeyDevice(ownManagementKey);
    final localDevices = {
      for (final host in localHosts) host.device,
      if (ownDevice != null && ownDevice.isNotEmpty) ownDevice,
    };
    final devices = <String>{
      for (final service in visible) service.device,
      ...localDevices,
    }.toList()..sort();
    // With no host running here and management off (so no published key),
    // nothing names this computer's device. Its hosting and management
    // controls must stay reachable anyway, or management could never be
    // switched back on: they then sit under whichever device is selected.
    final localUnknown = !devices.any(localDevices.contains);
    final preferredKey = ref.watch(
      uiPrefsProvider.select(
        (prefs) => prefs.valueOrNull?.preferredAppServiceKey,
      ),
    );
    final preferredDevice = visible
        .where((service) => service.key == preferredKey)
        .firstOrNull
        ?.device;
    devices.sort((a, b) {
      int rank(String device) {
        if (device == preferredDevice) return 0;
        if (localDevices.contains(device)) return 1;
        return 2;
      }

      final byRank = rank(a).compareTo(rank(b));
      return byRank == 0 ? a.compareTo(b) : byRank;
    });
    // Side by side only while the fixed-width column still holds its
    // identity row at the current text scale; large text gets the one-level
    // layout instead, with the column at full width.
    final split =
        MediaQuery.sizeOf(context).width >= _splitWidth &&
        _identityRowWidth(context, l10n.statusOnline) <= _columnWidth;
    // Wide always has a device in the detail pane — an empty pane beside a
    // populated column reads as broken. Narrow shows the list first and only
    // resolves a device once one is picked, so nothing is chosen on the user's
    // behalf on a screen that can only show one level at a time.
    final activeDevice = devices.contains(selectedDevice)
        ? selectedDevice
        : !split
        ? null
        : preferredDevice != null && devices.contains(preferredDevice)
        ? preferredDevice
        : devices.firstOrNull;
    final deviceEntries =
        visible
            .where(
              (service) =>
                  service.device == activeDevice && service.kind != 'host',
            )
            .toList()
          ..sort((a, b) {
            final byName = a.name.compareTo(b.name);
            return byName == 0 ? a.kind.compareTo(b.kind) : byName;
          });
    final apps = deviceEntries
        .where((service) => isSessionKind(service.kind))
        .toList();
    // The session browser reads Codex rollouts, so only Codex hosts get a
    // Sessions (meta) row.
    final codexApps = apps.where((service) => service.kind == 'app').toList();
    final apis = deviceEntries
        .where((service) => service.kind == 'api')
        .toList();
    final capabilityCount =
        apps.length + apis.length + (account ? codexApps.length : 0);

    // Loopback probing speaks the Codex handshake; ACP gateways
    // are probed through appProbe, which dispatches by key kind.
    final localAppAddr = <String, String>{
      for (final host in localHosts)
        if (host.isCodex) host.appServiceKey: host.appListenAddr,
    };
    final localApiAddr = <String, String>{
      for (final host in localHosts)
        if (host.isCodex) host.apiServiceKey: host.apiListenAddr,
    };
    final localTunnels = <String, ({String name, String kind})>{
      for (final host in localHosts)
        if (host.isCodex) ...{
          host.appServiceKey: (name: host.name, kind: 'app'),
          host.apiServiceKey: (name: host.name, kind: 'api'),
        } else
          host.appServiceKey: (name: host.name, kind: host.sessionKind),
    };
    final subscriptions = {
      for (final sub
          in ref.watch(subscriptionsProvider).valueOrNull ?? const <SubInfo>[])
        sub.key: sub,
    };
    final bridge = ref.watch(bridgeApiProvider);
    final observedDown = ref.watch(observedDisconnectedProvider);
    final online = successColor(scheme);

    // A capability's status pill, plus the reason when it is unreachable: the
    // relay registration can outlive the backend it forwards to, and "offline"
    // alone leaves the user unable to tell which half is at fault.
    ({Widget chip, String? reason}) status({
      required bool unreachable,
      required String label,
      required Color color,
      required String reasonText,
    }) => (
      chip: StatusChip(color: color, label: label, filled: true),
      reason: unreachable ? reasonText : null,
    );

    ({Widget chip, String? reason}) appStatus(ServiceEntry service) {
      if (!observedDown.contains(service.key) &&
          bridge.appIsConnected(service.key)) {
        return status(
          unreachable: false,
          label: l10n.statusConnected,
          color: online,
          reasonText: l10n.unreachableReason,
        );
      }
      if (observedDown.contains(service.key)) {
        return status(
          unreachable: true,
          label: l10n.statusUnreachable,
          color: scheme.error,
          reasonText: l10n.unreachableReason,
        );
      }
      final localAddr = localAppAddr[service.key];
      final reach = localAddr == null
          ? ref.watch(appReachableProvider(service.key))
          : ref.watch(appReachableLocalProvider(localAddr));
      return reach.when(
        data: (ok) => status(
          unreachable: !ok,
          label: ok ? l10n.statusOnline : l10n.statusUnreachable,
          color: ok ? online : scheme.error,
          reasonText: l10n.unreachableReason,
        ),
        loading: () => status(
          unreachable: false,
          label: l10n.statusChecking,
          color: scheme.outline,
          reasonText: l10n.unreachableReason,
        ),
        error: (_, _) => status(
          unreachable: true,
          label: l10n.statusUnreachable,
          color: scheme.error,
          reasonText: l10n.unreachableReason,
        ),
      );
    }

    ({Widget chip, String? reason}) apiStatus(ServiceEntry service) {
      final sub = subscriptions[service.key];
      if (sub != null) {
        return status(
          unreachable: !sub.alive,
          label: sub.alive ? l10n.subscribedAlive : l10n.subscribedDead,
          color: sub.alive ? online : scheme.error,
          reasonText: l10n.apiUnreachableReason,
        );
      }
      final localAddr = localApiAddr[service.key];
      final reach = localAddr == null
          ? ref.watch(apiReachableProvider(service.key))
          : ref.watch(apiReachableLocalProvider(localAddr));
      return reach.when(
        data: (ok) => status(
          unreachable: !ok,
          label: ok ? l10n.statusOnline : l10n.statusUnreachable,
          color: ok ? online : scheme.error,
          reasonText: l10n.apiUnreachableReason,
        ),
        loading: () => status(
          unreachable: false,
          label: l10n.statusChecking,
          color: scheme.outline,
          reasonText: l10n.apiUnreachableReason,
        ),
        error: (_, _) => status(
          unreachable: true,
          label: l10n.statusUnreachable,
          color: scheme.error,
          reasonText: l10n.apiUnreachableReason,
        ),
      );
    }

    bool unreachable(ServiceEntry service) {
      final local = localTunnels.containsKey(service.key);
      if (local) return false;
      if (isSessionKind(service.kind) && observedDown.contains(service.key)) {
        return true;
      }
      final probe = isSessionKind(service.kind)
          ? ref.watch(appReachableProvider(service.key))
          : ref.watch(apiReachableProvider(service.key));
      return probe.hasError || probe.valueOrNull == false;
    }

    final unreachableEntries = deviceEntries
        .where(unreachable)
        .toList(growable: false);
    // Resolve each status once — the builders watch providers, so calling one
    // twice per row would double the watch registrations.
    final appStates = {for (final s in apps) s.key: appStatus(s)};
    final apiStates = {for (final s in apis) s.key: apiStatus(s)};
    // The instance name only earns its place when it isn't the default one: the
    // device already names itself above, and a lone "default" repeated down the
    // column says nothing.
    String protocolOf(String wire, ServiceEntry service) =>
        service.name == 'default' ? wire : '$wire · ${service.name}';
    // A host we run publishes its meta tunnel on the same host record as its
    // app-server, so the session capability's address comes from there.
    final localMetaAddr = <String, String>{
      for (final host in localHosts)
        if (host.metaRegistered) host.appServiceKey: host.metaListenAddr,
    };
    // The meta tunnel is keyed by its host's app-server, because that is the row
    // session sharing is rendered against — so it needs its own map rather than
    // reusing `localTunnels` (which is app/api and is what re-registration for
    // those two reads).
    final metaHostOf = <String, ({String name, String kind})>{
      for (final host in localHosts)
        host.appServiceKey: (name: host.name, kind: 'meta'),
    };
    final offlineMeta = <String>{
      for (final host in localHosts)
        if (!host.metaRegistered) host.appServiceKey,
    };
    VoidCallback? reregisterOf(
      Map<String, ({String name, String kind})> owners,
      Set<String> offline,
      String key,
    ) {
      final owner = owners[key];
      if (owner == null || !offline.contains(key)) return null;
      return () => _reregisterTunnel(
        context,
        ref,
        hostName: owner.name,
        kind: owner.kind,
      );
    }

    // `localTunnels` already maps every tunnel we host to its owner — which is
    // exactly "whose tunnel is this, and of what kind", the question
    // re-registration asks. It used to be built a second time under another
    // name a hundred lines further down.
    VoidCallback? reregisterFor(String key) =>
        reregisterOf(localTunnels, offlineTunnels, key);

    // A tunnel we took off the relay reads as offline, not unreachable: nothing
    // is broken, it simply is not published.
    Widget? offlineChip(String key) => offlineTunnels.contains(key)
        ? StatusChip(
            color: scheme.outline,
            label: l10n.tunnelOffline,
            filled: true,
          )
        : null;
    final capabilityRows = <Widget>[
      for (final service in apps)
        _CapabilityRow(
          key: Key('device-capability-${service.key}'),
          icon: Icons.chat_bubble_outline,
          title: l10n.servicesChatCapability,
          provider: switch (service.kind) {
            'acp' => 'acp',
            'opencode' => 'opencode',
            _ => 'codex',
          },
          providerName: localHosts
              .where((h) => h.appServiceKey == service.key)
              .firstOrNull
              ?.providerName,
          profileId: localHosts
              .where((h) => h.appServiceKey == service.key)
              .firstOrNull
              ?.profileId,
          protocol: protocolOf(switch (service.kind) {
            'acp' => 'ACP',
            'opencode' => 'OpenCode HTTP',
            _ => 'App-server',
          }, service),
          localAddr: localAppAddr[service.key],
          menuKey: Key('capability-menu-${service.key}'),
          status: offlineChip(service.key) ?? appStates[service.key]!.chip,
          reason: appStates[service.key]!.reason,
          onReregister: reregisterFor(service.key),
          isDefault: service.key == preferredKey,
          onSetDefault: () => ref
              .read(uiPrefsProvider.notifier)
              .setPreferredAppService(service.key),
          actionLabel: l10n.servicesOpen,
          // Straight back to the chat, pointed at this service. The project /
          // conversation picker this used to push lives in the chat's own
          // sidebar, so drilling into a third page only put the same tree
          // behind an extra tap.
          onAction: () => _openInChat(context, ref, service.key),
          onDeregister: () => _confirmDeregister(
            context,
            ref,
            service,
            localTunnel: localTunnels[service.key],
            unreachable: unreachableEntries.any(
              (entry) => entry.key == service.key,
            ),
          ),
        ),
      for (final service in apis)
        _CapabilityRow(
          key: Key('device-capability-${service.key}'),
          icon: Icons.bolt_outlined,
          title: l10n.servicesApiCapability,
          protocol: protocolOf('API', service),
          localAddr: localApiAddr[service.key],
          menuKey: Key('capability-menu-${service.key}'),
          status: offlineChip(service.key) ?? apiStates[service.key]!.chip,
          reason: apiStates[service.key]!.reason,
          onReregister: reregisterFor(service.key),
          actionLabel: l10n.servicesManage,
          // A panel, not a page: subscribing is one port and one button, and
          // the row it acts on stays in view behind it.
          onAction: () => showApiServicePanel(context, service.key),
          onDeregister: () => _confirmDeregister(
            context,
            ref,
            service,
            localTunnel: localTunnels[service.key],
            unreachable: unreachableEntries.any(
              (entry) => entry.key == service.key,
            ),
          ),
        ),
      if (account)
        for (final service in codexApps)
          _CapabilityRow(
            key: Key('device-capability-meta-${service.key}'),
            icon: Icons.forum_outlined,
            title: l10n.servicesSessionsCapability,
            protocol: protocolOf('Meta', service),
            localAddr: localMetaAddr[service.key],
            menuKey: Key('capability-menu-meta-${service.key}'),
            // The meta tunnel is unpublishable like the other two, so this row
            // carries the same controls the tunnel list used to.
            status: offlineMeta.contains(service.key)
                ? StatusChip(
                    color: scheme.outline,
                    label: l10n.tunnelOffline,
                    filled: true,
                  )
                : null,
            onReregister: reregisterOf(metaHostOf, offlineMeta, service.key),
            onDeregister: metaHostOf.containsKey(service.key)
                ? () => _confirmDeregister(
                    context,
                    ref,
                    ServiceEntry(
                      device: service.device,
                      kind: 'meta',
                      name: metaHostOf[service.key]!.name,
                      key: service.key,
                    ),
                    localTunnel: (
                      name: metaHostOf[service.key]!.name,
                      kind: 'meta',
                    ),
                  )
                : null,
            actionLabel: l10n.servicesBrowse,
            // Replaces this page rather than stacking on it: the session
            // browser is a top-level destination in its own right (it has a
            // page-menu entry and a shortcut), so it reads as `Chat /
            // <device>` instead of a third level under Services.
            onAction: () => context.pushReplacement(
              Uri(
                path: '/sessions',
                queryParameters: {'svc': service.key},
              ).toString(),
            ),
          ),
    ];

    int countFor(String device) {
      final entries = visible
          .where(
            (service) => service.device == device && service.kind != 'host',
          )
          .toList();
      final appCount = entries.where((service) => service.kind == 'app').length;
      return entries.length + (account ? appCount : 0);
    }

    final deviceColumn = _DeviceColumn(
      relay: relay ?? l10n.relayNotConfigured,
      accountLogin: accountLogin,
      accountId: accountId,
      devices: devices,
      activeDevice: activeDevice,
      localDevices: localDevices,
      capabilityCount: countFor,
      onSelect: onSelectDevice,
      // Beside a detail pane the column owns the full height and scrolls its
      // own list; stacked it is the page's only content and scrolls with it.
      filled: split,
    );

    final managementKey = activeDevice == null
        ? null
        : managementKeys[activeDevice];
    final detail = <Widget>[
      _DeviceDetailHeader(
        device: activeDevice,
        local: activeDevice != null && localDevices.contains(activeDevice),
        isDefault: activeDevice != null && activeDevice == preferredDevice,
        onClean: unreachableEntries.isEmpty
            ? null
            : () => _batchRemove(context, ref, unreachableEntries),
      ),
      // Another computer that can be managed: its services, running or
      // not, come first. This computer is managed by its own hosting card.
      if (managementKey != null && !localDevices.contains(activeDevice)) ...[
        ManagedDevicePanel(
          key: ValueKey('managed-panel-$managementKey'),
          serviceKey: managementKey,
          device: activeDevice!,
          onOpen: (key) => _openInChat(context, ref, key),
        ),
        const SizedBox(height: 12),
      ],
      GroupCard(
        title: l10n.servicesCapabilities,
        trailing: _CountPill(
          label: l10n.servicesDeviceCapabilityCount(capabilityCount),
        ),
        children: [
          if (capabilityRows.isEmpty)
            Padding(
              padding: const EdgeInsets.all(32),
              child: Text(
                l10n.servicesNoCapabilities,
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            )
          else
            // One child, not one per row: the rows draw their own separators, so
            // letting the card divide them too would double every hairline.
            Column(children: capabilityRows),
        ],
      ),
      // Hosting is about THIS machine, so it belongs under this machine's
      // device — showing it while a remote peer is selected implied the hosts
      // listed were that peer's. The no-devices case still needs it, since that
      // is the only route to starting a first host, and so does a computer
      // whose own device is not known (see `localUnknown`).
      if (_hostingSupported &&
          (localUnknown || localDevices.contains(activeDevice))) ...[
        const SizedBox(height: 12),
        // No status on the header: each host card carries its own, and the same
        // pill in both places said one thing twice.
        GroupCard(
          title: l10n.localHostingSection,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Column(
                children: [
                  for (final host in localHosts)
                    _LocalHostCard(
                      key: Key('local-host-${host.name}'),
                      host: host,
                    ),
                  const _AddLocalHostCard(),
                  const SizedBox(height: 8),
                  const DeviceManagementSwitch(),
                ],
              ),
            ),
          ],
        ),
      ],
    ];

    // Narrow: one level at a time. The device list stands alone until a device
    // is picked; the detail then replaces it, with a back affordance in the
    // header rather than a second column squeezed alongside.
    if (!split) {
      return _NarrowServices(
        // With no devices at all there is no list worth showing — and the empty
        // state and the "host this machine" card both live in the detail, so
        // going straight there is the only way to reach them.
        showDetail: activeDevice != null || devices.isEmpty,
        canGoBack: devices.isNotEmpty,
        onBack: onClearDevice,
        deviceColumn: deviceColumn,
        detail: detail,
      );
    }

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1160),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 18, 24, 24),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(width: _columnWidth, child: deviceColumn),
              const SizedBox(width: 14),
              Expanded(child: ListView(children: detail)),
            ],
          ),
        ),
      ),
    );
  }
}

/// The compact two-level form of [_DeviceFirstServices]: the device list, or one
/// device's capabilities with a back row above them.
class _NarrowServices extends StatelessWidget {
  const _NarrowServices({
    required this.showDetail,
    required this.canGoBack,
    required this.onBack,
    required this.deviceColumn,
    required this.detail,
  });

  final bool showDetail;

  /// Whether there is a device list to return to. False when the detail is the
  /// only level (no devices discovered), so no back affordance is offered.
  final bool canGoBack;

  final VoidCallback onBack;
  final Widget deviceColumn;
  final List<Widget> detail;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // A level change is a navigation, so it moves rather than cross-fades:
    // forward slides in from the trailing edge, back from the leading one.
    final switcher = AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeOutCubic,
      transitionBuilder: (child, animation) => SlideTransition(
        position: Tween<Offset>(
          begin: Offset(showDetail ? 0.06 : -0.06, 0),
          end: Offset.zero,
        ).animate(animation),
        child: FadeTransition(opacity: animation, child: child),
      ),
      child: showDetail
          ? ListView(
              key: const ValueKey('svc-narrow-detail'),
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
              children: [
                if (canGoBack) ...[
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      key: const Key('device-back'),
                      onPressed: onBack,
                      icon: const Icon(Icons.chevron_left, size: 18),
                      label: Text(l10n.servicesDevices),
                    ),
                  ),
                  const SizedBox(height: 4),
                ],
                ...detail,
              ],
            )
          : Padding(
              key: const ValueKey('svc-narrow-devices'),
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
              child: deviceColumn,
            ),
    );
    // Drilling into a device is a level, not a route, so the platform's back
    // gesture has to be told: without this it would leave Services entirely
    // from the detail, skipping the device list the user came through.
    return PopScope(
      canPop: !showDetail || !canGoBack,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) onBack();
      },
      child: switcher,
    );
  }
}
