/// Reading the human-facing parts out of a relay service key.
///
/// A key is `pcx:<device>:<kind>:<name>` when self-hosting, and
/// `pcxu:<user>:<device>:<kind>:<name>` in account mode — same shape with one
/// more segment in front. Three screens each parsed this inline and disagreed:
/// one indexed `parts[1]` for the device, which is the USER in account mode, so
/// a hosted service was labelled with the account name instead of the machine.
///
/// Counting back from the end is what makes both forms work: the name is last,
/// the kind before it, the device before that, whatever precedes is a namespace.
library;

/// The device, kind and instance name of [key].
///
/// Every field is empty for a key too short to be one (a caller passing an
/// arbitrary string), so callers can fall back on the raw key rather than
/// index-crash.
({String device, String kind, String name}) parseServiceKey(String key) {
  final parts = key.split(':');
  if (parts.length < 4) return (device: '', kind: '', name: '');
  // The known prefixes fix the kind's offset, so an instance name that equals
  // a kind (`pcx:mac:acp:acp`) cannot be mistaken for it. Other keys
  // anchor on the KIND, which is the one segment with a fixed vocabulary,
  // searched from the end so a leading namespace doesn't shift the offsets.
  // Everything after it is the name — a name may contain colons, and
  // splitting on the last one would truncate it.
  final fixedAt = switch (parts.first) {
    'pcx' => 2,
    'pcxu' when parts.length >= 5 => 3,
    _ => -1,
  };
  final kindAt = fixedAt > 0 && _isKind(parts[fixedAt])
      ? fixedAt
      : parts.lastIndexWhere(_isKind);
  if (kindAt < 1) return (device: '', kind: '', name: '');
  return (
    device: parts[kindAt - 1],
    kind: parts[kindAt],
    name: parts.sublist(kindAt + 1).join(':'),
  );
}

/// The service kinds the relay namespaces by. `meta` never appears in a
/// discovered key (it is derived from an app host), but it is a real kind and a
/// key carrying it must still parse. `host` is a computer's management entry,
/// never a conversation or model service.
bool _isKind(String part) =>
    part == 'app' ||
    part == 'api' ||
    part == 'meta' ||
    part == 'acp' ||
    part == 'opencode' ||
    part == 'host';

/// Whether [key] names a computer's device-management service.
bool isManagementKey(String key) => parseServiceKey(key).kind == 'host';

/// Whether [kind] is a conversation service the session UI can open: a Codex
/// app-server (`app`), an ACP agent gateway (`acp`) or a native OpenCode
/// host (`opencode`).
bool isSessionKind(String kind) =>
    kind == 'app' || kind == 'acp' || kind == 'opencode';

/// Whether [key] names an ACP agent service.
bool isAcpKey(String key) => parseServiceKey(key).kind == 'acp';

/// The wire protocol a session service key selects (its kind, never a
/// provider name).
enum SessionProtocol {
  /// Native Codex app-server.
  codexAppServer,

  /// The Pocket-Codex gateway to a host-owned ACP agent.
  acp,

  /// The Pocket-Codex gateway to a host-owned native `opencode serve`.
  opencode,
}

/// The protocol of [key]. Keys that are not session keys keep the historical
/// behaviour of addressing the native app-server, as the bridge does.
SessionProtocol sessionProtocolOf(String key) =>
    switch (parseServiceKey(key).kind) {
      'acp' => SessionProtocol.acp,
      'opencode' => SessionProtocol.opencode,
      _ => SessionProtocol.codexAppServer,
    };

/// The device that publishes [key], or empty when [key] isn't a service key.
String serviceKeyDevice(String key) => parseServiceKey(key).device;

final _installationId = RegExp(r'^[0-9a-f]{32}$');

