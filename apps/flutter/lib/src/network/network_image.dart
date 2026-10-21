import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:pocket_codex/src/rust/api/bridge/network.dart' as frb;

/// Flutter's image cache and decoder, with bounded reads through the app proxy.
/// Proxy URLs never enter cache keys, image diagnostics or error messages.
@immutable
class AppNetworkImage extends ImageProvider<AppNetworkImage> {
  const AppNetworkImage(this.url);

  final String url;

  @override
  Future<AppNetworkImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    AppNetworkImage key,
    ImageDecoderCallback decode,
  ) => MultiFrameImageStreamCompleter(codec: _load(decode), scale: 1);

  Future<ui.Codec> _load(ImageDecoderCallback decode) async {
    try {
      final bytes = await frb.networkImage(url: url);
      return await decode(await ui.ImmutableBuffer.fromUint8List(bytes));
    } catch (_) {
      PaintingBinding.instance.imageCache.evict(this);
      throw StateError('Application image request failed');
    }
  }

  @override
  bool operator ==(Object other) =>
      other is AppNetworkImage && other.url == url;

  @override
  int get hashCode => url.hashCode;
}
