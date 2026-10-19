/// Paints one frame of the galaxy: sky, the disk's plane, star systems far
/// to near with their orbits split around each star, connections as arcs of
/// light, and labels that keep out of each other's way.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/service_key.dart';
import 'package:pocket_codex/src/tools/galaxy/galaxy_backdrop.dart';
import 'package:pocket_codex/src/tools/galaxy/galaxy_camera.dart';
import 'package:pocket_codex/src/tools/galaxy/galaxy_model.dart';
import 'package:pocket_codex/src/tools/galaxy/galaxy_view.dart';
import 'package:pocket_codex/src/tools/planet_glyph.dart';

/// The colours of one theme.
class GalaxyPalette {
  /// Creates a palette.
  const GalaxyPalette({
    required this.dark,
    required this.ratio,
    required this.scheme,
    required this.signal,
    required this.text,
  });

  /// Night sky or daylight orrery.
  final bool dark;

  /// Device pixel ratio.
  final double ratio;

  /// The app's colours.
  final ColorScheme scheme;

  /// The one signal colour: this device's star.
  final Color signal;

  /// The app's text style, for labels.
  final TextStyle text;

  /// Ink for rings, labels and moons.
  Color get ink => dark ? Colors.white : const Color(0xFF26262A);

  /// Another device's star.
  Color get star => dark ? const Color(0xFFF4F4F2) : const Color(0xFFD9D9D4);

  /// A service's colour.
  Color status(String status) => statusColor(scheme, status);

  /// Equal palettes paint alike.
  bool same(GalaxyPalette o) =>
      dark == o.dark && ratio == o.ratio && signal == o.signal;
}

/// Laid-out labels, reused across frames.
class LabelCache {
  final Map<String, TextPainter> _painters = {};

  /// The painter for [text] in [style].
  TextPainter of(String text, TextStyle style) {
    final key =
        '${style.fontSize}|${style.fontWeight?.value}|${style.color?.toARGB32()}|$text';
    final cached = _painters[key];
    if (cached != null) return cached;
    if (_painters.length > 300) _painters.clear();
    return _painters[key] = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: 220);
  }
}

double _easeOut(double t) => 1 - math.pow(1 - t.clamp(0, 1), 3).toDouble();

/// [p] turned by [angle] around the disk's axis.
Vec3 _turned(Vec3 p, double angle) {
  final c = math.cos(angle), s = math.sin(angle);
  return Vec3(p.x * c - p.z * s, p.y, p.x * s + p.z * c);
}

/// What a planet is called on its label.
String planetLabel(AppLocalizations l10n, Planet planet) {
  final service = planet.service;
  return switch (planet.kind) {
    BodyKind.port => service.title ?? l10n.toolsPort(service.name),
    BodyKind.agent => _agentLabel(l10n, service.agent, service.name),
    BodyKind.api => 'API · ${service.name}',
  };
}

/// `Claude`, or `Codex · work` when the instance has a name of its own.
String _agentLabel(AppLocalizations l10n, String? agent, String name) {
  final title = _agentName(l10n, agent);
  final plain =
      name == 'default' || name.toLowerCase() == (agent ?? '').toLowerCase();
  return plain ? title : '$title · $name';
}

String _agentName(AppLocalizations l10n, String? agent) => switch (agent) {
  'codex' => 'Codex',
  'claude' => 'Claude',
  'opencode' => 'OpenCode',
  'grok' => 'Grok',
  null || '' || 'acp' => l10n.galaxyKindAgent,
  final other => other,
};

Color _moonColor(GalaxyPalette palette, String? harness) => switch (harness) {
  'claude' => const Color(0xFFD97757),
  'opencode' => const Color(0xFF8E8E8A),
  _ => palette.ink.withValues(alpha: 0.85),
};

/// The painter. Repaints whenever [view] ticks.
class GalaxyPainter extends CustomPainter {
  /// Paints [view] in [palette].
  GalaxyPainter({
    required this.view,
    required this.palette,
    required this.l10n,
    required this.labels,
    required this.starfield,
    required this.onBackdrop,
  }) : super(repaint: view);

  /// What to draw.
  final GalaxyView view;

  /// In which colours.
  final GalaxyPalette palette;

  /// In which language bodies are named.
  final AppLocalizations l10n;

  /// Label layout cache.
  final LabelCache labels;

  /// The stars.
  final Starfield starfield;

