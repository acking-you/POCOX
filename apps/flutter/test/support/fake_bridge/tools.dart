part of '../../fake_bridge_api.dart';

/// Agent tools: a seedable overview, a controllable update stream, and a
/// record of the user's answers and actions.
mixin _FakeTools on _FakeBridgeState {
  /// This installation's tools.
  AgentToolsStatus toolsStatusValue = const AgentToolsStatus(
    supported: true,
    hosting: true,
    enabled: true,
    askBeforeSharing: true,
    endpoint: 'http://127.0.0.1:17863/mcp',
  );

  /// What [toolsOverview] answers and [toolsWatch] starts from.
  ToolsOverview toolsOverviewValue = ToolsOverview.empty;

  final StreamController<ToolsUpdate> _toolsUpdates =
      StreamController<ToolsUpdate>.broadcast();

  /// `(device, id, decision)` of every answer.
  final List<(String, String, String)> toolsAnswers = [];

  /// `(device, id)` of every stopped share.
  final List<(String, String)> toolsStopped = [];

  /// `(device, id)` of every kept share.
  final List<(String, String)> toolsKept = [];

  /// Services connected through [toolsConnect].
  final List<String> toolsConnected = [];

  /// Services disconnected through [toolsDisconnect].
  final List<String> toolsDisconnected = [];

  /// Issued tokens.
  List<ToolsToken> toolsTokenList = [];

  /// Revoked token ids.
  final List<String> toolsRevoked = [];

  /// Push an update to every watcher (and make it the current overview).
  void pushToolsUpdate(ToolsUpdate update) {
    toolsOverviewValue = update.overview;
    _toolsUpdates.add(update);
  }

  @override
  AgentToolsStatus toolsStatus() => toolsStatusValue;

  @override
  Future<AgentToolsStatus> toolsSetEnabled(bool enabled) async =>
      toolsStatusValue = AgentToolsStatus(
        supported: toolsStatusValue.supported,
        hosting: toolsStatusValue.hosting,
        enabled: enabled,
        askBeforeSharing: toolsStatusValue.askBeforeSharing,
        endpoint: enabled ? 'http://127.0.0.1:17863/mcp' : null,
      );

  @override
  Future<AgentToolsStatus> toolsSetAskBeforeSharing(bool ask) async =>
      toolsStatusValue = AgentToolsStatus(
        supported: toolsStatusValue.supported,
        hosting: toolsStatusValue.hosting,
        enabled: toolsStatusValue.enabled,
        askBeforeSharing: ask,
        endpoint: toolsStatusValue.endpoint,
      );

  @override
  Future<ToolsOverview> toolsOverview() async => toolsOverviewValue;

  @override
  Stream<ToolsUpdate> toolsWatch() async* {
    yield ToolsUpdate(overview: toolsOverviewValue);
    yield* _toolsUpdates.stream;
  }

  @override
  Future<void> toolsAnswer(
    String device,
    String consentId,
    String decision,
  ) async => toolsAnswers.add((device, consentId, decision));

  @override
  Future<void> toolsStopShare(String device, String shareId) async =>
      toolsStopped.add((device, shareId));

  @override
  Future<void> toolsKeepShare(String device, String shareId) async =>
      toolsKept.add((device, shareId));

  @override
  Future<ToolsShared> toolsShare(
    List<int> ports, {
    String? title,
    String? path,
  }) async {
    final share = ToolsShare(
      id: 'fake-share',
      title: title ?? 'Port ${ports.first}',
      path: path ?? '/',
      ports: [
        for (final port in ports)
          ToolsPort(port: port, key: 'pcx:local:port:$port', status: 'online'),
      ],
      owner: const ToolsOwner(kind: 'user', label: 'You'),
      createdMs: 0,
    );
    return ToolsShared(
      share: share,
      onThisMachine: 'http://localhost:${ports.first}${share.path}',
      open: 'pocox://open?service=pcx:local:port:${ports.first}&path=/',
      ends: 'when the user stops sharing it',
    );
  }

  /// `(device, ports)` of every share asked for on a device.
  final List<(String, List<int>)> toolsSharedOn = [];

  @override
  Future<ToolsShared> toolsShareOn(
    String device,
    List<int> ports, {
    String? title,
    String? path,
    bool secure = false,
  }) async {
    toolsSharedOn.add((device, ports));
    final shared = await toolsShare(ports, title: title, path: path);
    final key = 'pcx:$device:port:${ports.first}';
    return ToolsShared(
      share: ToolsShare(
        id: shared.share.id,
        title: shared.share.title,
        path: shared.share.path,
        secure: secure,
        ports: [ToolsPort(port: ports.first, key: key, status: 'online')],
        owner: shared.share.owner,
        createdMs: 0,
      ),
      onThisMachine: shared.onThisMachine,
      open: 'pocox://open?service=$key&path=${shared.share.path}',
      ends: shared.ends,
    );
  }

  @override
  Future<ToolsConnection> toolsConnect(String service, {int? localPort}) async {
    toolsConnected.add(service);
    final port = localPort ?? int.tryParse(service.split(':').last) ?? 41000;
    return ToolsConnection(
      service: service,
      local: '127.0.0.1:$port',
      samePort: localPort == null,
      owner: const ToolsOwner(kind: 'user', label: 'This device'),
    );
  }

  @override
  Future<void> toolsDisconnect(String service) async =>
      toolsDisconnected.add(service);

  @override
  List<ToolsToken> toolsTokens() => toolsTokenList;

  @override
  Future<void> toolsRevoke(String tokenId) async {
    toolsRevoked.add(tokenId);
    toolsTokenList = [
      for (final token in toolsTokenList)
        if (token.id != tokenId) token,
    ];
  }

  @override
  Future<String> toolsHarnessConfig(String harness) async =>
      '{"mcpServers": {"pocox": {"type": "http"}}}';
}
