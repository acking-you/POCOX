import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:window_manager/window_manager.dart';
import 'package:pocox/src/app_icons.dart';
import 'package:pocox/src/desktop_theme.dart';

/// True on the desktop platforms that run frameless (macOS + Windows). Linux
/// keeps its native title bar for now. Gated on [defaultTargetPlatform] (NOT
/// `dart:io`) so `flutter test` — forced to android — takes the mobile branch
/// and never exercises the desktop insets/drag.
bool get isFramelessDesktop =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.windows);

/// True on macOS, frameless or not. Read through [defaultTargetPlatform] for
/// the same test-safety reason as [isFramelessDesktop].
bool get isMacDesktop =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

/// Geometry of the window chrome every desktop screen shares, so a sidebar
/// strip, a content header and a utility page all line up with the native
/// window buttons instead of each guessing.
abstract final class WindowChrome {
  /// Height of the top strip that doubles as the title bar.
  ///
  /// macOS: 60 pt, a unified-toolbar height. The traffic lights are
  /// re-centred into it natively (see `MainFlutterWindow.swift`), so controls
  /// in the strip — and in a content sheet's bar, see [sheetBarHeight] —
  /// share their centre line. Windows: 44 px, which the 46 px caption
  /// buttons fill edge to edge.
  static double get barHeight => isMacDesktop ? 60 : 44;

  /// Height of a bar heading a content sheet, which sits [kSheetInset]
  /// below the window's top edge: on macOS it is centred on the traffic
  /// lights' line; elsewhere it keeps the full bar height.
  static double get sheetBarHeight =>
      isMacDesktop ? barHeight - 2 * kSheetInset : barHeight;

  /// Width the macOS traffic lights occupy from the window's leading edge,
  /// including the native 20 pt inset and the gap after the zoom button.
  static const double trafficLightsWidth = 78;

  /// Leading inset that keeps content clear of the traffic lights; zero where
  /// there are none.
  static double get leadingInset =>
      isFramelessDesktop && isMacDesktop ? trafficLightsWidth : 0;

  /// Width [WindowTitleBar] adds after its actions for the drawn Windows
  /// caption buttons; zero elsewhere.
  static double get trailingInset =>
      isFramelessDesktop && !isMacDesktop ? 3 * _CaptionButton.width : 0;
}

/// An [AppBar] replacement for the frameless desktop window.
///
/// The native title bar is hidden (see `desktop_tray.dart`), so this bar sits
/// flush at the window's top edge and IS the title bar: its empty space drags
/// the window ([DragToMoveArea]). Platform differ on the window buttons: macOS
/// keeps its native traffic lights (top-left, floating over content), so we
/// only inset the leading edge to clear them; Windows loses ALL native caption
/// buttons with `TitleBarStyle.hidden`, so this bar draws its own
/// minimize/maximize/close ([WindowCaptionButtons]) at the trailing edge. The
/// theme's `appBarTheme` flattens tint/elevation so it blends into the content.
///
/// On mobile (and Linux, which keeps native decorations) it is a plain
/// [AppBar]. Implements [PreferredSizeWidget] so it drops into
/// `Scaffold.appBar` in place of an `AppBar`.
class WindowTitleBar extends StatelessWidget implements PreferredSizeWidget {
  /// Creates a window title bar with the usual [AppBar] slots.
  const WindowTitleBar({
    super.key,
    this.leading,
    this.title,
    this.actions,
    this.bottom,
    this.automaticallyImplyLeading = true,
    this.backgroundColor,
    this.foregroundColor,
    this.centerTitle,
    this.clearTrafficLights = true,
    this.height,
  });

  /// Whether the bar keeps clear of the macOS traffic lights. False for a
  /// bar inside a content sheet, whose window corner the sidebar owns.
  final bool clearTrafficLights;

  /// Overrides the bar's height (the window chrome's by default).
  final double? height;

  /// Whether to centre the title; null follows the platform (centred on
  /// macOS, leading elsewhere).
  final bool? centerTitle;

