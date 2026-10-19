part of '../bridge_api.dart';

/// Where this controller stands with one session of a host-access engine
/// (ACP agents and native OpenCode), as the host decided it.
///
/// Two axes are kept apart: [writer] says who can write the session and
/// [turn] whether a turn is running. "No turn is running" never implies
/// "nobody else writes". The UI renders [mode]; it never derives it.
class SessionAccess {
  /// Creates an access snapshot.
  const SessionAccess({
    required this.sessionId,
    required this.hostId,
    required this.generation,
    this.sourceGeneration,
    required this.provider,
    required this.mode,
    required this.writer,
    required this.turn,
    this.exclusion = '',
    required this.reason,
    this.detail,
    this.holder,
    this.canRelease = false,
    this.recheck = false,
  });

  /// Exact original session id.
  final String sessionId;

  /// Host incarnation the snapshot belongs to.
  final String hostId;

  /// Engine generation the snapshot belongs to.
  final int generation;

  /// Persisted source identity, when the engine has one.
  final String? sourceGeneration;

  /// `claude`, `opencode` or another agent's provider id.
  final String provider;

  /// `write`, `follow` or `blocked`.
  final String mode;

  /// `this_host`, `none`, `pocket_host`, `native_client` or `unknown`.
  final String writer;

  /// `idle`, `running`, `unfinished` or `unknown`.
  final String turn;

  /// What a write here excludes: `engine`, `pocket` or `none`; empty unless
  /// [mode] is `write`.
  final String exclusion;

  /// Stable reason code: `owned`, `released`, `released_here`,
  /// `transition`, `host_stopped`, `external_idle`, `external_running`,
  /// `external_open` (a client has it open; turn unknown),
  /// `external_source_open`, `source_unknown`, `pocket_host`, `unsupported`
  /// or `not_found`.
  final String reason;

  /// Host-written detail safe to show (an error text), never a secret.
  final String? detail;

  /// Who holds the session, when known.
  final AccessHolder? holder;

  /// This host can hand its idle writer back to other clients.
  final bool canRelease;

  /// The state is expected to change by itself; the view re-checks.
  final bool recheck;

  /// A composer may write.
  bool get writable => mode == 'write';

  /// A turn is known to run (here or elsewhere).
  bool get running => turn == 'running';
}

/// The client holding a session this controller cannot write.
class AccessHolder {
  /// Creates a holder description.
  const AccessHolder({
    required this.client,
    this.pid,
    this.startedAt,
    this.hostName,
    this.serviceKey,
  });

  /// `claude_code`, `opencode`, `pocket_host` or `unknown`.
  final String client;

  /// Process id, when known.
  final int? pid;

  /// Process start time in epoch milliseconds, when known.
  final int? startedAt;

  /// The holding Pocket host's instance name, when known.
  final String? hostName;

  /// The holding Pocket host's session service key; only with it can the
  /// view navigate there.
  final String? serviceKey;
}

/// One native slash command an engine lists.
class AgentCommand {
  /// Creates a command.
  const AgentCommand({
    required this.name,
    this.description,
    this.source = 'command',
    this.hints = const [],
  });

  /// Name without the leading `/`.
  final String name;

  /// Description, when given.
  final String? description;

  /// `command`, `mcp` or `skill`.
  final String source;

  /// Argument hints, in order.
  final List<String> hints;
}
