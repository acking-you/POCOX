// The galaxy's cached sprites must paint what the vector layers paint:
// spheres of every size the galaxy draws, faded and opaque, in both themes,
// plus the glows and halos drawn as soft discs.
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocox/src/tools/galaxy/galaxy_sprites.dart';
import 'package:pocox/src/tools/planet_glyph.dart';

const _ratio = 2.0;
const _size = Size(420, 260);

/// Spheres and glows laid out in a grid, through [layers].
void _scene(SphereLayers layers, bool dark) {
  const colors = [Color(0xFF3FB950), Color(0xFFE5534B), Color(0xFF8E8E8A)];
  const radii = [1.2, 2.5, 4.4, 7.3, 13.0, 26.0];
  var x = 30.0;
  for (final radius in radii) {
    var y = 30.0;
    for (final (i, opacity) in [1.0, 0.62, 0.3].indexed) {
      paintSphere(
        layers,
        Offset(x, y),
        radius,
        colors[i],
        dark: dark,
        glow: i == 2 ? 0 : 0.9,
        opacity: opacity,
      );
      y += 80;
    }
    x += radius * 2 + 40;
  }
  layers.softDisc(
    const Offset(360, 200),
    60,
    30,
    colors[0].withValues(alpha: 0.16),
  );
}

Future<Uint8List> _pixels(void Function(Canvas canvas) paint) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)..scale(_ratio);
  canvas.drawColor(const Color(0xFF808080), BlendMode.src);
  paint(canvas);
  final picture = recorder.endRecording();
  final image = await picture.toImage(
    (_size.width * _ratio).round(),
    (_size.height * _ratio).round(),
  );
  final data = await image.toByteData();
  image.dispose();
  picture.dispose();
  return data!.buffer.asUint8List();
}

void main() {
  for (final dark in [false, true]) {
    test(
      'sprites paint the vector layers (${dark ? 'dark' : 'light'})',
      () async {
        final sprites = GalaxySprites();
        void frame(Canvas canvas) {
          sprites.begin(canvas, dark: dark, ratio: _ratio);
          _scene(sprites, dark);
          sprites.flush();
        }

        final vector = await _pixels(
          (c) => _scene(CanvasSphereLayers(c), dark),
        );
        // The first frame asks for the layers and paints vectors.
        final first = await _pixels(frame);
        expect(first, vector);
        final cached = await _pixels(frame);
        expect(cached, isNot(vector), reason: 'the second frame uses sprites');
        // Resampling a cached image moves anti-aliased edges by a fraction of
        // a pixel; anything else (a wrong colour, size, place or opacity)
        // would differ over whole areas.
        var worst = 0;
        var off = 0;
        for (var i = 0; i < vector.length; i++) {
          final d = (vector[i] - cached[i]).abs();
          if (d > worst) worst = d;
          if (d > 8) off++;
        }
        expect(off / vector.length, lessThan(0.001));
        expect(worst, lessThan(64));
        sprites.dispose();
      },
    );
  }
}
