/// A small lit sphere: how a service looks wherever it appears, on a card or
/// in the galaxy. Its colour is the service's state.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pocox/src/theme.dart';

/// The colour of a service state: healthy, waiting, failing, refused or gone.
Color statusColor(ColorScheme scheme, String status) => switch (status) {
  'online' => successColor(scheme),
  'starting' => infoColor(scheme),
  'unreachable' => cautionColor(scheme),
  'refused' || 'error' => scheme.error,
  _ => scheme.outline,
};

/// Paint one sphere of [radius] at [center], lit from the upper left.
///
/// Dark themes let it glow in its colour; light themes give it a glossy
/// ceramic body with a soft shadow below, which reads on paper-white.
void paintPlanet(
  Canvas canvas,
  Offset center,
  double radius,
  Color color, {
  required bool dark,
  double glow = 1,
  double opacity = 1,
}) => paintSphere(
  CanvasSphereLayers(canvas),
  center,
  radius,
  color,
  dark: dark,
  glow: glow,
  opacity: opacity,
);

/// [paintPlanet] onto [layers]: each layer keeps its own opacity, so a
/// faded sphere stays as translucent as its parts.
void paintSphere(
  SphereLayers layers,
  Offset center,
  double radius,
  Color color, {
  required bool dark,
  double glow = 1,
  double opacity = 1,
}) {
  if (radius <= 0 || opacity <= 0) return;
  final alpha = opacity.clamp(0.0, 1.0);
  if (dark && glow > 0) {
    layers.softDisc(
      center,
      radius * 1.6,
      radius * 1.1,
      color.withValues(alpha: 0.30 * glow * alpha),
    );
  } else if (!dark) {
    layers.contactShadow(
      center,
      radius,
      Colors.black.withValues(alpha: 0.10 * alpha),
    );
  }
  layers.body(center, radius, color, dark: dark, alpha: alpha);
  // Rim light from the far side, which keeps the edge readable on any ground.
  layers.rim(
    center,
    radius,
    math.max(0.6, radius * 0.08),
    (dark ? 0.22 : 0.5) * alpha,
  );
  // The specular point.
  layers.softDisc(
    center + Offset(-radius * 0.36, -radius * 0.40),
    radius * 0.18,
    radius * 0.12,
    Colors.white.withValues(alpha: (dark ? 0.55 : 0.8) * alpha),
  );
}

/// Where a sphere's layers go: straight onto a canvas
/// ([CanvasSphereLayers]), or from images rendered once (the galaxy's
/// sprites).
abstract interface class SphereLayers {
  /// A disc of [radius] blurred by [sigma], in [color]: glows and halos.
  void softDisc(Offset center, double radius, double sigma, Color color);

  /// The shadow a sphere of [radius] at [center] casts on the plane beneath.
  void contactShadow(Offset center, double radius, Color color);

  /// The sphere's body in [color], lit from the upper left, at [alpha].
  void body(
    Offset center,
    double radius,
    Color color, {
    required bool dark,
    required double alpha,
  });

  /// A white rim light of [width], brightest on the far side, at [alpha].
  void rim(Offset center, double radius, double width, double alpha);
}

/// The oval of the shadow a sphere of [radius] at [center] casts on the plane
/// beneath, and its blur.
({Rect oval, double sigma}) contactShadowShape(Offset center, double radius) =>
    (
      oval: Rect.fromCenter(
        center: center + Offset(radius * 0.15, radius * 0.95),
        width: radius * 1.9,
        height: radius * 0.55,
      ),
      sigma: radius * 0.35,
    );

/// Sphere layers drawn as vectors onto [canvas].
class CanvasSphereLayers implements SphereLayers {
  /// Draws onto [canvas].
  const CanvasSphereLayers(this.canvas);

  /// The canvas.
  final Canvas canvas;

  @override
  void softDisc(Offset center, double radius, double sigma, Color color) {
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = color
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, sigma),
    );
  }

  @override
  void contactShadow(Offset center, double radius, Color color) {
    final shape = contactShadowShape(center, radius);
    canvas.drawOval(
      shape.oval,
      Paint()
        ..color = color
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, shape.sigma),
    );
  }

  @override
  void body(
    Offset center,
    double radius,
    Color color, {
    required bool dark,
    required double alpha,
  }) {
    final highlight = Color.lerp(color, Colors.white, dark ? 0.55 : 0.75)!;
    final shade = Color.lerp(color, Colors.black, dark ? 0.62 : 0.30)!;
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.38, -0.42),
          radius: 1.05,
          colors: [
            highlight.withValues(alpha: alpha),
            color.withValues(alpha: alpha),
            shade.withValues(alpha: alpha),
          ],
          stops: const [0, 0.48, 1],
        ).createShader(Rect.fromCircle(center: center, radius: radius)),
    );
  }

  @override
  void rim(Offset center, double radius, double width, double alpha) {
    canvas.drawCircle(
      center,
      radius * 0.94,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..shader = SweepGradient(
          startAngle: 0,
          endAngle: math.pi * 2,
          colors: [
            Colors.white.withValues(alpha: 0),
            Colors.white.withValues(alpha: alpha),
            Colors.white.withValues(alpha: 0),
          ],
          stops: const [0.05, 0.22, 0.42],
        ).createShader(Rect.fromCircle(center: center, radius: radius)),
    );
  }
}

/// A sphere in a square box, with an optional dashed orbit for a share an
/// agent made.
class PlanetGlyph extends StatelessWidget {
  /// A sphere of [color].
  const PlanetGlyph({
    super.key,
    required this.color,
    this.size = 32,
    this.orbit = false,
  });

  /// Its colour (see [statusColor]).
  final Color color;

  /// Edge of the box.
  final double size;

  /// Draw a dashed orbit around it.
  final bool orbit;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: _PlanetPainter(
          color: color,
          dark: dark,
          orbit: orbit,
          ring: Theme.of(context).colorScheme.onSurface,
        ),
      ),
    );
  }
}

class _PlanetPainter extends CustomPainter {
  _PlanetPainter({
    required this.color,
    required this.dark,
    required this.orbit,
    required this.ring,
  });

  final Color color;
  final bool dark;
  final bool orbit;
  final Color ring;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide * (orbit ? 0.24 : 0.30);
    if (orbit) {
      final path = Path()
        ..addOval(
          Rect.fromCenter(
            center: center,
            width: size.width * 0.92,
            height: size.height * 0.42,
          ),
        );
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = ring.withValues(alpha: dark ? 0.35 : 0.28);
      for (final metric in path.computeMetrics()) {
        for (var d = 0.0; d < metric.length; d += 5) {
          canvas.drawPath(metric.extractPath(d, d + 2.5), paint);
        }
      }
    }
    paintPlanet(canvas, center, radius, color, dark: dark);
  }

  @override
  bool shouldRepaint(_PlanetPainter old) =>
      old.color != color || old.dark != dark || old.orbit != orbit;
}
