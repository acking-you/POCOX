import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/app_icons.dart';
import 'package:pocox/src/desktop_theme.dart';
import 'package:pocox/src/fonts.dart';
import 'package:pocox/src/motion.dart';
import 'package:pocox/src/theme.dart';
import 'package:pocox/src/widgets/glass.dart';
import 'package:pocox/src/widgets/window_title_bar.dart';
import 'package:pocox/src/widgets/workspace_navigation.dart';

/// The list column's default width.
const double workspaceColumnWidth = 296;

/// A quiet icon button for the title strip: 30 px under a pointer, sized for
/// a finger on touch.
class StripButton extends StatelessWidget {
  /// Creates the button.
  const StripButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.selected = false,
  });

  /// Its name.
  final String tooltip;

  /// Its glyph.
  final IconData icon;

  /// What it does.
  final VoidCallback? onPressed;

  /// A toggle that is on.
  final bool selected;

  /// The side of the button.
  static double get size => isDesktop ? 30 : 44;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      isSelected: selected,
      style: IconButton.styleFrom(
        minimumSize: Size.square(size),
        fixedSize: Size.square(size),
        padding: EdgeInsets.zero,
        foregroundColor: scheme.onSurfaceVariant,
        backgroundColor: selected ? softWash(scheme) : null,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(kControlRadius - 1),
        ),
      ),
      icon: Icon(icon, size: 18),
    );
  }
}

/// A window from [workspaceCompactWidth] up: a full-width title strip on the
/// backdrop, the icon rail under it, and the pane holding an optional list
/// [column] beside the [body]. Every page lays out the same way, so the window
/// keeps its shape as the user moves between them.
class WorkspaceShell extends StatelessWidget {
  /// Creates the shell with [section] current.
  const WorkspaceShell({
    super.key,
    required this.section,
    required this.onOpen,
    required this.title,
    required this.body,
    this.actions = const [],
    this.column,
    this.columnOpen = true,
    this.columnWidth = workspaceColumnWidth,
    this.columnDragging = false,
    this.columnHandle,
    this.onToggleColumn,
    this.leading = const [],
    this.grouped = false,
  });

  /// The destination shown as current.
  final String section;

  /// Leaves for another destination.
  final ValueChanged<String> onOpen;

  /// What the strip names, starting at the body's edge.
  final Widget title;

  /// Controls at the strip's end.
  final List<Widget> actions;

  /// What the page shows beside its [column].
  final Widget body;

  /// The page's list, or null for a page that spans the pane.
  final Widget? column;

  /// Whether [column] stands open.
  final bool columnOpen;

  /// [column]'s width while open.
  final double columnWidth;

  /// A drag is resizing [column]: it follows without easing.
  final bool columnDragging;

  /// The handle on [column]'s edge that resizes it.
  final Widget? columnHandle;

  /// Shows or hides [column]; null offers no toggle.
  final VoidCallback? onToggleColumn;

  /// Further strip controls right after the toggle.
  final List<Widget> leading;

  /// A page of cards rather than of reading.
  final bool grouped;

