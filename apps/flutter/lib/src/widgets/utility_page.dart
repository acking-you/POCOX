import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pocox/src/app_icons.dart';
import 'package:pocox/src/text_measure.dart';
import 'package:pocox/src/ui_prefs.dart';
import 'package:pocox/src/widgets/glass.dart';
import 'package:pocox/src/widgets/pocket_sheet.dart';
import 'package:pocox/src/widgets/window_title_bar.dart';
import 'package:pocox/src/widgets/workspace_navigation.dart';
import 'package:pocox/src/widgets/workspace_shell.dart';

export 'package:pocox/src/widgets/workspace_navigation.dart'
    show AppPageShortcuts, UtilityLeaveGuard;

/// Shared shell for secondary, full-window pages.
///
/// Wide windows lay the page out in the workspace: the title strip names it
/// and carries its actions, the icon rail moves between pages. A compact one
/// has one bar: back, and a title with a chevron that opens the Pocket.
class UtilityPage extends ConsumerWidget {
  /// Creates a secondary page shell.
  const UtilityPage({
    super.key,
    required this.route,
    required this.title,
    required this.body,
    this.parent,
    this.lead,
    this.column,
    this.actions = const [],
    this.primaryAction,
    this.bottomNavigationBar,
    this.floatingActionButton,
  });

  /// The top-level route represented by this page.
  final String route;

  /// Localized page title.
  final String title;

  /// The list this page drilled down from, for a detail page. Renders as a
  /// breadcrumb (`Services / <name>`) whose first segment is the way back up;
  /// omit it on a top-level page.
  final UtilityParent? parent;

  /// What the wide title strip names before [title], when that is not a way
  /// back but the page's own place (`Settings / Connection`).
  final String? lead;

  /// The page's own list, in the workspace's column on a wide window.
  final Widget? column;

  /// Page content below the shared title bar.
  final Widget body;

  /// Actions specific to this page, at the end of its bar.
  final List<Widget> actions;

  /// The page's main action, after [actions]; see [UtilityPrimaryAction].
  final UtilityPrimaryAction? primaryAction;

  /// Optional bar the page keeps under its body.
  final Widget? bottomNavigationBar;

  /// Optional page floating action button.
  final Widget? floatingActionButton;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wide = MediaQuery.sizeOf(context).width >= workspaceCompactWidth;
    if (!wide) {
      return AppPageShortcuts(
        currentRoute: route,
        child: Scaffold(
          appBar: UtilityPageTitleBar(
            route: route,
            title: title,
            parent: parent,
            actions: actions,
            primaryAction: primaryAction,
          ),
          body: body,
          bottomNavigationBar: bottomNavigationBar,
          floatingActionButton: floatingActionButton,
        ),
      );
    }
    final section = parent?.route ?? route;
    final open = ref.watch(
      uiPrefsProvider.select((prefs) => prefs.valueOrNull?.sidebarOpen ?? true),
    );
    final page = Scaffold(
      backgroundColor: Colors.transparent,
      body: EntranceMotion(child: body),
      bottomNavigationBar: bottomNavigationBar,
      floatingActionButton: floatingActionButton,
    );
    return AppPageShortcuts(
      currentRoute: route,
      child: WorkspaceShell(
        section: section,
        grouped: true,
        onOpen: (target) => openWorkspaceRoute(context, section, target),
        column: column,
        columnOpen: open,
        onToggleColumn: column == null
            ? null
            : () => ref.read(uiPrefsProvider.notifier).setSidebarOpen(!open),
        title: _StripTitle(title: title, parent: parent, lead: lead),
        actions: [
          ...actions,
          if (primaryAction case final primary?)
            _StripPrimary(
              action: primary,
              reserved: actions.length * kMinInteractiveDimension,
            ),
        ],
        body: page,
      ),
    );
  }
}

/// A wide page's name on the title strip: where it sits, then what it is.
class _StripTitle extends StatelessWidget {
  const _StripTitle({required this.title, this.parent, this.lead});

