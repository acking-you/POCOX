part of '../bridge_api.dart';

bool _listEquals(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// What the external Codex has on disk in `CODEX_HOME`, for the setup wizard.
class CodexSetupStatus {
  /// Creates a codex setup status.
  const CodexSetupStatus({
    required this.codexHome,
    required this.hasConfig,
    required this.hasAuth,
    required this.hasCustomProvider,
    this.authMode,
    required this.needsSetup,
    required this.promptVariant,
    this.selectedProvider,
    this.configError = false,
    this.effectiveSource = '',
  });

  /// Resolved `CODEX_HOME` (display path).
  final String codexHome;

  /// `config.toml` exists.
  final bool hasConfig;

  /// A credential exists (`auth.json` or `CODEX_ACCESS_TOKEN`).
  final bool hasAuth;

  /// A non-OpenAI custom provider is configured (authorizes turns on its own,
  /// so no `codex login` is required).
  final bool hasCustomProvider;

  /// `auth.json`'s `auth_mode` (`apikey` / `chatgpt` / …), when present.
  final String? authMode;

  /// Nothing lets codex authenticate a model call yet → show the wizard.
  final bool needsSetup;

  /// Active system-prompt variant (`default` / `non_degraded` / `custom`).
  final String promptVariant;

  /// `config.toml`'s top-level `model_provider`, when set.
  final String? selectedProvider;

  /// `config.toml` exists but could not be read or parsed.
  final bool configError;

  /// What a host inheriting this configuration uses: `custom`, `account`,
  /// `none` or `invalid` (configured, not verified); empty from an older
  /// bridge.
  final String effectiveSource;
}

/// A host's runtime: what runs, not its model service.
class HostRuntime {
  /// A native Codex runtime.
  const HostRuntime.codex({this.binary, this.port = 0, this.proxy})
    : kind = 'codex',
      agent = null;

  /// An ACP agent runtime.
  const HostRuntime.acp(AcpAgentSpec this.agent)
    : kind = 'acp',
      binary = null,
      port = 0,
      proxy = null;

  /// A native OpenCode runtime (`opencode serve`, owned by the host).
  const HostRuntime.opencode({this.binary})
    : kind = 'opencode',
      port = 0,
      proxy = null,
      agent = null;

  /// `codex`, `acp` or `opencode`.
  final String kind;

  /// Codex / OpenCode: the executable; null uses the saved one, then
  /// `PATH`.
  final String? binary;

  /// Codex: the app-server port; `0` picks one.
  final int port;

  /// Codex: the upstream proxy; null inherits the app's environment.
  final String? proxy;

  /// ACP: the agent's profile and exact command line.
  final AcpAgentSpec? agent;

  /// Whether this is a native Codex runtime.
  bool get isCodex => kind == 'codex';

  /// Whether this is a native OpenCode runtime.
  bool get isOpenCode => kind == 'opencode';
}

/// What a running host runs with now (never the key).
class HostActive {
  /// Creates an active-configuration snapshot.
  const HostActive({
    required this.incarnation,
    required this.runtime,
    this.source = 'inherited',
    this.revision = 0,
  });

  /// The run identity to pass to [BridgeApi.appServeApply].
  final String incarnation;

  /// The runtime as launched (Codex: the exact executable used).
  final HostRuntime runtime;

  /// The model-service source as launched.
  final String source;

  /// The saved revision it was launched with; `0` when never saved.
  final int revision;
}

/// A host instance's saved model-service configuration and desired runtime,
/// plus what it runs with now. Never carries the key, only whether one is
/// stored.
class HostConfig {
  /// Creates a saved configuration.
  const HostConfig({
    this.source = 'inherited',
    this.protocol,
    this.baseUrl,
    this.model,
    this.keySet = false,
    this.claudeEnv = const {},
    this.revision = 0,
    this.runtime,
    this.problem,
    this.active,
  });

  /// `inherited` (the agent's own configuration), `official` (native Codex
  /// account) or `custom`.
  final String source;

  /// Custom provider API: `responses`, `anthropic-messages` or
  /// `chat-completions`.
  final String? protocol;

  /// Custom provider base URL.
  final String? baseUrl;

  /// Custom provider default model: the model the provider uses for a new
  /// session, not a per-conversation choice.
  final String? model;

  /// A key is stored for this instance.
  final bool keySet;

  /// Explicit Claude overrides; null values indicate stored secrets.
  final Map<String, String?> claudeEnv;

  /// Moves on every save; `0` when never saved.
  final int revision;

  /// The saved desired runtime, when one was saved.
  final HostRuntime? runtime;

  /// Why the saved record cannot be used (safe to show); saving replaces it.
  final String? problem;

  /// What the running host runs with now; null when it does not run.
  final HostActive? active;

  /// The saved configuration differs from what the running host runs.
  bool get pendingApply => active != null && active!.revision != revision;
}

/// What a host configuration save asks for, everything but the key.
class HostConfigInput {
  /// Creates a save request.
  const HostConfigInput({
    required this.source,
    this.protocol,
    this.baseUrl,
    this.model,
    this.claudeEnv,
  });

  /// `inherited`, `official` or `custom`.
  final String source;

  /// Custom provider API.
  final String? protocol;

  /// Custom provider base URL.
  final String? baseUrl;

  /// Custom provider default model.
  final String? model;

  /// Null keeps existing overrides; otherwise replace the set.
  final Map<String, String?>? claudeEnv;
}

/// What a save does with the stored key.
enum HostKeyAction {
  /// Leave it as it is.
  keep,

  /// Store a new one.
  replace,

  /// Remove it.
  remove,
}

/// What an engine can select, so the editor offers only real mappings.
class HostConfigSupport {
  /// Creates a support description.
  const HostConfigSupport({
    this.sources = const ['inherited'],
    this.protocols = const [],
    this.modelRequired = false,
    this.keyRequired = false,
    this.claudeVariables = const [],
  });

  /// Selectable sources, in display order.
  final List<String> sources;

  /// Custom provider APIs; empty when the agent has no known mechanism.
  final List<String> protocols;

  /// A custom provider must name its default model.
  final bool modelRequired;

  /// A custom provider must have a key (Claude: otherwise its own sign-in
  /// would be sent to the gateway).
  final bool keyRequired;

  /// Supported Claude behavior controls.
  final List<ClaudeVariable> claudeVariables;
}

/// The outcome of applying a saved configuration to a running host.
class HostApplyResult {
  /// Creates an apply outcome.
  const HostApplyResult({
    required this.name,
    required this.applied,
    this.restoredPrevious = false,
    this.error,
    this.restoreError,
    this.revision,
  });

  /// Instance name.
  final String name;

  /// The host runs the new configuration.
  final bool applied;

  /// The new start failed and the previous configuration runs again.
  final bool restoredPrevious;

  /// Why the new start failed, when it did.
  final String? error;

  /// Why restoring the previous configuration failed too: the host is
  /// stopped.
  final String? restoreError;

  /// The saved revision the host now runs, when it runs.
  final int? revision;
}

/// A host started with its configuration by
/// [BridgeApi.appServeStartConfigured].
class HostStartResult {
  /// Creates a start outcome.
  const HostStartResult({
    required this.name,
    required this.provider,
    required this.serviceKey,
    this.reused = false,
  });

  /// Instance name as hosted.
  final String name;

  /// `codex`, `acp` or `opencode`.
  final String provider;

  /// The controller key (`app:` for Codex, `acp:` for an agent, `opencode:`
  /// for OpenCode).
  final String serviceKey;

  /// An already-running host was reused.
  final bool reused;
}

/// A started ChatGPT login on the external Codex. [mode] is `browser` (open
/// [authUrl] and poll) or `device` (open [verificationUrl], show [userCode], and
/// poll) — codex falls back to device code when it can't bind its local OAuth
/// callback port. Poll [BridgeApi.codexAuthStatus] until authenticated either way.
class CodexLoginStart {
  /// Creates a started codex login.
  const CodexLoginStart({
    required this.mode,
    required this.loginId,
    this.authUrl,
    this.verificationUrl,
    this.userCode,
  });

  /// `browser` or `device`.
  final String mode;

  /// Opaque id to pass back to [BridgeApi.codexLoginCancel].
  final String loginId;

  /// Browser flow: URL to open in a browser. Null for the device flow.
  final String? authUrl;

  /// Device flow: URL to open. Null for the browser flow.
  final String? verificationUrl;

  /// Device flow: one-time code the user enters. Null for the browser flow.
  final String? userCode;
}

/// codex auth status for one app-server.
class CodexAuthStatus {
  /// Creates a codex auth status.
  const CodexAuthStatus({
    required this.authenticated,
    this.method,
    this.completed,
    this.error,
  });

  /// Whether a credential is active (login complete / provider key present).
  /// It may predate the current login attempt.
  final bool authenticated;

  /// Auth method when signed in (`chatgpt` / `apikey` / …).
  final String? method;

  /// Private sign-in only: how the asked-for login ended (`true` succeeded,
  /// `false` failed); null while it has not finished.
  final bool? completed;

  /// Why the asked-for login failed, when it did.
  final String? error;
}

/// One supported Claude environment variable.
class ClaudeVariable {
  const ClaudeVariable({
    required this.name,
    required this.group,
    this.secret = false,
    this.choices = const [],
  });
  final String name;
  final String group;
  final bool secret;
  final List<String> choices;
}
