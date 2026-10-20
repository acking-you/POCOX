/// The galaxy's glows, halos, shadows, lit spheres and spikes as sprites:
/// each layer is rendered once per kind, colour and size into one atlas
/// image, and a frame draws them with `drawRawAtlas` in the order the vector
/// painter would, each with its own colour and opacity. A frame then needs
/// no blur or gradient of its own. A layer is painted as vectors in the one
/// frame that first asks for it; the next frame takes it into the atlas.
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:pocket_codex/src/tools/planet_glyph.dart';

/// Paint a star's body in the dark sky: white at the core, its colour at
/// the edge.
void paintStarBody(
  Canvas canvas,
  Offset center,
  double radius,
  Color color,
  double alpha,
) {
  canvas.drawCircle(
    center,
    radius,
    Paint()
      ..shader = RadialGradient(
        colors: [
          Colors.white.withValues(alpha: alpha),
          color.withValues(alpha: alpha),
        ],
        stops: const [0.25, 1],
      ).createShader(Rect.fromCircle(center: center, radius: radius)),
  );
}

/// Paint one diffraction spike through [center]: a white line of [width]
/// reaching [reach] either side, fading out from [alpha] at the centre;
/// [vertical] turns it upright.
void paintSpike(
  Canvas canvas,
  Offset center,
  double reach,
  double width,
  double alpha, {
  bool vertical = false,
}) {
  final along = vertical ? Offset(0, reach) : Offset(reach, 0);
  canvas.drawLine(
    center - along,
    center + along,
    Paint()
      ..strokeWidth = width
      ..shader = RadialGradient(
        colors: [
          Colors.white.withValues(alpha: alpha),
          Colors.white.withValues(alpha: 0),
        ],
      ).createShader(Rect.fromCircle(center: center, radius: reach)),
  );
}

/// Paints a cell's layer at the origin, at its size of [unit] pixels and
/// full strength.
typedef _CellPaint = void Function(Canvas canvas, double unit);

/// One layer's image in the atlas.
class _Cell {
  _Cell(this.rect, this.anchor, this.unit, this.paint);

  /// Where it is in the atlas, in pixels.
  final Rect rect;

  /// The layer's centre, from [rect]'s top left.
  final Offset anchor;

  /// The layer's size (a radius, or a spike's reach) in pixels.
  final double unit;

  final _CellPaint paint;

  /// Whether the atlas image holds it yet.
  bool ready = false;
}

/// A stretch of the atlas's skyline: from [x], [width] wide, filled down
/// to [y].
class _Span {
  _Span(this.x, this.y, this.width);

  final double x;
  final double y;
  final double width;
}

/// The sprites of one galaxy page, owned with its painter state.
///
/// Sharp layers (bodies, rims, spikes) are rendered per size bucket, four
/// per octave of on-screen pixels, and drawn at most 16 % smaller than
/// rendered. Soft layers (blurred discs, shadows, the plane's glow) blur
/// over several pixels, so two buckets per octave serve them, and above a
/// small size they are scaled up, which a blur survives unchanged. Colours
/// other than a body's are applied when drawn (white images, modulated), so
/// one image serves every colour. Cells are packed bottom-left on a
/// skyline; the atlas is at most 512×2048 pixels (4 MB) and, measured at a
/// pixel ratio of 2, a few hundred kilobytes.
class GalaxySprites implements SphereLayers {
  final Map<int, _Cell> _cells = {};
  final List<_Cell> _fresh = [];
  ui.Image? _image;
  Canvas? _canvas;
  double _ratio = 1;
  bool? _dark;
  bool _full = false;
  int _frames = 0;

  /// Frames left to paint only vectors after an image failed to rasterize
  /// (a lost GPU context); then the images are made again.
  int _hold = 0;
  final List<_Span> _skyline = [_Span(0, 0, _width.toDouble())];
  double _height = 0;

  ui.Image? _plane;
  (int, int)? _planeKey;
  Rect _planeSource = Rect.zero;

