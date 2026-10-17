import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/desktop_theme.dart';
import 'package:pocket_codex/src/fonts.dart';
import 'package:pocket_codex/src/motion.dart';
import 'package:pocket_codex/src/app_icons.dart';

/// Parent/child affordances shared by live and on-disk session inventories.
///
/// The fold control sits inside the row's own plate, in the inset the row
/// keeps before its title ([leadingInset]), widened only where that is too
/// narrow for the control; [builder] lays the row out with that inset, so a
/// selected or hovered plate covers the control instead of stopping beside
/// it. A child indents to its parent's fold control, and a hairline rail
/// there joins the family. Rows outside any hierarchy are built unchanged.
class SessionTreeRow extends StatelessWidget {
  /// Creates the hierarchy affordances around [child].
  const SessionTreeRow({
    super.key,
    required this.id,
    required this.depth,
    required this.childCount,
    required this.expanded,
    required this.onToggle,
    required this.builder,
    this.childSession = false,
    this.guardian = false,
    this.leadingInset = 0,
    this.plateInset = 0,
  });

  /// The session id, used in the row and toggle keys.
  final String id;

  /// Nesting depth; 0 for a root.
  final int depth;

  /// Direct children, folded or not.
  final int childCount;

  /// Whether the children are shown.
  final bool expanded;

  /// Shows or hides the children.
  final VoidCallback onToggle;

  /// Builds the session row with the given inset before its title, measured
  /// inside its plate.
  final Widget Function(double titleInset) builder;

  /// Whether this session was spawned by another.
  final bool childSession;

  /// Whether this session is a model approval review.
  final bool guardian;

  /// Space the row normally leaves before its title, inside its plate.
  final double leadingInset;

  /// Space between the row's edge and its plate.
  final double plateInset;

  /// The fold control's box; touch keeps a finger-sized target.
  static double _box() => isDesktop ? 22 : 44;

  @override
  Widget build(BuildContext context) {
    if (childCount == 0 && !childSession && !guardian) {
      return builder(leadingInset);
    }
    final box = _box();
    final inset = math.max(leadingInset, box + 4);
    // One level puts a child's edge under its parent's fold control.
    final step = plateInset + inset / 2;
    final rail = Theme.of(context).colorScheme.outlineVariant;
    final caption = guardian || childSession
        ? Padding(
            padding: EdgeInsetsDirectional.only(
              start: plateInset + inset,
              top: 4,
            ),
            child: Text(
              guardian
                  ? AppLocalizations.of(context).guardianSession
                  : AppLocalizations.of(context).childSession,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          )
        : null;
    return Padding(
      key: ValueKey('session-tree-$id'),
      padding: EdgeInsetsDirectional.only(start: math.min(depth, 4) * step),
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          // Beneath the row, so a selected child's plate covers it.
          if (depth > 0)
            PositionedDirectional(
              start: 0,
              top: 0,
              bottom: 0,
              width: 1,
              child: ColoredBox(color: rail),
            ),
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ?caption,
              Stack(
                fit: StackFit.passthrough,
                children: [
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: childCount > 0 ? box : 0,
                    ),
                    child: builder(inset),
                  ),
                  // Above the plate, inside its leading inset.
                  if (childCount > 0)
                    PositionedDirectional(
                      start: plateInset + (inset - box) / 2,
                      top: 0,
                      bottom: 0,
                      child: Center(child: _foldToggle(context, box)),
                    ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _foldToggle(BuildContext context, double box) {
    final scheme = Theme.of(context).colorScheme;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    return IconButton(
      key: ValueKey('session-children-$id'),
      tooltip: AppLocalizations.of(context).childSessions(childCount),
      isSelected: expanded,
      onPressed: onToggle,
      padding: EdgeInsets.zero,
      style: IconButton.styleFrom(
        fixedSize: Size.square(box),
        minimumSize: Size.square(box),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(kRowRadius),
        ),
      ),
      // The project heading's glyph, turning the same way, so every fold in
      // the sidebar speaks one language. The mirrored glyph turns the other
      // way in RTL to land pointing down.
      icon: Semantics(
        expanded: expanded,
        child: AnimatedRotation(
          turns: expanded ? (rtl ? -0.25 : 0.25) : 0,
          duration: Motion.of(context, Motion.fast),
          curve: Motion.move,
          child: Transform.flip(
            flipX: rtl,
            child: Icon(
              AppIcons.keyboard_arrow_right,
              size: isDesktop ? 16 : 20,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}
