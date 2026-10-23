part of '../../fake_bridge_api.dart';

/// The fake's generic ACP preset.
const fixturePreset = AcpPreset(
  id: 'fixture',
  displayName: 'Fixture Agent',
  program: 'fixture-agent',
  args: ['acp'],
);

abstract class _FakeBridgeState implements BridgeApi {
  /// Creates a fake seeded with an optional [config] and [services].
  _FakeBridgeState({ConfigInfo? config, List<ServiceEntry>? services})
    : _config = config ?? const ConfigInfo(relay: null, hasKey: false),
      _services = List.of(services ?? const []);

  ConfigInfo _config;
  final List<ServiceEntry> _services;
  final Map<String, SubInfo> _subs = {};

  // App-server session simulation.
  final Set<String> _appConnected = {};
  final Map<String, StreamController<AppEvent>> _appEvents = {};
  final List<ThreadMeta> appThreads = [];
  int _threadSeq = 0;

  /// Make [discoverServices] throw, to exercise error states.
  Object? discoverError;

  /// When set, [discoverServices] waits for it (it stays set, so every
  /// discovery is held until it completes).
  Completer<void>? discoverGate;

  /// Number of [discoverServices] calls.
  int discoverCalls = 0;

  /// Mutable view of the discovery list, so a test can make a service appear
  /// (or vanish) after construction — e.g. the home screen's auto-retry.
  List<ServiceEntry> get services => _services;

  final Map<String, ThreadHistory> cachedHistories = {};

  // --- 自带 codex bootstrap ---

  /// Seedable codex setup status returned by [codexSetupStatus].
  CodexSetupStatus codexStatus = const CodexSetupStatus(
    codexHome: '/fake/.codex',
    hasConfig: false,
    hasAuth: false,
    hasCustomProvider: false,
    needsSetup: true,
    promptVariant: 'default',
  );

  /// Records the last provider config written via [codexSetupProvider].
  ({String baseUrl, String apiKey, String? model})? lastProvider;

  // --- Hosted account ---

  /// Seedable signed-in user signed in by the account login calls (null = signed out).
  AccountUser? accountUser;

  /// Status [accountLoginPoll] returns (default `authorized`).
  String accountPollStatus = 'authorized';

  /// Mirror what Rust does on a successful login: persist the token, which flips
  /// `mode` to `account`. Without this the fake left `mode: unconfigured`, so a
  /// test could never catch the UI reading a stale config after signing in.
  void _signIn(AccountUser user) {
    _config = ConfigInfo(
      relay: _config.relay,
      hasKey: _config.hasKey,
      locale: _config.locale,
      mode: 'account',
      accountLogin: user.login,
      hasAccountToken: true,
    );
  }

  /// Records the last [accountWebLoginStart] redirectUri for assertions.
  String? lastWebRedirectUri;

  /// Records the last [accountDeregisterService] call for assertions.
  String? lastDeregistered;

  /// Every key passed to [accountDeregisterService], in order — so a batch
  /// removal can assert it dropped each selected key.
  final List<String> deregistered = [];

  /// When true, [accountDeregisterService] records the call but does NOT drop
  /// the entry from discovery — mirroring an orphaned/hollow relay key the
  /// backend can't force off. Lets tests exercise the durable client-side
  /// dismiss (which must hide it anyway).
  bool keepOnDeregister = false;

  // --- Local hosting ---

  /// Live local hosts, keyed by name (mirrors the bridge's per-name map).
  final List<AppServeStatus> serveHosts = [];

  /// Records the last [appServeStart] args for assertions.
  int? lastServePort;
  String? lastServeBinary, lastServeName, lastServeProxy;
  bool? lastServeEmbedded;

  /// Path returned by [codexLocate] (set null to simulate "codex not found").
  String? codexPath = '/usr/local/bin/codex';

  /// When set, [codexLocate] waits for it (then clears it).
  Completer<void>? codexLocateGate;

  /// How many times [codexLocate] was asked.
  int codexLocateCalls = 0;

  /// When set, [appServeStart] waits for it (then clears it).
  Completer<void>? serveStartGate;

  /// Thrown by the next [appServeStart] (then cleared).
  Object? serveStartError;

  AppServeStatus _withTunnel(AppServeStatus h, String kind, bool registered) =>
      AppServeStatus(
        name: h.name,
        device: h.device,
        pid: h.pid,
        alive: h.alive,
        appListenAddr: h.appListenAddr,
        appServiceKey: h.appServiceKey,
        appRegistered: kind == 'app' || kind == 'acp'
            ? registered
            : h.appRegistered,
        apiListenAddr: h.apiListenAddr,
        apiServiceKey: h.apiServiceKey,
        apiRegistered: kind == 'api' ? registered : h.apiRegistered,
        metaListenAddr: h.metaListenAddr,
        metaServiceKey: h.metaServiceKey,
        metaRegistered: kind == 'meta' ? registered : h.metaRegistered,
        codexBinary: h.codexBinary,
        proxy: h.proxy,
        provider: h.provider,
        providerVersion: h.providerVersion,
      );

