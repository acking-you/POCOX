import 'dart:io';

import 'package:pocket_codex/src/file_exports.dart';
import 'package:pocket_codex/src/widgets/links.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/attachment_refs.dart';
import 'package:pocket_codex/src/desktop_theme.dart';
import 'package:pocket_codex/src/ide_context.dart';
import 'package:pocket_codex/src/image_attachments.dart';
import 'package:pocket_codex/src/lru_cache.dart';
import 'package:pocket_codex/src/widgets/app_toast.dart';
import 'package:pocket_codex/src/app_icons.dart';
import 'package:pocket_codex/src/widgets/image_viewer.dart';

export 'package:pocket_codex/src/widgets/image_viewer.dart';

/// A user attachment or generated image: decoded inline pixels, a host path
/// loaded on demand, or a visible unavailable reference.
class ResolvedImage {
  ResolvedImage._({this.bytes, this.hostPath, this.broken = false});

  /// An image that exists only as a path on the host — a client-side file
  /// mention (see `ide_context.dart`) rather than a wire attachment.
  ResolvedImage.hostFile(String path) : this._(hostPath: path);

  /// Decoded image bytes for a data URL; null for a host path or broken image.
  final Uint8List? bytes;

  /// Host filesystem path for a `localImage`; null for a data URL.
  final String? hostPath;

  /// True for a `data:image/...` URL whose payload failed to decode — kept
  /// (not dropped) so the strip can show an honest "couldn't load" placeholder
  /// instead of silently hiding an attachment the sender meant to include.
  final bool broken;

  /// Basename of [hostPath] for the chip label.
  String get hostName {
    final p = hostPath ?? '';
    final cut = p.lastIndexOf(RegExp(r'[/\\]'));
    return cut < 0 ? p : p.substring(cut + 1);
  }
}

/// The image paths of [mentions] that are not already among [attached], to
/// show as their own tiles.
///
/// A client that names its attachments in the message text (the desktop
/// app's "Files mentioned by the user") also sends each picture as an
/// image: a mention is the same attachment when its path matches one, or —
/// for copies that lost their path on the way (a rollout's inline images) —
/// while such copies remain, one each in order. Where the text flags its
/// attachments (`Image attachment: true`), only flagged mentions take such a
/// copy; older text without any flag pairs every image mention in order.
List<String> unattachedImageMentions(
  List<IdeMentionedFile> mentions,
  List<ResolvedImage> attached,
) {
  final paths = {
    for (final i in attached)
      if (i.hostPath case final p?) p.replaceAll('\\', '/'),
  };
  var pathless = attached.where((i) => i.hostPath == null).length;
  final flagged = mentions.any((m) => m.attachedImage);
  final out = <String>[];
  for (final m in mentions) {
    if (!looksLikeImagePath(m.path)) continue;
    if (paths.contains(m.path.replaceAll('\\', '/'))) continue;
    if (pathless > 0 && (m.attachedImage || !flagged)) {
      pathless--;
      continue;
    }
    out.add(m.path);
  }
  return out;
}

/// Resolve wire URLs into renderable attachments, decoding each base64
/// payload exactly once (decoding per rebuild would jank the list).
/// An undecodable data URL becomes a `broken` placeholder (kept, not dropped);
/// Opaque `codex-file:` references cannot be downloaded through app-server;
/// keep a placeholder without attempting a host filesystem read.
/// Other references are host paths, fetched only by the supplied loader.
List<ResolvedImage> resolveImageUrls(List<String> urls) {
  final out = <ResolvedImage>[];
  for (final url in urls) {
    if (url.startsWith('codex-file:')) {
      out.add(ResolvedImage._(broken: true));
    } else if (url.startsWith('data:')) {
      final bytes = url.length <= (kMaxInlineImageBytes * 4 ~/ 3) + 256
          ? decodeImageDataUrl(url)
          : null;
      out.add(
        bytes != null && bytes.length <= kMaxInlineImageBytes
            ? ResolvedImage._(bytes: bytes)
            : ResolvedImage._(broken: true),
      );
    } else {
      out.add(ResolvedImage._(hostPath: url));
    }
  }
  return out;
}

/// Whether native file exporting is supported.
bool get canSaveImages => !kIsWeb;

/// Save [bytes] to a user-chosen file, reporting the outcome via a snackbar.
/// [suggestedName] seeds the dialog filename; a cancelled dialog is a no-op.
/// Guard call sites with [canSaveImages].
Future<void> saveImageBytes(
  BuildContext context,
  Uint8List bytes, {
  required String suggestedName,
}) async {
  final l10n = AppLocalizations.of(context);
  final messenger = ToastMessenger.of(context);
  try {
    final saved = await exportBytes(bytes, suggestedName);
    if (saved != null) messenger.ok(l10n.imageSaved(saved));
  } catch (e) {
    messenger.error(l10n.imageSaveFailed('$e'));
  }
}