  final List<double> _transforms = [];
  final List<double> _rects = [];
  final List<int> _colors = [];
  final Paint _paint = Paint()..filterQuality = FilterQuality.low;

  static int _liveBytes = 0;

  /// Bytes held by every page's sprite images: for diagnostics (the
  /// galaxy's performance harness).
  static int get liveBytes => _liveBytes;

  static const int _width = 512;
  static const double _maxHeight = 2048;
  static const double _pad = 2;

  /// A full atlas starts afresh at most this often (in frames), so it drops
  /// sizes no longer drawn without rebuilding every frame; in between, what
  /// does not fit is painted as vectors.
  static const int _refill = 600;

  static const int _sharp = 4;
  static const int _smooth = 2;

  /// Largest buckets: 16 px for blurred discs, 32 px for shadows, 128 px for
  /// sharp layers (larger ones are painted as vectors).
  static const int _softMax = 4 * _smooth;
  static const int _shadowMax = 5 * _smooth;
  static const int _sharpMax = 7 * _sharp;

  static const int _soft = 1;
  static const int _shadow = 2;
  static const int _body = 3;
  static const int _rim = 4;
  static const int _star = 5;
  static const int _spike = 6;

  /// Start a frame on [canvas]: the atlas takes in what the last frame asked
  /// for. A change of theme starts it afresh.
  void begin(Canvas canvas, {required bool dark, required double ratio}) {
    _canvas = canvas;
    _ratio = ratio;
    _frames++;
    if (_hold > 0) _hold--;
    // Nothing carries over from a frame that did not finish.
    _transforms.clear();
    _rects.clear();
    _colors.clear();
    if (_dark != dark || (_full && _frames > _refill)) _clear();
    _dark = dark;
    if (_fresh.isNotEmpty) _render();
  }

  /// Draw what is queued. Call before painting anything else, so sprites
  /// stay under what is drawn after them.
  void flush() {
    final image = _image;
    final canvas = _canvas;
    if (_colors.isEmpty || image == null || canvas == null) return;
    try {
      canvas.drawRawAtlas(
        image,
        Float32List.fromList(_transforms),
        Float32List.fromList(_rects),
        Int32List.fromList(_colors),
        BlendMode.modulate,
        null,
        _paint,
      );
    } on ui.PictureRasterizationException {
      // These sprites are lost for this one frame.
      _failed();
    }
    _transforms.clear();
    _rects.clear();
    _colors.clear();
  }

  /// An image could not be rasterized, which surfaces only when it is
  /// drawn: drop every image and paint vectors for a while.
  void _failed() {
    _clear();
    _setPlane(null);
    _planeKey = null;
    _hold = _refill;
  }

  /// Release the images.
  void dispose() {
    _clear();
    _setPlane(null);
    _planeKey = null;
  }

  @override
  void softDisc(Offset center, double radius, double sigma, Color color) {
    if (radius <= 0) return;
    // Blur relative to the disc, in 1/4096ths.
    final k = (sigma / radius * 4096).round();
    final bucket = math.min(_bucket(radius, _smooth), _softMax);
    final key = _key(_soft, k, bucket);
    if (_draw(key, center, radius, color)) return;
    if (!_cells.containsKey(key)) {
      final blur = k / 4096;
      final e = 1 + 3 * blur;
      _add(
        key,
        _unit(bucket, _smooth),
        Rect.fromLTRB(-e, -e, e, e),
        (canvas, unit) => CanvasSphereLayers(
          canvas,
        ).softDisc(Offset.zero, unit, unit * blur, Colors.white),
      );
    }
    _vector.softDisc(center, radius, sigma, color);
  }

