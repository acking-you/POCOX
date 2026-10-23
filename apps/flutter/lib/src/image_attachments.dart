import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:pocox/src/rust/api/bridge/attachments.dart' as native;

/// Longest edge an attachment is downscaled to before sending. Keeps a photo's
/// base64 payload in the hundreds-of-KB range (vs multi-MB camera originals)
/// so it stays cheap through the relay tunnel, in the rollout file, and in the
/// model context — while remaining plenty of resolution for the model to read
/// UI text and diagrams.
const int kMaxImageEdge = 1568;

/// JPEG quality for re-encoded attachments.
const int kJpegQuality = 85;

/// Originals at most this size that also fit [kMaxImageEdge] and carry no
/// EXIF rotation are sent as-is — preserving lossless PNG screenshots instead
/// of fuzzing their text through a JPEG round-trip.
const int kPassthroughMaxBytes = 1024 * 1024;

/// The most images one message may carry (UI guard; the protocol has no cap).
const int kMaxImagesPerMessage = 8;

/// A picked image after client-side processing, ready to send.
class ProcessedImage {
  /// Creates a processed image (bytes + the mime they're encoded in).
  const ProcessedImage({
    required this.bytes,
    required this.mime,
    required this.width,
    required this.height,
    required this.dataUrl,
  });

  /// Encoded image bytes (original passthrough, or the downscaled JPEG).
  final Uint8List bytes;

  /// Mime type of [bytes] (e.g. `image/jpeg`).
  final String mime;

  /// Pixel width of the encoded image.
  final int width;

  /// Pixel height of the encoded image.
  final int height;

  /// The `data:` URL form sent to the app-server — the only image form that
  /// works for BOTH local and relay-tunneled remote hosts (a filesystem path
  /// would resolve on the wrong machine).
  final String dataUrl;
}

/// CPU work and Base64 encoding run in the bounded native worker queue.
Future<ProcessedImage> processImageNative(Uint8List bytes) async =>
    _processed(await native.attachmentPrepareImage(bytes: bytes, path: null));

/// Picked local paths are read on the native worker too.
Future<ProcessedImage> processImageFileNative(String path) async =>
    _processed(await native.attachmentPrepareImage(bytes: null, path: path));

/// Tests inject file preparation without loading a native library.
@visibleForTesting
Future<ProcessedImage> Function(String path) processImageFileImpl =
    processImageFileNative;

Future<ProcessedImage> processImageFile(String path) =>
    processImageFileImpl(path);

ProcessedImage _processed(native.PreparedImageDto image) => ProcessedImage(
  bytes: image.bytes,
  mime: image.mime,
  width: image.width,
  height: image.height,
  dataUrl: image.dataUrl,
);

/// Widget tests inject prepared fixtures; algorithms are covered in Rust.
@visibleForTesting
Future<ProcessedImage> Function(Uint8List bytes) processImageImpl =
    processImageNative;

Future<ProcessedImage> processImage(Uint8List bytes) => processImageImpl(bytes);

/// Whether a picker supplied an actual local path rather than a platform URI
/// or an in-memory source. Such sources stay with the platform's byte reader.
bool localAttachmentPath(String path) =>
    path.startsWith('/') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path);

/// File extension for [bytes] sniffed from container magic: `png` / `gif` /
/// `webp`, else `jpg` (the only other format this app produces or passes
/// through). Used to suggest an honest filename when saving a viewed image.
String sniffImageExtension(Uint8List bytes) {
  if (bytes.length > 8 && bytes[0] == 0x89 && bytes[1] == 0x50) return 'png';
  if (bytes.length > 4 &&
      bytes[0] == 0x47 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46) {
    return 'gif';
  }
  if (bytes.length > 12 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return 'webp';
  }
  return 'jpg';
}

/// Decode the base64 payload of a `data:image/...` URL; null for any other
/// URL shape (host paths, http URLs) or a corrupt payload.
Uint8List? decodeImageDataUrl(String url) {
  if (!url.startsWith('data:image/')) return null;
  final comma = url.indexOf(',');
  if (comma < 0) return null;
  if (!url.substring(0, comma).endsWith(';base64')) return null;
  try {
    return base64Decode(url.substring(comma + 1));
  } on FormatException {
    return null;
  }
}