  /// How many times [appServeStatus] was read.
  int serveStatusCalls = 0;

  /// When set, [appServeStop] waits for it (then clears it).
  Completer<void>? serveStopGate;

  /// How many more [appServeStop] calls fail as the bridge does when a
  /// host's codex did not exit (the host stays listed).
  int serveStopFailures = 0;

  /// Negotiated capabilities per ACP service key; unset keys report the
  /// conservative, not-yet-negotiated [AppCapabilities.acp].
  final Map<String, AppCapabilities> acpCapabilities = {};

  /// Every [appCapabilities] call, in order.
  final List<String> capabilityCalls = [];

  /// Running session ids per ACP service key.
  final Map<String, List<String>> runningThreads = {};

  /// Provider-native Local sessions per provider (`claude`, `grok`, ...).
  final Map<String, List<LocalSession>> nativeSessions = {};

  /// Every native rename as `(provider, session, title)`.
  final List<(String, String, String)> nativeRenames = [];

  /// Every native delete as `(provider, session)`.
  final List<(String, String)> nativeDeletes = [];

  /// Refuses native renames and deletes with this error while set.
  Object? nativeManageError;

  /// Presets the fake reports: one generic ACP preset, so preset handling
  /// is tested apart from any real agent's own rules.
  List<AcpPreset> presets = const [fixturePreset];

  /// What [openCodeDetect] reports without an explicit executable.
  OpenCodeEnvironment openCodeEnvironment = const OpenCodeEnvironment(
    path: '/Users/me/.opencode/bin/opencode',
    version: '1.19.0',
  );

  /// Every [openCodeDetect] call's executable.
  final List<String?> openCodeDetectCalls = [];

  /// Holds the next [openCodeDetect] until it completes (then cleared).
  Completer<void>? openCodeDetectGate;

  /// Thrown by the next OpenCode start (then cleared).
  Object? openCodeServeError;

  /// Every [openCodeRefresh] call's host name.
  final List<String> openCodeRefreshCalls = [];

  /// Holds the next [openCodeRefresh] until it completes (then cleared).
  Completer<void>? openCodeRefreshGate;

  /// Thrown by the next [openCodeRefresh] (then cleared).
  Object? openCodeRefreshError;

  /// The catalog summary the next [openCodeRefresh] stores on its host
  /// (then cleared); `null` keeps the host's status.
  OpenCodeHostStatus? openCodeRefreshStatus;

  /// Whether this fake device can host ACP agents.
  bool acpHosting = true;

  /// How many times [acpHostingSupported] was asked.
  int acpHostingSupportedCalls = 0;

  /// Another app owns this fake computer's hosting state.
  bool hostingElsewhere = false;

  /// Programs [acpLocate] resolves, by program text.
  final Map<String, String> acpPrograms = {
    'fixture-agent': '/Users/me/.local/bin/fixture-agent',
  };

  /// Holds lookups of a program until its completer completes.
  final Map<String, Completer<void>> acpLocateGates = {};

  /// Programs whose next lookup throws (then cleared).
  final Set<String> acpLocateFailures = {};

  /// Every [acpLocate] call's program.
  final List<String> acpLocateCalls = [];

  /// What [acpClaudeStatus] reports.
  AcpClaudeStatus claudeStatus = const AcpClaudeStatus(
    ready: true,
    adapter: 'installed',
    adapterPath: '/Users/me/.npm-global/bin/claude-agent-acp',
    runtime: 'found',
    runtimeVersion: '22.11.0',
    runtimePath: '/usr/local/bin/node',
    cli: 'found',
    cliPath: '/Users/me/.local/bin/claude',
    canPrepare: false,
    package: '@agentclientprotocol/claude-agent-acp@0.89.1',
  );

  /// How many times [acpClaudeStatus] was asked.
  int claudeStatusCalls = 0;

  /// Holds the next [acpClaudeStatus] answer until completed (then cleared).
  Completer<void>? claudeStatusGate;

  /// Holds the next [acpClaudePrepareStart] answer until completed (then
  /// cleared).
  Completer<void>? claudePrepareGate;

  /// What the next [acpClaudePrepareStart] answers at once instead of a
  /// running preparation (then cleared), e.g. `done`; it gets the new run.
  AcpClaudeSetup? claudePrepareAnswer;

