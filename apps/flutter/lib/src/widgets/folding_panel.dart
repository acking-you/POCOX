import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:pocox/src/motion.dart';

/// Content that folds into a slim [folded] form and unfolds back to [child].
///
/// The height morphs while the two cross-fade: the outgoing form fades in
/// the first half and the incoming one in the second, so the pane never
/// shows both at full strength. Whatever wraps this (a glass card) resizes
/// with it, keeping one surface throughout. At rest the panel is exactly as
/// tall as the form it shows, so the content's own size changes (a wrapped
/// line, a chip row) stay immediate.
///
/// [child] stays mounted while folded: its state, controllers and focus
/// survive, and focus moving into it is how an owner learns to unfold. It
/// takes no pointer, semantics or tickers then, and is not painted.
class FoldingPanel extends StatefulWidget {
  /// Creates the panel, folded when [isFolded].
  const FoldingPanel({
    super.key,
    required this.isFolded,
    required this.folded,
    required this.child,
  });

  /// Whether the slim form is shown.
  final bool isFolded;

  /// The slim form.
  final Widget folded;

  /// The full form.
  final Widget child;

  @override
  State<FoldingPanel> createState() => _FoldingPanelState();
}

class _FoldingPanelState extends State<FoldingPanel>
    with SingleTickerProviderStateMixin {
  /// 0 unfolded, 1 folded.
  late final AnimationController _fold = AnimationController(
    vsync: this,
    value: widget.isFolded ? 1 : 0,
  )..addStatusListener(_settled);

  /// The height: a quick start that settles, in both directions.
  late final CurvedAnimation _height = CurvedAnimation(
    parent: _fold,
    curve: Motion.emphasized,
    reverseCurve: Motion.emphasized.flipped,
  );
  late final Animation<double> _childOpacity = _fold
      .drive(CurveTween(curve: const Interval(0, 0.5, curve: Curves.easeOut)))
      .drive(Tween(begin: 1, end: 0));
  late final Animation<double> _foldedOpacity = _fold.drive(
    CurveTween(curve: const Interval(0.45, 1, curve: Curves.easeIn)),
  );

  /// Drops the slim form once fully unfolded.
  void _settled(AnimationStatus status) {
    if (status == AnimationStatus.dismissed && mounted) setState(() {});
  }

  @override
  void didUpdateWidget(FoldingPanel old) {
    super.didUpdateWidget(old);
    if (old.isFolded == widget.isFolded) return;
    final duration = Motion.of(context, Motion.medium);
    if (duration == Duration.zero) {
      _fold.value = widget.isFolded ? 1 : 0;
      return;
    }
    // forward/reverse rather than animateTo: unfolding must end dismissed.
    _fold.duration = duration;
    widget.isFolded ? _fold.forward() : _fold.reverse();
  }

  @override
  void dispose() {
    _height.dispose();
    _fold.dispose();
    super.dispose();
  }

  /// One form: shown, or on its way out (or gone) and inert.
  Widget _form(bool shown, Animation<double> opacity, Widget child) =>
      IgnorePointer(
        ignoring: !shown,
        child: ExcludeSemantics(
          excluding: !shown,
          child: TickerMode(
            enabled: shown,
            child: FadeTransition(opacity: opacity, child: child),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final folded = widget.isFolded;
    return _FoldLayout(
      fold: _height,
      children: [
        _form(!folded, _childOpacity, widget.child),
        if (folded || !_fold.isDismissed)
          _form(folded, _foldedOpacity, widget.folded),
      ],
    );
  }
}

/// Lays out the full form (first) and, while there is one, the slim form
/// (second) at the full width, both resting on the bottom edge, and is as
/// tall as [fold] says between their heights.
class _FoldLayout extends MultiChildRenderObjectWidget {
  const _FoldLayout({required this.fold, super.children});

  final Animation<double> fold;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderFold(fold);

  @override
  void updateRenderObject(BuildContext context, _RenderFold renderObject) =>
      renderObject.fold = fold;
}

class _FoldParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderFold extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _FoldParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _FoldParentData> {
  _RenderFold(this._fold);

  Animation<double> _fold;
  set fold(Animation<double> value) {
    if (identical(value, _fold)) return;
    if (attached) _fold.removeListener(markNeedsLayout);
    _fold = value;
    if (attached) _fold.addListener(markNeedsLayout);
    markNeedsLayout();
  }

  final _clip = LayerHandle<ClipRectLayer>();

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _FoldParentData) {
      child.parentData = _FoldParentData();
    }
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _fold.addListener(markNeedsLayout);
  }

  @override
  void detach() {
    _fold.removeListener(markNeedsLayout);
    super.detach();
  }

  @override
  void dispose() {
    _clip.layer = null;
    super.dispose();
  }

  /// Mid-fold the outgoing form overflows the morphing height.
  bool get _morphing => _fold.value > 0 && _fold.value < 1;

  @override
  void performLayout() {
    final inner = BoxConstraints(
      minWidth: constraints.maxWidth,
      maxWidth: constraints.maxWidth,
      maxHeight: constraints.maxHeight,
    );
    final full = firstChild!..layout(inner, parentUsesSize: true);
    final slim = childAfter(full)?..layout(inner, parentUsesSize: true);
    final height = slim == null
        ? full.size.height
        : lerpDouble(full.size.height, slim.size.height, _fold.value)!;
    size = constraints.constrain(Size(constraints.maxWidth, height));
    for (var child = firstChild; child != null; child = childAfter(child)) {
      (child.parentData! as _FoldParentData).offset = Offset(
        0,
        size.height - child.size.height,
      );
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (!_morphing) {
      _clip.layer = null;
      defaultPaint(context, offset);
      return;
    }
    _clip.layer = context.pushClipRect(
      needsCompositing,
      offset,
      Offset.zero & size,
      defaultPaint,
      oldLayer: _clip.layer,
    );
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}
