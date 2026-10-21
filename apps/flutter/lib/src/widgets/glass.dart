import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:pocox/src/desktop_theme.dart';
import 'package:pocox/src/motion.dart';
import 'package:pocox/src/text_measure.dart';
import 'package:pocox/src/theme.dart';

/// The app's layered material, back to front:
///
/// 1. [AppBackdrop] — the window's ground, a neutral with soft pools of
///    ambient colour;
/// 2. the sidebar, drawn straight on the backdrop;
/// 3. [ContentSheet] — the opaque, rounded page the content lives on;
/// 4. [Glass] — translucent controls and panels floating above the sheet,
///    blurring what moves beneath them, lit along a rim.
///
/// Every surface states its layer rather than picking a grey, which is what
/// gives the app depth without outlines.

/// A translucent surface: a blurred view of what is behind it, a tinted body,
/// a sheen across its top and a rim catching the light from the top-left. Its
/// shadow is cast only outside it, so the glass stays clear.
class Glass extends StatelessWidget {
  /// Wraps [child] in glass of [depth].
  const Glass({
    super.key,
    required this.child,
    this.depth = GlassDepth.floating,
    this.borderRadius = const BorderRadius.all(Radius.circular(20)),
    this.padding = EdgeInsets.zero,
    this.lift = 1,
    this.tint,
    this.edge,
  });

  /// The content.
  final Widget child;

  /// Which recipe the surface follows.
  final GlassDepth depth;

  /// The surface's corners; a large radius makes a capsule.
  final BorderRadius borderRadius;

  /// Space between the rim and [child].
  final EdgeInsetsGeometry padding;

  /// Scales the cast shadow: more for a focused or raised state.
  final double lift;

  /// Replaces the recipe's body colour.
  final Color? tint;

  /// Replaces the outer hairline, e.g. with a status colour.
  final Color? edge;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final recipe = glassRecipe(scheme, depth, lift: lift);
    final sigma = recipe.blur;
    Widget body = CustomPaint(
      painter: _GlassBodyPainter(
        borderRadius: borderRadius,
        fill: tint ?? recipe.fill,
        sheen: recipe.sheen,
      ),
      foregroundPainter: _GlassRimPainter(
        borderRadius: borderRadius,
        light: recipe.rimLight,
        shade: recipe.rimShade,
        hairline: edge ?? recipe.hairline,
      ),
      child: Material(
        type: MaterialType.transparency,
        child: Padding(padding: padding, child: child),
      ),
    );
    if (sigma > 0) {
      body = BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        child: body,
      );
    }
    body = ClipRRect(borderRadius: borderRadius, child: body);
    if (recipe.shadows.isEmpty) return body;
    return CustomPaint(
      painter: OuterShadowPainter(
        borderRadius: borderRadius,
        shadows: recipe.shadows,
      ),
      child: body,
    );
  }
}

RRect _rrect(BorderRadius radius, Rect rect) =>
    radius.toRRect(rect).scaleRadii();

class _GlassBodyPainter extends CustomPainter {
  const _GlassBodyPainter({
    required this.borderRadius,
    required this.fill,
    required this.sheen,
  });

  final BorderRadius borderRadius;
  final Color fill;
  final Color sheen;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = _rrect(borderRadius, rect);
    canvas.drawRRect(rrect, Paint()..color = fill);
    // The sheen fades out by the middle, so tall panels keep a clear body
    // and short capsules read as lit from above.
    final reach = size.height < 72 ? 1.0 : 72 / size.height;
    canvas.drawRRect(
      rrect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [sheen, sheen.withValues(alpha: 0)],
          stops: [0, 0.55 * reach.clamp(0.0, 1.0)],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_GlassBodyPainter old) =>
      old.borderRadius != borderRadius ||
      old.fill != fill ||
      old.sheen != sheen;
}

class _GlassRimPainter extends CustomPainter {
  const _GlassRimPainter({
    required this.borderRadius,
    required this.light,
    required this.shade,
    required this.hairline,
  });