/// Fetches a host-side image's bytes, or null when it cannot be read (the
/// host is remote and the path sits outside the shared roots, the file is
/// gone, or it is too big to be worth pulling over a tunnel).
typedef HostImageLoader = Future<Uint8List?> Function(String hostPath);

/// Side of a composer attachment tile, and of a multi-image message thumbnail.
/// One constant because the two are meant to read as the same object: what you
/// staged in the composer is what appears in the sent message.
const double kAttachmentTileSide = 72;

/// Corner radius shared by every attachment tile and thumbnail.
const double kAttachmentTileRadius = 12;

/// The rounded-square frame every attachment tile and message thumbnail sits
/// in, optionally with a remove button in its top-right corner.
///
/// Exists so the composer strip and the transcript can't drift apart: they used
/// to hand-roll the same Container + Stack with different radii, borders and
/// button styling, which is exactly how a "staged image" and a "sent image"
/// ended up looking like two unrelated controls.
class AttachmentTile extends StatelessWidget {
  /// Creates a framed tile around [child].
  const AttachmentTile({
    super.key,
    required this.child,
    this.side = kAttachmentTileSide,
    this.onRemove,
    this.removeTooltip,
    this.removeKey,
    this.onTap,
    this.tapTooltip,
  });

  /// What the frame contains — usually an `Image.memory`.
  final Widget child;

  /// Width and height of the square frame.
  final double side;

  /// Removes this attachment; null hides the corner button (sent messages).
  final VoidCallback? onRemove;

  /// Tooltip for the remove button.
  final String? removeTooltip;

  /// Key for the remove button, so a test can target this specific tile.
  final Key? removeKey;

  /// Opens this attachment (preview); null leaves the tile inert.
  final VoidCallback? onTap;

  /// Tooltip for the tile itself.
  final String? tapTooltip;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(kAttachmentTileRadius);
    Widget frame = Container(
      width: side,
      height: side,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: radius,
        color: scheme.surfaceContainerHighest,
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: child,
    );
    if (onTap != null) {
      // A transparent Material ON TOP of the (opaque) image, so the tap ripple
      // is visible — ink on an ancestor Material would paint underneath it.
      frame = Stack(
        children: [
          frame,
          Positioned.fill(
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                mouseCursor: clickable,
                borderRadius: radius,
                onTap: onTap,
                child: tapTooltip == null
                    ? null
                    : Tooltip(message: tapTooltip!),
              ),
            ),
          ),
        ],
      );
    }
    if (onRemove == null) return frame;
    // The button overhangs the frame's corner rather than sitting inside it, so
    // it doesn't cover the picture it belongs to (matches the reference app).
    return SizedBox(
      width: side + 8,
      height: side + 8,
      child: Stack(
        children: [
          Positioned(left: 0, top: 8, child: frame),
          Positioned(
            right: 0,
            top: 0,
            child: _RemoveButton(
              buttonKey: removeKey,
              tooltip: removeTooltip,
              onPressed: onRemove!,
            ),
          ),
        ],
      ),
    );
  }
}

/// The circular ✕ that removes a staged attachment. A filled disc with a
/// hairline ring, so it stays legible over a light OR dark thumbnail without
/// needing to know what it's sitting on.
class _RemoveButton extends StatelessWidget {
  const _RemoveButton({required this.onPressed, this.tooltip, this.buttonKey});

  final VoidCallback onPressed;
  final String? tooltip;
  final Key? buttonKey;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final button = Material(
      color: scheme.inverseSurface,
      shape: CircleBorder(side: BorderSide(color: scheme.surface, width: 1.5)),
      child: InkWell(
        mouseCursor: clickable,
        key: buttonKey,
        customBorder: const CircleBorder(),
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: Icon(AppIcons.close, size: 12, color: scheme.onInverseSurface),
        ),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}

/// Largest image worth loading inline: above this the decoded bitmap costs
/// more than the preview is worth, and the filename chip stays.
const int kMaxInlineImageBytes = 8 * 1024 * 1024;

/// [HostImageLoader] for a path on THIS machine. Null when the file is
/// missing, oversized or unreadable.
Future<Uint8List?> readLocalImage(String path) async {
  try {
    final file = File(path);
    if (!await file.exists()) return null;
    final length = await file.length();
    // An empty file decodes to nothing: the chip is a better answer than a
    // broken-image tile.
    if (length == 0 || length > kMaxInlineImageBytes) return null;
    return await file.readAsBytes();
  } catch (_) {
    return null;
  }
}

/// Thumbnail strip for a message's image attachments. Tapping a thumbnail
/// opens the fullscreen [ImageViewerPage] (swipe between the message's
/// images, pinch to zoom).
///
/// An image that only ever existed as a host path — a `localImage` or a file
/// the sending client mentioned — has no bytes on the wire. Given a
/// [hostImageLoader] the strip fetches them so the picture shows like any
/// other attachment; without one, or when the fetch fails, it falls back to
/// the honest filename chip.
class MessageImagesView extends StatefulWidget {
  /// Creates the strip for [images] (resolved once by the item model).
  const MessageImagesView({
    super.key,
    required this.images,
    this.hostImageLoader,
    this.cacheScope,
    this.previewSide = 180,
  });