  /// The adapter preparation as the fake reports it (a state snapshot, so
  /// never `started`); tests move it along with [settleClaudePrepare], or
  /// set another caller's run directly.
  AcpClaudeSetup claudeSetup = const AcpClaudeSetup(state: 'idle');

  /// How many preparations were started (a running one is joined, not
  /// counted again).
  int claudePrepareStarts = 0;

  /// Thrown by the next [acpClaudePrepareStart] (then cleared).
  Object? claudePrepareError;

  /// How many times [acpClaudePrepareCancel] was called.
  int claudePrepareCancels = 0;

  /// Every run [acpClaudePrepareCancelRun] was asked to stop.
  final List<int> claudeCancelledRuns = [];

  /// End the current run as [state] (`done`, `failed`, `cancelled`),
  /// keeping its run number as the bridge does.
  void settleClaudePrepare(String state, {String? error}) {
    claudeSetup = AcpClaudeSetup(
      state: state,
      error: error,
      run: claudeSetup.run,
    );
  }

  /// Start another caller's run (a later one replaces this page's).
  void startOtherClaudePrepare() {
    claudeSetup = AcpClaudeSetup(
      state: 'running',
      stage: 'installing',
      run: claudeSetup.run + 1,
    );
  }

  /// Every [appServeStartAcp] call as `(name, spec)`.
  final List<(String?, AcpAgentSpec)> acpServeCalls = [];

  /// When set, [appServeStartAcp] waits for it (then clears it).
  Completer<void>? serveStartAcpGate;

  /// Thrown by the next [appServeStartAcp] (then cleared).
  Object? acpServeError;

  /// Every [appServeRestartAcp] call.
  final List<String> acpRestartCalls = [];

  /// When set, [appServeRestartAcp] waits for it (then clears it).
  Completer<void>? acpRestartGate;

  /// Thrown (once) by the next [appServeRestartAcp], after its gate.
  Object? acpRestartError;

  // --- Per-host model service ---

  /// Saved configurations, keyed by instance name ([HostConfig.active] is
  /// derived from [serveHosts] on read, as the bridge does).
  final Map<String, HostConfig> hostConfigs = {};

  /// Every [hostConfigSave] call as `(name, input, keyAction, key, spec)`.
  final List<(String, HostConfigInput, HostKeyAction, String?, AcpAgentSpec?)>
  hostConfigSaves = [];

  /// The runtime of every [hostConfigSave] call, in the same order.
  final List<HostRuntime?> hostConfigSaveRuntimes = [];

  /// Thrown by the next [hostConfigSave] (then cleared).
  Object? hostConfigSaveError;

  /// When set, [hostConfigSave] waits for it (then clears it).
  Completer<void>? hostConfigSaveGate;

  /// When set, [hostConfigGet] waits for it (then clears it).
  Completer<void>? hostConfigGetGate;

  /// Thrown by the next [hostConfigGet] (then cleared).
  Object? hostConfigGetError;

  /// How many times [hostConfigGet] was called.
  int hostConfigGets = 0;

  int _incarnations = 0;

  /// A fresh run identity for a started host.
  String nextIncarnation() => 'inc-${++_incarnations}';

  /// The exact runtime each host was (re)launched with here, when known
  /// (an ACP agent's arguments are not in its status row).
  final Map<String, HostRuntime> activeRuntimes = {};

  /// What host [h] runs, as the bridge reports it.
  HostActive? activeOf(AppServeStatus? h) {
    if (h == null) return null;
    final runtime =
        activeRuntimes[h.name] ??
        (h.isAcp
            ? HostRuntime.acp(
                AcpAgentSpec(
                  profileId: h.profileId ?? '',
                  displayName: h.providerName,
                  program: h.codexBinary ?? '',
                ),
              )
            : HostRuntime.codex(
                binary: h.codexBinary,
                port:
                    int.tryParse(
                      h.appListenAddr.substring(
                        h.appListenAddr.indexOf(':') + 1,
                      ),
                    ) ??
                    0,
                proxy: h.proxy,
              ));
    return HostActive(
      incarnation: h.incarnation ?? 'inc-${h.name}',
      runtime: runtime,
      source: h.configSource ?? 'inherited',
      revision: h.configRevision ?? 0,
    );
  }

  HostConfig _withActive(HostConfig c, String name) => HostConfig(
    claudeEnv: c.claudeEnv,
    source: c.source,
    protocol: c.protocol,
    baseUrl: c.baseUrl,
    model: c.model,
    keySet: c.keySet,
    revision: c.revision,
    runtime: c.runtime,
    problem: c.problem,
    active: activeOf(serveHosts.where((h) => h.name == name).firstOrNull),
  );