  @override
  void contactShadow(Offset center, double radius, Color color) {
    if (radius <= 0) return;
    final bucket = math.min(_bucket(radius, _smooth), _shadowMax);
    final key = _key(_shadow, 0, bucket);
    if (_draw(key, center, radius, color)) return;
    if (!_cells.containsKey(key)) {
      final shape = contactShadowShape(Offset.zero, 1);
      _add(
        key,
        _unit(bucket, _smooth),
        shape.oval.inflate(shape.sigma * 3),
        (canvas, unit) => CanvasSphereLayers(
          canvas,
        ).contactShadow(Offset.zero, unit, Colors.white),
      );
    }
    _vector.contactShadow(center, radius, color);
  }

  @override
  void body(
    Offset center,
    double radius,
    Color color, {
    required bool dark,
    required double alpha,
  }) {
    if (radius <= 0) return;
    final bucket = _bucket(radius, _sharp);
    if (bucket <= _sharpMax) {
      // The body's alpha is applied when drawn: only its colour picks the
      // image.
      final rgb = color.toARGB32() & 0xFFFFFF;
      final key = _key(_body, rgb * 2 + (dark ? 1 : 0), bucket);
      if (_draw(key, center, radius, Colors.white.withValues(alpha: alpha))) {
        return;
      }
      if (!_cells.containsKey(key)) {
        final opaque = color.withValues(alpha: 1);
        _add(
          key,
          _unit(bucket, _sharp),
          _unitBox,
          (canvas, unit) => CanvasSphereLayers(
            canvas,
          ).body(Offset.zero, unit, opaque, dark: dark, alpha: 1),
        );
      }
    }
    _vector.body(center, radius, color, dark: dark, alpha: alpha);
  }

  @override
  void rim(Offset center, double radius, double width, double alpha) {
    if (radius <= 0) return;
    final bucket = _bucket(radius, _sharp);
    if (bucket <= _sharpMax) {
      final relative = _relative(width / radius);
      final key = _key(_rim, relative.$1 + 1024, bucket);
      if (_draw(key, center, radius, Colors.white.withValues(alpha: alpha))) {
        return;
      }
      if (!_cells.containsKey(key)) {
        final w = relative.$2;
        final e = 0.94 + w / 2;
        _add(
          key,
          _unit(bucket, _sharp),
          Rect.fromLTRB(-e, -e, e, e),
          (canvas, unit) =>
              CanvasSphereLayers(canvas).rim(Offset.zero, unit, unit * w, 1),
        );
      }
    }
    _vector.rim(center, radius, width, alpha);
  }

  /// [paintStarBody] from the atlas.
  void starBody(Offset center, double radius, Color color, double alpha) {
    if (radius <= 0) return;
    final bucket = _bucket(radius, _sharp);
    if (bucket <= _sharpMax) {
      final key = _key(_star, color.toARGB32() & 0xFFFFFF, bucket);
      if (_draw(key, center, radius, Colors.white.withValues(alpha: alpha))) {
        return;
      }
      if (!_cells.containsKey(key)) {
        final opaque = color.withValues(alpha: 1);
        _add(
          key,
          _unit(bucket, _sharp),
          _unitBox,
          (canvas, unit) => paintStarBody(canvas, Offset.zero, unit, opaque, 1),
        );
      }
    }
    flush();
    paintStarBody(_canvas!, center, radius, color, alpha);
  }

  /// A star's two diffraction spikes ([paintSpike], level and upright) from
  /// one image of the level one, turned for the other.
  void spikes(Offset center, double reach, double width, double alpha) {
    if (reach <= 0) return;
    final bucket = _bucket(reach, _sharp);
    if (bucket <= _sharpMax) {
      final relative = _relative(width / reach);
      final key = _key(_spike, relative.$1 + 1024, bucket);
      final color = Colors.white.withValues(alpha: alpha);
      if (_draw(key, center, reach, color)) {
        _draw(key, center, reach, color, upright: true);
        return;
      }
      if (!_cells.containsKey(key)) {
        final half = relative.$2 / 2;
        _add(
          key,
          _unit(bucket, _sharp),
          Rect.fromLTRB(-1, -half, 1, half),
          (canvas, unit) =>
              paintSpike(canvas, Offset.zero, unit, unit * relative.$2, 1),
        );
      }
    }
    flush();
    paintSpike(_canvas!, center, reach, width, alpha);
    paintSpike(_canvas!, center, reach, width, alpha, vertical: true);
  }

