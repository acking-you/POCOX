import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/app_icons.dart';
import 'package:pocox/src/desktop_theme.dart';
import 'package:pocox/src/fonts.dart';
import 'package:pocox/src/motion.dart';
import 'package:pocox/src/providers.dart';
import 'package:pocox/src/theme.dart';
import 'package:pocox/src/ui_prefs.dart';
import 'package:pocox/src/widgets/glass.dart';

/// Below this window width the workspace shows one pane at a time: a phone's
/// drawer and pocket instead of the rail and the column.
const double workspaceCompactWidth = 720;

/// The icon rail's width.
const double workspaceRailWidth = 60;

/// A persistent destination: the [section] it belongs to (what a page reports
/// as current), where it leads, its glyph, its name and its shortcut key.
typedef WorkspaceDestination = ({
  String section,
  String route,
  IconData icon,
  String label,
  LogicalKeyboardKey key,
});

/// Every persistent destination, in the order every navigation lists them.
/// [history] is where the session history leads; null leaves it out.
List<WorkspaceDestination> workspaceDestinations(
  AppLocalizations l10n, {
  required String? history,
}) => [
  (
    section: '/',
    route: '/',
    icon: AppIcons.chat_bubble_outline_rounded,
    label: l10n.utilityChat,
    key: LogicalKeyboardKey.digit0,
  ),
  (
    section: '/manage',
    route: '/manage',
    icon: AppIcons.dns_outlined,
    label: l10n.manageServices,
    key: LogicalKeyboardKey.digit1,
  ),
  (
    section: '/galaxy',
    route: '/galaxy',
    icon: AppIcons.orbit,
    label: l10n.galaxyTitle,
    key: LogicalKeyboardKey.digit2,
  ),
  if (history != null)
    (
      section: '/sessions',
      route: history,
      icon: AppIcons.history_rounded,
      label: l10n.hostSessions,
      key: LogicalKeyboardKey.digit3,
    ),
  (
    section: '/logs',
    route: '/logs',
    icon: AppIcons.article_outlined,
    label: l10n.logsTitle,
    key: LogicalKeyboardKey.digit4,
  ),
  (
    section: '/settings',
    route: '/settings',
    icon: AppIcons.settings_outlined,
    label: l10n.settingsTitle,
    key: LogicalKeyboardKey.comma,
  ),
];

/// Where session history leads for the service the user is chatting on: that
/// host, read over its meta tunnel, an account-mode feature of a service that
/// has one. A computer's own service reads its own disk instead, which also
/// lists its other agents. With no such service only a computer has a history
/// of its own to show; a phone has none, so the destination is left out.
String? workspaceHistoryRoute(WidgetRef ref) {
  final service = ref.watch(
    uiPrefsProvider.select((prefs) => prefs.valueOrNull?.lastServiceKey),
  );
  final account = ref.watch(
    configProvider.select((config) => config.valueOrNull?.mode == 'account'),
  );
  final api = ref.read(bridgeApiProvider);
  final remote =
      service != null && account && api.appCapabilities(service).localSessions;
  // The exact keys of this process's own registry, never a matching label.
  final own =
      isDesktop &&
      service != null &&
      api.localServices().any((entry) => entry.key == service);
  if (remote && !own) {
    return Uri(path: '/sessions', queryParameters: {'svc': service}).toString();
  }
  return isDesktop ? '/sessions' : null;
}

/// The destinations for this window, from the service in use.
List<WorkspaceDestination> currentDestinations(
  WidgetRef ref,
  AppLocalizations l10n,
) => workspaceDestinations(l10n, history: workspaceHistoryRoute(ref));

bool get _commandIsMeta => defaultTargetPlatform == TargetPlatform.macOS;

/// [label] followed by the [key] of its window shortcut in the platform's
/// notation (`⌘1` on macOS, `Ctrl+1` elsewhere), for a tooltip.
String withShortcut(String label, String key) =>
    '$label  ${_commandIsMeta ? '⌘$key' : 'Ctrl+$key'}';

/// Lets a page with unsaved edits decide before the shared navigation (rail,
/// pocket, breadcrumbs and page shortcuts) leaves it. Those go through the
/// router (`go`, `pushReplacement`), which a `PopScope` does not see; the
/// page's own back gesture stays with its `PopScope`.
class UtilityLeaveGuard extends InheritedWidget {
  /// Creates a guard; [confirm] answers whether leaving may proceed.
  const UtilityLeaveGuard({
    super.key,
    required this.confirm,
    required super.child,
  });

  /// Asked before navigating away; `true` lets the navigation proceed.
  final Future<bool> Function() confirm;

  /// Run [navigate] once the page around [context] may be left: at once
  /// without a guard, else after its [confirm] agreed while still mounted.
  static void leave(BuildContext context, VoidCallback navigate) {
    final guard = context.getInheritedWidgetOfExactType<UtilityLeaveGuard>();
    if (guard == null) {
      navigate();
      return;
    }
    unawaited(
      guard.confirm().then((ok) {
        if (ok && context.mounted) navigate();
      }),
    );
  }

  @override
  bool updateShouldNotify(UtilityLeaveGuard oldWidget) =>
      confirm != oldWidget.confirm;
}

