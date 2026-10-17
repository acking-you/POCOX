import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:pocket_codex/src/app_icons.dart';
import 'package:pocket_codex/src/desktop_theme.dart';
import 'package:pocket_codex/src/fonts.dart';
import 'package:pocket_codex/src/glass_recipe.dart';
import 'package:pocket_codex/src/motion.dart';
import 'package:pocket_codex/src/widgets/glass.dart';

/// Turn navigation that keeps out of the reader's way: at rest a slim, faint
/// handle at the conversation's edge; touched, it opens into its [controls];
/// it folds back once the reader scrolls on or leaves it alone a while.
class TurnNavigationHandle extends StatefulWidget {
  /// Creates the handle over [controls].
  const TurnNavigationHandle({
    super.key,
    required this.controls,
    required this.label,
    this.scroll,
  });

  /// The navigation buttons it opens into, top to bottom.
  final List<Widget> controls;

  /// What the handle offers, for its tooltip and screen readers.
  final String label;

  /// The conversation's scroll: a scroll the reader makes folds it.
  final ScrollController? scroll;

  /// How long it stays open untouched.
  static const idle = Duration(seconds: 5);

  @override
  State<TurnNavigationHandle> createState() => _TurnNavigationHandleState();
}

class _TurnNavigationHandleState extends State<TurnNavigationHandle> {
  bool _open = false;
  Timer? _idle;

  @override
  void initState() {
    super.initState();
    widget.scroll?.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(TurnNavigationHandle old) {
    super.didUpdateWidget(old);
    if (!identical(old.scroll, widget.scroll)) {
      old.scroll?.removeListener(_onScroll);
      widget.scroll?.addListener(_onScroll);
    }
  }

  @override
  void dispose() {
    _idle?.cancel();
    widget.scroll?.removeListener(_onScroll);
    super.dispose();
  }

  void _onScroll() {
    final scroll = widget.scroll;
    if (!_open || scroll == null || !scroll.hasClients) return;
    // A jump the controls make is not the reader scrolling on.
    if (scroll.position.userScrollDirection != ScrollDirection.idle) _close();
  }

  void _touched() {
    _idle?.cancel();
    _idle = Timer(TurnNavigationHandle.idle, _close);
  }

  void _close() {
    _idle?.cancel();
    if (mounted && _open) setState(() => _open = false);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final touch = !isDesktop;
    final duration = Motion.of(context, Motion.medium);
    final body = _open
        ? Column(
            key: const ValueKey('turn-navigation-open'),
            mainAxisSize: MainAxisSize.min,
            children: widget.controls,
          )
        : Semantics(
            button: true,
            label: widget.label,
            child: Tooltip(
              message: widget.label,
              child: InkWell(
                key: const Key('turn-navigation-handle'),
                mouseCursor: clickable,
                borderRadius: BorderRadius.circular(16),
                onTap: () {
                  setState(() => _open = true);
                  _touched();
                },
                child: SizedBox(
                  width: touch ? 30 : 26,
                  height: touch ? 48 : 40,
                  child: Icon(
                    AppIcons.unfold_more,
                    size: 16,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          );
    return Listener(
      onPointerDown: (_) {
        if (_open) _touched();
      },
      // Faint while folded: a mark of where the controls are, not a control
      // over the text.
      child: AnimatedOpacity(
        opacity: _open ? 1 : 0.6,
        duration: duration,
        child: Glass(
          depth: GlassDepth.floating,
          borderRadius: BorderRadius.circular(_open ? 24 : 16),
          lift: _open ? 0.6 : 0.3,
          child: Motion.resize(
            context,
            duration: Motion.medium,
            curve: Motion.spring,
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: _open
                  ? const EdgeInsets.symmetric(vertical: 4, horizontal: 2)
                  : EdgeInsets.zero,
              child: body,
            ),
          ),
        ),
      ),
    );
  }
}