  /// Overrides the themed bar colour — for a surface that isn't the page, like
  /// the black image viewer. Null keeps the theme's flat app-bar colour.
  final Color? backgroundColor;

  /// Overrides the themed ink for the bar's title and icons.
  final Color? foregroundColor;

  /// Leading widget (e.g. a hamburger or back button), as on [AppBar].
  final Widget? leading;

  /// Title widget, as on [AppBar].
  final Widget? title;

  /// Trailing action widgets, as on [AppBar].
  final List<Widget>? actions;

  /// Bottom widget (e.g. a warning strip or tab bar), as on [AppBar].
  final PreferredSizeWidget? bottom;

  /// Whether to imply a leading widget when none is given, as on [AppBar].
  final bool automaticallyImplyLeading;

  @override
  Size get preferredSize => Size.fromHeight(
    (height ?? (isFramelessDesktop ? WindowChrome.barHeight : kToolbarHeight)) +
        (bottom?.preferredSize.height ?? 0),
  );

  @override
  Widget build(BuildContext context) {
    if (!isFramelessDesktop) {
      return AppBar(
        leading: leading,
        title: title,
        actions: actions,
        bottom: bottom,
        toolbarHeight: height,
        automaticallyImplyLeading: automaticallyImplyLeading,
        backgroundColor: backgroundColor,
        foregroundColor: foregroundColor,
      );
    }

    final isMac = isMacDesktop;
    final leadInset = clearTrafficLights ? WindowChrome.leadingInset : 0.0;
    final barHeight = height ?? WindowChrome.barHeight;

    // Materialise the implied back button ourselves: AppBar's own implied
    // leading knows nothing about the traffic lights and would sit under
    // them, so every leading — explicit or implied — goes through the inset.
    final impliedBack =
        leading == null &&
            automaticallyImplyLeading &&
            (ModalRoute.of(context)?.canPop ?? false)
        ? const BackButton()
        : null;
    final effectiveLeading = leading ?? impliedBack;

    // Push a leading widget right past the traffic lights; when there is none,
    // inset the title instead so it doesn't start under them.
    final leadingWidget = effectiveLeading == null
        ? null
        : Padding(
            padding: EdgeInsets.only(left: leadInset),
            child: effectiveLeading,
          );

    final centered = centerTitle ?? isMac;
    // The toolbar applies its title spacing on both sides of the title, so a
    // leading-aligned title takes the traffic-light inset as its own leading
    // padding; only a centred title keeps it symmetric, to stay centred.
    final insetTitle =
        effectiveLeading == null && !centered && title != null && leadInset > 0;
    return AppBar(
      automaticallyImplyLeading: false,
      toolbarHeight: barHeight,
      // macOS centres a window's title; Windows leads with it.
      centerTitle: centered,
      backgroundColor: backgroundColor,
      foregroundColor: foregroundColor,
      leadingWidth: effectiveLeading == null ? null : leadInset + barHeight,
      leading: leadingWidget,
      titleSpacing: effectiveLeading == null && !insetTitle
          ? leadInset + NavigationToolbar.kMiddleSpacing
          : NavigationToolbar.kMiddleSpacing,
      title: insetTitle
          ? Padding(
              padding: EdgeInsets.only(left: leadInset),
              child: title,
            )
          : title,
      actions: [
        ...?actions,
        // macOS keeps its native traffic lights (top-left); Windows lost its
        // native caption buttons to TitleBarStyle.hidden, so draw our own at
        // the trailing edge.
        if (!isMac) const WindowCaptionButtons(),
      ],
      // The bar's empty space drags the window (and double-click zooms, as
      // a native title bar does); the leading/title/actions sit above this
      // layer and keep their own taps.
      flexibleSpace: const WindowDragArea(),
      bottom: bottom,
    );
  }
}

/// Empty title-bar space: drags the window, and a double-click zooms it the
/// way the native title bar would. `DragToMoveArea` covers the drag but not
/// the double-click, which is the first thing a Mac user tries.
class WindowDragArea extends StatelessWidget {
  /// Fills its parent; pass [child] to drag from something visible.
  const WindowDragArea({super.key, this.child});

