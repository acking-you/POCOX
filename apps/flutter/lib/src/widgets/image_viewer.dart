import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Uint8List;
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/app_icons.dart';
import 'package:pocox/src/desktop_theme.dart';
import 'package:pocox/src/image_attachments.dart';
import 'package:pocox/src/widgets/message_images.dart';
import 'package:pocox/src/widgets/window_title_bar.dart';

/// Fullscreen image viewer: swipe (PageView) between a message's images,
/// pinch/scroll to zoom (InteractiveViewer), save-to-file on desktop.
class ImageViewerPage extends StatefulWidget {
  /// Creates the viewer over [images] starting at [initialIndex].
  const ImageViewerPage({
    super.key,
    required this.images,
    required this.initialIndex,
  });

  /// Decoded image bytes, in message order.
  final List<Uint8List> images;

  /// Which image to show first.
  final int initialIndex;

  /// Push the viewer as a fullscreen dialog route.
  static Future<void> show(
    BuildContext context,
    List<Uint8List> images,
    int initialIndex,
  ) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) =>
          ImageViewerPage(images: images, initialIndex: initialIndex),
    ),
  );

  @override
  State<ImageViewerPage> createState() => _ImageViewerPageState();
}

class _ImageViewerPageState extends State<ImageViewerPage> {
  late final PageController _pager = PageController(
    initialPage: widget.initialIndex,
  );
  late int _index = widget.initialIndex;

  // One controller per page, so the −/+ buttons and the pinch gesture drive the
  // same transform (a button that fought the gesture would be worse than no
  // button) and so leaving a page resets its zoom.
  final Map<int, TransformationController> _zoom = {};

  /// Zoom steps the buttons walk through. Multiplicative rather than additive:
  /// +25 percentage points is a huge jump at 0.5× and a nudge at 6×.
  static const double _zoomStep = 1.25;
  static const double _minZoom = 0.5;
  static const double _maxZoom = 6;

  TransformationController _controllerFor(int i) =>
      _zoom.putIfAbsent(i, TransformationController.new);

  @override
  void dispose() {
    _pager.dispose();
    for (final c in _zoom.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// Current scale of the visible page (the matrix is uniform-scale only —
  /// InteractiveViewer never shears — so the x-scale IS the zoom).
  double get _scale => _controllerFor(_index).value.getMaxScaleOnAxis();

  void _setZoom(double target) {
    final next = target.clamp(_minZoom, _maxZoom);
    // Scale about the viewport centre, which is what the buttons imply — the
    // default origin is the top-left, which would walk the image off-screen.
    final box = context.findRenderObject() as RenderBox?;
    final size = box?.size ?? Size.zero;
    _controllerFor(_index).value = Matrix4.identity()
      ..translateByDouble(size.width / 2, size.height / 2, 0, 1)
      ..scaleByDouble(next, next, next, 1)
      ..translateByDouble(-size.width / 2, -size.height / 2, 0, 1);
    setState(() {});
  }

  Future<void> _save() {
    final bytes = widget.images[_index];
    // Sniff the real container (small GIF/WebP originals pass through
    // byte-identical) so the suggested extension is honest.
    return saveImageBytes(
      context,
      bytes,
      suggestedName: 'image-${_index + 1}.${sniffImageExtension(bytes)}',
    );
  }

  Widget _brokenViewer(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(
          AppIcons.broken_image_outlined,
          color: Colors.white70,
          size: 48,
        ),
        const SizedBox(height: 8),
        Text(
          l10n.imageLoadFailed,
          style: const TextStyle(color: Colors.white70),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: Colors.black,
      // The viewer fills the window, so it needs the app's own title bar rather
      // than a bare AppBar: on macOS that insets the close button past the
      // native traffic lights, and on Windows — where TitleBarStyle.hidden
      // removed the native caption buttons — it redraws minimise/maximise/close.
      // A plain AppBar left the window with no way to be closed or maximised
      // for as long as the viewer was open.
      appBar: WindowTitleBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: widget.images.length > 1
            ? Text('${_index + 1}/${widget.images.length}')
            : null,
        actions: [
          if (canSaveImages)
            IconButton(
              key: const Key('image-save-btn'),
              tooltip: l10n.imageSave,
              icon: const Icon(AppIcons.download_outlined),
              onPressed: _save,
            ),
        ],
      ),
      body: Stack(
        children: [
          // A tap anywhere over a page pops the viewer, so the backdrop and
          // margins close it — not just the X button. Pinch and double-tap
          // still zoom; those are scale gestures, distinct from a no-move tap.
          PageView.builder(
            controller: _pager,
            itemCount: widget.images.length,
            onPageChanged: (i) => setState(() => _index = i),
            itemBuilder: (context, i) => GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => Navigator.of(context).maybePop(),
              child: InteractiveViewer(
                key: Key('image-viewer-$i'),
                transformationController: _controllerFor(i),
                minScale: _minZoom,
                maxScale: _maxZoom,
                // Keep the readout honest while the user pinches, not just
                // when a button is pressed.
                onInteractionEnd: (_) => setState(() {}),
                child: Center(
                  child: Image.memory(
                    widget.images[i],
                    gaplessPlayback: true,
                    errorBuilder: (context, _, _) => _brokenViewer(context),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 24,
            child: Center(child: _zoomBar()),
          ),
        ],
      ),
    );
  }

  /// The floating −/percentage/+ pill. Tapping the readout resets to 100%,
  /// which is the fastest way back after over-zooming.
  Widget _zoomBar() {
    final scale = _scale;
    return Material(
      key: const Key('image-zoom-bar'),
      color: Colors.black.withValues(alpha: 0.62),
      shape: const StadiumBorder(),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _zoomButton(
              buttonKey: const Key('image-zoom-out'),
              icon: AppIcons.remove,
              // Disabled at the stop rather than silently doing nothing, so the
              // control says where the limit is.
              onPressed: scale <= _minZoom + 0.001
                  ? null
                  : () => _setZoom(scale / _zoomStep),
            ),
            InkWell(
              mouseCursor: clickable,
              key: const Key('image-zoom-reset'),
              customBorder: const StadiumBorder(),
              onTap: () => _setZoom(1),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Text(
                  '${(scale * 100).round()}%',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12.5,
                    // Tabular-ish: a fixed width stops the pill resizing as the
                    // number goes 98% → 100% → 125% mid-pinch.
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
            _zoomButton(
              buttonKey: const Key('image-zoom-in'),
              icon: AppIcons.add,
              onPressed: scale >= _maxZoom - 0.001
                  ? null
                  : () => _setZoom(scale * _zoomStep),
            ),
          ],
        ),
      ),
    );
  }

  Widget _zoomButton({
    required Key buttonKey,
    required IconData icon,
    required VoidCallback? onPressed,
  }) => IconButton(
    key: buttonKey,
    icon: Icon(icon, size: 18),
    color: Colors.white,
    disabledColor: Colors.white30,
    visualDensity: VisualDensity.compact,
    onPressed: onPressed,
  );
}
