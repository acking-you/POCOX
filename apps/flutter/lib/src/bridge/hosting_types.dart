part of '../bridge_api.dart';

/// Result of starting local hosting. One host publishes two tunnels:
/// `app:<name>` (codex app-server) and `api:<name>` (Responses API proxy).
class AppServeResult {
  /// Creates a hosting-start result.
  const AppServeResult({
    required this.device,
    required this.name,
    required this.appServiceKey,
    required this.appListenAddr,
    required this.apiServiceKey,
    required this.apiListenAddr,
    required this.metaServiceKey,
    required this.metaListenAddr,
    required this.pid,
    required this.reused,
  });

  /// Device id both services registered under.
  final String device;

  /// Service instance name (shared by the app + api tunnels).
  final String name;

  /// `pcx:<device>:app:<name>` key (what discovery + `appConnect` use).
  final String appServiceKey;

  /// Loopback `host:port` codex is listening on.
  final String appListenAddr;

  /// `pcx:<device>:api:<name>` key (what an `api connect` resolves).
  final String apiServiceKey;

  /// Loopback `host:port` the in-app Responses API proxy is listening on.
  final String apiListenAddr;

  /// `pcx:<device>:meta:<name>` key (the host meta service tunnel).
  final String metaServiceKey;

  /// Loopback `host:port` the in-app meta service is listening on.
  final String metaListenAddr;

  /// The codex process id.
  final int pid;

  /// Whether an already-running host was reused instead of freshly spawned.
  final bool reused;
}

/// Status of one local host: a codex app-server + an in-app Responses API
/// proxy, or an ACP agent's gateway (see [provider]), each service published
/// through its own (independently toggleable) tunnel.
class AppServeStatus {
  /// Creates a hosting-status snapshot.
  const AppServeStatus({
    required this.name,
    required this.device,
    this.pid,
    this.alive = false,
    this.appListenAddr = '',
    this.appServiceKey = '',
    this.appRegistered = false,
    this.apiListenAddr = '',
    this.apiServiceKey = '',
    this.apiRegistered = false,
    this.metaListenAddr = '',
    this.metaServiceKey = '',
    this.metaRegistered = false,
    this.embedded = false,
    this.codexBinary,
    this.proxy,
    this.provider = 'codex',
    this.providerVersion,
    this.protocol = '',
    this.providerName = '',
    this.profileId,
    this.agentPhase,
    this.agentError,
    this.authRequired = false,
    this.opencode,
    this.configSource,
    this.configRevision,
    this.incarnation,
    this.busy,
  });

  /// Service instance name.
  final String name;

  /// Device id.
  final String device;

  /// codex process id; null for ACP hosts.
  final int? pid;

  /// codex is accepting on its listen port; for ACP, the agent is ready.
  final bool alive;

  /// Loopback `host:port` codex (or the ACP gateway) listens on.
  final String appListenAddr;

  /// `pcx:<device>:app:<name>` key, or `pcx:<device>:acp:<name>` for ACP.
  final String appServiceKey;

  /// The app tunnel is currently published.
  final bool appRegistered;

  /// Loopback `host:port` the API proxy listens on.
  final String apiListenAddr;

  /// `pcx:<device>:api:<name>` key.
  final String apiServiceKey;

  /// The api tunnel is currently published.
  final bool apiRegistered;

  /// Loopback `host:port` the meta service listens on.
  final String metaListenAddr;

  /// `pcx:<device>:meta:<name>` key.
  final String metaServiceKey;

  /// The meta tunnel is currently published.
  final bool metaRegistered;

  /// Legacy runtime flag; always false for external Codex hosts.
  final bool embedded;

  /// The resolved external Codex binary path.
  final String? codexBinary;

  /// Upstream proxy codex + the API proxy were started with, or `null` when
  /// they inherit the app's environment.
  final String? proxy;

  /// Service provider family of this host: `codex`, `acp` or `opencode`.
  /// For `acp` and `opencode` the `app*` fields describe the host's gateway
  /// and `api*` are empty.
  final String provider;

  /// Provider version when known (ACP agents).
  final String? providerVersion;

