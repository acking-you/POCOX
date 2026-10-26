/// The galaxy's scene: every visible device as a star system and its
/// services as planets, laid out on a disk so each keeps its place between
/// visits. Pure data and arithmetic; nothing here paints.
library;

import 'dart:math' as math;

import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/service_key.dart';

/// A point or direction in the galaxy's world (the disk is the x–z plane,
/// y points up out of it).
class Vec3 {
  /// Creates a vector.
  const Vec3(this.x, this.y, this.z);

  /// Components.
  final double x, y, z;

  /// The origin.
  static const zero = Vec3(0, 0, 0);

  /// Sum.
  Vec3 operator +(Vec3 o) => Vec3(x + o.x, y + o.y, z + o.z);

  /// Difference.
  Vec3 operator -(Vec3 o) => Vec3(x - o.x, y - o.y, z - o.z);

  /// Scaled.
  Vec3 operator *(double k) => Vec3(x * k, y * k, z * k);

  /// Dot product.
  double dot(Vec3 o) => x * o.x + y * o.y + z * o.z;

  /// Cross product.
  Vec3 cross(Vec3 o) =>
      Vec3(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x);

  /// Length.
  double get length => math.sqrt(dot(this));

  /// Unit vector in the same direction.
  Vec3 get unit {
    final l = length;
    return l == 0 ? this : this * (1 / l);
  }

  /// Linear interpolation towards [o].
  Vec3 lerp(Vec3 o, double t) => this + (o - this) * t;
}