/// Leave the page in [section] for [target], behind the page's leave guard.
///
/// The conversation stays where it is: a page opens above it, pages swap
/// without replacing it, and `go('/')` removes them all without rebuilding it.
void openWorkspaceRoute(BuildContext context, String section, String target) {
  if (Uri.parse(target).path == section) return;
  UtilityLeaveGuard.leave(context, () {
    if (target == '/') {
      context.go('/');
    } else if (section == '/') {
      context.push(target);
    } else {
      context.pushReplacement(target);
    }
  });
}

/// Installs app-level page shortcuts while leaving [child] unchanged.
///
/// Home uses section `/`, so a page is pushed above the live conversation.
/// Pages replace one another and retain that same conversation beneath them.
/// Compact platforms do not install desktop keys.
class AppPageShortcuts extends ConsumerWidget {
  /// Creates a shortcut scope for [currentRoute].
  const AppPageShortcuts({
    super.key,
    required this.currentRoute,
    required this.child,
  });

  /// The section rendered by [child].
  final String currentRoute;

  /// Content receiving the shortcut scope.
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!isDesktop) return child;
    final meta = _commandIsMeta;
    void open(String target) {
      final current = ModalRoute.of(context);
      if (current != null && !current.isCurrent) return;
      openWorkspaceRoute(context, currentRoute, target);
    }

    return CallbackShortcuts(
      bindings: {
        for (final destination in currentDestinations(
          ref,
          AppLocalizations.of(context),
        ))
          SingleActivator(destination.key, meta: meta, control: !meta): () =>
              open(destination.route),
      },
      child: Focus(autofocus: true, child: child),
    );
  }
}

/// The icon rail on the window's backdrop: the destinations with tooltips and
/// shortcuts, Settings at its foot, the selection a pane of glass gliding
/// between them.
class WorkspaceRail extends ConsumerStatefulWidget {
  /// Creates the rail with [section] current.
  const WorkspaceRail({super.key, required this.section, required this.onOpen});

  /// The destination shown as current.
  final String section;

  /// Leaves for another destination; the page decides how (behind its
  /// leave guard, for one).
  final ValueChanged<String> onOpen;

  @override
  ConsumerState<WorkspaceRail> createState() => _WorkspaceRailState();
}

class _WorkspaceRailState extends ConsumerState<WorkspaceRail> {
  /// The section a destination was picked from, just now: each page builds
  /// its own rail, so the next one starts its selection there and glides it
  /// to its own, and the pane reads as one control across the swap.
  static ({String section, DateTime at})? _departure;

  late String _shown = _initialSection();

  String _initialSection() {
    final from = _departure;
    _departure = null;
    if (from == null ||
        from.section == widget.section ||
        DateTime.now().difference(from.at) > const Duration(seconds: 2)) {
      return widget.section;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _shown = widget.section);
    });
    return from.section;
  }

  @override
  void didUpdateWidget(WorkspaceRail old) {
    super.didUpdateWidget(old);
    if (old.section != widget.section) _shown = widget.section;
  }

  void _open(String target) {
    _departure = (section: widget.section, at: DateTime.now());
    widget.onOpen(target);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final entries = currentDestinations(ref, l10n);
    // A finger's target on touch; a pointer needs less.
    final size = isDesktop ? 40.0 : 44.0;
    const gap = 4.0;
    const inset = 4.0;
    const foot = 14.0;
    const radius = BorderRadius.all(Radius.circular(12));
    Widget button(WorkspaceDestination entry) {
      final selected = entry.section == widget.section;
      return Semantics(
        selected: selected,
        button: true,
        label: entry.label,
        excludeSemantics: true,
        child: Tooltip(
          message: isDesktop
              ? withShortcut(entry.label, entry.key.keyLabel)
              : entry.label,
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              key: Key('workspace-nav-${entry.section}'),
              mouseCursor: clickable,
              hoverColor: backdropHover(scheme),
              borderRadius: radius,
              onTap: selected ? null : () => _open(entry.route),
              child: Center(
                child: Icon(
                  entry.icon,
                  size: 20,
                  color: selected ? scheme.onSurface : scheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, box) {
        final needed =
            inset + entries.length * (size + gap) + foot + (gap + size);
        final height = math.max(box.maxHeight, needed);
        // Settings sits at the foot; a window too short for that scrolls.
        double top(int index) => index == entries.length - 1
            ? height - foot - size
            : inset + index * (size + gap);
        final shown = entries.indexWhere((entry) => entry.section == _shown);
        final left = (workspaceRailWidth - size) / 2;
        return SingleChildScrollView(
          primary: false,
          physics: needed > box.maxHeight
              ? null
              : const NeverScrollableScrollPhysics(),
          child: SizedBox(
            height: height,
            child: Stack(
              children: [
                if (shown >= 0)
                  AnimatedPositioned(
                    duration: Motion.of(
                      context,
                      const Duration(milliseconds: 520),
                    ),
                    curve: Motion.spring,
                    top: top(shown),
                    left: left,
                    width: size,
                    height: size,
                    child: const IgnorePointer(
                      child: Glass(
                        depth: GlassDepth.chrome,
                        borderRadius: radius,
                        child: SizedBox.expand(),
                      ),
                    ),
                  ),
                for (final (index, entry) in entries.indexed)
                  Positioned(
                    top: top(index),
                    left: left,
                    width: size,
                    height: size,
                    child: button(entry),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
