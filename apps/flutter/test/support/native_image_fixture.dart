import 'dart:convert';
import 'dart:typed_data';

import 'package:image/image.dart' as image;
import 'package:pocox/src/image_attachments.dart';

/// Small PNG fixture for widget orchestration tests. Native image algorithms
/// and resource limits are tested by the Rust engine.
ProcessedImage preparedImageFixture(Uint8List bytes) {
  final decoded = image.decodePng(bytes);
  if (decoded == null) throw const FormatException('invalid fixture PNG');
  return ProcessedImage(
    bytes: bytes,
    mime: 'image/png',
    width: decoded.width,
    height: decoded.height,
    dataUrl: 'data:image/png;base64,${base64Encode(bytes)}',
  );
}