  HostConfig _store(
    String name,
    HostConfigInput input,
    HostKeyAction keyAction,
    int? expectedRevision,
    AcpAgentSpec? spec,
    HostRuntime? runtime,
  ) {
    final current = hostConfigs[name] ?? const HostConfig();
    if (expectedRevision != null && expectedRevision != current.revision) {
      throw StateError('changed elsewhere');
    }
    final effective = runtime ?? current.runtime;
    final support = hostConfigSupported(
      spec: runtime?.agent ?? spec,
      engine: effective != null && effective.isOpenCode ? 'opencode' : null,
    );
    if (!support.sources.contains(input.source) ||
        (input.source == 'custom' &&
            (!support.protocols.contains(input.protocol) ||
                (input.baseUrl ?? '').trim().isEmpty))) {
      throw StateError('unsupported configuration');
    }
    final custom = input.source == 'custom';
    final saved = HostConfig(
      claudeEnv: input.claudeEnv == null
          ? current.claudeEnv
          : {
              for (final entry in input.claudeEnv!.entries)
                entry.key:
                    support.claudeVariables.any(
                      (v) => v.name == entry.key && v.secret,
                    )
                    ? null
                    : entry.value,
            },
      source: input.source,
      protocol: input.protocol,
      baseUrl: input.baseUrl?.trim(),
      model: input.model,
      keySet:
          custom &&
          switch (keyAction) {
            HostKeyAction.keep => current.keySet,
            HostKeyAction.replace => true,
            HostKeyAction.remove => false,
          },
      revision: current.revision + 1,
      runtime: runtime ?? current.runtime,
    );
    hostConfigs[name] = saved;
    return saved;
  }

  /// Host [h] as relaunched: a new incarnation, [runtime] and [config].
  AppServeStatus relaunched(
    AppServeStatus h, {
    HostRuntime? runtime,
    HostConfig? config,
  }) {
    final agent = runtime?.agent;
    if (runtime != null) activeRuntimes[h.name] = runtime;
    return AppServeStatus(
      name: h.name,
      device: h.device,
      pid: h.pid,
      alive: h.alive,
      appListenAddr: runtime != null && runtime.isCodex
          ? '127.0.0.1:${runtime.port}'
          : h.appListenAddr,
      appServiceKey: h.appServiceKey,
      appRegistered: h.appRegistered,
      apiListenAddr: h.apiListenAddr,
      apiServiceKey: h.apiServiceKey,
      apiRegistered: h.apiRegistered,
      metaListenAddr: h.metaListenAddr,
      metaServiceKey: h.metaServiceKey,
      metaRegistered: h.metaRegistered,
      codexBinary: agent?.program ?? runtime?.binary ?? h.codexBinary,
      proxy: runtime == null || !runtime.isCodex ? h.proxy : runtime.proxy,
      provider: h.provider,
      providerVersion: h.providerVersion,
      protocol: h.protocol,
      providerName: agent?.displayName ?? h.providerName,
      profileId: agent?.profileId ?? h.profileId,
      agentPhase: h.agentPhase,
      opencode: _withHistory(h.opencode, runtime),
      configSource: config?.source ?? h.configSource ?? 'inherited',
      configRevision: config?.revision ?? h.configRevision ?? 0,
      incarnation: nextIncarnation(),
    );
  }

  /// Every [appServeApply] call as `(name, incarnation, revision)`.
  final List<(String, String?, int?)> applyCalls = [];

  /// When set, [appServeApply] waits for it (then clears it).
  Completer<void>? applyGate;

  /// Returned by the next [appServeApply] instead of success (then cleared).
  HostApplyResult? applyResult;

  /// Every [appServeStartConfigured] call as `(name, runtime, input,
  /// keyAction, key)`.
  final List<(String?, HostRuntime, HostConfigInput, HostKeyAction, String?)>
  startConfiguredCalls = [];

  /// Open private sign-in sessions, in order (closed ones are removed).
  final List<String> signInSessions = [];

  /// Every closed private sign-in session.
  final List<String> closedSignInSessions = [];

  /// Thrown by the next [codexLocalSessionOpen] (then cleared).
  Object? signInOpenError;

  /// When set, the next [codexLocalSessionOpen] waits for it (then clears).
  Completer<void>? localSessionGate;

  /// Every [codexLocalSessionOpen] proxy argument.
  final List<String?> localSessionProxies = [];

  /// Every [codexLocalSessionOpen] binary argument.
  final List<String?> localSessionBinaries = [];

  /// Every logout, by session.
  final List<String> localLogoutSessions = [];