  /// [oval] blurred by [sigma] in [color], from an image of its shape
  /// rendered small (the plane's glow).
  void softOval(Rect oval, double sigma, Color color) {
    if (oval.isEmpty || sigma <= 0) return;
    flush();
    void vector() => _canvas!.drawOval(
      oval,
      Paint()
        ..color = color
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, sigma),
    );
    if (_hold > 0) return vector();
    // The shape is its size relative to its blur, in 1/32 octaves.
    int log(double v) => (math.log(v) / math.ln2 * 32).round();
    final key = (log(oval.width / sigma), log(oval.height / sigma));
    if (key != _planeKey) {
      _planeKey = key;
      // A blur of 8 px, which scales up smoothly.
      const blur = 8.0;
      final size = Size(
        math.pow(2, key.$1 / 32) * blur,
        math.pow(2, key.$2 / 32) * blur,
      );
      _planeSource = (Offset.zero & size)
          .inflate(blur * 3)
          .shift(const Offset(blur * 3, blur * 3));
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawOval(
        Offset(blur * 3, blur * 3) & size,
        Paint()
          ..color = Colors.white
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, blur),
      );
      final picture = recorder.endRecording();
      // Rasterized when first drawn; a failure surfaces there.
      _setPlane(
        picture.toImageSync(
          _round(_planeSource.width, 16),
          _round(_planeSource.height, 16),
        ),
      );
      picture.dispose();
    }
    final image = _plane;
    if (image == null) return vector();
    try {
      _canvas!.drawImageRect(
        image,
        _planeSource,
        oval.inflate(sigma * 3),
        Paint()
          ..filterQuality = FilterQuality.low
          ..colorFilter = ColorFilter.mode(color, BlendMode.modulate),
      );
    } on ui.PictureRasterizationException {
      _failed();
      vector();
    }
  }

  static final Rect _unitBox = Rect.fromLTRB(-1, -1, 1, 1);

  /// Vector layers, after what is queued.
  CanvasSphereLayers get _vector {
    flush();
    return CanvasSphereLayers(_canvas!);
  }

  /// The size bucket of [size] (in logical pixels) on screen, [perOctave]
  /// buckets per octave.
  int _bucket(double size, int perOctave) => math.max(
    -2 * perOctave,
    (math.log(size * _ratio) / math.ln2 * perOctave).ceil(),
  );

  static double _unit(int bucket, int perOctave) =>
      math.pow(2, bucket / perOctave).toDouble();

  /// A width relative to its layer's size, in eighths of an octave, and
  /// the relative width that stands for.
  static (int, double) _relative(double ratio) {
    final step = (math.log(ratio) / math.ln2 * 8).round();
    return (step, math.pow(2, step / 8).toDouble());
  }

  /// [size] rounded up to a multiple of [step]: images of few sizes, which
  /// the GPU can reuse as they are replaced, instead of one size each.
  static int _round(double size, int step) => (size / step).ceil() * step;

  static int _key(int kind, int variant, int bucket) =>
      kind * (1 << 44) + variant * (1 << 12) + bucket + 2048;

  /// Queue the cell of [key] at [center] and [size] in [color] (turned a
  /// quarter if [upright]), if the atlas holds it.
  bool _draw(
    int key,
    Offset center,
    double size,
    Color color, {
    bool upright = false,
  }) {
    final cell = _cells[key];
    if (cell == null || !cell.ready || _hold > 0) return false;
    final scale = size / cell.unit;
    final anchor = cell.anchor;
    if (upright) {
      _transforms
        ..add(0)
        ..add(scale)
        ..add(center.dx + scale * anchor.dy)
        ..add(center.dy - scale * anchor.dx);
    } else {
      _transforms
        ..add(scale)
        ..add(0)
        ..add(center.dx - scale * anchor.dx)
        ..add(center.dy - scale * anchor.dy);
    }
    _rects
      ..add(cell.rect.left)
      ..add(cell.rect.top)
      ..add(cell.rect.right)
      ..add(cell.rect.bottom);
    _colors.add(color.toARGB32());
    return true;
  }

  /// Place a cell of [unit] pixels spanning [box] (in units around its
  /// centre) for the next frame's atlas.
  void _add(int key, double unit, Rect box, _CellPaint paint) {
    if (_full || _hold > 0) return;
    final width = (box.width * unit).ceilToDouble() + _pad * 2;
    final height = (box.height * unit).ceilToDouble() + _pad * 2;
    final rect = _place(width, height);
    if (rect == null) {
      _full = true;
      return;
    }
    final cell = _Cell(
      rect,
      Offset(_pad - box.left * unit, _pad - box.top * unit),
      unit,
      paint,
    );
    _cells[key] = cell;
    _fresh.add(cell);
  }

  /// The lowest room for a cell on the skyline, leftmost first, or null
  /// when the atlas is full.
  Rect? _place(double width, double height) {
    var best = -1;
    var bestY = double.infinity;
    for (var i = 0; i < _skyline.length; i++) {
      final x = _skyline[i].x;
      if (x + width > _width) break;
      // The cell rests on the highest span it covers.
      var y = 0.0;
      for (var j = i; j < _skyline.length && _skyline[j].x < x + width; j++) {
        y = math.max(y, _skyline[j].y);
      }
      if (y < bestY) {
        best = i;
        bestY = y;
      }
    }
    if (best < 0 || bestY + height > _maxHeight) return null;
    final x = _skyline[best].x;
    // Replace the spans the cell covers by its top, keeping what sticks out.
    final right = x + width;
    var end = best;
    while (end < _skyline.length && _skyline[end].x < right) {
      end++;
    }
    final last = _skyline[end - 1];
    final rest = last.x + last.width - right;
    _skyline.replaceRange(best, end, [
      _Span(x, bestY + height, width),
      if (rest > 0) _Span(right, last.y, rest),
    ]);
    _height = math.max(_height, bestY + height);
    return Rect.fromLTWH(x, bestY, width, height);
  }

  /// Render the atlas again: the last image as it was, the new cells below
  /// and beside it.
  void _render() {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final old = _image;
    if (old != null) {
      try {
        canvas.drawImage(old, Offset.zero, Paint());
      } on ui.PictureRasterizationException {
        recorder.endRecording().dispose();
        _failed();
        return;
      }
    }
    for (final cell in _fresh) {
      final rect = cell.rect;
      canvas
        ..save()
        ..clipRect(rect)
        ..translate(rect.left + cell.anchor.dx, rect.top + cell.anchor.dy);
      cell.paint(canvas, cell.unit);
      canvas.restore();
    }
    final picture = recorder.endRecording();
    // Rasterized when first drawn; a failure surfaces there ([flush]).
    _setImage(picture.toImageSync(_width, _round(_height, 64)));
    picture.dispose();
    for (final cell in _fresh) {
      cell.ready = true;
    }
    _fresh.clear();
  }

  void _setImage(ui.Image? image) {
    final old = _image;
    if (old != null) {
      _liveBytes -= old.width * old.height * 4;
      old.dispose();
    }
    _image = image;
    if (image != null) _liveBytes += image.width * image.height * 4;
  }

  void _setPlane(ui.Image? image) {
    final old = _plane;
    if (old != null) {
      _liveBytes -= old.width * old.height * 4;
      old.dispose();
    }
    _plane = image;
    if (image != null) _liveBytes += image.width * image.height * 4;
  }

  void _clear() {
    _transforms.clear();
    _rects.clear();
    _colors.clear();
    _setImage(null);
    _cells.clear();
    _fresh.clear();
    _full = false;
    _frames = 0;
    _skyline
      ..clear()
      ..add(_Span(0, 0, _width.toDouble()));
    _height = 0;
  }
}
