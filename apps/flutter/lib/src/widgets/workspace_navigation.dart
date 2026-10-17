import 'package:flutter/material.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/app_icons.dart';
import 'package:pocket_codex/src/desktop_theme.dart';
import 'package:pocket_codex/src/motion.dart';
import 'package:pocket_codex/src/theme.dart';
import 'package:pocket_codex/src/widgets/brand_logo.dart';
import 'package:pocket_codex/src/widgets/glass.dart';
import 'package:pocket_codex/src/widgets/window_title_bar.dart';

/// The rail's width on wide windows.
const double workspaceNavigationWidth = 208;

/// The wide navigation's row height and the gap between rows; the sliding
/// selection steps by their sum.
const double _rowHeight = 38;
const double _rowGap = 2;

/// A persistent destination: where it leads, its glyph and its name.
typedef WorkspaceDestination = ({String route, IconData icon, String label});

/// The persistent destinations, in the order every navigation lists them
/// (the rail, the bottom bar and the page menu).
List<WorkspaceDestination> workspaceDestinations(AppLocalizations l10n) => [
  (
    route: '/',
    icon: AppIcons.chat_bubble_outline_rounded,
    label: l10n.utilityChat,
  ),
  (route: '/manage', icon: AppIcons.dns_outlined, label: l10n.manageServices),
  (
    route: '/sessions',
    icon: AppIcons.history_rounded,
    label: l10n.localSessionsTitle,
  ),
  (route: '/logs', icon: AppIcons.article_outlined, label: l10n.logsTitle),
  (
    route: '/settings',
    icon: AppIcons.settings_outlined,
    label: l10n.settingsTitle,
  ),
];

/// The destinations' routes, in [workspaceDestinations] order.
const _routes = ['/', '/manage', '/sessions', '/logs', '/settings'];

/// The workspace's persistent destinations: a rail on the backdrop of a wide
/// window, its selection a pane of glass gliding between rows, or a bottom
/// bar on a compact one.
class WorkspaceNavigation extends StatefulWidget {
  /// Creates the navigation with [route] current.
  const WorkspaceNavigation({
    super.key,
    required this.route,
    required this.onOpen,
    this.compact = false,
  });

  /// The destination shown as current.
  final String route;

  /// Leaves for another destination; the page decides how (behind its
  /// leave guard, for one).
  final ValueChanged<String> onOpen;

  /// A bottom bar instead of the wide rail.
  final bool compact;

  @override
  State<WorkspaceNavigation> createState() => _WorkspaceNavigationState();
}

class _WorkspaceNavigationState extends State<WorkspaceNavigation> {
  /// The row a destination was picked from, just now: each page builds its
  /// own navigation, so the next one starts its selection there and glides
  /// it to its own row, and the pane reads as one control across the swap.
  static ({int index, DateTime at})? _departure;

  late int _shown = _initialRow();

  int get _row => _routes.indexOf(widget.route);

  int _initialRow() {
    final row = _row;
    final from = _departure;
    _departure = null;
    if (from == null ||
        from.index == row ||
        DateTime.now().difference(from.at) > const Duration(seconds: 2)) {
      return row;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _shown = _row);
    });
    return from.index;
  }

  @override
  void didUpdateWidget(WorkspaceNavigation old) {
    super.didUpdateWidget(old);
    if (old.route != widget.route) _shown = _row;
  }

  void _open(String target) {
    _departure = (index: _row, at: DateTime.now());
    widget.onOpen(target);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final compact = widget.compact;
    final route = widget.route;
    final entries = workspaceDestinations(l10n);
    Widget destination(WorkspaceDestination entry) {
      final selected = entry.route == route;
      final ink = selected ? scheme.onSurface : scheme.onSurfaceVariant;
      return Semantics(
        selected: selected,
        button: true,
        child: Tooltip(
          message: entry.label,
          child: Material(
            // Wide rows sit over the sliding glass; compact ones carry
            // their own plate.
            color: compact && selected
                ? surfaceSelection(scheme)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(999),
            child: InkWell(
              key: Key('workspace-nav-${entry.route}'),
              mouseCursor: clickable,
              hoverColor: compact ? null : backdropHover(scheme),
              borderRadius: BorderRadius.circular(999),
              onTap: selected ? null : () => _open(entry.route),
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: compact ? 8 : 14,
                  vertical: compact ? 12 : 0,
                ),
                child: Row(
                  mainAxisAlignment: compact
                      ? MainAxisAlignment.center
                      : MainAxisAlignment.start,
                  children: [
                    Icon(entry.icon, size: compact ? 21 : 18, color: ink),
                    if (!compact) ...[
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          entry.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: selected
                                ? FontWeight.w600
                                : FontWeight.w400,
                            color: ink,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    if (compact) {
      return Material(
        color: surfaceSidebar(scheme),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                for (final entry in entries)
                  Expanded(child: destination(entry)),
              ],
            ),
          ),
        ),
      );
    }
    final step = MediaQuery.textScalerOf(context).scale(_rowHeight);
    return Material(
      type: MaterialType.transparency,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The window's corner: the traffic lights live here, and it drags.
          SizedBox(
            height: isFramelessDesktop ? WindowChrome.barHeight : 14,
            child: isFramelessDesktop ? const WindowDragArea() : null,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 12, 16),
            child: Row(
              children: [
                const BrandLogo(size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    l10n.appTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Stack(
              children: [
                if (_shown >= 0)
                  AnimatedPositioned(
                    duration: Motion.of(
                      context,
                      const Duration(milliseconds: 520),
                    ),
                    curve: Motion.spring,
                    top: _shown * (step + _rowGap),
                    left: 0,
                    right: 0,
                    height: step,
                    child: const IgnorePointer(
                      child: Glass(
                        depth: GlassDepth.chrome,
                        borderRadius: BorderRadius.all(Radius.circular(999)),
                        child: SizedBox.expand(),
                      ),
                    ),
                  ),
                Column(
                  children: [
                    for (final entry in entries) ...[
                      SizedBox(height: step, child: destination(entry)),
                      const SizedBox(height: _rowGap),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
