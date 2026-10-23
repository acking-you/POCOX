part of '../bridge_api.dart';

/// Saved network preferences; existing tunnels keep their captured settings.
class RelayPreferences {
  const RelayPreferences({this.path = 'relay_only', this.allowDirect = false});
  final String path;
  final bool allowDirect;
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
    this.path = 'unknown',
    this.activeDirect = 0,
    this.activeRelay = 0,
    this.fallbacks = 0,
    this.lastFallback,
  });

  /// Service key being subscribed to.
  final String key;

  /// Local `host:port` the subscriber listener is bound on.
  final String localAddr;

  /// Whether the subscription task is still running.
  final bool alive;
  final String path;
  final int activeDirect;
  final int activeRelay;
  final int fallbacks;
  final String? lastFallback;
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
