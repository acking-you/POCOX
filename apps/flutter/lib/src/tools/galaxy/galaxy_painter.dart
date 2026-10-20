/// Paints one frame of the galaxy: sky, the disk's plane, star systems far
/// to near with their orbits split around each star, connections as arcs of
/// light, and labels that keep out of each other's way. Where everything
/// goes is computed in Rust ([GalaxyGeometry], `galaxy_frame.dart`); this
/// only draws it.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/service_key.dart';
import 'package:pocket_codex/src/tools/galaxy/galaxy_backdrop.dart';
import 'package:pocket_codex/src/tools/galaxy/galaxy_frame.dart';
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

/// The scene's buffers, re-encoded only when the scene, the bodies'
/// motions or the labels change; owned by the page with its [LabelCache].
class GalaxyGeometry {
  /// The computed frames.
  final GalaxyFrameBuffer frames = GalaxyFrameBuffer();

  /// The bodies of the encoded scene.
  GalaxyBodies? bodies;

  /// Frees the native buffers.
  void dispose() => frames.dispose();

  Float64List? _scene;
  Object? _key;

  /// The scene buffer for [view], encoded when something it holds changed.
  Float64List prepare(
    GalaxyView view, {
    required AppLocalizations l10n,
    required LabelCache labels,
    required GalaxyLabelStyles styles,
    required Starfield starfield,
  }) {
    final key = (view.scene, view.revision, l10n, styles.base, styles.strong);
    final cached = _scene;
    if (cached != null && key == _key) return cached;
    final bodies = this.bodies = GalaxyBodies(view.scene);
    _key = key;
    return _scene = encodeScene(
      bodies,
      stars: starfield.data,
      // A device's label is always in the strong style.
      deviceLabel: (system) =>
          labels.of(deviceLabel(system.device.name), styles.strong).size,
      planetLabel: (planet, {required strong}) => labels
          .of(planetLabel(l10n, planet), strong ? styles.strong : styles.base)
          .size,
      appeared: view.appeared,
      rippled: view.rippled,
    );
  }
}

/// The painter. Repaints whenever [view] ticks.
class GalaxyPainter extends CustomPainter {
  /// Paints [view] in [palette].
  GalaxyPainter({
    required this.view,
    required this.palette,
    required this.l10n,
    required this.labels,
    required this.geometry,
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

  /// The scene's buffers and the frame computation.
  final GalaxyGeometry geometry;

  /// The stars.
  final Starfield starfield;

  /// Called when the backdrop image arrives.
  final VoidCallback onBackdrop;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    if (view.still) view.stopMotion();
    final dark = palette.dark;
    final camera = view.camera;
    final styles = GalaxyLabelStyles(palette);
    final scene = geometry.prepare(
      view,
      l10n: l10n,
      labels: labels,
      styles: styles,
      starfield: starfield,
    );
    encodeFrame(
      geometry.frames.frame,
      size: size,
      yaw: camera.yaw,
      tilt: camera.tilt,
      distance: camera.distance,
      target: camera.target,
      time: view.time,
      still: view.still,
      selected: geometry.bodies!.indexOf(view.selected),
      hovered: geometry.bodies!.indexOf(view.hovered),
      focused: geometry.bodies!.indexOf(view.focused),
    );
    Backdrop.of(size, dark, palette.ratio, onBackdrop).paint(canvas);
    final values = geometry.frames.compute(scene);
    if (values == null) return;
    final reader = FrameReader(values);
    starfield.paint(canvas, reader, dark: dark);
    final frame = _Frame(this, canvas, reader, geometry.bodies!, styles, size);
    frame.plane();
    frame.systems();
    frame.links();
    frame.ghosts();
    frame.labels();
    view.hits = frame.hits;
  }

  @override
  bool shouldRepaint(GalaxyPainter old) =>
      old.view != view || !old.palette.same(palette) || old.l10n != l10n;
}

/// The labels' two styles: a planet's, and a device's or an emphasized
/// body's.
class GalaxyLabelStyles {
  GalaxyLabelStyles(GalaxyPalette palette) {
    final dark = palette.dark;
    // A soft halo of the sky's own colour keeps a label legible over light.
    final halo = [
      Shadow(
        color: (dark ? Colors.black : Colors.white).withValues(
          alpha: dark ? 0.85 : 0.95,
        ),
        blurRadius: 6,
      ),
    ];
    base = palette.text.copyWith(
      fontSize: 11.5,
      color: palette.ink.withValues(alpha: dark ? 0.82 : 0.78),
      letterSpacing: 0.1,
      height: 1.2,
      shadows: halo,
    );
    strong = base.copyWith(
      fontSize: 12.5,
      fontWeight: FontWeight.w600,
      color: palette.ink.withValues(alpha: dark ? 0.92 : 0.88),
    );
  }

  /// A planet's label.
  late final TextStyle base;

  /// A device's, or an emphasized body's, label.
  late final TextStyle strong;
}

/// One frame's drawing, reading the computed frame in order.
class _Frame {
  _Frame(
    this.painter,
    this.canvas,
    this.reader,
    this.bodies,
    this.styles,
    this.size,
  );