  /// Every cancelled login as `(session, loginId)`.
  final List<(String, String)> localCancels = [];

  /// What [codexLocalAuthStatus] answers, per session (else not signed in,
  /// login not finished).
  final Map<String, CodexAuthStatus> localAuth = {};

  /// Thrown by the next [codexLocalAuthStatus] (then cleared).
  Object? localAuthError;

  /// Holds a session's next [codexLocalAuthStatus] answer until completed
  /// (then cleared), by session.
  final Map<String, Completer<void>> localAuthGates = {};

  /// Holds the next [codexLocalLogout] until completed (then cleared).
  Completer<void>? localLogoutGate;

  void _requireLocal(String sessionId) {
    if (!signInSessions.contains(sessionId)) {
      throw StateError('this sign-in was closed; open it again');
    }
  }

  /// How many times [codexLocalLogout] signed out.
  int localLogouts = 0;

  /// Per-session ACP settings, keyed `'$serviceKey|$threadId'`.
  final Map<String, SessionSettings> sessionSettings = {};

  /// Every [appSetSessionConfig] / [appSetSessionMode] call.
  final List<(String, String, String)> sessionConfigCalls = [];

  /// The complete option set an agent answers a change with, as ACP's
  /// `session/set_config_option` does; null keeps the current settings.
  /// Called with (configId, value, current settings).
  SessionSettings? Function(String, String, SessionSettings?)? onSessionConfig;

  /// Holds the next [appSetSessionConfig] until completed.
  Completer<void>? sessionConfigGate;

  /// Thrown (once) by the next [appSetSessionConfig].
  Object? sessionConfigError;

  // --- App-server remote control ---

  /// Number of [appConnect] calls (asserts a reconnect actually happened).
  int appConnectCount = 0;
  Future<void>? appConnectGate;

  /// Seedable reachability returned by [appProbe] (default: reachable). A
  /// connected service is always reachable.
  final Map<String, bool> reachable = {};

  /// Every key passed to [appProbe] / [apiProbe], in call order.
  final List<String> appProbeCalls = [], apiProbeCalls = [];

  /// Seedable failure reason for [appProbeReason]; null falls back to a generic
  /// one so an unreachable fake still exercises the "we know why" path.
  final Map<String, String> probeReason = {};

  /// Seedable reachability for the loopback health checks ([appProbeLocal] /
  /// [apiProbeLocal]), keyed by the local `host:port` (default: reachable).
  final Map<String, bool> reachableLocal = {};

  final StreamController<RetryProgress> _retryEvents =
      StreamController<RetryProgress>.broadcast();

  /// Inject a retry tick, so a test can assert the "retrying n/max" indicator.
  void pushRetry(int attempt, {int maxAttempts = 10}) => _retryEvents.add(
    RetryProgress(attempt: attempt, maxAttempts: maxAttempts),
  );

  /// Inject a server event into [serviceKey]'s stream (test helper).
  void pushEvent(String serviceKey, AppEvent event) =>
      _appEvents[serviceKey]?.add(event);

  /// Closes a lagged event feed while retaining its live app-server socket.
  Future<void> closeAppEventStream(String serviceKey) async {
    await _appEvents.remove(serviceKey)?.close();
  }

  /// When true, the next [appThreadList] throws (simulating a stale/closed
  /// socket), then resets — to exercise the picker's reconnect-and-retry path.
  bool failNextThreadList = false;

  /// Simulate a backend whose handshake works but whose first RPC kills the link.
  bool disconnectOnThreadList = false;
  Future<void>? threadListGate;

  /// Every [appThreadMetadata] call, in order.
  final List<String> threadMetadataCalls = [];

  /// Raw JSON returned by [appRateLimits] (tests can override).
  String rateLimitsJson = '{}';

  /// Unified diff returned by [appGitDiff] (tests can override).
  DiffModel gitDiff = const DiffModel([]);

  /// When set, [appGitDiff] waits on this before returning — so a test can hold
  /// the fetch open and assert on the loading state, then complete it.
  Completer<void>? gitDiffGate;

  /// Records whether [appCompact] was called.
  bool compacted = false;

  /// Names set via [appSetThreadName], keyed by thread id.
  final Map<String, String> setNames = {};

  /// When true, [appSetThreadName] throws, to exercise the rollback path.
  bool failSetThreadName = false;

  /// Fails only the NEXT [appSetThreadName] call, so a test can interleave one
  /// failing rename with a succeeding one.
  bool failNextSetThreadName = false;

  /// When set, the next [appSetThreadName] parks until this completes — lets a
  /// test hold one rename in flight while issuing another.
  Completer<void>? renameGate;