  /// Called when the backdrop image arrives.
  final VoidCallback onBackdrop;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    if (view.still) {
      // A still scene has no entrances, ripples or fading ghosts.
      view.appeared.clear();
      view.rippled.clear();
      view.ghosts.clear();
    }
    final dark = palette.dark;
    final camera = view.camera;
    Backdrop.of(size, dark, palette.ratio, onBackdrop).paint(canvas);
    starfield.paint(
      canvas,
      size,
      camera.yaw,
      camera.tilt,
      view.time,
      dark: dark,
      still: view.still,
    );
    final projection = camera.project(size);
    final frame = _Frame(this, canvas, projection, size);
    frame.plane();
    final ordered = [
      for (final system in view.scene.systems)
        if (projection.at(system.position) case final core?) (system, core),
    ]..sort((a, b) => b.$2.depth.compareTo(a.$2.depth));
    for (final (system, core) in ordered) {
      frame.system(system, core);
    }
    frame.links();
    frame.ghosts();
    frame.labels();
    view.hits = frame.hits;
  }

  @override
  bool shouldRepaint(GalaxyPainter old) =>
      old.view != view || !old.palette.same(palette) || old.l10n != l10n;
}

/// One frame's drawing state.
class _Frame {
  _Frame(this.painter, this.canvas, this.projection, this.size);

  final GalaxyPainter painter;
  final Canvas canvas;
  final Projection projection;
  final Size size;
  final List<Hit> hits = [];

  GalaxyView get view => painter.view;
  GalaxyPalette get palette => painter.palette;
  bool get dark => palette.dark;

  /// Whether [id] (of [system]) stays bright while something is selected.
  bool _lit(String id, StarSystem system) {
    final selected = view.selected;
    if (selected == null) return true;
    if (selected == id || selected == system.id) return true;
    return system.planets.any((p) => p.id == selected) && id == system.id;
  }

  /// Fainter with distance, so depth reads without blur.
  double _fade(double depth) {
    final reference = view.camera.distance;
    return (1.25 - (depth - reference) / (reference * 1.6)).clamp(0.42, 1.0);
  }

  void plane() {
    final systems = view.scene.systems;
    if (systems.isEmpty) return;
    var reach = 3.0;
    for (final system in systems) {
      reach = math.max(reach, system.position.length + system.extent);
    }
    // A soft glow over the plane, with no edge to it.
    final rim = <Offset>[];
    for (var i = 0; i < 48; i++) {
      final a = i / 48 * math.pi * 2;
      final p = projection.at(
        Vec3(math.cos(a) * reach, 0, math.sin(a) * reach),
      );
      if (p != null) rim.add(p.point);
    }
    if (rim.length > 8) {
      var bounds = Rect.fromPoints(rim.first, rim.first);
      for (final point in rim) {
        bounds = bounds.expandToInclude(Rect.fromPoints(point, point));
      }
      canvas.drawOval(
        bounds.deflate(bounds.shortestSide * 0.12),
        Paint()
          ..color = palette.ink.withValues(alpha: dark ? 0.035 : 0.03)
          ..maskFilter = MaskFilter.blur(
            BlurStyle.normal,
            bounds.shortestSide * 0.22,
          ),
      );
    }
    // Faint guide circles give the plane its perspective, fading outwards.
    for (var r = 2.6; r < reach; r += 2.6) {
      final guide = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8
        ..color = palette.ink.withValues(
          alpha: (dark ? 0.06 : 0.07) * (1 - r / (reach * 1.15)),
        );
      final path = Path();
      var started = false;
      for (var i = 0; i <= 96; i++) {
        final a = i / 96 * math.pi * 2;
        final p = projection.at(Vec3(math.cos(a) * r, 0, math.sin(a) * r));
        if (p == null) {
          started = false;
          continue;
        }
        if (started) {
          path.lineTo(p.point.dx, p.point.dy);
        } else {
          path.moveTo(p.point.dx, p.point.dy);
          started = true;
        }
      }
      canvas.drawPath(path, guide);
    }
  }