  /// The message's resolved attachments, in send order.
  final List<ResolvedImage> images;

  /// How to read a host path's bytes; null leaves host images as chips.
  final HostImageLoader? hostImageLoader;

  /// Host and thread identity; changing it discards pending/cached reads.
  final Object? cacheScope;

  /// Preferred side of a single-image preview, bounded by available width.
  final double previewSide;

  @override
  State<MessageImagesView> createState() => _MessageImagesViewState();
}

/// Host images already read, by host and thread ([MessageImagesView.cacheScope])
/// and path: different hosts and threads can use the same filename. A strip
/// scrolled away and back shows its pictures at once instead of reading them
/// again over the relay. Only bytes are kept; a refusal stays retryable.
final _hostImages = LruCache<(Object, String), Uint8List>(
  maxWeight: 64 << 20,
  weigh: (_, bytes) => bytes.length,
);

class _MessageImagesViewState extends State<MessageImagesView> {
  final Map<String, Uint8List?> _loaded = {};
  final Set<String> _loading = {};
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _fetchHostImages();
  }

  @override
  void didUpdateWidget(MessageImagesView old) {
    super.didUpdateWidget(old);
    if (old.cacheScope != widget.cacheScope ||
        old.hostImageLoader != widget.hostImageLoader) {
      _generation++;
      _loaded.clear();
      _loading.clear();
    }
    final paths = widget.images.map((image) => image.hostPath).toSet();
    _loaded.removeWhere((path, _) => !paths.contains(path));
    _fetchHostImages();
  }

  void _fetchHostImages() {
    final load = widget.hostImageLoader;
    if (load == null) return;
    final scope = widget.cacheScope;
    for (final image in widget.images) {
      final path = image.hostPath;
      if (path == null || _loaded.containsKey(path)) continue;
      final cached = scope == null ? null : _hostImages.get((scope, path));
      if (cached != null) {
        _loaded[path] = cached;
        continue;
      }
      if (!_loading.add(path)) continue;
      final generation = _generation;
      Future.sync(() => load(path)).then(
        (bytes) {
          if (!mounted || generation != _generation) return;
          final usable =
              bytes != null &&
              bytes.isNotEmpty &&
              bytes.length <= kMaxInlineImageBytes;
          if (usable && scope != null) _hostImages.put((scope, path), bytes);
          setState(() {
            _loading.remove(path);
            _loaded[path] = usable ? bytes : null;
          });
        },
        onError: (Object error, StackTrace stack) {
          if (!mounted || generation != _generation) return;
          setState(() {
            _loading.remove(path);
            _loaded[path] = null;
          });
        },
      );
    }
  }

  /// Bytes to draw for [image]: its own (a data URL) or the host file's, once
  /// fetched.
  Uint8List? _bytesFor(ResolvedImage image) =>
      image.bytes ?? (image.hostPath == null ? null : _loaded[image.hostPath]);