  /// Optional content painted inside the drag area.
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    if (!isFramelessDesktop) return child ?? const SizedBox.expand();
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: (_) => windowManager.startDragging(),
      onDoubleTap: _toggleMaximized,
      child: child ?? const SizedBox.expand(),
    );
  }
}

/// Maximize the window, or restore it when it already is.
Future<void> _toggleMaximized() async {
  try {
    if (await windowManager.isMaximized()) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
  } catch (_) {
    // Best-effort; there is no real window under `flutter test`.
  }
}

/// The minimize / maximize-restore / close buttons drawn at the trailing edge
/// of the frameless Windows title bar (macOS uses its native traffic lights, so
/// these are Windows-only). Stateful to swap the maximize glyph for a restore
/// glyph while the window is maximized, tracked via [WindowListener]. Public
/// so screens that draw their own top strip (no [WindowTitleBar]) can still
/// give the frameless Windows window its caption buttons.
class WindowCaptionButtons extends StatefulWidget {
  /// Default constructor.
  const WindowCaptionButtons({super.key});

  @override
  State<WindowCaptionButtons> createState() => _WindowCaptionButtonsState();
}

class _WindowCaptionButtonsState extends State<WindowCaptionButtons>
    with WindowListener {
  bool _maximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _syncMaximized();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  Future<void> _syncMaximized() async {
    try {
      final m = await windowManager.isMaximized();
      if (mounted) setState(() => _maximized = m);
    } catch (_) {
      // Best-effort (and no-op under `flutter test`, which has no real window).
    }
  }

  @override
  void onWindowMaximize() {
    if (mounted) setState(() => _maximized = true);
  }

  @override
  void onWindowUnmaximize() {
    if (mounted) setState(() => _maximized = false);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _CaptionButton(
          icon: AppIcons.remove,
          tooltip: l10n.windowMinimize,
          onTap: () => windowManager.minimize(),
        ),
        _CaptionButton(
          icon: _maximized ? AppIcons.filter_none : AppIcons.crop_square,
          tooltip: _maximized ? l10n.windowRestore : l10n.windowMaximize,
          // filter_none (two stacked squares) reads better a touch smaller.
          iconSize: _maximized ? 13 : 15,
          onTap: _toggleMaximized,
        ),
        _CaptionButton(
          icon: AppIcons.close,
          tooltip: l10n.windowClose,
          isClose: true,
          // Honors setPreventClose → hides to tray, matching the native button.
          onTap: () => windowManager.close(),
        ),
      ],
    );
  }
}

/// A single Windows-style caption button: full-bar-height, fixed-width, with a
/// hover highlight (red for [isClose], a subtle wash otherwise).
class _CaptionButton extends StatefulWidget {
  const _CaptionButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.isClose = false,
    this.iconSize = 16,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool isClose;
  final double iconSize;

  /// Each button's width; three of them ≈ the classic 138 px Windows caption.
  static const double width = 46;

  @override
  State<_CaptionButton> createState() => _CaptionButtonState();
}

class _CaptionButtonState extends State<_CaptionButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final Color bg;
    final Color fg;
    if (_hover && widget.isClose) {
      bg = const Color(0xFFC42B1C); // Windows close-button red
      fg = Colors.white;
    } else if (_hover) {
      bg = scheme.onSurface.withValues(alpha: 0.08);
      fg = scheme.onSurface;
    } else {
      bg = Colors.transparent;
      fg = scheme.onSurfaceVariant;
    }
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: Container(
            width: _CaptionButton.width,
            // Fill whatever strip hosts the buttons (56dp AppBar or a slimmer
            // custom top bar) — the hover wash must reach both edges.
            height: double.infinity,
            color: bg,
            alignment: Alignment.center,
            child: Icon(widget.icon, size: widget.iconSize, color: fg),
          ),
        ),
      ),
    );
  }
}