  /// Summaries returned by [appThreadSummary], keyed by thread id. A thread
  /// with no entry summarizes to null, like one whose history has no agent
  /// reply yet.
  final Map<String, String> summaries = {};

  /// Thread ids [appThreadSummary] was called for, in call order — lets a test
  /// assert the activity view only fetches the rows it actually built.
  final List<String> summaryCalls = [];

  /// When set, every [appThreadSummary] parks on this, so a test can inspect
  /// the pre-summary row.
  Completer<void>? summaryGate;

  /// When true, [appModelList] returns no models, to exercise the
  /// "can't switch collaboration mode without a model" path.
  bool emptyModelList = false;

  /// Per-service model lists [appModelList] returns instead of its default
  /// pair; replacing an entry models a host restarted with another catalog.
  final Map<String, List<ModelInfo>> modelLists = {};

  /// Every [appModelList] call's service key.
  final List<String> modelListServices = [];

  /// Per-project model lists (`service|directory`) of
  /// [appModelListForProject]; without one it answers as [appModelList].
  final Map<String, List<ModelInfo>> projectModelLists = {};

  /// Holds [appModelListForProject] answers for a directory until completed.
  final Map<String?, Completer<void>> projectModelListGates = {};

  /// Every [appModelListForProject] call's directory.
  final List<String?> modelListProjects = [];

  /// Per-project draft defaults (`service|directory`) of
  /// [appDraftSessionSettings]; without one it answers as
  /// [appSessionSettings] with an empty thread id.
  final Map<String, SessionSettings> draftSettings = {};

  /// Every [appDraftSessionSettings] call's directory.
  final List<String?> draftSettingsProjects = [];

  /// Holds [appDraftSessionSettings] answers for a directory until
  /// completed (each answers what was seeded when it was asked).
  final Map<String?, Completer<void>> draftSettingsGates = {};

  /// Every [appSessionSettingsRefresh] call's thread id.
  final List<String> sessionSettingsRefreshCalls = [];

  /// Holds [appSessionSettingsRefresh] answers until completed (each
  /// answers what was seeded when it was asked).
  Completer<void>? sessionSettingsRefreshGate;
  Completer<void>? modelListGate;
  Completer<void>? configReadGate;

  /// Records the params of the last [appThreadStart] for assertions.
  String? lastModel, lastCwd, lastApproval, lastSandbox;
  String? lastApprovalsReviewer, lastServiceTier;

  /// Holds the next [appThreadStart] until completed.
  Completer<void>? threadStartGate;

  /// Where the host creates a session started without a folder.
  String? threadStartDefaultCwd;

  /// Every [appThreadStart] call's service key.
  final List<String> threadStartCalls = [];

  /// Returned ids in invocation order, including still-pending calls.
  final List<String?> threadStartResults = [];

  /// Fails the next [appThreadStart] (after its gate), then resets.
  Object? threadStartError;

  /// Settings a new ACP session reports (seeded for every started thread).
  SessionSettings? newSessionSettings;

  /// Records the last resumed thread id for assertions.
  String? lastResumed;
  final Map<String, List<Future<void>>> pendingResumes = {};
  final Map<String, List<Future<ThreadHistory>>> pendingReads = {};
  final List<String> threadReads = [];
  final List<bool> threadReadIncludesPages = [];

  /// Access fixtures by thread id ([appSessionOpen], [appSessionAccess]).
  final Map<String, SessionAccess> sessionAccess = {};

  /// Answers of the next [appSessionOpen] calls, in order, before
  /// [sessionAccess].
  final List<SessionAccess> sessionOpenResults = [];

  /// Answers of the next [appSessionAccess] calls, in order.
  final List<SessionAccess> sessionAccessResults = [];

  /// Holds the next [appSessionOpen] until completed (then cleared).
  Completer<void>? sessionOpenGate;

  /// Holds the next [appSessionAccess] until completed (then cleared); its
  /// answer is taken when it is released.
  Completer<void>? sessionAccessGate;

  /// Thrown by the next [appSessionAccess] (after its gate), then cleared.
  Object? sessionAccessError;

  /// Every [appSessionOpen] / [appSessionAccess] thread id.
  final List<String> sessionOpenCalls = [];
  final List<String> sessionAccessCalls = [];

  /// Every [appSessionRelease] snapshot.
  final List<SessionAccess> sessionReleaseCalls = [];

  /// Thrown by the next [appSessionRelease] (then cleared).
  Object? sessionReleaseError;

  /// What [appCommandListForProject] reports for a project without
  /// [projectCommands], and the service of every call.
  List<AgentCommand> agentCommands = const [];
  final List<String> commandListCalls = [];