  /// Wire protocol (`codex-app-server`, `acp`, `opencode-http`); empty from
  /// an older bridge, where [provider] decides.
  final String protocol;

  /// Human-readable provider / agent name; empty when not reported.
  final String providerName;

  /// ACP agent profile id.
  final String? profileId;

  /// ACP agent phase: `starting`, `ready`, `failed` or `stopped`.
  final String? agentPhase;

  /// Why the ACP agent is not running, safe to show.
  final String? agentError;

  /// The ACP agent reported that authentication is required.
  final bool authRequired;

  /// The native OpenCode summary, for an `opencode` host. Null for every
  /// other host and while it is not reported.
  final OpenCodeHostStatus? opencode;

  /// Where the running host gets its model service, as launched:
  /// `inherited`, `official` or `custom`. Null from an older bridge.
  final String? configSource;

  /// The saved configuration revision the running host was launched with;
  /// a newer saved [HostConfig.revision] means "restart to apply".
  final int? configRevision;

  /// This run's identity; it changes whenever the host starts again. Passed
  /// to [BridgeApi.appServeApply] so a replaced host is never restarted.
  /// Null from an older bridge.
  final String? incarnation;

  /// A lifecycle operation holds this host now: `starting`, `stopping`,
  /// `restarting` or `applying`; null when idle.
  final String? busy;

  /// Whether this host runs a native Codex app-server.
  bool get isCodex => provider == 'codex';

  /// Whether this host owns an ACP agent.
  bool get isAcp => provider == 'acp';

  /// Whether this host owns a native `opencode serve`.
  bool get isOpenCode => provider == 'opencode';

  /// The relay kind of this host's session service.
  String get sessionKind => switch (provider) {
    'acp' => 'acp',
    'opencode' => 'opencode',
    _ => 'app',
  };
}

/// A running native OpenCode host's catalog summary: counts and names only,
/// never a provider endpoint, option, key or header.
class OpenCodeHostStatus {
  /// Creates a summary.
  const OpenCodeHostStatus({
    required this.version,
    this.providersConnected = 0,
    this.models = 0,
    this.defaultModel,
    this.agents = const [],
    this.problem,
  });

  /// The running `opencode` version.
  final String version;

  /// Providers OpenCode can use now (signed in or configured).
  final int providersConnected;

  /// Chat models those providers offer.
  final int models;

  /// OpenCode's default model (`provider/model`), when it has one.
  final String? defaultModel;

  /// Selectable primary agents.
  final List<String> agents;

  /// Why the host cannot serve turns (`no_provider`, …), when it cannot.
  final String? problem;
}

/// The OpenCode executable found on this device.
class OpenCodeEnvironment {
  /// Creates a detection result.
  const OpenCodeEnvironment({this.path, this.version, this.problem});

  /// The resolved executable.
  final String? path;

  /// Its reported version.
  final String? version;

  /// Why it cannot be hosted (`not_found`, `unsupported_version`, …).
  final String? problem;
}

/// One ACP agent configuration: profile identity plus executable and the
/// argument vector, passed to the host's operating system verbatim.
class AcpAgentSpec {
  /// Creates an agent configuration.
  const AcpAgentSpec({
    required this.profileId,
    required this.displayName,
    required this.program,
    this.args = const [],
  });

  /// Profile id (a preset id such as `claude`, or a custom id).
  final String profileId;

  /// Name shown in the UI.
  final String displayName;

  /// Executable path, or a bare name searched on the host's `PATH`.
  final String program;

  /// Arguments, one entry each; never joined or split.
  final List<String> args;

  /// From persisted JSON; `null` when malformed.
  static AcpAgentSpec? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['profileId'];
    final name = json['displayName'];
    final program = json['program'];
    final args = json['args'];
    if (id is! String || name is! String || program is! String) return null;
    if (args is! List || args.any((a) => a is! String)) return null;
    return AcpAgentSpec(
      profileId: id,
      displayName: name,
      program: program,
      args: [for (final a in args) a as String],
    );
  }

  /// JSON for persistence.
  Map<String, dynamic> toJson() => {
    'profileId': profileId,
    'displayName': displayName,
    'program': program,
    'args': args,
  };

  @override
  bool operator ==(Object other) =>
      other is AcpAgentSpec &&
      other.profileId == profileId &&
      other.displayName == displayName &&
      other.program == program &&
      _listEquals(other.args, args);

  @override
  int get hashCode =>
      Object.hash(profileId, displayName, program, Object.hashAll(args));
}

