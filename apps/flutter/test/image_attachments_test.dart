import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pocox/src/image_attachments.dart';

Uint8List _png({int w = 6, int h = 4, bool alpha = false}) {
  final im = img.Image(width: w, height: h, numChannels: alpha ? 4 : 3);
  img.fill(
    im,
    color: alpha ? img.ColorRgba8(200, 40, 40, 0) : img.ColorRgb8(200, 40, 40),
  );
  return img.encodePng(im);
}

void main() {
  test('sniffImageExtension names the real container', () {
    expect(sniffImageExtension(_png()), 'png');
    final gif = img.encodeGif(img.Image(width: 4, height: 4));
    expect(sniffImageExtension(gif), 'gif');
    final jpg = img.encodeJpg(img.Image(width: 4, height: 4));
    expect(sniffImageExtension(jpg), 'jpg');
  });

  test('decodeImageDataUrl round-trips and rejects junk', () {
    final bytes = _png();
    final url = 'data:image/png;base64,${base64Encode(bytes)}';
    expect(decodeImageDataUrl(url), bytes);
    // Not an image data URL.
    expect(decodeImageDataUrl('/host/path/pic.png'), isNull);
    expect(decodeImageDataUrl('data:text/plain;base64,aGk='), isNull);
    // Missing the base64 marker.
    expect(decodeImageDataUrl('data:image/png,plain'), isNull);
    // Corrupt payload.
    expect(decodeImageDataUrl('data:image/png;base64,!!!'), isNull);
  });
}