  @override
  Widget build(BuildContext context) {
    final images = widget.images;
    final renderable = [
      for (final i in images)
        if (_bytesFor(i) != null) _bytesFor(i)!,
    ];
    // A single image gets a larger preview; several tile as uniform squares.
    final side = images.length == 1 ? widget.previewSide : 96.0;
    return LayoutBuilder(
      builder: (context, constraints) {
        var bytesIndex = 0;
        final boundedSide = side.clamp(0.0, constraints.maxWidth);
        return Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final image in images)
              if (_bytesFor(image) != null)
                _ImageThumb(
                  images: renderable,
                  index: bytesIndex++,
                  side: boundedSide,
                )
              else if (image.broken)
                _brokenThumb(context, boundedSide)
              else if (_loading.contains(image.hostPath))
                ImageLoadingPlaceholder(
                  label: AppLocalizations.of(context).imageLoading,
                  side: boundedSide,
                )
              else if (_loaded.containsKey(image.hostPath))
                _brokenThumb(
                  context,
                  boundedSide,
                  name: image.hostName,
                  retry: () {
                    setState(() {
                      _loaded.remove(image.hostPath);
                      _fetchHostImages();
                    });
                  },
                )
              else
                _hostChip(context, image),
          ],
        );
      },
    );
  }

  Widget _brokenThumb(
    BuildContext context,
    double side, {
    VoidCallback? retry,
    String? name,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final retryLabel = AppLocalizations.of(context).retry;
    return Tooltip(
      message: [
        AppLocalizations.of(context).imageLoadFailed,
        ?name,
        if (retry != null) retryLabel,
      ].join('\n'),
      child: Container(
        width: side,
        height: side,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: InkWell(
          onTap: retry,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(AppIcons.broken_image_outlined, color: scheme.outline),
                if (name != null)
                  Flexible(
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                if (retry != null)
                  Flexible(
                    child: Text(
                      retryLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: scheme.primary),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _hostChip(BuildContext context, ResolvedImage image) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: AppLocalizations.of(context).imageOnHost(image.hostPath ?? ''),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              AppIcons.image_outlined,
              size: 16,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 180),
              child: Text(
                image.hostName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Stable image-sized loading feedback, also used while Codex is generating.
class ImageLoadingPlaceholder extends StatelessWidget {
  const ImageLoadingPlaceholder({
    super.key,
    required this.label,
    this.side = 180,
  });
  final String label;
  final double side;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final compact = side < 140;
    return Semantics(
      label: label,
      liveRegion: true,
      child: Container(
        width: side,
        height: side,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(kAttachmentTileRadius),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (!compact)
              Icon(AppIcons.image_outlined, size: 32, color: scheme.primary),
            SizedBox(height: compact ? 6 : 16),
            if (!MediaQuery.disableAnimationsOf(context))
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            SizedBox(height: compact ? 6 : 12),
            Flexible(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Text(
                  label,
                  maxLines: compact ? 2 : 3,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Chips for a message's document attachments — host paths parsed back from
/// the text's attached-files block (see `attachment_refs.dart`). Their bytes
/// never crossed the wire; the chip names the file, the tooltip shows the
/// full HOST path the agent was given.
class FileRefChips extends StatelessWidget {
  /// Creates chips for the parsed host [paths].
  const FileRefChips({super.key, required this.paths});

  /// Absolute host paths, in message order.
  final List<String> paths;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final path in paths)
          Tooltip(
            message: path,
            child: InkWell(
              onTap: () => openUrl(context, path),
              borderRadius: BorderRadius.circular(10),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: scheme.outlineVariant),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      AppIcons.description_outlined,
                      size: 16,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 6),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 200),
                      child: Text(
                        hostPathBasename(path),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// One tappable thumbnail. Stateful so a desktop hover can reveal a quick
/// save button without a viewer round-trip.
class _ImageThumb extends StatefulWidget {
  const _ImageThumb({
    required this.images,
    required this.index,
    required this.side,
  });

  final List<Uint8List> images;
  final int index;
  final double side;

  @override
  State<_ImageThumb> createState() => _ImageThumbState();
}

class _ImageThumbState extends State<_ImageThumb> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final scale = MediaQuery.of(context).devicePixelRatio;
    final bytes = widget.images[widget.index];
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      // Sized to the tile so the overlaid button positions against the picture's
      // own edges. Left to the Stack's default sizing it anchored to whatever
      // the largest child measured, which put the disc half outside the frame.
      child: SizedBox(
        width: widget.side,
        height: widget.side,
        child: Stack(
          fit: StackFit.expand,
          children: [
            AttachmentTile(
              side: widget.side,
              onTap: () =>
                  ImageViewerPage.show(context, widget.images, widget.index),
              child: Image.memory(
                bytes,
                key: Key('msg-image-${widget.index}'),
                width: widget.side,
                height: widget.side,
                fit: BoxFit.cover,
                // Decode near thumbnail resolution — full-res frames for every
                // thumb would hold megabytes of pixels per message. 2× the box so
                // a landscape image's SHORT edge still reaches the square cover
                // box (cacheWidth alone would decode it too short and blurry).
                cacheWidth: (widget.side * scale * 2).round(),
                gaplessPlayback: true,
                errorBuilder: (context, _, _) => Icon(
                  AppIcons.broken_image_outlined,
                  color: Theme.of(context).colorScheme.outline,
                ),
              ),
            ),
            if (canSaveImages && _hovering)
              Positioned(
                top: 4,
                right: 4,
                child: _SaveChip(
                  onPressed: () => saveImageBytes(
                    context,
                    bytes,
                    suggestedName:
                        'image-${widget.index + 1}.${sniffImageExtension(bytes)}',
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A small circular save button overlaid on a hovered thumbnail.
class _SaveChip extends StatelessWidget {
  const _SaveChip({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black54,
      shape: const CircleBorder(),
      child: InkWell(
        mouseCursor: clickable,
        customBorder: const CircleBorder(),
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Tooltip(
            message: AppLocalizations.of(context).imageSave,
            child: const Icon(
              AppIcons.download_outlined,
              size: 18,
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}