/// A stable 32-bit hash of [text] (FNV-1a), so a device or service keeps its
/// place between visits and runs.
int stableHash(String text) {
  var hash = 0x811c9dc5;
  for (final unit in text.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash;
}

/// [hash] as a fraction in [0, 1).
double unitOf(int hash) => (hash & 0xffffff) / 0x1000000;

/// What a planet is.
enum BodyKind {
  /// An agent host (Codex, Claude, OpenCode, …).
  agent,

  /// A Responses API.
  api,

  /// A shared port.
  port,
}

/// One service, orbiting its device.
class Planet {
  /// Creates a planet.
  const Planet({
    required this.service,
    required this.kind,
    required this.ring,
    required this.radius,
    required this.phase,
    required this.period,
    required this.size,
    required this.tiltAxis,
    required this.tilt,
    this.share,
  });

  /// The service.
  final ToolsService service;

  /// What it is.
  final BodyKind kind;

  /// Its ring: 0 for agents, 1 for APIs, 2 and beyond for shared ports.
  final int ring;

  /// Orbit radius in world units.
  final double radius;

  /// Where on the orbit it starts, in radians.
  final double phase;

  /// One orbit, in seconds.
  final double period;

  /// Body radius in world units.
  final double size;

  /// The orbit plane's tilt, around this direction in the disk.
  final double tiltAxis;

  /// The orbit plane's tilt, in radians.
  final double tilt;

  /// The share it belongs to, for a shared port.
  final ToolsShare? share;

  /// Stable id.
  String get id => service.key;

  /// Its position relative to its device at time [t] (seconds).
  Vec3 offsetAt(double t) {
    final angle = phase + (t / period) * math.pi * 2;
    // A circle in the disk plane, then tilted around [tiltAxis].
    final flat = Vec3(math.cos(angle) * radius, 0, math.sin(angle) * radius);
    return tiltAround(flat, tiltAxis, tilt);
  }
}

/// [p] rotated by [tilt] around the in-plane axis at angle [axis].
Vec3 tiltAround(Vec3 p, double axis, double tilt) {
  final ax = math.cos(axis), az = math.sin(axis);
  // Rodrigues' rotation around k = (ax, 0, az).
  final k = Vec3(ax, 0, az);
  final cos = math.cos(tilt), sin = math.sin(tilt);
  return p * cos + k.cross(p) * sin + k * (k.dot(p) * (1 - cos));
}

/// One device: a star and its planets.
class StarSystem {
  /// Creates a system.
  const StarSystem({
    required this.device,
    required this.position,
    required this.planets,
    required this.home,
  });

  /// The device.
  final ToolsDevice device;

  /// Where its star sits.
  final Vec3 position;

  /// Its services.
  final List<Planet> planets;

  /// Whether this is the device in the user's hand.
  final bool home;

  /// Stable id.
  String get id => 'device:${device.name}';

  /// The radius its outermost orbit reaches.
  double get extent => planets.isEmpty
      ? 0.4
      : planets.map((p) => p.radius).reduce(math.max) + 0.2;
}

/// How a link's data travels, as its tunnel was observed. The order is the
/// frame's code (`engine::galaxy::links::LinkPath`): a drawn strand names one of
/// these, never [mixed], which draws a [direct] and a [relay] strand.
enum LinkPath {
  /// Not observed: drawn as links were before paths were known.
  unknown,

  /// Through the relay, by preference or after a fallback.
  relay,

  /// Peer to peer.
  direct,

  /// Direct and relay connections at once.
  mixed,

  /// Ready, with no data flowing.
  idle,

  /// Trying a direct path: hole punching is under way.
  probing,

  /// Coming up, or recovering its link to the relay.
  recovering;

  /// The path of a live tunnel's [observation], unknown without one.
  static LinkPath of(TunnelPath? observation) => switch (observation) {
    null => unknown,
    TunnelPath.relayOnly || TunnelPath.relay => relay,
    TunnelPath.local || TunnelPath.direct => direct,
    TunnelPath.mixed => mixed,
    TunnelPath.idle => idle,
  };

  /// The strands drawn for it.
  List<LinkPath> get strands => this == mixed ? const [direct, relay] : [this];

  /// How high a strand spanning [span] rises over the plane: a direct one (or
  /// one trying to be) runs nearly straight between the two bodies; any other
  /// arcs up and back down, as if by way of a relay above the disk.
  double rise(double span) => this == direct || this == probing
      ? span * 0.12 + 0.12
      : span * 0.42 + 0.4;

  /// How fast its particles run, in curves per second: quick while probing,
  /// none while idle or recovering.
  double? get flow => switch (this) {
    direct => 0.42,
    probing => 0.9,
    idle || recovering => null,
    _ => 0.22,
  };

  /// The path of the [tunnels] to one body: recovering while any is coming
  /// up or recovering its relay link, probing while one tries a direct path,
  /// else what their data goes through ([merge]).
  static LinkPath ofTunnels(Iterable<SubInfo> tunnels) {
    if (tunnels.any((tunnel) => tunnel.recovering)) return recovering;
    if (tunnels.any((tunnel) => tunnel.attempt != null)) return probing;
    return merge(tunnels.map((tunnel) => tunnel.path));
  }

  /// The path of several tunnels to one body: mixed once both kinds carry
  /// data, idle only when none does, unknown without any.
  static LinkPath merge(Iterable<TunnelPath> observed) {
    var (direct, relay, idle) = (false, false, false);
    for (final path in observed) {
      switch (path) {
        case TunnelPath.local || TunnelPath.direct:
          direct = true;
        case TunnelPath.relay || TunnelPath.relayOnly:
          relay = true;
        case TunnelPath.mixed:
          (direct, relay) = (true, true);
        case TunnelPath.idle:
          idle = true;
      }
    }
    return switch ((direct, relay)) {
      (true, true) => LinkPath.mixed,
      (true, false) => LinkPath.direct,
      (false, true) => LinkPath.relay,
      _ => idle ? LinkPath.idle : LinkPath.unknown,
    };
  }
}

/// A connection of this device to another device: to one of its services (a
/// planet), or to the device itself when the galaxy shows no planet for the
/// service (a host's metadata tunnel).
class Link {
  /// Creates a link.
  const Link({
    required this.service,
    required this.to,
    required this.from,
    this.path = LinkPath.unknown,
    this.tunnels = const [],
    this.connection,
  });

  /// The service key it reaches (the first, when several share the body).
  final String service;

  /// The device using it (this one).
  final StarSystem to;

  /// The body it reaches: a planet, or the device's star.
  final ({StarSystem system, Planet? planet}) from;

  /// How its data travels now, over all of [tunnels].
  final LinkPath path;

  /// The live tunnels behind it: a conversation's, an agent tool's, an API's.
  final List<SubInfo> tunnels;

  /// The agent tools connection that keeps it, if one does.
  final ToolsConnection? connection;

  /// The id of the body it reaches.
  String get targetId => from.planet?.id ?? from.system.id;
}

/// The registry family of agent tools' tunnels, as the bridge names them
/// (`agent_tools::connections::FAMILY`): `tools␟<context>␟<service>`.
const _toolsTunnels = 'tools\u001f';

/// The live tunnel behind this device's tools connection to [service].
SubInfo? toolsTunnelOf(Iterable<SubInfo> subs, String service) => subs
    .where(
      (sub) =>
          sub.alive &&
          sub.key.startsWith(_toolsTunnels) &&
          subscriptionServiceKey(sub.key) == service,
    )
    .firstOrNull;

/// What of [subs] can change the galaxy's links: each live tunnel's key and
/// path, in a stable order, comparable with `listEquals`.
List<(String, LinkPath)> tunnelSignature(Iterable<SubInfo> subs) => [
  for (final sub in subs)
    if (sub.alive) (sub.key, LinkPath.ofTunnels([sub])),
]..sort((a, b) => a.$1.compareTo(b.$1));

/// Everything the galaxy shows.
class GalaxyScene {
  /// Creates a scene.
  const GalaxyScene({required this.systems, required this.links});

  /// The empty scene.
  static const empty = GalaxyScene(systems: [], links: []);

  /// Star systems, this device first.
  final List<StarSystem> systems;

  /// This device's connections.
  final List<Link> links;

  /// The planet with [id], and its system.
  ({StarSystem system, Planet planet})? planetOf(String id) {
    for (final system in systems) {
      for (final planet in system.planets) {
        if (planet.id == id) return (system: system, planet: planet);
      }
    }
    return null;
  }

  /// The system with [id].
  StarSystem? systemOf(String id) {
    for (final system in systems) {
      if (system.id == id) return system;
    }
    return null;
  }
}

/// The golden angle, which spreads spiral slots evenly.
const double goldenAngle = 2.399963229728653;

/// Spacing of the spiral, in world units.
const double _spiral = 2.35;

BodyKind? _kindOf(String kind) => switch (kind) {
  'agent' => BodyKind.agent,
  'api' => BodyKind.api,
  'port' => BodyKind.port,
  _ => null,
};

/// Which services and devices a filter keeps.
class GalaxyFilter {
  /// Creates a filter.
  const GalaxyFilter({this.query = '', this.kind});

  /// Text to match in device, service, title or owner.
  final String query;

  /// One kind only.
  final BodyKind? kind;

  /// Whether nothing is filtered.
  bool get isEmpty => query.trim().isEmpty && kind == null;

  /// Whether [service] of [device] passes.
  bool keeps(ToolsDevice device, ToolsService service, BodyKind kind) {
    if (this.kind != null && this.kind != kind) return false;
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return [
      device.name,
      deviceLabel(device.name),
      service.name,
      service.agent ?? '',
      service.title ?? '',
      service.owner ?? '',
    ].any((text) => text.toLowerCase().contains(q));
  }
}

/// Lay [overview] out as a scene. Devices take spiral slots in the order of
/// their names' hashes, so the same set of devices lands in the same places
/// on every visit and on every device, and a few devices stay close.
///
/// Every live tunnel of [tunnels] to another device becomes a link: to the
/// planet of its service, or to the device's star when the galaxy shows no
/// planet for it. Tunnels reaching one body share one link, whose path merges
/// theirs; an agent tools connection with no live tunnel keeps its link with
/// an unknown path.
GalaxyScene buildScene(
  ToolsOverview overview, {
  Iterable<SubInfo> tunnels = const [],
}) {
  final devices = [...overview.devices]
    ..sort((a, b) {
      final byHash = stableHash(a.name).compareTo(stableHash(b.name));
      return byHash != 0 ? byHash : a.name.compareTo(b.name);
    });
  final systems = <StarSystem>[];
  var slot = 0;
  for (final device in devices) {
    final home = device.name == overview.thisDevice;
    Vec3 position;
    if (home) {
      position = const Vec3(0, 0.12, 0);
    } else {
      final angle = slot * goldenAngle + unitOf(stableHash(device.name)) * 0.5;
      // Offline devices drift a little outwards.
      final r = _spiral * math.sqrt(slot + 1.6) * (device.online ? 1 : 1.08);
      position = Vec3(math.cos(angle) * r, 0, math.sin(angle) * r);
      slot++;
    }
    systems.add(
      StarSystem(
        device: device,
        position: position,
        planets: _planetsOf(device),
        home: home,
      ),
    );
  }
  systems.sort((a, b) => a.home == b.home ? 0 : (a.home ? -1 : 1));
  final scene = GalaxyScene(systems: systems, links: const []);
  final home = systems.where((s) => s.home).firstOrNull;
  if (home == null) return scene;
  // One entry per body reached, in the order bodies are first reached.
  final reached =
      <
        String,
        ({
          String service,
          ({StarSystem system, Planet? planet}) from,
          List<SubInfo> tunnels,
          ToolsConnection? connection,
        })
      >{};
  void reach(String service, {SubInfo? tunnel, ToolsConnection? connection}) {
    final ({StarSystem system, Planet? planet})? from =
        scene.planetOf(service) ??
        switch (scene.systemOf('device:${serviceKeyDevice(service)}')) {
          final system? => (system: system, planet: null),
          null => null,
        };
    // Its own services are reached over loopback, never a link.
    if (from == null || from.system.home) return;
    final id = from.planet?.id ?? from.system.id;
    final entry = reached.putIfAbsent(
      id,
      () => (
        service: service,
        from: from,
        tunnels: <SubInfo>[],
        connection: connection,
      ),
    );
    if (tunnel != null) entry.tunnels.add(tunnel);
    if (connection != null && entry.connection == null) {
      reached[id] = (
        service: entry.service,
        from: entry.from,
        tunnels: entry.tunnels,
        connection: connection,
      );
    }
  }

  for (final connection in overview.connections) {
    reach(connection.service, connection: connection);
  }
  for (final tunnel in tunnels) {
    if (tunnel.alive) reach(subscriptionServiceKey(tunnel.key), tunnel: tunnel);
  }
  return GalaxyScene(
    systems: systems,
    links: [
      for (final entry in reached.values)
        Link(
          service: entry.service,
          to: home,
          from: entry.from,
          path: LinkPath.ofTunnels(entry.tunnels),
          tunnels: List.unmodifiable(entry.tunnels),
          connection: entry.connection,
        ),
    ],
  );
}

List<Planet> _planetsOf(ToolsDevice device) {
  final byKind = <BodyKind, List<ToolsService>>{};
  for (final service in device.services) {
    final kind = _kindOf(service.kind);
    if (kind == null) continue;
    byKind.putIfAbsent(kind, () => []).add(service);
  }
  final planets = <Planet>[];
  var ring = 0;
  for (final kind in BodyKind.values) {
    final services = [...?byKind[kind]]..sort((a, b) => a.key.compareTo(b.key));
    if (services.isEmpty) continue;
    // Up to six bodies share a ring; more open the next one out.
    for (var start = 0; start < services.length; start += 6) {
      final group = services.sublist(
        start,
        math.min(start + 6, services.length),
      );
      final radius = 0.62 + ring * 0.34;
      // Kepler: the outer rings turn slower; the slowest takes about 90 s.
      final period = 90 * math.pow(radius / 1.3, 1.5).toDouble();
      final seed = stableHash('${device.name}/$ring');
      for (var i = 0; i < group.length; i++) {
        final service = group[i];
        final share = device.shares
            .where((s) => s.ports.any((p) => p.key == service.key))
            .firstOrNull;
        planets.add(
          Planet(
            service: service,
            kind: kind,
            ring: ring,
            radius: radius,
            phase: unitOf(seed) * math.pi * 2 + i * math.pi * 2 / group.length,
            period: period,
            size: switch (kind) {
              BodyKind.agent => 0.105,
              BodyKind.api => 0.082,
              BodyKind.port => 0.075,
            },
            tiltAxis: unitOf(seed >> 3) * math.pi * 2,
            tilt: (unitOf(seed >> 7) - 0.5) * 0.28,
            share: share,
          ),
        );
      }
      ring++;
    }
  }
  return planets;
}

/// The scene with only what [filter] keeps (devices stay, for orientation).
GalaxyScene filterScene(GalaxyScene scene, GalaxyFilter filter) {
  if (filter.isEmpty) return scene;
  final systems = [
    for (final system in scene.systems)
      StarSystem(
        device: system.device,
        position: system.position,
        home: system.home,
        planets: [
          for (final planet in system.planets)
            if (filter.keeps(system.device, planet.service, planet.kind))
              planet,
        ],
      ),
  ];
  final filtered = GalaxyScene(systems: systems, links: const []);
  // A link to a kept planet stays, and so does one to a device itself.
  ({StarSystem system, Planet? planet})? kept(Link link) =>
      switch (link.from.planet) {
        final planet? => filtered.planetOf(planet.id),
        null => switch (filtered.systemOf(link.from.system.id)) {
          final system? => (system: system, planet: null),
          null => null,
        },
      };
  return GalaxyScene(
    systems: systems,
    links: [
      for (final link in scene.links)
        if (kept(link) case final from?)
          Link(
            service: link.service,
            to: systems.first,
            from: from,
            path: link.path,
            tunnels: link.tunnels,
            connection: link.connection,
          ),
    ],
  );
}