  final BorderRadius borderRadius;
  final Color light;
  final Color shade;
  final Color hairline;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    if (rect.isEmpty) return;
    // The hairline is the outermost pixel; the lit rim sits just inside it,
    // brightest at the top-left and catching again at the bottom-right, the
    // way a rounded pane of glass refracts a light from above.
    canvas.drawRRect(
      _rrect(borderRadius, rect.deflate(0.5)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = hairline,
    );
    canvas.drawRRect(
      _rrect(borderRadius, rect.deflate(1.5)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            light,
            shade,
            shade,
            light.withValues(alpha: light.a * 0.5),
          ],
          stops: const [0, 0.38, 0.7, 1],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_GlassRimPainter old) =>
      old.borderRadius != borderRadius ||
      old.light != light ||
      old.shade != shade ||
      old.hairline != hairline;
}

/// Paints [shadows] for a rounded box of [borderRadius] only outside the box,
/// so a translucent surface over it is not greyed by its own shadow.
class OuterShadowPainter extends CustomPainter {
  /// Creates the painter.
  const OuterShadowPainter({required this.borderRadius, required this.shadows});

  /// The box's corners.
  final BorderRadius borderRadius;

  /// The shadows to cast.
  final List<BoxShadow> shadows;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    if (rect.isEmpty) return;
    final rrect = _rrect(borderRadius, rect);
    var reach = 0.0;
    for (final s in shadows) {
      final r = s.blurRadius * 2 + s.spreadRadius + s.offset.distance;
      if (r > reach) reach = r;
    }
    canvas.save();
    canvas.clipPath(
      Path.combine(
        PathOperation.difference,
        Path()..addRect(rect.inflate(reach + 4)),
        Path()..addRRect(rrect),
      ),
    );
    for (final s in shadows) {
      canvas.drawRRect(
        rrect.shift(s.offset).inflate(s.spreadRadius),
        Paint()
          ..color = s.color
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, s.blurSigma),
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(OuterShadowPainter old) =>
      old.borderRadius != borderRadius || old.shadows != shadows;
}

/// The window's ground: [backdropBase] with the [backdropGlows] washed over
/// it. Painted once into its own layer; the sidebar and the gaps around the
/// sheet show it, and glass over it picks up its colour.
class AppBackdrop extends StatelessWidget {
  /// Paints the backdrop behind [child].
  const AppBackdrop({super.key, required this.child});

  /// What sits on the backdrop.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Stack(
      fit: StackFit.expand,
      children: [
        RepaintBoundary(
          child: CustomPaint(
            painter: _BackdropPainter(
              base: backdropBase(scheme),
              glows: backdropGlows(scheme),
            ),
          ),
        ),
        child,
      ],
    );
  }
}

class _BackdropPainter extends CustomPainter {
  const _BackdropPainter({required this.base, required this.glows});

  final Color base;
  final List<({Alignment center, double radius, Color color})> glows;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..color = base);
    for (final glow in glows) {
      canvas.drawRect(
        rect,
        Paint()
          ..shader = RadialGradient(
            center: glow.center,
            radius: glow.radius,
            colors: [glow.color, glow.color.withValues(alpha: 0)],
          ).createShader(rect),
      );
    }
  }

  @override
  bool shouldRepaint(_BackdropPainter old) =>
      old.base != base || old.glows != glows;
}

/// The opaque, rounded page that content lives on, lifted off the
/// [AppBackdrop] by a soft shadow. [grouped] selects the grey ground that
/// white cards sit on.
class ContentSheet extends StatelessWidget {
  /// Lays [child] on a sheet.
  const ContentSheet({super.key, required this.child, this.grouped = false});

  /// The page content.
  final Widget child;

  /// A page of cards rather than of reading.
  final bool grouped;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const radius = BorderRadius.all(Radius.circular(kSheetRadius));
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: sheetShadows(scheme),
      ),
      child: Material(
        color: sheetColor(scheme, grouped: grouped),
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(color: sheetEdge(scheme)),
        ),
        child: child,
      ),
    );
  }
}

