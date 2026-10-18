part of '../bridge_api_rust.dart';

mixin _RustTools implements BridgeApi {
  @override
  AgentToolsStatus toolsStatus() => _toolsStatus(frb.toolsStatus());

  @override
  Future<AgentToolsStatus> toolsSetEnabled(bool enabled) async =>
      _toolsStatus(await frb.toolsSetEnabled(enabled: enabled));

  @override
  Future<AgentToolsStatus> toolsSetAskBeforeSharing(bool ask) async =>
      _toolsStatus(await frb.toolsSetAskBeforeSharing(ask: ask));

  @override
  Future<ToolsOverview> toolsOverview() async =>
      _toolsOverview(await frb.toolsOverview());

  @override
  Stream<ToolsUpdate> toolsWatch() => frb.toolsWatch().map(
    (u) => ToolsUpdate(
      overview: _toolsOverview(u.overview),
      added: [for (final r in u.added) ToolsRef(device: r.device, id: r.id)],
    ),
  );

  @override
  Future<void> toolsAnswer(String device, String consentId, String decision) =>
      frb.toolsAnswer(device: device, consentId: consentId, decision: decision);

  @override
  Future<void> toolsStopShare(String device, String shareId) =>
      frb.toolsStopShare(device: device, shareId: shareId);

  @override
  Future<void> toolsKeepShare(String device, String shareId) =>
      frb.toolsKeepShare(device: device, shareId: shareId);

  @override
  Future<ToolsShared> toolsShare(
    List<int> ports, {
    String? title,
    String? path,
  }) async {
    final s = await frb.toolsShare(
      ports: Uint16List.fromList(ports),
      title: title,
      path: path,
    );
    return ToolsShared(
      share: _toolsShare(s.share),
      onThisMachine: s.onThisMachine,
      open: s.open,
      ends: s.ends,
    );
  }

  @override
  Future<ToolsShared> toolsShareOn(
    String device,
    List<int> ports, {
    String? title,
    String? path,
    bool secure = false,
  }) async {
    final s = await frb.toolsShareOn(
      device: device,
      ports: Uint16List.fromList(ports),
      title: title,
      path: path,
      secure: secure,
    );
    return ToolsShared(
      share: _toolsShare(s.share),
      onThisMachine: s.onThisMachine,
      open: s.open,
      ends: s.ends,
    );
  }

  @override
  Future<ToolsConnection> toolsConnect(
    String service, {
    int? localPort,
  }) async => _toolsConnection(
    await frb.toolsConnect(service: service, localPort: localPort),
  );

  @override
  Future<void> toolsDisconnect(String service) =>
      frb.toolsDisconnect(service: service);

  @override
  List<ToolsToken> toolsTokens() => [
    for (final t in frb.toolsTokens())
      ToolsToken(
        id: t.id,
        kind: t.kind,
        label: t.label,
        harness: t.harness,
        createdMs: t.createdMs.toInt(),
      ),
  ];

  @override
  Future<void> toolsRevoke(String tokenId) => frb.toolsRevoke(tokenId: tokenId);

  @override
  Future<String> toolsHarnessConfig(String harness) =>
      frb.toolsHarnessConfig(harness: harness);
}

AgentToolsStatus _toolsStatus(frb.AgentToolsStatusDto s) => AgentToolsStatus(
  supported: s.supported,
  hosting: s.hosting,
  enabled: s.enabled,
  askBeforeSharing: s.askBeforeSharing,
  endpoint: s.endpoint,
  problem: s.problem,
  sharedPorts: s.sharedPorts,
  connections: s.connections,
);

ToolsOwner _toolsOwner(frb.ToolsOwnerDto o) => ToolsOwner(
  kind: o.kind,
  label: o.label,
  harness: o.harness,
  host: o.host,
  conversation: o.conversation,
);

ToolsShare _toolsShare(frb.ToolsShareDto s) => ToolsShare(
  id: s.id,
  title: s.title,
  path: s.path,
  secure: s.secure,
  ports: [
    for (final p in s.ports)
      ToolsPort(port: p.port, key: p.key, status: p.status),
  ],
  owner: _toolsOwner(s.owner),
  createdMs: s.createdMs.toInt(),
  expiresMs: s.expiresMs?.toInt(),
);

ToolsConnection _toolsConnection(frb.ToolsConnectionDto c) => ToolsConnection(
  service: c.service,
  local: c.local,
  samePort: c.samePort,
  owner: _toolsOwner(c.owner),
  expiresMs: c.expiresMs?.toInt(),
);

ToolsOverview _toolsOverview(frb.ToolsOverviewDto o) => ToolsOverview(
  thisDevice: o.thisDevice,
  devices: [
    for (final d in o.devices)
      ToolsDevice(
        name: d.name,
        platform: d.platform,
        online: d.online,
        catalog: d.catalog,
        toolsEnabled: d.toolsEnabled,
        services: [
          for (final s in d.services)
            ToolsService(
              key: s.key,
              kind: s.kind,
              name: s.name,
              status: s.status,
              agent: s.agent,
              title: s.title,
              port: s.port,
              owner: s.owner,
              share: s.share,
            ),
        ],
        shares: [for (final s in d.shares) _toolsShare(s)],
        consents: [
          for (final c in d.consents)
            ToolsConsent(
              id: c.id,
              owner: _toolsOwner(c.owner),
              title: c.title,
              ports: List.of(c.ports),
              createdMs: c.createdMs.toInt(),
              expiresMs: c.expiresMs.toInt(),
            ),
        ],
      ),
  ],
  connections: [for (final c in o.connections) _toolsConnection(c)],
);
