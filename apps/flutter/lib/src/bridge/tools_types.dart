part of '../bridge_api.dart';

/// This installation's agent tools, from [BridgeApi.toolsStatus].
class AgentToolsStatus {
  /// Creates a status.
  const AgentToolsStatus({
    required this.supported,
    required this.hosting,
    required this.enabled,
    required this.askBeforeSharing,
    this.endpoint,
    this.problem,
    this.sharedPorts = 0,
    this.connections = 0,
  });

  /// This platform can serve the tools (desktop).
  final bool supported;

  /// This app serves them now.
  final bool hosting;

  /// The user's switch.
  final bool enabled;

  /// An agent's first share needs the user's answer.
  final bool askBeforeSharing;

  /// The MCP URL while serving.
  final String? endpoint;

  /// Safe explanation of a problem.
  final String? problem;

  /// Ports this computer shares.
  final int sharedPorts;

  /// Other devices' services reachable here.
  final int connections;
}

/// Who made a share or connection, as POCOX recorded it.
class ToolsOwner {
  /// Creates an owner.
  const ToolsOwner({
    required this.kind,
    required this.label,
    this.harness,
    this.host,
    this.conversation,
  });

  /// `user` or `agent`.
  final String kind;

  /// Display name (`Codex · default`, `Claude Code`, `You`).
  final String label;

  /// `codex`, `claude`, `opencode`, an ACP agent or an MCP client.
  final String? harness;

  /// The hosted instance, for a harness POCOX runs.
  final String? host;

  /// The conversation (Codex thread or ACP session), when known.
  final String? conversation;

  /// Whether an agent made it.
  bool get isAgent => kind == 'agent';
}

/// One shared port.
class ToolsPort {
  /// Creates a port.
  const ToolsPort({
    required this.port,
    required this.key,
    required this.status,
  });

  /// Port number on the sharing device.
  final int port;

  /// Its relay service key.
  final String key;

  /// `online`, `starting`, `unreachable` or `refused` (the relay refused
  /// its registration; it is retried).
  final String status;
}

/// Loopback ports of one device, shared with the user's other devices.
class ToolsShare {
  /// Creates a share.
  const ToolsShare({
    required this.id,
    required this.title,
    required this.path,
    required this.ports,
    required this.owner,
    required this.createdMs,
    this.expiresMs,
    this.secure = false,
  });

  /// Id on its device.
  final String id;

  /// What it is.
  final String title;

  /// Path to open on the first port.
  final String path;

  /// Whether the page is served over TLS (opened with `https`).
  final bool secure;

  /// Its ports, the page's first.
  final List<ToolsPort> ports;

  /// Who made it.
  final ToolsOwner owner;

  /// Unix milliseconds.
  final int createdMs;

  /// When it ends on its own; null while the user keeps it.
  final int? expiresMs;

  /// The first port's key, the one a link opens.
  String? get firstKey => ports.isEmpty ? null : ports.first.key;

  /// Whether the user keeps it (no expiry).
  bool get kept => expiresMs == null;

  /// The share's overall state: the first port's.
  String get status => ports.isEmpty ? 'starting' : ports.first.status;
}

/// An agent's share, or its connection to another device's Responses API,
/// waiting for the user's answer.
class ToolsConsent {
  /// Creates a request.
  const ToolsConsent({
    required this.id,
    required this.owner,
    required this.title,
    required this.ports,
    this.service,
    required this.createdMs,
    required this.expiresMs,
  });

  /// Answer with this id.
  final String id;

  /// Who asks.
  final ToolsOwner owner;

  /// What would be shared, or the name of the service to connect.
  final String title;

  /// Which ports (none for a connection).
  final List<int> ports;

  /// The key of the service to connect; null for a share.
  final String? service;

  /// Unix milliseconds.
  final int createdMs;

  /// When it lapses.
  final int expiresMs;
}

/// One service of a device in a [ToolsOverview].
class ToolsService {
  /// Creates a service.
  const ToolsService({
    required this.key,
    required this.kind,
    required this.name,
    required this.status,
    this.agent,
    this.title,
    this.port,
    this.owner,
    this.share,
  });

  /// Relay key.
  final String key;

  /// `agent`, `api`, `port` or `host`.
  final String kind;

  /// Instance name (the port number for a shared port).
  final String name;

  /// `online`, `starting`, `unreachable`, `refused` or `offline`.
  final String status;

  /// The agent, for an agent host (`codex`, `claude`, `opencode`, …).
  final String? agent;

  /// A shared port's title.
  final String? title;

  /// A shared port's number.
  final int? port;

  /// Who shared it.
  final String? owner;

  /// The share it belongs to.
  final String? share;
}

/// One device in a [ToolsOverview].
class ToolsDevice {
  /// Creates a device.
  const ToolsDevice({
    required this.name,
    required this.online,
    required this.catalog,
    this.platform,
    this.toolsEnabled,
    this.services = const [],
    this.shares = const [],
    this.consents = const [],
    this.builtinTools = const [],
  });

