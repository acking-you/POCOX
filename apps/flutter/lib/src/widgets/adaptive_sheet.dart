import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pocox/src/desktop_theme.dart';
import 'package:pocox/src/theme.dart';
import 'package:pocox/src/widgets/app_dialog.dart';
import 'package:pocox/src/widgets/popover.dart';
import 'package:pocox/src/app_icons.dart';

/// Width at or above which a transient panel is shown as a centred dialog
/// rather than a bottom sheet. Matches the transcript's document-layout
/// breakpoint so the whole window changes idiom at once.
const double kDesktopPanelWidth = 720;

/// Show [builder] as the right kind of transient panel for the window.
///
/// A bottom sheet is a thumb idiom: it rises from the edge the hand is near.
/// On a desktop window it reads as a phone control bolted to a big screen and
/// puts its content as far from the pointer as possible, so wide windows get a
/// centred dialog instead — or, with [anchored], a popover hanging from the
/// control that opened it, the desktop idiom for pickers and details.
///
/// Both forms are height-bounded and scrollable. The sheet in particular MUST
/// be `isScrollControlled` — without it Flutter caps the sheet at 9/16 of the
/// screen and simply clips whatever doesn't fit, with no way to reach it.
Future<T?> showAdaptivePanel<T>({
  required BuildContext context,
  required WidgetBuilder builder,

  /// Set false when the body brings its own scrollable (a `ListView`), which
  /// cannot be nested inside another one without an unbounded-height error.
  bool scrollable = true,

  /// Set false when the body draws its own top edge (its own grab bar or
  /// header), so the panel doesn't add a second inset above it.
  bool insetTop = true,
  double maxWidth = 460,

  /// Open from the pressed control on wide windows (pickers, details).
  /// Falls back to a centred dialog when no control is known.
  bool anchored = false,

  /// The control to hang from, when the caller knows it; otherwise the
  /// pressed control is used (see [PopoverAnchor]).
  Rect? anchorRect,
}) {
  final size = MediaQuery.sizeOf(context);
  final scheme = Theme.of(context).colorScheme;
  Widget body(BuildContext c) {
    final child = builder(c);
    return scrollable ? SingleChildScrollView(child: child) : child;
  }

  if (size.width < kDesktopPanelWidth) {
    return showModalBottomSheet<T>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: floatingSurface(scheme),
      // Lighter than Material's default: the panel is already lifted by its own
      // ground and hairline, so the page only needs dimming, not hiding. Always
      // a dark veil: a light one would wash a dark page out to grey.
      barrierColor: Colors.black.withValues(
        alpha: scheme.brightness == Brightness.light ? 0.28 : 0.4,
      ),
      constraints: BoxConstraints(maxHeight: size.height * 0.85),
      // The drag handle occupies the top edge, so the body starts right under it.
      builder: (c) => SafeArea(
        child: Padding(
          padding: EdgeInsets.only(top: insetTop ? 4 : 0),
          child: body(c),
        ),
      ),
    );
  }
  final anchor = anchored ? anchorRect ?? PopoverAnchor.current() : null;
  if (anchor != null) {
    return showPopover<T>(
      context: context,
      anchor: anchor,
      maxWidth: math.min(maxWidth, 420),
      maxHeight: math.min(560, size.height * 0.8),
      builder: (c) => Padding(
        padding: EdgeInsets.only(top: insetTop ? 14 : 0),
        child: body(c),
      ),
    );
  }
  return showAppDialog<T>(
    context: context,
    builder: (c) => Dialog(
      clipBehavior: Clip.antiAlias,
      backgroundColor: floatingSurface(scheme),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: maxWidth,
          maxHeight: size.height * 0.8,
        ),
        // No drag handle here, so the body needs its own breathing room at the
        // top — without it a title sits hard against the card's edge.
        child: Padding(
          padding: EdgeInsets.only(top: insetTop ? 20 : 0),
          child: body(c),
        ),
      ),
    ),
  );
}

/// Offer a short list of exclusive [choices] (value, label) from the pressed
/// control (or [anchor]); resolves with the picked value, or null when
/// dismissed. The [current] value is checked.
Future<T?> showChoicePanel<T>({
  required BuildContext context,
  String? title,
  required List<(T, String)> choices,
  required T? current,
  Rect? anchor,
  double maxWidth = 300,
}) => showAdaptivePanel<T>(
  context: context,
  anchored: true,
  anchorRect: anchor,
  maxWidth: maxWidth,
  insetTop: false,
  builder: (c) {
    final theme = Theme.of(c);
    return Padding(
      padding: const EdgeInsets.all(6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
              child: Text(
                title,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          for (final (value, label) in choices)
            ChoiceRow<T>(
              value: value,
              label: label,
              checked: value == current,
              onTap: () => Navigator.of(c).pop(value),
            ),
        ],
      ),
    );
  },
);

/// One row of a choice panel: its label in full (wrapping rather than cut
/// to an ambiguous prefix) and a check on the current value.
class ChoiceRow<T> extends StatelessWidget {
  /// Creates a row offering [value].
  const ChoiceRow({
    super.key,
    required this.value,
    required this.label,
    required this.checked,
    required this.onTap,
  });

  /// The value this row picks.
  final T? value;

  /// What the row shows.
  final String label;

  /// Whether [value] is the current one.
  final bool checked;

  /// Picks [value].
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        key: ValueKey('choice-$value'),
        mouseCursor: clickable,
        borderRadius: BorderRadius.circular(kControlRadius),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 40),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: checked
              ? BoxDecoration(
                  color: scheme.onSurface.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(kControlRadius),
                )
              : null,
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: checked ? FontWeight.w600 : FontWeight.w400,
                    color: scheme.onSurface,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 18,
                child: checked
                    ? Icon(AppIcons.check, size: 17, color: scheme.onSurface)
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Show a short explanation from the control that asked for it, instead of
/// a modal dialog with a lone "Done" button.
Future<void> showInfoPanel({
  required BuildContext context,
  required String title,
  required String body,
}) => showAdaptivePanel<void>(
  context: context,
  anchored: true,
  maxWidth: 360,
  insetTop: false,
  builder: (c) {
    final theme = Theme.of(c);
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          Text(
            body,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  },
);
