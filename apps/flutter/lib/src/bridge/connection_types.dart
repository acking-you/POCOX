part of '../bridge_api.dart';

/// Outgoing path preference for new subscriptions.
enum ConnectionPath {
  /// Every new subscription uses the relay (the default).
  relayOnly,

  /// Direct first, falling back to the relay before any data is sent.
  auto,
}

/// Saved network preferences; existing tunnels keep their captured settings.
class RelayPreferences {
  /// Creates preferences; direct paths require an explicit opt-in.
  const RelayPreferences({
    this.path = ConnectionPath.relayOnly,
    this.allowDirect = false,
  });

  /// Path preference for new subscriptions.
  final ConnectionPath path;

  /// Whether newly published local services accept direct setup.
  final bool allowDirect;

  /// A copy with the given fields replaced.
  RelayPreferences copyWith({ConnectionPath? path, bool? allowDirect}) =>
      RelayPreferences(
        path: path ?? this.path,
        allowDirect: allowDirect ?? this.allowDirect,
      );

  @override
  bool operator ==(Object other) =>
      other is RelayPreferences &&
      other.path == path &&
      other.allowDirect == allowDirect;

  @override
  int get hashCode => Object.hash(path, allowDirect);
}

/// What a subscription's data connections go through right now: a local SDK
/// observation, never the saved preference.
enum TunnelPath {
  /// Opened with the relay-only preference.
  relayOnly,

  /// Ready, with no data connection open.
  idle,

  /// Every open data connection is direct.
  direct,

  /// Every open data connection uses the relay.
  relay,

  /// Direct and relay data connections are both open.
  mixed,
}

/// Why a tunnel's attempt to reach the relay failed.
enum TunnelFailure {
  /// The relay's name did not resolve.
  dns,

  /// The connection to the relay broke.
  transport,

  /// The relay did not answer in time.
  timeout,

  /// The service is not published, or its host is unavailable.
  serviceUnavailable,

  /// The relay refused the credential or the request.
  rejected,

  /// The device's network changed underneath it.
  networkChanged,
}

/// The phase a tunnel's link to the relay entered last.
enum RelayPhase {
  /// Starting up.
  starting,

  /// Waiting for a free setup slot.
  queued,

  /// Looking up the relay's address.
  resolving,

  /// Connecting to the relay.
  connecting,

  /// Authenticating and confirming the service.
  handshake,

  /// Confirmed by the relay.
  ready,

  /// Waiting to try again after a failure.
  backoff,

  /// Stopped.
  stopped,
}

/// How far a direct (hole-punched) attempt got.
enum DirectStage {
  /// Asking whether the other side offers direct.
  negotiating,

  /// Learning this device's public address and asking for a grant.
  discovering,

  /// Dialing the other side through both NATs.
  punching,

  /// The path is up; the other side is opening its service.
  committing,
}

/// A direct attempt in flight.
class DirectAttempt {
  /// Creates an attempt at [stage], begun [elapsedMs] ago.
  const DirectAttempt({
    required this.stage,
    required this.elapsedMs,
    this.inFlight = 1,
  });

  /// The stage most recently entered.
  final DirectStage stage;

  /// Milliseconds since the attempt began.
  final int elapsedMs;

  /// Attempts in flight, this one included.
  final int inFlight;
}

/// What a [LinkEvent] records.
enum LinkEventKind {
  /// The relay answered, for the first time or after failures.
  relayReady,

  /// An attempt to reach the relay failed.
  relayFailed,

  /// The device's network changed.
  networkChanged,

  /// A connection went direct.
  directEstablished,

  /// A connection gave up on direct and used the relay.
  directFallback,
}

/// One entry of a tunnel's recent history.
class LinkEvent {
  /// Creates an event.
  const LinkEvent({
    required this.seq,
    required this.ageMs,
    required this.kind,
    this.repeats = 1,
    this.failure,
    this.stage,
    this.ms,
  });