  final String title;
  final UtilityParent? parent;
  final String? lead;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const style = TextStyle(fontSize: 14, fontWeight: FontWeight.w500);
    final parent = this.parent;
    final lead = this.lead;
    return Row(
      children: [
        if (parent != null) ...[
          Flexible(
            child: _BreadcrumbLink(
              label: parent.title,
              onTap: () => _openParent(context, parent),
            ),
          ),
          _breadcrumbSeparator(scheme),
        ] else if (lead != null) ...[
          Flexible(
            child: Text(
              lead,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style.copyWith(
                fontWeight: FontWeight.w400,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          _breadcrumbSeparator(scheme),
        ],
        Flexible(
          flex: 2,
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
        ),
      ],
    );
  }
}

/// A wide page's main action: labelled while its label fits the strip beside
/// what else is there and the strip's height, otherwise an icon.
class _StripPrimary extends StatelessWidget {
  const _StripPrimary({required this.action, required this.reserved});

  final UtilityPrimaryAction action;
  final double reserved;

  /// What the strip keeps clear beside the action: the rail, the page's name
  /// at its narrowest, and the insets.
  static const double _strip = workspaceRailWidth + 200;

  @override
  Widget build(BuildContext context) {
    final height =
        WorkspaceShell.stripHeight - 2 * UtilityPrimaryAction._barInset;
    final room = MediaQuery.sizeOf(context).width - _strip - reserved;
    return action.labelledWidth(context) <= room &&
            action.labelledHeight(context) <= height
        ? action.labelled()
        : action.compact();
  }
}

/// The list a detail page sits under, named so the breadcrumb can lead back to
/// it. [route] is the top-level route the rail should treat as current, so a
/// detail page highlights the section it belongs to.
@immutable
class UtilityParent {
  /// Creates a parent breadcrumb segment.
  const UtilityParent({required this.title, required this.route});

  /// Localized title of the list this page came from.
  final String title;

  /// Route that list lives at.
  final String route;
}

/// A page's main title-bar action. It is labelled while the bar has room for
/// the label beside the title, the page's other actions and the page menu;
/// otherwise it is a filled icon button whose tooltip (and so its semantics)
/// carries the full [label]. Either form keeps [key], focus and activation.
@immutable
class UtilityPrimaryAction {
  /// Creates a primary action.
  const UtilityPrimaryAction({
    required this.key,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  /// Key of the button, in either form.
  final Key key;

  /// The button's icon.
  final IconData icon;

  /// The full label: shown, or the icon button's tooltip.
  final String label;

  /// Called on activation.
  final VoidCallback onPressed;

  // The labelled form's own geometry, so its width is known before layout.
  static const _padding = EdgeInsetsDirectional.fromSTEB(12, 0, 16, 0);
  static const _iconSize = 18.0;
  static const _gap = 8.0;

  /// The labelled form's width in [context].
  double labelledWidth(BuildContext context) {
    final style = FilledButtonTheme.of(context).style;
    final text = _textWidth(context, label, _labelStyle(context));
    final minimum = style?.minimumSize?.resolve(const {})?.width ?? 0;
    return math.max(minimum, _padding.horizontal + _iconSize + _gap + text);
  }

  /// The height the labelled form's content needs in [context]: the label's
  /// natural line (its style's line height at the current text scale) or the
  /// icon, whichever is taller. Its own padding adds nothing vertically.
  double labelledHeight(BuildContext context) => math.max(
    _iconSize,
    measureTextLine(context, label, _labelStyle(context)).height,
  );

  /// The label's style: the filled button theme's, else Material's.
  TextStyle? _labelStyle(BuildContext context) =>
      FilledButtonTheme.of(context).style?.textStyle?.resolve(const {}) ??
      Theme.of(context).textTheme.labelLarge;

  /// The labelled form's vertical inset inside the bar.
  static const double _barInset = 8;

  /// The labelled form.
  Widget labelled() => Padding(
    padding: const EdgeInsets.symmetric(vertical: _barInset),
    child: FilledButton(
      key: key,
      onPressed: onPressed,
      style: FilledButton.styleFrom(padding: _padding),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: _iconSize),
          const SizedBox(width: _gap),
          Text(label, maxLines: 1, softWrap: false),
        ],
      ),
    ),
  );

  /// The icon form. Its colours are explicit: an icon button reads its
  /// foreground from the ambient [IconTheme] when that is not the default,
  /// and a title bar's icon colour can equal the filled background, which
  /// would leave a blank disc.
  Widget compact() => Builder(
    builder: (context) {
      final scheme = Theme.of(context).colorScheme;
      return IconButton.filled(
        key: key,
        tooltip: label,
        onPressed: onPressed,
        style: IconButton.styleFrom(
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
        ),
        icon: Icon(icon),
      );
    },
  );
}

/// The width of [text] in [style] at the current text scale.
double _textWidth(BuildContext context, String text, TextStyle? style) =>
    measureTextLine(context, text, style).width;

/// A compact page's bar: back, and a title with a chevron that opens the
/// Pocket, centred so the chevron reads as the title's own.
class UtilityPageTitleBar extends StatelessWidget
    implements PreferredSizeWidget {
  /// Creates a compact page's title bar.
  const UtilityPageTitleBar({
    super.key,
    required this.route,
    required this.title,
    this.parent,
    this.actions = const [],
    this.primaryAction,
  });

  /// The current top-level route.
  final String route;

  /// Localized current-page title.
  final String title;

  /// The list this page drilled down from, if any.
  final UtilityParent? parent;

  /// Actions that belong only to the current page.
  final List<Widget> actions;

  /// The page's main action, after [actions].
  final UtilityPrimaryAction? primaryAction;

  @override
  Size get preferredSize => Size.fromHeight(
    isFramelessDesktop ? WindowChrome.barHeight : kToolbarHeight,
  );

  @override
  Widget build(BuildContext context) {
    final parent = this.parent;
    final canPop = ModalRoute.of(context)?.canPop ?? false;
    final Widget back = parent != null
        ? IconButton(
            key: const Key('utility-parent-origin'),
            tooltip: parent.title,
            icon: const Icon(AppIcons.chevron_left_rounded),
            onPressed: () => _openParent(context, parent),
          )
        : canPop
        ? const BackButton()
        // A page reached directly has nothing beneath it to return to.
        : IconButton(
            key: const Key('utility-chat-origin'),
            tooltip: MaterialLocalizations.of(context).backButtonTooltip,
            icon: const Icon(AppIcons.chevron_left_rounded),
            onPressed: () => openWorkspaceRoute(context, route, '/'),
          );
    return WindowTitleBar(
      leading: back,
      centerTitle: true,
      // A page's own detail keeps its name plain: its parent is a tap away.
      title: parent == null
          ? PocketTitle(section: route, title: title)
          : Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
      actions: [
        ...actions,
        if (primaryAction case final primary?) primary.compact(),
        const SizedBox(width: 4),
      ],
    );
  }
}

/// Climb from a detail page to the list it came from.
///
/// Pops when that list is the route directly beneath — the usual case, since the
/// detail was pushed from it — which keeps the list's scroll position and
/// selection. Only when the detail was reached some other way (a deep link, or a
/// sibling swap that left no list underneath) does it navigate instead. Note this
/// can't go through [openWorkspaceRoute]: a detail page reports its parent's
/// section as its own `route` so the rail highlights correctly, so that helper
/// would see target == current and do nothing.
void _openParent(BuildContext context, UtilityParent parent) =>
    UtilityLeaveGuard.leave(context, () {
      final router = GoRouter.of(context);
      if (router.canPop()) {
        router.pop();
        return;
      }
      context.go(parent.route);
    });

/// The `/` between breadcrumb segments — ink at 28%, well under the labels it
/// divides so the chain reads as one line rather than three words.
Widget _breadcrumbSeparator(ColorScheme scheme) => Padding(
  padding: const EdgeInsets.symmetric(horizontal: 7),
  child: Text(
    '/',
    style: TextStyle(
      color: scheme.onSurface.withValues(alpha: 0.28),
      fontWeight: FontWeight.w400,
    ),
  ),
);

/// A breadcrumb segment leading up: the current page's parent, in quiet ink.
class _BreadcrumbLink extends StatelessWidget {
  const _BreadcrumbLink({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return TextButton(
      key: const Key('utility-parent-origin'),
      onPressed: onTap,
      style: TextButton.styleFrom(
        foregroundColor: scheme.onSurfaceVariant,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w400),
      ),
    );
  }
}