  void system(StarSystem system, Projected core) {
    final online = system.device.online;
    final lit = _lit(system.id, system);
    final base = (online ? 1.0 : 0.45) * (lit ? 1.0 : 0.3) * _fade(core.depth);
    // One orbit per ring, split at the star so the front half covers it.
    final rings = <int, Planet>{};
    for (final planet in system.planets) {
      rings.putIfAbsent(planet.ring, () => planet);
    }
    final back = <List<Offset>>[];
    final front = <List<Offset>>[];
    for (final planet in rings.values) {
      _ring(system, planet, core.depth, back, front);
    }
    final placed = [
      for (final planet in system.planets)
        if (_place(system, planet) case final p?) (planet, p.$1, p.$2),
    ];
    _strokeRuns(back, base * 0.55);
    for (final (planet, projected, appear) in placed) {
      if (projected.depth > core.depth) {
        _planet(system, planet, projected, appear, base);
      }
    }
    _core(system, core, base);
    _strokeRuns(front, base);
    for (final (planet, projected, appear) in placed) {
      if (projected.depth <= core.depth) {
        _planet(system, planet, projected, appear, base);
      }
    }
  }

  void _ring(
    StarSystem system,
    Planet planet,
    double coreDepth,
    List<List<Offset>> back,
    List<List<Offset>> front,
  ) {
    List<Offset>? run;
    bool? behind;
    for (var i = 0; i <= 96; i++) {
      final a = i / 96 * math.pi * 2;
      final local = tiltAround(
        Vec3(math.cos(a) * planet.radius, 0, math.sin(a) * planet.radius),
        planet.tiltAxis,
        planet.tilt,
      );
      final p = projection.at(system.position + local);
      if (p == null) {
        run = null;
        continue;
      }
      final isBehind = p.depth > coreDepth;
      if (run == null || isBehind != behind) {
        final previous = run?.last;
        run = [?previous, p.point];
        (isBehind ? back : front).add(run);
        behind = isBehind;
      } else {
        run.add(p.point);
      }
    }
  }

  void _strokeRuns(List<List<Offset>> runs, double opacity) {
    if (runs.isEmpty || opacity <= 0) return;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = dark ? 0.9 : 0.8
      ..color = palette.ink.withValues(alpha: (dark ? 0.16 : 0.22) * opacity);
    for (final run in runs) {
      if (run.length < 2) continue;
      canvas.drawPath(Path()..addPolygon(run, false), paint);
    }
  }

  /// Where [planet] is drawn now, and how far it has come out of its star.
  (Projected, double)? _place(StarSystem system, Planet planet) {
    final since = view.appeared[planet.id];
    final appear = since == null ? 1.0 : _easeOut((view.time - since) / 1.6);
    if (since != null && appear >= 1) view.appeared.remove(planet.id);
    final orbit = planet.offsetAt(view.orbitTime);
    // A new body spirals out of its star: it turns half a revolution while
    // its distance grows.
    final local = appear >= 1
        ? orbit
        : _turned(orbit, (1 - appear) * math.pi) * appear +
              Vec3(0, 0.25 * (1 - appear), 0);
    final projected = projection.at(system.position + local);
    return projected == null ? null : (projected, appear);
  }