  final GalaxyPainter painter;
  final Canvas canvas;
  final FrameReader reader;
  final GalaxyBodies bodies;
  final GalaxyLabelStyles styles;
  final Size size;
  final List<Hit> hits = [];

  GalaxyView get view => painter.view;
  GalaxyPalette get palette => painter.palette;
  bool get dark => palette.dark;

  /// Runs of points (count, then each run's points) as views of the frame.
  List<Float32List> _runs() => [
    for (var n = reader.count(); n > 0; n--) reader.points(reader.count()),
  ];

  static Path _path(Float32List run, [Path? into]) {
    final path = into ?? Path();
    path.moveTo(run[0], run[1]);
    for (var i = 2; i < run.length; i += 2) {
      path.lineTo(run[i], run[i + 1]);
    }
    return path;
  }

  void plane() {
    final glow = reader.next() != 0;
    final oval = Rect.fromLTRB(
      reader.next(),
      reader.next(),
      reader.next(),
      reader.next(),
    );
    final blur = reader.next();
    // A soft glow over the plane, with no edge to it.
    if (glow) {
      canvas.drawOval(
        oval,
        Paint()
          ..color = palette.ink.withValues(alpha: dark ? 0.035 : 0.03)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, blur),
      );
    }
    // Faint guide circles give the plane its perspective, fading outwards.
    for (var guides = reader.count(); guides > 0; guides--) {
      final fade = reader.next();
      final path = Path();
      for (final run in _runs()) {
        if (run.isNotEmpty) _path(run, path);
      }
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.8
          ..color = palette.ink.withValues(alpha: (dark ? 0.06 : 0.07) * fade),
      );
    }
  }

  void systems() {
    for (var n = reader.count(); n > 0; n--) {
      final system = bodies.systems[reader.count()];
      final c = Offset(reader.next(), reader.next());
      final radius = reader.next();
      final depth = reader.next();
      final base = reader.next();
      final back = _runs();
      final front = _runs();
      final planets = [
        for (var p = reader.count(); p > 0; p--)
          (
            planet: bodies.planets[reader.count()],
            center: Offset(reader.next(), reader.next()),
            radius: reader.next(),
            depth: reader.next(),
            opacity: reader.next(),
            ripple: reader.next(),
            behind: reader.next() != 0,
          ),
      ];
      // One orbit per ring, split at the star so the front half covers it.
      _strokeRuns(back, base * 0.55);
      for (final planet in planets) {
        if (planet.behind) _planet(planet);
      }
      _core(system, c, radius, depth, base);
      _strokeRuns(front, base);
      for (final planet in planets) {
        if (!planet.behind) _planet(planet);
      }
    }
  }

  void _strokeRuns(List<Float32List> runs, double opacity) {
    if (runs.isEmpty || opacity <= 0) return;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = dark ? 0.9 : 0.8
      ..color = palette.ink.withValues(alpha: (dark ? 0.16 : 0.22) * opacity);
    for (final run in runs) {
      if (run.length < 4) continue;
      canvas.drawPath(_path(run), paint);
    }
  }

  void _core(
    StarSystem system,
    Offset c,
    double radius,
    double depth,
    double opacity,
  ) {
    final online = system.device.online;
    final color = system.home
        ? palette.signal
        : online
        ? palette.star
        : palette.scheme.outline;
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
      Hit(system.id, c, radius * 1.6, depth, deviceLabel(system.device.name)),
    );
  }

  void _planet(
    ({
      Planet planet,
      Offset center,
      double radius,
      double depth,
      double opacity,
      double ripple,
      bool behind,
    })
    body,
  ) {
    final planet = body.planet;
    final (c, radius, opacity) = (body.center, body.radius, body.opacity);
    final color = palette.status(planet.service.status);
    final share = planet.share;
    // A ripple crosses the ring when the status changes.
    final t = body.ripple;
    if (t >= 0) {
      canvas.drawCircle(
        c,
        radius * (1.2 + t * 3.2),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4
          ..color = color.withValues(alpha: (1 - t) * 0.7 * opacity),
      );
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
      Hit(planet.id, c, radius, body.depth, planetLabel(painter.l10n, planet)),
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
    final light = palette.signal;
    for (var n = reader.count(); n > 0; n--) {
      final curve = reader.points(reader.count());
      final particles = reader.points(reader.count());
      final last = curve.length - 2;
      final bounds = Rect.fromPoints(
        Offset(curve[0], curve[1]),
        Offset(curve[last], curve[last + 1]),
      ).inflate(1);
      canvas.drawPath(
        _path(curve),
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
      for (var i = 0; i < particles.length; i += 2) {
        canvas.drawCircle(
          Offset(particles[i], particles[i + 1]),
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
    if (view.ghosts.isEmpty) return;
    final projection = view.camera.project(size);
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
    for (var n = reader.count(); n > 0; n--) {
      final body = reader.count();
      final strong = reader.next() != 0;
      final offset = Offset(reader.next(), reader.next());
      final text = body < bodies.systems.length
          ? deviceLabel(bodies.systems[body].device.name)
          : planetLabel(
              painter.l10n,
              bodies.planets[body - bodies.systems.length],
            );
      painter.labels
          .of(text, strong ? styles.strong : styles.base)
          .paint(canvas, offset);
    }
  }
}
