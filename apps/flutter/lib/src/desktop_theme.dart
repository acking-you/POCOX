import 'package:flutter/material.dart';

/// The desktop design layer.
///
/// The app stays on Material everywhere — this doesn't fork the widget tree or
/// adopt a native toolkit (which would be wrong on two of the three desktop
/// OSes we ship). Instead it re-tunes Material itself for a desktop language:
/// denser, quieter, bordered surfaces rather than tonal elevation, tighter
/// radii, crisp inputs, hover feedback instead of touch ripples. Applied only
/// on desktop (see `theme.dart`); mobile keeps the shared touch-ready defaults.
///
/// The feel to aim at is VS Code / Linear / Zed — an app design language, not a
/// skin of any one OS. [DesktopTokens] carries the handful of values shared
/// widgets read so a bespoke desktop primitive stays consistent with the theme.

/// The design's corner radii. Spacing is deliberately not tokenised — each
/// widget bakes its own metrics from the design — but these recur often enough
/// that a literal at every site drifts. They live here rather than in
/// `theme.dart` because that file imports this one.

/// Cards, panels, code blocks, message bubbles.
const double kPanelRadius = 16.0;

/// The composer card and other large raised frames.
const double kComposerRadius = 26.0;

/// The phone composer: rounder, so the card reads as one soft control.
const double kTouchComposerRadius = 28.0;

/// Small controls: chips, suggestion rows, hover chips, menu items.
const double kControlRadius = 10.0;

/// Sidebar rows and other list selections.
const double kRowRadius = 14.0;

/// Rows and fields of the phone sidebar: a finger-sized list reads as a pill.
const double kTouchRowRadius = 22.0;

/// Grouped cards on secondary pages.
const double kCardRadius = 20.0;

/// The user's message bubble.
const double kUserBubbleRadius = 22.0;

/// Dialogs and modal panels.
const double kDialogRadius = 24.0;

/// The content sheet laid over the window's backdrop.
const double kSheetRadius = 18.0;

/// The backdrop left showing around a content sheet.
const double kSheetInset = 8.0;

/// Text fields outside the composer.
const double kFieldRadius = 14.0;

/// Popup and context menus.
const double kMenuRadius = 14.0;

/// The desktop corner radius. Follows the design's control radius so a
/// desktop-tuned control and a chat-surface chip round the same amount.
const double kDesktopRadius = kControlRadius;

/// Every lift in the design is a single offsetless shadow of the ink at a low
/// alpha — there is no Material `elevation` anywhere. A wider blur is for
/// content that floats over scrolling material.
List<BoxShadow> panelShadow(ColorScheme scheme, {double blur = 12}) => [
  BoxShadow(
    color: Colors.black.withValues(
      alpha: scheme.brightness == Brightness.light ? 0.05 : 0.28,
    ),
    blurRadius: blur,
    offset: const Offset(0, 2),
  ),
];

/// Values a desktop-flavored widget reads to stay in step with the theme. Only
/// present in the tree on desktop; `context.desktop` is null on mobile.
@immutable
class DesktopTokens extends ThemeExtension<DesktopTokens> {
  const DesktopTokens({
    required this.radius,
    required this.panel,
    required this.border,
    required this.hover,
  });

  /// Shared corner radius.
  final double radius;

  /// A quiet raised surface (a panel, a menu) — a hair above the background
  /// rather than a tonally-elevated Material card.
  final Color panel;

  /// Hairline separator / outline colour.
  final Color border;

  /// Pointer-hover wash for an interactive row or button.
  final Color hover;

  /// Tokens derived from a colour scheme. The panel is the design's raised
  /// card — opaque in both themes, so it lifts off the page rather than
  /// tinting it.
  factory DesktopTokens.of(ColorScheme s) => DesktopTokens(
    radius: kDesktopRadius,
    panel: s.surfaceBright,
    border: s.outlineVariant,
    hover: s.onSurface.withValues(alpha: 0.05),
  );

  @override
  DesktopTokens copyWith({
    double? radius,
    Color? panel,
    Color? border,
    Color? hover,
  }) => DesktopTokens(
    radius: radius ?? this.radius,
    panel: panel ?? this.panel,
    border: border ?? this.border,
    hover: hover ?? this.hover,
  );

  @override
  DesktopTokens lerp(ThemeExtension<DesktopTokens>? other, double t) {
    if (other is! DesktopTokens) return this;
    return DesktopTokens(
      radius: radius + (other.radius - radius) * t,
      panel: Color.lerp(panel, other.panel, t)!,
      border: Color.lerp(border, other.border, t)!,
      hover: Color.lerp(hover, other.hover, t)!,
    );
  }
}

/// Read the desktop tokens, or null on mobile (where they aren't installed).
extension DesktopThemeX on BuildContext {
  DesktopTokens? get desktop => Theme.of(this).extension<DesktopTokens>();
}