  /// Per-project commands (`service|directory`) of
  /// [appCommandListForProject]; without one it answers [agentCommands].
  final Map<String, List<AgentCommand>> projectCommands = {};

  /// Holds [appCommandListForProject] answers for a directory until
  /// completed.
  final Map<String?, Completer<void>> projectCommandGates = {};

  /// Every [appCommandListForProject] call's directory.
  final List<String?> commandListProjects = [];

  /// Optional failure thrown by [appThreadResume].
  Object? appThreadResumeError;

  /// Seedable history for resume tests.
  ThreadHistory readResult = const ThreadHistory(items: [], running: false);

  /// Older pages a paginated thread hands back, oldest batch LAST — each call
  /// to [appThreadOlderPage] pops the last one, so seeding
  /// `[oldest, middle]` serves `middle` then `oldest`, the order the UI walks.
  List<List<ThreadItem>> olderPages = [];

  /// Turn ids passed to [appThreadOlderPage], in call order.
  int olderPageCalls = 0;

  /// Controlled responses for interleaving requests across threads.
  final Map<String, Future<OlderPage>> pendingOlderPages = {};

  /// Items each turn hands back, keyed by turn id.
  Map<String, List<ThreadItem>> turnItems = {};

  /// Explicit continuation fixtures for independently paged turns.
  final Map<String, List<TurnItemsPage>> turnPages = {};

  /// Turn ids passed to [appThreadTurnPage], in call order.
  final List<String> turnItemCalls = [];

  /// Controlled responses for hover/select races.
  final Map<String, Future<List<ThreadItem>>> pendingTurnItems = {};

  /// Seedable runtime config for the status-bar model indicator tests.
  ThreadRuntimeConfig? runtimeConfig;

  /// Per-turn override of the model recorded for assertions.
  String? lastTurnModel;

  /// Last prompt text passed to [appTurnStart].
  String? lastTurnText;

  /// Last image data URLs passed to [appTurnStart].
  List<String> lastTurnImages = const [];

  /// Last collaboration mode passed to [appTurnStart] ("plan"/"default"/null).
  String? lastCollaborationMode;

  /// Last reasoning effort passed to [appTurnStart] ("low"/"medium"/"high"/null).
  String? lastReasoningEffort;

  /// Count of [appTurnStart] calls, so a test can assert a retry did NOT start a
  /// second server-side turn (the retry-safety guard reloaded instead).
  int turnStartCount = 0;

  /// When set, [appTurnStart] records its params then awaits this gate before
  /// emitting turn events / returning — so a test can act (e.g. change effort)
  /// while a turn is "in flight". Complete it to let the turn finish.
  Completer<void>? turnStartGate;

  /// Thrown by the next [appTurnStart] before anything is admitted (then
  /// cleared), as a host refusal is.
  Object? turnStartError;

  /// Thrown by the next [appTurnStart] after it was admitted (its params
  /// are recorded, no event is sent), then cleared: the answer was lost.
  Object? turnStartLostAnswer;

  /// Whether [appTurnStart] announces `turn/started` itself; off, the test
  /// sends it (or not) to model a start that arrives late.
  bool announceTurnStart = true;

  /// When false, [appTurnStart] emits ONLY `turn/started` (no reply delta, no
  /// completion) — leaving the turn "streaming with no output yet" so a test can
  /// drive the rest (deltas / completion / interrupt) precisely via [pushEvent].
  /// Used to exercise the Esc state machine + message queue.
  bool autoCompleteTurn = true;

  /// Thread id of the last [appTurnStart].
  String? lastTurnThread;

  /// Every [appTurnStart] call as `(serviceKey, threadId, text, images)`,
  /// refused ones included.
  final List<(String, String, String, List<String>)> turnStartCalls = [];

  String? lastSteerText;
  List<String> lastSteerImages = [];
  Completer<void>? steerGate;
  String? lastSteerTurnId;
  String? steerError;
  String resolvedSteerTurnId = 'turn-1';

  /// Every [appTurnSupplement] call as `(threadId, turnId, text, images)`.
  final List<(String, String?, String, List<String>)> supplementCalls = [];

  /// The client id of the last [appTurnStart] / [appTurnSupplement].
  String? lastTurnClientId;
  String? lastSupplementClientId;

  /// Holds the next [appTurnSupplement] until completed (then cleared).
  Completer<void>? supplementGate;

  /// Thrown by the next [appTurnSupplement] (then cleared).
  Object? supplementError;

  /// When `false`, [appTurnSupplement] answers that nothing was consumed
  /// (no turn was running). ACP only: a native supplement is a steer.
  bool supplementInjects = true;