/// Gives [child] a soft press: it sinks a little under the pointer and
/// springs back when released, the way a glass control yields to a finger.
/// Purely visual — taps, focus and semantics stay with [child].
class PressScale extends StatefulWidget {
  /// Wraps [child].
  const PressScale({
    super.key,
    required this.child,
    this.scale = 0.95,
    this.enabled = true,
  });

  /// The control.
  final Widget child;

  /// The size while pressed, as a fraction.
  final double scale;

  /// Whether pressing animates at all.
  final bool enabled;

  @override
  State<PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<PressScale> {
  bool _down = false;

  void _set(bool down) {
    if (_down != down && mounted) setState(() => _down = down);
  }

  @override
  Widget build(BuildContext context) {
    final animate =
        widget.enabled && Motion.of(context, Motion.fast) > Duration.zero;
    if (!animate) return widget.child;
    return Listener(
      onPointerDown: (_) => _set(true),
      onPointerUp: (_) => _set(false),
      onPointerCancel: (_) => _set(false),
      child: AnimatedScale(
        scale: _down ? widget.scale : 1,
        duration: _down
            ? const Duration(milliseconds: 90)
            : const Duration(milliseconds: 420),
        curve: _down ? Curves.easeOut : Motion.spring,
        child: widget.child,
      ),
    );
  }
}

/// Plays [child] in once when it first mounts: it fades up from a few pixels
/// below, so a page's content settles onto its sheet instead of appearing.
class EntranceMotion extends StatefulWidget {
  /// Animates [child]'s arrival.
  const EntranceMotion({
    super.key,
    required this.child,
    this.offset = 10,
    this.delay = Duration.zero,
  });

  /// The content.
  final Widget child;

  /// How far below its place it starts, in logical pixels.
  final double offset;

  /// A wait before it starts, for a staggered group.
  final Duration delay;

  @override
  State<EntranceMotion> createState() => _EntranceMotionState();
}

class _EntranceMotionState extends State<EntranceMotion>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  );
  late final Animation<double> _t = CurvedAnimation(
    parent: _controller,
    curve: Motion.emphasized,
  );
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (Motion.of(context, Motion.medium) == Duration.zero) {
      _controller.value = 1;
    } else if (widget.delay == Duration.zero) {
      _controller.forward();
    } else {
      Future.delayed(widget.delay, () {
        if (mounted) _controller.forward();
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _t,
    child: widget.child,
    builder: (context, child) => Opacity(
      opacity: _t.value.clamp(0.0, 1.0),
      child: Transform.translate(
        offset: Offset(0, (1 - _t.value) * widget.offset),
        child: child,
      ),
    ),
  );
}

/// The lit face the button themes lay over a button's own fill: a sheen down
/// from the top and a highlight along the upper rim, so a filled capsule
/// reads as a raised, glossy piece rather than a flat shape. [glass] is the
/// translucent secondary style, whose rim is the brighter part. Disabled
/// buttons stay flat.
class LitFace extends StatelessWidget {
  /// Lights [child]'s button in [states].
  const LitFace({
    super.key,
    required this.states,
    required this.child,
    this.glass = false,
  });

  /// The button's current states.
  final Set<WidgetState> states;

  /// The button content.
  final Widget? child;

  /// The translucent secondary style rather than a filled one.
  final bool glass;

  @override
  Widget build(BuildContext context) {
    if (states.contains(WidgetState.disabled)) {
      return child ?? const SizedBox.shrink();
    }
    final light = Theme.of(context).brightness == Brightness.light;
    final pressed = states.contains(WidgetState.pressed);
    final double sheen;
    final double rim;
    if (glass) {
      sheen = light ? 0.55 : 0.06;
      rim = light ? 0.95 : 0.16;
    } else {
      sheen = light ? 0.16 : 0.42;
      rim = light ? 0.22 : 0.6;
    }
    return CustomPaint(
      painter: _LitFacePainter(sheen: pressed ? sheen * 0.4 : sheen, rim: rim),
      child: child,
    );
  }
}

class _LitFacePainter extends CustomPainter {
  const _LitFacePainter({required this.sheen, required this.rim});

  final double sheen;
  final double rim;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    if (rect.isEmpty) return;
    // Every lit button is a capsule, and its Material does not clip (buttons
    // default to `Clip.none`): the sheen is clipped to the capsule here, or
    // its square corners show past the curve on a dark page.
    final radius = Radius.circular(size.shortestSide / 2);
    canvas
      ..save()
      ..clipRRect(RRect.fromRectAndRadius(rect, radius))
      ..drawRect(
        rect,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.white.withValues(alpha: sheen),
              Colors.white.withValues(alpha: 0),
            ],
            stops: const [0, 0.6],
          ).createShader(rect),
      )
      ..restore();
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect.deflate(0.5), radius),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.white.withValues(alpha: rim),
            Colors.white.withValues(alpha: 0),
          ],
          stops: const [0, 0.5],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_LitFacePainter old) =>
      old.sheen != sheen || old.rim != rim;
}