  /// Increases with every event, so new ones can be told from seen ones.
  final int seq;

  /// Milliseconds since it (last) happened.
  final int ageMs;

  /// What happened.
  final LinkEventKind kind;

  /// Times it happened in a row.
  final int repeats;

  /// [LinkEventKind.relayFailed]: why.
  final TunnelFailure? failure;

  /// [LinkEventKind.directFallback]: the stage it gave up at.
  final DirectStage? stage;

  /// Setup latency of a ready relay, the wait before the next try after a
  /// failure, or the setup time of a direct connection.
  final int? ms;
}

/// A step of connecting a session.
enum ConnectStage {
  /// Opening or reusing the tunnel to the service.
  tunnel,

  /// Opening the session through the tunnel; a direct attempt happens here.
  session,

  /// The session's protocol handshake.
  handshake,
}

/// A discovered service on the relay.
class ServiceEntry {
  /// Creates a service entry.
  const ServiceEntry({
    required this.device,
    required this.kind,
    required this.name,
    required this.key,
  });

  /// Device id segment.
  final String device;

  /// `app` (Codex app-server), `acp` (ACP agent gateway), `api` (Responses
  /// proxy) or `meta` (host meta service).
  final String kind;

  /// Instance name segment.
  final String name;

  /// Full `pcx:<device>:<kind>:<name>` key.
  final String key;
}

/// Status of one active local subscription.
class SubInfo {
  /// Creates a subscription status.
  const SubInfo({
    required this.key,
    required this.localAddr,
    required this.alive,
    this.path = TunnelPath.relayOnly,
    this.activeDirect = 0,
    this.activeRelay = 0,
    this.directSessions = 0,
    this.relaySessions = 0,
    this.fallbacks = 0,
    this.lastFallback,
    this.retrying = false,
    this.consecutiveFailures = 0,
    this.lastFailure,
    this.setupLatencyMs,
    this.ready = true,
    this.relayPhase = RelayPhase.ready,
    this.nextRetryMs,
    this.attempt,
    this.events = const [],
  });

  /// Service key being subscribed to.
  final String key;

  /// Local `host:port` the subscriber listener is bound on.
  final String localAddr;

  /// Whether the subscription task is still running.
  final bool alive;

  /// What its data connections go through right now.
  final TunnelPath path;

  /// Open direct data connections.
  final int activeDirect;

  /// Open relay data connections, counted when direct was preferred.
  final int activeRelay;

  /// Data connections that went direct in this tunnel's lifetime.
  final int directSessions;

  /// Data connections that used the relay in this tunnel's lifetime.
  final int relaySessions;

  /// Pre-commit relay fallbacks in this tunnel's lifetime.
  final int fallbacks;

  /// The SDK's reason for the most recent fallback.
  final String? lastFallback;

  /// Waiting to try the relay again after a failure.
  final bool retrying;

  /// Failures since the tunnel last reached the relay.
  final int consecutiveFailures;

  /// Why the most recent attempt failed, if one did.
  final TunnelFailure? lastFailure;

  /// How long the last answered setup took, in milliseconds.
  final int? setupLatencyMs;

  /// Whether it has been ready; false while it is still coming up.
  final bool ready;

  /// The phase its link to the relay entered last.
  final RelayPhase relayPhase;

  /// Milliseconds before the next attempt, while waiting for one.
  final int? nextRetryMs;

  /// The direct attempt in flight, if any.
  final DirectAttempt? attempt;

  /// What happened to it lately, oldest first.
  final List<LinkEvent> events;

  /// Whether its link to the relay is coming up or recovering rather than
  /// steady.
  bool get recovering => !ready || retrying || consecutiveFailures > 0;

  /// Direct setups this tunnel tried: each data connection either went direct
  /// or fell back to the relay before any data moved.
  int get directAttempts => directSessions + fallbacks;
}