  /// Device id.
  final String name;

  /// Platform, when its catalog answered.
  final String? platform;

  /// Something of it is on the relay.
  final bool online;

  /// Its catalog answered (a device without one runs an older POCOX).
  final bool catalog;

  /// Its agent tools switch, when known.
  final bool? toolsEnabled;

  /// Its services.
  final List<ToolsService> services;

  /// Its shares.
  final List<ToolsShare> shares;

  /// Its shares waiting for the user.
  final List<ToolsConsent> consents;

  /// The built-in tools a conversation on it can be handed from the
  /// composer (none from an older POCOX).
  final List<ToolsBuiltinTool> builtinTools;
}

/// A built-in tool of POCOX that the composer can hand a conversation.
class ToolsBuiltinTool {
  /// Creates a tool.
  const ToolsBuiltinTool({
    required this.id,
    required this.title,
    required this.summary,
    this.gated = false,
  });

  /// Stable id (`services`, `share`, `connect`).
  final String id;

  /// English name, for an id this app does not know.
  final String title;

  /// What it lets the agent do, for an id this app does not know.
  final String summary;

  /// Picking it gives the user's consent for the conversation.
  final bool gated;
}

/// Another device's service reachable on this device.
class ToolsConnection {
  /// Creates a connection.
  const ToolsConnection({
    required this.service,
    required this.local,
    required this.samePort,
    required this.owner,
    this.expiresMs,
  });

  /// The remote service's key.
  final String service;

  /// `127.0.0.1:<port>`.
  final String local;

  /// Whether it got the service's own port number.
  final bool samePort;

  /// Who keeps it.
  final ToolsOwner owner;

  /// When it ends on its own.
  final int? expiresMs;

  /// The local port.
  int? get localPort => int.tryParse(local.split(':').last);
}

/// Every device and service visible now.
class ToolsOverview {
  /// Creates an overview.
  const ToolsOverview({
    required this.thisDevice,
    this.devices = const [],
    this.connections = const [],
  });

  /// The empty overview, before the first answer.
  static const empty = ToolsOverview(thisDevice: '');

  /// This device's id.
  final String thisDevice;

  /// This device first, then the others.
  final List<ToolsDevice> devices;

  /// This device's connections.
  final List<ToolsConnection> connections;

  /// The device and share holding port [key], if any.
  ({ToolsDevice device, ToolsShare share})? shareOfKey(String key) {
    for (final device in devices) {
      for (final share in device.shares) {
        if (share.ports.any((port) => port.key == key)) {
          return (device: device, share: share);
        }
      }
    }
    return null;
  }

  /// This device's connection to [service], if any.
  ToolsConnection? connectionTo(String service) {
    for (final connection in connections) {
      if (connection.service == service) return connection;
    }
    return null;
  }

  /// Every share, with its device, newest first.
  List<({ToolsDevice device, ToolsShare share})> get shares {
    final all = [
      for (final device in devices)
        for (final share in device.shares) (device: device, share: share),
    ];
    all.sort((a, b) => b.share.createdMs.compareTo(a.share.createdMs));
    return all;
  }

  /// Every consent request, with its device, oldest first.
  List<({ToolsDevice device, ToolsConsent consent})> get consents {
    final all = [
      for (final device in devices)
        for (final consent in device.consents)
          (device: device, consent: consent),
    ];
    all.sort((a, b) => a.consent.createdMs.compareTo(b.consent.createdMs));
    return all;
  }
}

/// A share that is new on a device.
class ToolsRef {
  /// Creates a reference.
  const ToolsRef({required this.device, required this.id});

  /// The device.
  final String device;

  /// The share id.
  final String id;
}

/// One update of [BridgeApi.toolsWatch]. Pending consent requests are read
/// from [overview], whichever device holds them.
class ToolsUpdate {
  /// Creates an update.
  const ToolsUpdate({required this.overview, this.added = const []});

  /// Everything visible now.
  final ToolsOverview overview;

  /// Shares announced since the previous update, this device's included.
  final List<ToolsRef> added;
}

/// A share this device made, from [BridgeApi.toolsShare].
class ToolsShared {
  /// Creates a result.
  const ToolsShared({
    required this.share,
    required this.onThisMachine,
    required this.open,
    required this.ends,
  });

  /// The share.
  final ToolsShare share;

  /// `http://localhost:<port><path>`.
  final String onThisMachine;

  /// The `pocox://open` link.
  final String open;

  /// When it ends, in words.
  final String ends;
}

/// A token issued on this installation (never the token itself).
class ToolsToken {
  /// Creates a token entry.
  const ToolsToken({
    required this.id,
    required this.kind,
    required this.label,
    required this.createdMs,
    this.harness,
  });

  /// Revoke with this id.
  final String id;

  /// `user`, `hosted` or `installed`.
  final String kind;

  /// Display name.
  final String label;

  /// The harness.
  final String? harness;

  /// Unix milliseconds.
  final int createdMs;
}