/// The border of the app's filled fields. At rest it draws nothing (the fill
/// is the field); focused or in error it draws a ring, with an optional soft
/// [glow] so focus reads as the field lighting up rather than as a heavier
/// outline.
///
/// It is not an outline border, so a floating label sits inside the fill,
/// above the text, instead of straddling the field's top edge.
class FieldBorder extends InputBorder {
  /// Creates the border.
  const FieldBorder({
    super.borderSide = BorderSide.none,
    this.borderRadius = const BorderRadius.all(Radius.circular(4)),
    this.glow,
  });

  /// The corners of the fill and of the ring.
  final BorderRadius borderRadius;

  /// The halo around the ring, if any.
  final Color? glow;

  @override
  bool get isOutline => false;

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.all(borderSide.width);

  @override
  FieldBorder copyWith({
    BorderSide? borderSide,
    BorderRadius? borderRadius,
    Color? glow,
  }) => FieldBorder(
    borderSide: borderSide ?? this.borderSide,
    borderRadius: borderRadius ?? this.borderRadius,
    glow: glow ?? this.glow,
  );

  @override
  FieldBorder scale(double t) => FieldBorder(
    borderSide: borderSide.scale(t),
    borderRadius: borderRadius * t,
    glow: glow,
  );

  RRect _shape(Rect rect) => borderRadius.toRRect(rect);

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      Path()..addRRect(_shape(rect).deflate(borderSide.width));

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) =>
      Path()..addRRect(_shape(rect));

  @override
  bool get preferPaintInterior => true;

  @override
  void paintInterior(
    Canvas canvas,
    Rect rect,
    Paint paint, {
    TextDirection? textDirection,
  }) => canvas.drawRRect(_shape(rect), paint);

  static FieldBorder _lerp(FieldBorder a, FieldBorder b, double t) =>
      FieldBorder(
        borderSide: BorderSide.lerp(a.borderSide, b.borderSide, t),
        borderRadius: BorderRadius.lerp(a.borderRadius, b.borderRadius, t)!,
        glow: Color.lerp(a.glow, b.glow, t),
      );

  @override
  ShapeBorder? lerpFrom(ShapeBorder? a, double t) =>
      a is FieldBorder ? _lerp(a, this, t) : super.lerpFrom(a, t);

  @override
  ShapeBorder? lerpTo(ShapeBorder? b, double t) =>
      b is FieldBorder ? _lerp(this, b, t) : super.lerpTo(b, t);

  @override
  void paint(
    Canvas canvas,
    Rect rect, {
    double? gapStart,
    double gapExtent = 0.0,
    double gapPercentage = 0.0,
    TextDirection? textDirection,
  }) {
    final shape = _shape(rect);
    if (glow case final glow? when glow.a > 0) {
      canvas.drawRRect(
        shape.inflate(2.5),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4
          ..color = glow,
      );
    }
    if (borderSide.style == BorderStyle.none || borderSide.width == 0) return;
    canvas.drawRRect(shape.deflate(borderSide.width / 2), borderSide.toPaint());
  }

  @override
  bool operator ==(Object other) =>
      other is FieldBorder &&
      other.borderSide == borderSide &&
      other.borderRadius == borderRadius &&
      other.glow == glow;

  @override
  int get hashCode => Object.hash(borderSide, borderRadius, glow);
}