  /// Records the last turn id passed to [appTurnInterrupt].
  String? lastInterruptTurnId;
  bool interrupted = false;

  /// Records the last approval decision for assertions.
  String? lastApprovalDecision;

  /// Records the request id the last approval decision answered.
  String? lastApprovalRequestId;

  /// Records the last answers JSON passed to [appRespondUserInput].
  String? lastUserInputAnswers;

  // --- Local session takeover ---

  /// Seedable local sessions returned by [appLocalSessions].
  List<LocalSession> localSessions = const [];
  int localSessionCalls = 0;
  Object? localSessionError;

  /// Seedable per-thread liveness returned by [appSessionLiveness].
  final Map<String, SessionLiveness> liveness = {};

  /// Seedable per-thread transcript returned by [appLocalSessionTranscript].
  final Map<String, List<ThreadItem>> transcripts = {};

  /// Records the last `(serviceKey, threadId)` passed to [appForceResume].
  String? lastForceResumedKey, lastForceResumedThread;

  /// Result returned by [appForceResume] (tests can override).
  ForceResumeReport forceResumeResult = const ForceResumeReport(
    killed: [],
    survived: [],
    stillHeld: false,
    resumed: true,
  );

  // --- Remote (meta service) sessions + per-thread config ---

  /// Per-service-key override for [metaSessions]; falls back to [localSessions]
  /// so a test that only seeds local sessions also sees them "remotely".
  final Map<String, List<LocalSession>> remoteSessions = {};

  /// Seedable per-thread config returned by [metaThreadConfigGet], keyed by
  /// thread id. [metaThreadConfigSet] writes here.
  final Map<String, ThreadConfig> threadConfigs = {};

  /// Records the last `(serviceKey, threadId)` passed to [metaThreadConfigGet] /
  /// [metaThreadConfigSet], so tests can assert the config wiring fired.
  String? lastConfigGetThread, lastConfigSetThread;

  /// Records the last `(serviceKey, threadId)` passed to [metaForceResume].
  String? lastMetaResumedKey, lastMetaResumedThread;

  /// Number of live session streams opened, for asserting that active-writer
  /// chat uses the subscription instead of periodic transcript requests.
  int metaSessionEventSubscriptions = 0;
  bool metadataOnlyFollow = false;
  Future<void>? metaFollowGate;

  final Map<String, StreamController<SessionFollowUpdate>> _metaSessionEvents =
      {};

  /// Emits one remote-writer snapshot to subscribers of [threadId].
  void pushMetaSessionUpdate(String threadId, SessionFollowUpdate update) {
    _metaSessionEvents
        .putIfAbsent(threadId, StreamController<SessionFollowUpdate>.broadcast)
        .add(update);
  }

  /// Service key of the last [metaUploadFileScoped] call.
  String? lastUploadKey;

  /// Records the last [metaUploadFileScoped] call for assertions.
  String? lastUploadName;

  /// Bytes passed to the last [metaUploadFileScoped].
  Uint8List? lastUploadBytes;

  /// When set, [metaUploadFileScoped] throws it instead of returning a path.
  Object? uploadError;

  String uploadContext = 'fixture-context';
  String? lastImageUploadThread;
  String? lastImageUploadProject;
  Completer<void>? imageUploadGate;

  /// Seedable per-service project config returned by [metaProjectConfig].
  final Map<String, ProjectConfig> projectConfigs = {};

  /// Seedable directory tree for [metaListDir], keyed by absolute host path →
  /// its immediate sub-directories. A path with no entry lists empty.
  final Map<String, List<HostDirEntry>> dirTree = {};

  /// Fails the next [metaProjectConfig] call, then resets — simulates the
  /// cold-open race where the meta tunnel isn't up yet.
  bool failNextProjectConfig = false;

  /// How many times [metaProjectConfig] has been called, so a test can assert
  /// a retry happened (and that it stops once answered).
  int projectConfigCalls = 0;

  /// Seedable file listing for [metaListFiles], keyed by absolute host dir path.
  final Map<String, List<HostFileEntry>> fileTree = {};

  /// Seedable file bytes for [metaReadFile], keyed by absolute host file path.
  final Map<String, Uint8List> fileBytes = {};

  /// Records the last [metaWriteFile] call for assertions.
  String? lastWriteDir;

  /// Name passed to the last [metaWriteFile].
  String? lastWriteName;

  bool hostIsLocal = false;
  final List<String> filePreviewRequests = [];

  /// Paths the fake host will serve to [metaReadThreadImage] — i.e. the ones
  /// its transcript references. Anything else throws, like a real host's 403.
  final Map<String, Uint8List> threadImageBytes = {};
}