/// View of persisted config (relay/key presence, locale, account state).
class ConfigInfo {
  /// Creates a config view.
  const ConfigInfo({
    required this.relay,
    required this.hasKey,
    this.locale,
    this.mode = 'unconfigured',
    this.accountLogin,
    this.accountId,
    this.hasAccountToken = false,
  });

  /// Configured relay `host:port`, if any.
  final String? relay;

  /// Whether a 32-byte key is stored.
  final bool hasKey;

  /// Configured UI locale (BCP-47, e.g. `en`/`zh`), or `null` to follow the
  /// system locale.
  final String? locale;

  /// Active transport mode: `account` / `self_host` / `unconfigured`.
  final String mode;

  /// Signed-in GitHub login (account mode), if any.
  final String? accountLogin;

  /// Signed-in GitHub numeric account id, if any. The avatar URL is derived from
  /// it (see `GitHubAvatar`); no avatar field is fetched from the backend.
  final String? accountId;

  /// Whether an account session token is stored.
  final bool hasAccountToken;
}

/// A started GitHub device flow: show the code + URL, then poll.
class DeviceCode {
  /// Creates a device code.
  const DeviceCode({
    required this.userCode,
    required this.verificationUri,
    required this.pollHandle,
    required this.intervalSecs,
    required this.expiresInSecs,
    required this.backend,
  });

  /// Code the user types at [verificationUri].
  final String userCode;

  /// URL the user opens to enter [userCode].
  final String verificationUri;

  /// Opaque handle passed back to [BridgeApi.accountLoginPoll].
  final String pollHandle;

  /// Minimum seconds between polls.
  final int intervalSecs;

  /// Seconds until the flow expires.
  final int expiresInSecs;

  /// Resolved backend base URL to echo back to [BridgeApi.accountLoginPoll].
  final String backend;
}

/// Outcome of one device-flow poll. [status] is `pending` / `slow_down` /
/// `authorized` / `expired` / `denied`; [login] is set only when authorized.
class AccountPoll {
  /// Creates a poll outcome.
  const AccountPoll({required this.status, this.login, this.accountId});

  /// Poll status string.
  final String status;

  /// Signed-in login, when authorized.
  final String? login;

  /// GitHub account id, when authorized and known.
  final String? accountId;
}

/// The signed-in account identity.
class AccountUser {
  /// Creates an account user.
  const AccountUser({required this.login, this.accountId});

  /// GitHub login/handle.
  final String login;

  /// GitHub account id, if known.
  final String? accountId;
}

/// A started web (browser-redirect) login: open [authorizeUrl] in a browser,
/// capture the redirect back to the app, check its `state` equals [state], then
/// trade its `exchange_code` (with [codeVerifier]) via
/// [BridgeApi.accountWebLoginExchange]. [state] and [codeVerifier] stay
/// on-device — only the verifier's hashed challenge ever reaches the backend.
class WebLoginStart {
  /// Creates a started web login.
  const WebLoginStart({
    required this.authorizeUrl,
    required this.state,
    required this.codeVerifier,
    required this.backend,
  });

  /// GitHub authorization URL to open in a browser.
  final String authorizeUrl;

  /// CSRF state to match against the redirect's `state` query param.
  final String state;

  /// PKCE verifier to pass to [BridgeApi.accountWebLoginExchange].
  final String codeVerifier;

  /// Resolved backend base URL to echo back to
  /// [BridgeApi.accountWebLoginExchange].
  final String backend;
}

/// One service in the account (the `pcxu:` prefix already stripped).
class AccountService {
  /// Creates an account service.
  const AccountService({
    required this.device,
    required this.kind,
    required this.name,
  });

  /// Device id segment.
  final String device;

  /// `app` (Codex app-server), `acp` (ACP agent gateway), `api` (Responses
  /// proxy) or `meta` (host meta service).
  final String kind;

  /// Instance name segment.
  final String name;

  /// The local `pcx:<device>:<kind>:<name>` key the app/session layer uses.
  String get key => 'pcx:$device:$kind:$name';
}