  void _core(StarSystem system, Projected core, double opacity) {
    final breath = view.still
        ? 1.0
        : 1 + 0.04 * math.sin(view.time * 0.9 + system.position.x);
    final online = system.device.online;
    // Up close a star keeps a modest size, so the scene stays legible.
    final radius =
        ((system.home ? 0.22 : 0.15) * core.scale).clamp(
          3.0,
          system.home ? 26.0 : (online ? 15.0 : 11.0),
        ) *
        breath;
    final color = system.home
        ? palette.signal
        : online
        ? palette.star
        : palette.scheme.outline;
    final c = core.point;
    if (dark && !online) {
      // An offline device is a dim ember: no light of its own.
      paintPlanet(
        canvas,
        c,
        radius,
        color,
        dark: true,
        glow: 0,
        opacity: opacity,
      );
    } else if (dark) {
      for (final (scale, alpha) in [(7.0, 0.06), (3.4, 0.16), (1.8, 0.32)]) {
        canvas.drawCircle(
          c,
          radius * scale,
          Paint()
            ..color = color.withValues(alpha: alpha * opacity)
            ..maskFilter = MaskFilter.blur(
              BlurStyle.normal,
              radius * scale * 0.5,
            ),
        );
      }
      // Diffraction spikes, faint and short, on the brighter stars.
      if (online) {
        final reach = radius * 3.2;
        final spike = Paint()
          ..strokeWidth = 0.8
          ..shader = RadialGradient(
            colors: [
              Colors.white.withValues(alpha: 0.28 * opacity),
              Colors.white.withValues(alpha: 0),
            ],
          ).createShader(Rect.fromCircle(center: c, radius: reach));
        canvas
          ..drawLine(c - Offset(reach, 0), c + Offset(reach, 0), spike)
          ..drawLine(c - Offset(0, reach), c + Offset(0, reach), spike);
      }
      canvas.drawCircle(
        c,
        radius,
        Paint()
          ..shader = RadialGradient(
            colors: [
              Colors.white.withValues(alpha: opacity),
              color.withValues(alpha: opacity),
            ],
            stops: const [0.25, 1],
          ).createShader(Rect.fromCircle(center: c, radius: radius)),
      );
    } else {
      canvas.drawCircle(
        c,
        radius * 2.6,
        Paint()
          ..color = color.withValues(alpha: 0.14 * opacity)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, radius * 1.4),
      );
      paintPlanet(canvas, c, radius, color, dark: false, opacity: opacity);
    }
    _focusRings(system.id, c, radius);
    hits.add(
      Hit(
        system.id,
        c,
        radius * 1.6,
        core.depth,
        deviceLabel(system.device.name),
      ),
    );
  }

  void _planet(
    StarSystem system,
    Planet planet,
    Projected projected,
    double appear,
    double base,
  ) {
    final lit = _lit(planet.id, system);
    final opacity =
        (system.device.online ? 1.0 : 0.45) *
        (lit ? 1.0 : 0.3) *
        _fade(projected.depth) *
        appear;
    final radius =
        (planet.size * projected.scale).clamp(2.5, 13.0) * (0.4 + 0.6 * appear);
    final c = projected.point;
    final color = palette.status(planet.service.status);
    final share = planet.share;
    // A ripple crosses the ring when the status changes.
    final rippled = view.rippled[planet.id];
    if (rippled != null) {
      final t = (view.time - rippled) / 1.4;
      if (t >= 1) {
        view.rippled.remove(planet.id);
      } else {
        canvas.drawCircle(
          c,
          radius * (1.2 + t * 3.2),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.4
            ..color = color.withValues(alpha: (1 - t) * 0.7 * opacity),
        );
      }
    }
    paintPlanet(
      canvas,
      c,
      radius,
      color,
      dark: dark,
      opacity: opacity,
      glow: 0.9,
    );
    if (share != null && share.owner.isAgent) {
      _agentShare(c, radius, share.owner.harness, share.expiresMs, opacity);
    }
    _focusRings(planet.id, c, radius);
    hits.add(
      Hit(
        planet.id,
        c,
        radius,
        projected.depth,
        planetLabel(painter.l10n, planet),
      ),
    );
  }

  /// An agent's share: a dashed orbit, its harness as a moon, and a thin arc
  /// that runs down as its lease ends.
  void _agentShare(
    Offset c,
    double radius,
    String? harness,
    int? expiresMs,
    double opacity,
  ) {
    final orbit = radius * 2.3;
    final dash = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.9
      ..color = palette.ink.withValues(alpha: (dark ? 0.32 : 0.36) * opacity);
    const dashes = 18;
    for (var i = 0; i < dashes; i++) {
      final start = i / dashes * math.pi * 2;
      canvas.drawArc(
        Rect.fromCircle(center: c, radius: orbit),
        start,
        math.pi * 2 / dashes * 0.5,
        false,
        dash,
      );
    }
    final angle = view.still ? -0.6 : view.time * 0.9;
    paintPlanet(
      canvas,
      c + Offset(math.cos(angle) * orbit, math.sin(angle) * orbit * 0.55),
      math.max(1.6, radius * 0.34),
      _moonColor(palette, harness),
      dark: dark,
      opacity: opacity,
      glow: 0.5,
    );
    if (expiresMs != null) {
      final left =
          (expiresMs - DateTime.now().millisecondsSinceEpoch) /
          const Duration(hours: 24).inMilliseconds;
      canvas.drawArc(
        Rect.fromCircle(center: c, radius: radius * 1.55),
        -math.pi / 2,
        math.pi * 2 * left.clamp(0.0, 1.0),
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..strokeCap = StrokeCap.round
          ..color = palette.ink.withValues(alpha: 0.5 * opacity),
      );
    }
  }

  void _focusRings(String id, Offset c, double radius) {
    final pulse = view.still ? 0.0 : (math.sin(view.time * 3) + 1) / 2;
    if (view.selected == id || view.focused == id) {
      canvas.drawCircle(
        c,
        radius + 5 + pulse * 2,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = palette.ink.withValues(alpha: 0.75),
      );
    } else if (view.hovered == id) {
      canvas.drawCircle(
        c,
        radius + 4,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = palette.ink.withValues(alpha: 0.4),
      );
    }
  }

  void links() {
    for (final link in view.scene.links) {
      final from =
          link.from.system.position + link.from.planet.offsetAt(view.orbitTime);
      final to = link.to.position;
      final rise = (to - from).length * 0.42 + 0.4;
      final control = from.lerp(to, 0.5) + Vec3(0, rise, 0);
      Vec3 at(double t) =>
          from * ((1 - t) * (1 - t)) +
          control * (2 * (1 - t) * t) +
          to * (t * t);
      final points = <Offset>[];
      for (var i = 0; i <= 32; i++) {
        final p = projection.at(at(i / 32));
        if (p != null) points.add(p.point);
      }
      if (points.length < 2) continue;
      final light = palette.signal;
      final bounds = Rect.fromPoints(points.first, points.last).inflate(1);
      canvas.drawPath(
        Path()..addPolygon(points, false),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..strokeCap = StrokeCap.round
          ..shader = LinearGradient(
            colors: [
              light.withValues(alpha: dark ? 0.15 : 0.12),
              light.withValues(alpha: dark ? 0.7 : 0.55),
            ],
          ).createShader(bounds),
      );
      // Particles flow from the service to the device using it.
      for (var k = 0; k < 3; k++) {
        final t = view.still ? (k + 1) / 4 : (view.time * 0.22 + k / 3) % 1.0;
        final p = projection.at(at(t));
        if (p == null) continue;
        canvas.drawCircle(
          p.point,
          dark ? 2.2 : 1.8,
          Paint()
            ..color = light.withValues(alpha: 0.9)
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, dark ? 2.2 : 1),
        );
      }
    }
  }

  void ghosts() {
    view.ghosts.removeWhere((g) => view.time - g.since > 1.0);
    for (final ghost in view.ghosts) {
      final p = projection.at(ghost.position);
      if (p == null) continue;
      final t = (view.time - ghost.since).clamp(0.0, 1.0);
      paintPlanet(
        canvas,
        p.point,
        math.max(2.0, ghost.size * p.scale) * (1 + t * 0.4),
        palette.scheme.outline,
        dark: dark,
        opacity: 1 - t,
      );
    }
  }

  void labels() {
    // A soft halo of the sky's own colour keeps a label legible over light.
    final halo = [
      Shadow(
        color: (dark ? Colors.black : Colors.white).withValues(
          alpha: dark ? 0.85 : 0.95,
        ),
        blurRadius: 6,
      ),
    ];
    final base = palette.text.copyWith(
      fontSize: 11.5,
      color: palette.ink.withValues(alpha: dark ? 0.82 : 0.78),
      letterSpacing: 0.1,
      height: 1.2,
      shadows: halo,
    );
    final strong = base.copyWith(
      fontSize: 12.5,
      fontWeight: FontWeight.w600,
      color: palette.ink.withValues(alpha: dark ? 0.92 : 0.88),
    );
    final emphasized = {view.selected, view.hovered, view.focused}
      ..remove(null);
    final candidates = [...hits]
      ..sort((a, b) {
        int rank(Hit h) => emphasized.contains(h.id)
            ? 3
            : h.id.startsWith('device:')
            ? 2
            : 1;
        final byRank = rank(b).compareTo(rank(a));
        return byRank != 0 ? byRank : b.radius.compareTo(a.radius);
      });
    // Stars are obstacles: a planet's label never lies over one.
    final stars = [
      for (final hit in hits)
        if (hit.id.startsWith('device:'))
          Rect.fromCircle(center: hit.center, radius: hit.radius * 0.7),
    ];
    final placed = <Rect>[];
    var shown = 0;
    for (final hit in candidates) {
      final device = hit.id.startsWith('device:');
      final emphasis = emphasized.contains(hit.id);
      if (!emphasis && !device && hit.radius < 5) continue;
      if (shown >= 28 && !emphasis) break;
      final painter = _text(hit.label, device || emphasis ? strong : base);
      final offset = Offset(
        hit.center.dx - painter.width / 2,
        hit.center.dy + hit.radius + (device ? 8 : 5),
      );
      final rect = (offset & painter.size).inflate(3);
      if (!emphasis &&
          (placed.any(rect.overlaps) ||
              (!device && stars.any(rect.overlaps)))) {
        continue;
      }
      if (rect.right < 0 || rect.left > size.width || rect.top > size.height) {
        continue;
      }
      placed.add(rect);
      painter.paint(canvas, offset);
      shown++;
    }
  }

  TextPainter _text(String text, TextStyle style) =>
      painter.labels.of(text, style);
}