/// The parts of a device segment generated from a hosting installation's
/// identity, `<source>.<hostname>.<id>`; null for an explicit `--device`
/// override or an older hostname-only device. Routing always keeps the full
/// segment: this is for display only.
({String source, String hostname, String id})? installationOf(String device) {
  final first = device.indexOf('.');
  final last = device.lastIndexOf('.');
  if (first < 1 || last <= first + 1) return null;
  final id = device.substring(last + 1);
  if (!_installationId.hasMatch(id)) return null;
  return (
    source: device.substring(0, first),
    hostname: device.substring(first + 1, last),
    id: id,
  );
}

/// The OS (or `wsl`) a publisher reports, as people write it.
String osLabel(String os) => switch (os) {
  'windows' => 'Windows',
  'macos' => 'macOS',
  'linux' => 'Linux',
  'wsl' => 'WSL',
  'android' => 'Android',
  'ios' => 'iOS',
  _ => os,
};

/// The first eight hex digits of a stable ID: enough to tell installations of
/// the same name apart without showing the whole UUID.
String shortId(String id) {
  final hex = id.replaceAll('-', '');
  return hex.length <= 8 ? hex : hex.substring(0, 8);
}

final _versionDash = RegExp(r'(\d)-(\d)');

/// How [device] is named to people: `studio (WSL Ubuntu-24.04)` for a
/// generated installation segment, otherwise the segment itself. A WSL
/// distribution's name is its owner's choice, so all of it is kept; a native
/// Linux source is its release's long name, of which the first word says
/// enough (the selected device's header has the full platform).
String deviceLabel(String device) {
  final installation = installationOf(device);
  if (installation == null) return device;
  final [os, ...words] = installation.source.split('-');
  final distribution = os == 'wsl'
      ? words.join('-').replaceAllMapped(_versionDash, (m) => '${m[1]}.${m[2]}')
      : words.firstOrNull ?? '';
  final from = [
    osLabel(os),
    if (distribution.isNotEmpty)
      distribution[0].toUpperCase() + distribution.substring(1),
  ].join(' ');
  return '${installation.hostname} ($from)';
}

/// The devices among [devices] that share their [deviceLabel] with another
/// one: those need their [deviceShortId] shown to be told apart.
Set<String> sameNamedDevices(Iterable<String> devices) {
  final byLabel = <String, Set<String>>{};
  for (final device in devices) {
    (byLabel[deviceLabel(device)] ??= {}).add(device);
  }
  return {
    for (final same in byLabel.values)
      if (same.length > 1) ...same,
  };
}

/// The [shortId] of a generated installation segment; null for any other.
String? deviceShortId(String device) => switch (installationOf(device)) {
  final installation? => shortId(installation.id),
  null => null,
};

/// The instance name in [key], falling back to the whole key so a label is never
/// blank.
String serviceKeyName(String key) {
  final name = parseServiceKey(key).name;
  return name.isEmpty ? key : name;
}

/// `<device> · <name>`, the way every list labels a service. Falls back to the
/// raw key when it cannot be parsed, which at least stays identifiable.
String serviceKeyLabel(String key) {
  final parsed = parseServiceKey(key);
  if (parsed.device.isEmpty) return key;
  return '${deviceLabel(parsed.device)} · ${parsed.name}';
}

/// The route of conversation [threadId] on the session service [key].
String conversationRoute(String key, String threadId, {String? cwd}) {
  final q = <String>[
    'tid=${Uri.encodeComponent(threadId)}',
    if (cwd != null && cwd.trim().isNotEmpty)
      'cwd=${Uri.encodeComponent(cwd.trim())}',
  ];
  return '/app/${Uri.encodeComponent(key)}/session?${q.join('&')}';
}

/// The relay service key a subscription's [subscriptionKey] names.
///
/// Bridge subscriptions are identified by a composite of their family, the
/// transport context (relay and key fingerprint) and the service key, joined
/// by U+001F. That identity is internal: it shows as control-character boxes
/// and fingerprints. People recognise the service key, which is its last
/// part; a plain key is returned as is.
String subscriptionServiceKey(String subscriptionKey) =>
    subscriptionKey.split('\u001f').last;