  /// The strip's height.
  static double get stripHeight => isDesktop ? WindowChrome.barHeight : 52;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final slide = columnDragging
        ? Duration.zero
        : Motion.of(context, Motion.medium);
    final column = this.column;
    final open = column != null && columnOpen;
    final inset = isFramelessDesktop && isMacDesktop
        ? WindowChrome.trafficLightsWidth
        : 16.0;
    final controls = (onToggleColumn == null ? 0 : 1) + leading.length;
    // The strip's lead reaches the column's edge, so the title starts over
    // the body; with no column it only holds its own controls.
    final natural = inset + controls * (StripButton.size + 4);
    final lead = open ? workspaceRailWidth + columnWidth : natural;
    final strip = SizedBox(
      height: stripHeight,
      child: Stack(
        alignment: Alignment.centerLeft,
        children: [
          const Positioned.fill(child: WindowDragArea()),
          Row(
            children: [
              AnimatedContainer(
                duration: slide,
                curve: Motion.move,
                width: math.max(natural, lead),
                child: ClipRect(
                  child: OverflowBox(
                    alignment: AlignmentDirectional.centerStart,
                    maxWidth: double.infinity,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(width: inset),
                        if (onToggleColumn case final toggle?) ...[
                          StripButton(
                            key: Key(
                              columnOpen
                                  ? 'sidebar-collapse-btn'
                                  : 'sidebar-expand-btn',
                            ),
                            tooltip: withShortcut(
                              columnOpen ? l10n.hideSidebar : l10n.showSidebar,
                              'B',
                            ),
                            icon: columnOpen
                                ? AppIcons.view_sidebar_outlined
                                : AppIcons.panel_left_open,
                            onPressed: toggle,
                          ),
                          const SizedBox(width: 4),
                        ],
                        for (final control in leading) ...[
                          control,
                          const SizedBox(width: 4),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(child: title),
              const SizedBox(width: 8),
              ...actions,
              if (isFramelessDesktop && !isMacDesktop) ...[
                const SizedBox(width: 6),
                const WindowCaptionButtons(),
              ] else
                const SizedBox(width: 12),
            ],
          ),
        ],
      ),
    );
    return Scaffold(
      backgroundColor: backdropBase(scheme),
      body: AppBackdrop(
        child: SafeArea(
          bottom: false,
          child: Column(
            children: [
              strip,
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      width: workspaceRailWidth,
                      child: WorkspaceRail(section: section, onOpen: onOpen),
                    ),
                    Expanded(
                      child: ContentSheet(
                        grouped: grouped,
                        borderRadius: const BorderRadius.only(
                          topLeft: Radius.circular(kSheetRadius),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (column != null)
                              _ColumnSlot(
                                open: columnOpen,
                                width: columnWidth,
                                slide: slide,
                                handle: columnHandle,
                                child: column,
                              ),
                            Expanded(child: body),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The list column. It slides rather than snapping, so the user sees where the
/// list went; its content keeps its open width and is clipped meanwhile, so
/// rows never reflow mid-animation, and stops being built once it is away.
class _ColumnSlot extends StatefulWidget {
  const _ColumnSlot({
    required this.open,
    required this.width,
    required this.slide,
    required this.child,
    this.handle,
  });

  final bool open;
  final double width;
  final Duration slide;
  final Widget child;
  final Widget? handle;

  @override
  State<_ColumnSlot> createState() => _ColumnSlotState();
}

class _ColumnSlotState extends State<_ColumnSlot> {
  late bool _built = widget.open;

  @override
  void didUpdateWidget(_ColumnSlot old) {
    super.didUpdateWidget(old);
    if (widget.open) _built = true;
    // Nothing slides with reduced motion, so nothing would report its end.
    if (!widget.open && widget.slide == Duration.zero) _built = false;
  }

  @override
  Widget build(BuildContext context) {
    final handle = widget.handle;
    return ClipRect(
      child: AnimatedContainer(
        duration: widget.slide,
        curve: Motion.move,
        color: surfaceSidebar(Theme.of(context).colorScheme),
        width: widget.open ? widget.width : 0,
        onEnd: () {
          if (!widget.open && _built && mounted) {
            setState(() => _built = false);
          }
        },
        child: OverflowBox(
          alignment: AlignmentDirectional.centerEnd,
          minWidth: widget.width,
          maxWidth: widget.width,
          child: _built
              ? Stack(
                  fit: StackFit.expand,
                  children: [
                    widget.child,
                    if (handle != null)
                      PositionedDirectional(
                        top: 0,
                        bottom: 0,
                        end: 0,
                        width: 5,
                        child: handle,
                      ),
                  ],
                )
              : const SizedBox.shrink(),
        ),
      ),
    );
  }
}
