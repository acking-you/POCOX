part of '../bridge_api.dart';

/// Display identity declared by a local host or read from a remote host.
/// This never selects a transport or grants negotiated capabilities.
class AgentIdentity {
  /// An identity for [provider] (`codex`, `opencode` or `acp`).
  const AgentIdentity({required this.provider, this.profileId, this.name});

  /// Engine family.
  final String provider;

  /// Explicit ACP profile id, when known.
  final String? profileId;

  /// Agent display name, when known.
  final String? name;
}

/// What became of [BridgeApi.appTurnSupplement].
class TurnSupplement {
  /// Creates an outcome.
  const TurnSupplement({required this.injected, this.turnId});

  /// The running turn [turnId] took the input. Otherwise no turn was
  /// running and nothing was consumed: send it as an ordinary prompt.
  final bool injected;

  /// The turn that took it.
  final String? turnId;
}

/// One value of an ACP select configuration option.
class SessionConfigValue {
  /// Creates a value.
  const SessionConfigValue({
    required this.value,
    required this.name,
    this.group,
    this.description,
  });

  /// Opaque value id, sent back verbatim.
  final String value;

  /// Label.
  final String name;

  /// Group label, when grouped.
  final String? group;

  /// Description.
  final String? description;
}

/// One ACP select configuration option (model, mode, thought level, …).
class SessionConfigOption {
  /// Creates an option.
  const SessionConfigOption({
    required this.id,
    required this.name,
    required this.currentValue,
    required this.values,
    this.category,
    this.description,
  });

  /// Opaque option id.
  final String id;

  /// Label.
  final String name;

  /// Semantic category (UX only).
  final String? category;

  /// Description.
  final String? description;

  /// Current value id.
  final String currentValue;

  /// Values in agent order.
  final List<SessionConfigValue> values;

  /// Label of the current value (its id when unknown).
  String get currentLabel =>
      values.where((v) => v.value == currentValue).firstOrNull?.name ??
      currentValue;
}

/// One legacy ACP session mode.
class SessionMode {
  /// Creates a mode.
  const SessionMode({required this.id, required this.name, this.description});

  /// Opaque mode id.
  final String id;

  /// Label.
  final String name;

  /// Description.
  final String? description;
}

/// Per-session state an ACP agent reported.
class SessionSettings {
  /// Creates a settings snapshot.
  const SessionSettings({
    this.configOptions = const [],
    this.currentMode,
    this.modes = const [],
    this.usageUsed,
    this.usageSize,
    this.running = false,
    this.cancelRequested = false,
  });

  /// Select configuration options.
  final List<SessionConfigOption> configOptions;

  /// Current legacy mode id.
  final String? currentMode;

  /// Advertised legacy modes.
  final List<SessionMode> modes;

  /// Context tokens in use.
  final int? usageUsed;

  /// Context window size.
  final int? usageSize;

  /// A turn is running.
  final bool running;

  /// Cancellation was requested and the agent has not finished yet.
  final bool cancelRequested;
}

/// What a session connection supports, so the shared session UI can hide
/// controls that do not apply. Optional flags default to "no": a control
/// appears only when the protocol (and, for ACP,
/// the negotiated agent) actually has the feature.
class AppCapabilities {
  /// Creates a capability description.
  const AppCapabilities({
    required this.provider,
    required this.fast,
    required this.permissionPresets,
    required this.guardian,
    required this.rateLimits,
    required this.takeover,
    required this.externalWriterMonitor,
    required this.localSessions,
    required this.planMode,
    this.protocol = '',
    this.providerName = '',
    this.profileId = '',
    this.negotiated = false,
    this.generation = 0,
    this.voice = false,
    this.dictation = false,
    this.imageInput = false,
    this.steer = false,
    this.rename = false,
    this.compact = false,
    this.gitDiff = false,
    this.modelCatalog = false,
    this.sessionConfig = false,
    this.permissionOptions = false,
    this.nativeMetadata = false,
    this.sessionReopen = 'unknown',
    this.sessionList = 'host',
    this.historyScope = 'retained',
    this.runningInventory = 'none',
    this.authRequired = false,
    this.commands = false,
    this.draftOptions = false,
    this.questionMultiple = false,
    this.permissionFeedback = false,
  });