/// A pointing hand while enabled, the plain arrow while disabled — what a
/// desktop pointer should say about a control.
///
/// Flutter's own `WidgetStateMouseCursor.adaptiveClickable` resolves to a hand
/// ONLY on web; on a native desktop build it returns `basic`, so every button,
/// row and chip hovers as if it were inert text. The button/list themes below
/// substitute this, and [clickable] is the same value for the ink widgets that
/// can't be reached from a theme at all — `InkWell` hardcodes
/// `adaptiveClickable` (see ink_well.dart), so it has to be passed explicitly.
const WidgetStateMouseCursor clickable = WidgetStateMouseCursor.resolveWith(
  _clickableCursor,
  debugDescription: 'desktopClickable',
);

MouseCursor _clickableCursor(Set<WidgetState> states) =>
    states.contains(WidgetState.disabled)
    ? SystemMouseCursors.basic
    : SystemMouseCursors.click;

/// Re-tune [base] for the desktop design language. Same colour scheme and
/// shapes, denser chrome and pointer feedback instead of touch ripples.
ThemeData desktopize(ThemeData base) {
  final scheme = base.colorScheme;
  const pill = StadiumBorder();
  const density = EdgeInsets.symmetric(horizontal: 16);
  // `merge` keeps the receiver's values, so the desktop overrides come first.
  ButtonStyle tune(ButtonStyle? style, {EdgeInsets padding = density}) =>
      ButtonStyle(
        // Standard density: compact would take another 8 px off a button
        // that is already sized for a pointer.
        visualDensity: VisualDensity.standard,
        minimumSize: const WidgetStatePropertyAll(Size(36, 36)),
        padding: WidgetStatePropertyAll(padding),
        shape: const WidgetStatePropertyAll(pill),
        textStyle: WidgetStatePropertyAll(
          style?.textStyle
              ?.resolve(const <WidgetState>{})
              ?.copyWith(fontSize: 13.5),
        ),
        mouseCursor: clickable,
      ).merge(style);

  return base.copyWith(
    // Denser rows, buttons, list tiles — desktop packs more per screen.
    visualDensity: VisualDensity.compact,
    // Hover is the desktop's primary affordance; the ripple is a touch idiom.
    splashFactory: NoSplash.splashFactory,
    // Ink washes rather than opaque steps, so a hover reads the same over the
    // page, the sidebar and a raised card.
    hoverColor: scheme.onSurface.withValues(alpha: 0.05),
    highlightColor: scheme.onSurface.withValues(alpha: 0.08),
    focusColor: scheme.onSurface.withValues(alpha: 0.08),
    // A pointing hand over anything clickable. Flutter's default for ink
    // widgets (`WidgetStateMouseCursor.adaptiveClickable`) resolves to a click
    // cursor ONLY on web — on a native desktop build it returns `basic`, so
    // every button, list row and chip in the app hovered as if it were inert
    // content. Set once here rather than per widget.
    //
    // Text and text-like surfaces are NOT affected — `TextField`,
    // `SelectionArea` and links resolve their own cursor (`textable` /
    // per-span), so an I-beam still wins where the content is selectable.
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        minimumSize: const Size(34, 34),
        iconSize: 18,
      ).copyWith(mouseCursor: clickable).merge(base.iconButtonTheme.style),
    ),
    listTileTheme: base.listTileTheme.copyWith(mouseCursor: clickable),
    checkboxTheme: base.checkboxTheme.copyWith(mouseCursor: clickable),
    radioTheme: base.radioTheme.copyWith(mouseCursor: clickable),
    switchTheme: base.switchTheme.copyWith(mouseCursor: clickable),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: const ButtonStyle(
        mouseCursor: clickable,
      ).merge(base.segmentedButtonTheme.style),
    ),
    menuButtonTheme: MenuButtonThemeData(
      style: const ButtonStyle(
        minimumSize: WidgetStatePropertyAll(Size(0, 34)),
        mouseCursor: clickable,
      ).merge(base.menuButtonTheme.style),
    ),
    popupMenuTheme: base.popupMenuTheme.copyWith(
      textStyle: base.popupMenuTheme.textStyle?.copyWith(fontSize: 13),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: tune(base.filledButtonTheme.style),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: tune(base.outlinedButtonTheme.style),
    ),
    textButtonTheme: TextButtonThemeData(
      style: tune(
        base.textButtonTheme.style,
        padding: const EdgeInsets.symmetric(horizontal: 12),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: tune(base.elevatedButtonTheme.style),
    ),
    // Inputs are left to the widgets: the composer wants a borderless field
    // inside its own frame, the search pills want a filled borderless look, and
    // dialogs want the default outline. Just tighten the default density.
    inputDecorationTheme: base.inputDecorationTheme.copyWith(
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    ),
    extensions: [DesktopTokens.of(scheme)],
  );
}