/// One choice of a [GlassSegmented].
@immutable
class GlassSegment<T> {
  /// Creates a segment.
  const GlassSegment({
    required this.value,
    required this.label,
    this.icon,
    this.key,
  });

  /// What choosing it selects.
  final T value;

  /// Its label.
  final String label;

  /// An optional glyph before the label.
  final IconData? icon;

  /// The key of its tappable area.
  final Key? key;
}

/// A segmented control in the app's material: a recessed track with a pane
/// of glass that glides, with a little spring, to the chosen segment.
/// [expand] shares the full width; otherwise every segment takes the widest
/// label's width.
class GlassSegmented<T> extends StatelessWidget {
  /// Creates the control.
  const GlassSegmented({
    super.key,
    required this.segments,
    required this.selected,
    required this.onChanged,
    this.expand = true,
    this.height = 34,
  });

  /// The choices, in order.
  final List<GlassSegment<T>> segments;

  /// The chosen value.
  final T selected;

  /// Called with a newly chosen value.
  final ValueChanged<T> onChanged;

  /// Whether the control fills its width.
  final bool expand;

  /// The control's height.
  final double height;

  static const double _inset = 3;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final light = scheme.brightness == Brightness.light;
    const labelStyle = TextStyle(fontSize: 13, fontWeight: FontWeight.w500);
    final index = segments.indexWhere((s) => s.value == selected);
    final scaled = MediaQuery.textScalerOf(context).scale(height);
    double natural(GlassSegment<T> s) =>
        measureTextLine(context, s.label, labelStyle).width.ceilToDouble() +
        (s.icon == null ? 0 : 22) +
        28;
    return LayoutBuilder(
      builder: (context, box) {
        final width = expand && box.maxWidth.isFinite
            ? (box.maxWidth - 2 * _inset) / segments.length
            : segments.map(natural).fold(0.0, (a, b) => a > b ? a : b);
        final radius = BorderRadius.circular(scaled / 2);
        return Container(
          height: scaled,
          width: width * segments.length + 2 * _inset,
          padding: const EdgeInsets.all(_inset),
          decoration: BoxDecoration(
            color: light
                ? Colors.black.withValues(alpha: 0.055)
                : Colors.white.withValues(alpha: 0.06),
            borderRadius: radius,
          ),
          child: Stack(
            children: [
              if (index >= 0)
                AnimatedPositioned(
                  duration: Motion.of(
                    context,
                    const Duration(milliseconds: 480),
                  ),
                  curve: Motion.spring,
                  left: index * width,
                  top: 0,
                  bottom: 0,
                  width: width,
                  child: IgnorePointer(
                    child: Glass(
                      depth: GlassDepth.chrome,
                      borderRadius: radius,
                      tint: light
                          ? Colors.white.withValues(alpha: 0.95)
                          : Colors.white.withValues(alpha: 0.13),
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),
              Row(
                children: [
                  for (final segment in segments)
                    SizedBox(
                      width: width,
                      child: _segment(context, segment, labelStyle, radius),
                    ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _segment(
    BuildContext context,
    GlassSegment<T> segment,
    TextStyle style,
    BorderRadius radius,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final chosen = segment.value == selected;
    final ink = chosen ? scheme.onSurface : scheme.onSurfaceVariant;
    return Semantics(
      selected: chosen,
      button: true,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          key: segment.key,
          mouseCursor: clickable,
          borderRadius: radius,
          onTap: chosen ? null : () => onChanged(segment.value),
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (segment.icon != null) ...[
                  Icon(segment.icon, size: 16, color: ink),
                  const SizedBox(width: 6),
                ],
                Flexible(
                  child: Text(
                    segment.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: style.copyWith(
                      color: ink,
                      fontWeight: chosen ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
