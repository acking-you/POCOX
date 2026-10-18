/// The galaxy's sky: a backdrop rendered once per size and theme (ground,
/// nebula, vignette), and three layers of stars that move against the camera.
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// The nebula program, loaded once; null where shaders are unavailable.
Future<ui.FragmentProgram?> _program = ui.FragmentProgram.fromAsset(
  'shaders/nebula.frag',
).then<ui.FragmentProgram?>((p) => p, onError: (_) => null);

/// The ground colours of the sky.
({Color top, Color bottom, Color glow}) skyColors(bool dark) => dark
    ? (
        top: const Color(0xFF0B0C0E),
        bottom: const Color(0xFF131418),
        glow: const Color(0xFF1C1D22),
      )
    : (
        top: const Color(0xFFF6F6F4),
        bottom: const Color(0xFFEDEDEA),
        glow: const Color(0xFFFFFFFF),
      );

/// Paint the sky's ground without the nebula: what shows until the image
/// is ready, and where shaders are unavailable.
void paintGround(Canvas canvas, Size size, bool dark) {
  final colors = skyColors(dark);
  final rect = Offset.zero & size;
  canvas.drawRect(
    rect,
    Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [colors.top, colors.bottom],
      ).createShader(rect),
  );
  // Lit from the centre of the disk.
  canvas.drawRect(
    rect,
    Paint()
      ..shader = RadialGradient(
        center: const Alignment(0, 0.08),
        radius: 0.75,
        colors: [
          colors.glow.withValues(alpha: dark ? 0.55 : 0.9),
          colors.glow.withValues(alpha: 0),
        ],
      ).createShader(rect),
  );
}

/// The backdrop image for one size and theme, rendered once.
class Backdrop {
  Backdrop._(this.size, this.dark, this.ratio);

  /// Logical size.
  final Size size;

  /// Theme.
  final bool dark;

  /// Device pixel ratio.
  final double ratio;

  ui.Image? _image;
  bool _disposed = false;

  /// Told when the image arrives: the page that asked for it last, since
  /// one shared render may outlive the page that started it.
  VoidCallback? _ready;

  /// The rendered image, once ready.
  ui.Image? get image => _image;

  static Backdrop? _current;

  /// The backdrop for this size and theme, starting its render if new;
  /// [ready] runs when the image arrives.
  static Backdrop of(Size size, bool dark, double ratio, VoidCallback ready) {
    final current = _current;
    if (current != null &&
        current.size == size &&
        current.dark == dark &&
        current.ratio == ratio) {
      return current.._ready = ready;
    }
    current?._dispose();
    final next = _current = Backdrop._(size, dark, ratio).._ready = ready;
    next._render();
    return next;
  }

  Future<void> _render() async {
    final program = await _program;
    if (_disposed || size.isEmpty) return;
    // Half resolution is plenty for smoke and keeps the render quick.
    final scale = math.min(ratio, 1.5) * 0.5;
    final width = math.max(1, (size.width * scale).round());
    final height = math.max(1, (size.height * scale).round());
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.scale(scale);
    paintGround(canvas, size, dark);
    if (program != null) {
      final shader = program.fragmentShader()
        ..setFloat(0, size.width)
        ..setFloat(1, size.height)
        ..setFloat(2, 17.0)
        ..setFloat(3, dark ? 1 : 0);
      canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
    }
    // A vignette keeps the eye on the disk.
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = RadialGradient(
          radius: 0.95,
          colors: [
            Colors.transparent,
            (dark ? Colors.black : const Color(0xFF8A8A86)).withValues(
              alpha: dark ? 0.55 : 0.10,
            ),
          ],
          stops: const [0.55, 1],
        ).createShader(Offset.zero & size),
    );
    final picture = recorder.endRecording();
    try {
      final image = await picture.toImage(width, height);
      if (_disposed) {
        image.dispose();
        return;
      }
      _image = image;
      _ready?.call();
    } catch (_) {
      // No rasteriser (tests): the ground is painted live instead.
    } finally {
      picture.dispose();
    }
  }

  void _dispose() {
    _disposed = true;
    _ready = null;
    _image?.dispose();
    _image = null;
  }

  /// Draw it, or the plain ground until it is ready.
  void paint(Canvas canvas) {
    final image = _image;
    if (image == null) {
      paintGround(canvas, size, dark);
      return;
    }
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.medium,
    );
  }
}

/// One layer of stars: unit positions, drawn in brightness buckets so they
/// twinkle without per-star paints.
class _StarLayer {
  _StarLayer(this.points, this.parallax, this.size, this.phases);

  /// Per bucket: interleaved unit x, y.
  final List<Float32List> points;
  final double parallax;
  final double size;
  final List<double> phases;
}

/// Three layers of stars, far to near, with a slow twinkle.
class Starfield {
  /// Generates the layers from a fixed seed.
  Starfield() : _layers = _generate();

  final List<_StarLayer> _layers;
  final Float32List _scratch = Float32List(2 * 400);

  static List<_StarLayer> _generate() {
    final random = math.Random(4242);
    _StarLayer layer(int count, double parallax, double size) {
      final buckets = List.generate(4, (_) => <double>[]);
      for (var i = 0; i < count; i++) {
        buckets[i % 4]
          ..add(random.nextDouble())
          ..add(random.nextDouble());
      }
      return _StarLayer(
        [for (final b in buckets) Float32List.fromList(b)],
        parallax,
        size,
        [for (var i = 0; i < 4; i++) random.nextDouble() * math.pi * 2],
      );
    }

    return [layer(320, 0.12, 0.9), layer(150, 0.3, 1.35), layer(56, 0.62, 2.0)];
  }

  /// Paint every layer, shifted by the camera's [yaw] and [tilt].
  void paint(
    Canvas canvas,
    Size size,
    double yaw,
    double tilt,
    double time, {
    required bool dark,
    required bool still,
  }) {
    final base = dark ? Colors.white : const Color(0xFF2A2A2C);
    for (final layer in _layers) {
      final shiftX = (yaw / (math.pi * 2)) * size.width * layer.parallax * 2.2;
      final shiftY = (tilt - 0.52) * size.height * layer.parallax * 0.6;
      for (var b = 0; b < layer.points.length; b++) {
        final source = layer.points[b];
        final count = source.length ~/ 2;
        final out = count * 2 <= _scratch.length
            ? Float32List.sublistView(_scratch, 0, count * 2)
            : Float32List(count * 2);
        for (var i = 0; i < count; i++) {
          final x = (source[i * 2] * size.width + shiftX) % size.width;
          final y = (source[i * 2 + 1] * size.height + shiftY) % size.height;
          out[i * 2] = x < 0 ? x + size.width : x;
          out[i * 2 + 1] = y < 0 ? y + size.height : y;
        }
        final twinkle = still
            ? 0.8
            : 0.7 + 0.3 * math.sin(time * (0.6 + b * 0.23) + layer.phases[b]);
        final strength = (dark
            ? 0.32 + layer.parallax * 0.75
            : 0.10 + layer.parallax * 0.32);
        canvas.drawRawPoints(
          ui.PointMode.points,
          out,
          Paint()
            ..color = base.withValues(alpha: (strength * twinkle).clamp(0, 1))
            ..strokeWidth = layer.size
            ..strokeCap = StrokeCap.round,
        );
      }
    }
  }
}
