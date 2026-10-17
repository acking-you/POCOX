import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Reports [child]'s laid-out height to [onHeight] after each frame in which
/// it changed — for content that floats over a scroll view and must reserve
/// that much room at its end.
class HeightReporter extends SingleChildRenderObjectWidget {
  /// Measures [child].
  const HeightReporter({super.key, required this.onHeight, super.child});

  /// Called after layout with the new height.
  final ValueChanged<double> onHeight;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderHeightReporter(onHeight);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) =>
      (renderObject as _RenderHeightReporter).onHeight = onHeight;
}

class _RenderHeightReporter extends RenderProxyBox {
  _RenderHeightReporter(this.onHeight);

  ValueChanged<double> onHeight;
  double? _reported;

  @override
  void performLayout() {
    super.performLayout();
    final height = size.height;
    if (height == _reported) return;
    _reported = height;
    // Not during layout: the listener rebuilds what it reserves.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (attached) onHeight(height);
    });
  }
}