/// A built-in ACP agent preset.
class AcpPreset {
  /// Creates a preset.
  const AcpPreset({
    required this.id,
    required this.displayName,
    required this.program,
    required this.args,
  });

  /// Profile id.
  final String id;

  /// Display name.
  final String displayName;

  /// Bare executable name.
  final String program;

  /// Default arguments.
  final List<String> args;

  /// This preset as an agent configuration.
  AcpAgentSpec get spec => AcpAgentSpec(
    profileId: id,
    displayName: displayName,
    program: program,
    args: args,
  );
}

/// Result of hosting an ACP agent.
class AcpServeResult {
  /// Creates a hosting result.
  const AcpServeResult({
    required this.device,
    required this.name,
    required this.serviceKey,
    required this.listenAddr,
    required this.metaServiceKey,
    required this.profileId,
    required this.displayName,
    required this.reused,
  });

  /// Device id.
  final String device;

  /// Instance name.
  final String name;

  /// `pcx:<device>:acp:<name>` key.
  final String serviceKey;

  /// Loopback gateway address.
  final String listenAddr;

  /// `pcx:<device>:meta:<name>` key.
  final String metaServiceKey;

  /// Profile id.
  final String profileId;

  /// Display name.
  final String displayName;

  /// Whether an existing host was reused.
  final bool reused;
}

/// The Claude preset's local environment: its ACP adapter, a Node.js new
/// enough for it, and the native `claude` CLI the adapter drives. Paths and
/// versions only.
class AcpClaudeStatus {
  /// Creates a status.
  const AcpClaudeStatus({
    required this.ready,
    required this.adapter,
    this.adapterPath,
    required this.runtime,
    this.runtimeVersion,
    this.runtimePath,
    required this.cli,
    this.cliPath,
    required this.canPrepare,
    required this.package,
    this.problem,
  });

  /// The preset can start now.
  final bool ready;

  /// `installed` / `prepared` / `missing`.
  final String adapter;

  /// The adapter executable.
  final String? adapterPath;

  /// `found` / `tooOld` / `missing` / `notNeeded`.
  final String runtime;

  /// The Node.js version found (or the newest too-old one).
  final String? runtimeVersion;

  /// The Node.js executable used.
  final String? runtimePath;

  /// `inherited` / `found` / `missing` (the adapter's bundled CLI is used).
  final String cli;

  /// The native CLI handed to the adapter.
  final String? cliPath;

  /// Start can prepare the pinned adapter first.
  final bool canPrepare;

  /// The npm package and version Start prepares.
  final String package;

  /// Why it cannot start, when it cannot.
  final String? problem;
}

/// The preparation of Claude's pinned ACP adapter.
class AcpClaudeSetup {
  /// Creates a preparation state.
  const AcpClaudeSetup({
    required this.state,
    this.stage,
    this.elapsedMs = 0,
    this.error,
    this.run = 0,
    this.started = false,
    this.downloadedBytes,
    this.downloadBytesPerSecond,
  });

  /// `idle` / `running` / `done` / `failed` / `cancelled`.
  final String state;

  /// `installing` / `downloading` / `verifying` while running.
  final String? stage;

  /// Milliseconds since it started.
  final int elapsedMs;

  /// Why it failed.
  final String? error;

  /// The run this state belongs to (0 before any).
  final int run;

  /// This call started [run]; a call that joined one did not.
  final bool started;

  /// Actual package bytes received this run; null before telemetry arrives.
  final int? downloadedBytes;

  /// Recent package transfer rate; null when unavailable.
  final int? downloadBytesPerSecond;

  /// It is still running.
  bool get running => state == 'running';
}