  /// The Codex app-server's capabilities.
  static const codex = AppCapabilities(
    provider: 'codex',
    fast: true,
    permissionPresets: true,
    guardian: true,
    rateLimits: true,
    takeover: true,
    externalWriterMonitor: true,
    localSessions: true,
    planMode: true,
    protocol: 'codex-app-server',
    providerName: 'Codex',
    voice: true,
    dictation: true,
    imageInput: true,
    steer: true,
    rename: true,
    compact: true,
    gitDiff: true,
    modelCatalog: true,
    nativeMetadata: true,
    sessionReopen: 'native',
    sessionList: 'native',
    historyScope: 'full',
    runningInventory: 'meta',
  );

  /// An ACP service before negotiation: nothing optional.
  static const acp = AppCapabilities(
    provider: 'acp',
    fast: false,
    permissionPresets: false,
    guardian: false,
    rateLimits: false,
    takeover: false,
    externalWriterMonitor: false,
    localSessions: false,
    planMode: false,
    protocol: 'acp',
    providerName: 'ACP agent',
    permissionOptions: true,
    runningInventory: 'engine',
  );

  /// A native OpenCode service before its host answered: nothing optional.
  static const opencode = AppCapabilities(
    provider: 'opencode',
    fast: false,
    permissionPresets: false,
    guardian: false,
    rateLimits: false,
    takeover: false,
    externalWriterMonitor: false,
    localSessions: false,
    planMode: false,
    protocol: 'opencode-http',
    providerName: 'OpenCode',
    permissionOptions: true,
    runningInventory: 'engine',
  );

  /// Wire protocol: `codex-app-server`, `acp` or `opencode-http`.
  final String protocol;

  /// Human-readable agent name.
  final String providerName;

  /// Agent profile id reported by the host: `claude` for the Claude preset,
  /// a saved ACP agent's own id, `opencode` for native OpenCode; empty for
  /// Codex and before the host answered. Identity only: it never
  /// selects transport behaviour.
  final String profileId;

  /// Whether the values come from a live ACP negotiation.
  final bool negotiated;

  /// Host generation the values belong to (ACP; 0 otherwise).
  final int generation;

  /// Native live voice calls.
  final bool voice;

  /// Native composer dictation.
  final bool dictation;

  /// Image attachments in prompts.
  final bool imageInput;

  /// Supplementing a running turn.
  final bool steer;

  /// Renaming sessions.
  final bool rename;

  /// Manual compaction.
  final bool compact;

  /// Working-tree diff.
  final bool gitDiff;

  /// A service-wide model catalog for the model picker.
  final bool modelCatalog;

  /// Per-session agent options (ACP select options / modes).
  final bool sessionConfig;

  /// Approvals carry the agent's own options, answered by option id.
  final bool permissionOptions;

  /// Native thread metadata (Guardian pre-resume checks).
  final bool nativeMetadata;

  /// How earlier sessions reopen: `native`, `load`, `resume`, `none` or
  /// `unknown`.
  final String sessionReopen;

  /// Source of the session list: `native`, `agent` or `host`.
  final String sessionList;

  /// `full` or `retained`.
  final String historyScope;

  /// Running-session inventory: `meta`, `engine` or `none`.
  final String runningInventory;

  /// The agent reported that authentication is required.
  final bool authRequired;

  /// Native slash commands the engine lists ([BridgeApi.appCommandListForProject]).
  final bool commands;

  /// Session options exist before a session does: a draft keeps its own
  /// choices and they are applied when its session is created.
  final bool draftOptions;

  /// Questions may allow several answers each.
  final bool questionMultiple;

  /// A rejected permission may carry a message to the agent.
  final bool permissionFeedback;

  /// Whether this is an ACP connection.
  bool get isAcp => protocol == 'acp' || provider == 'acp';

  /// Whether this is a native OpenCode connection.
  bool get isOpenCode => protocol == 'opencode-http' || provider == 'opencode';

  /// The session engine: `codex`, `acp` or `opencode`.
  String get engine => isOpenCode
      ? 'opencode'
      : isAcp
      ? 'acp'
      : 'codex';

  /// Whether the host decides session access ([BridgeApi.appSessionOpen])
  /// instead of the Codex takeover path.
  bool get hostAccess => isAcp || isOpenCode;

  /// `codex`, `acp` or `opencode`.
  final String provider;

  /// Fast service tier toggle.
  final bool fast;

  /// Approval / sandbox permission presets.
  final bool permissionPresets;

  /// Guardian (auto-review) approvals.
  final bool guardian;

  /// Account rate-limit snapshot.
  final bool rateLimits;

  /// Taking over a session held by another local process.
  final bool takeover;

  /// Monitoring another writer of the same session.
  final bool externalWriterMonitor;

  /// Sessions read directly from this device's disk.
  final bool localSessions;

  /// Plan collaboration mode.
  final bool planMode;
}
