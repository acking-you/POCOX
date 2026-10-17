import 'package:flutter/material.dart';
import 'package:pocket_codex/src/desktop_theme.dart';
import 'package:pocket_codex/src/fonts.dart';
import 'package:pocket_codex/src/motion.dart';
import 'package:pocket_codex/src/widgets/glass.dart';

export 'package:pocket_codex/src/glass_recipe.dart';

/// Calm graphite neutrals, ink controls and one blue "signal".
///
/// Comfort over a long session decides every value: the neutrals carry no
/// blue or violet cast (a tint is what the eye keeps adapting to), the page
/// is a soft off-white rather than pure white, and only one hue appears
/// often. Controls are drawn in ink — a filled pill, the send action — so
/// colour stays free for meaning: the blue signal (taken from the logo's
/// relay arcs) marks what is live, and success / caution / error / info keep
/// their own hues, so a running turn never looks like a healthy service or a
/// diff addition. No purple anywhere.
///
/// Text roles are tuned for contrast on every ground they sit on:
/// `onSurfaceVariant` stays above 4.5:1 for small secondary text on the page,
/// the sidebar and raised panels, while `outline` is a border colour only and
/// must not carry text.
ColorScheme _flowScheme(Brightness brightness) {
  final light = brightness == Brightness.light;
  const ink = Color(0xFF1D1D1F);
  const paper = Color(0xFFE6E6E6);
  return ColorScheme.fromSeed(
    seedColor: const Color(0xFF2A52C4),
    brightness: brightness,
  ).copyWith(
    primary: light ? ink : paper,
    onPrimary: light ? Colors.white : const Color(0xFF19191B),
    primaryContainer: light ? const Color(0xFFE6E6E4) : const Color(0xFF333336),
    onPrimaryContainer: light ? ink : paper,
    secondary: light ? const Color(0xFF4A4A4D) : const Color(0xFFBDBDC0),
    onSecondary: light ? Colors.white : const Color(0xFF19191B),
    secondaryContainer: light
        ? const Color(0xFFE6E6E4)
        : const Color(0xFF333336),
    onSecondaryContainer: light ? ink : paper,
    tertiary: light ? const Color(0xFF2A52C4) : const Color(0xFF8EAAF2),
    onTertiary: light ? Colors.white : const Color(0xFF14245C),
    tertiaryContainer: light
        ? const Color(0xFFE8EDFA)
        : const Color(0xFF222B45),
    onTertiaryContainer: light
        ? const Color(0xFF1D3B94)
        : const Color(0xFFD5DEFC),
    surface: light ? const Color(0xFFFBFBFA) : const Color(0xFF19191B),
    surfaceBright: light ? Colors.white : const Color(0xFF27272A),
    surfaceDim: light ? const Color(0xFFEDEDEB) : const Color(0xFF141416),
    onSurface: light ? ink : paper,
    onSurfaceVariant: light ? const Color(0xFF4A4A4D) : const Color(0xFFBDBDC0),
    surfaceContainerLowest: light ? Colors.white : const Color(0xFF141416),
    surfaceContainerLow: light
        ? const Color(0xFFF4F4F2)
        : const Color(0xFF202022),
    surfaceContainer: light ? const Color(0xFFEDEDEB) : const Color(0xFF262628),
    surfaceContainerHigh: light
        ? const Color(0xFFE6E6E4)
        : const Color(0xFF2E2E31),
    surfaceContainerHighest: light
        ? const Color(0xFFDEDEDC)
        : const Color(0xFF38383B),
    outline: light ? const Color(0xFFC8C8C6) : const Color(0xFF4C4C50),
    outlineVariant: light ? const Color(0xFFE4E4E2) : const Color(0xFF313134),
    inverseSurface: light ? const Color(0xFF2B2B2E) : const Color(0xFFE6E6E6),
    onInverseSurface: light ? const Color(0xFFF2F2F2) : ink,
    inversePrimary: light ? const Color(0xFFAFC2F6) : const Color(0xFF2A52C4),
    // No elevation tint: a raised surface is told apart by tone and shadow.
    surfaceTint: Colors.transparent,
    error: light ? const Color(0xFFB3261E) : const Color(0xFFF2B8B5),
    onError: light ? Colors.white : const Color(0xFF601410),
    errorContainer: light ? const Color(0xFFFCE8E6) : const Color(0xFF3F1F1D),
    onErrorContainer: light ? const Color(0xFF8C1D18) : const Color(0xFFF9DEDC),
  );
}

/// The brand's blues, from the logo's tile, as a left-to-right gradient — for
/// the few moments that are about the app itself rather than about status
/// (the greeting on a first-run or sign-in page). Never a fill for a control.
LinearGradient brandGradient(ColorScheme scheme) => LinearGradient(
  begin: Alignment.centerLeft,
  end: Alignment.centerRight,
  colors: scheme.brightness == Brightness.light
      ? const [Color(0xFF4F7DF2), Color(0xFF2443B0)]
      : const [Color(0xFFA9BFF7), Color(0xFF6F8FEA)],
);

/// Ink for secondary chrome glyphs: placeholders, carets, quiet icons. Text
/// that must be read uses `onSurfaceVariant` instead, which keeps contrast on
/// the raised panels too.
Color onSurfaceMuted(ColorScheme scheme) =>
    scheme.onSurface.withValues(alpha: 0.55);

/// Ink at 30% — disabled content, like a send button that can't send.
Color onSurfaceDisabled(ColorScheme scheme) =>
    scheme.onSurface.withValues(alpha: 0.3);

/// The live signal: a running turn, a conversation working in the background,
/// the composer while the agent answers. Nothing else is drawn in it, which is
/// what lets one blue dot in a sidebar of grey rows say "this is working".
Color signalColor(ColorScheme scheme) => scheme.tertiary;

/// Dictation: the microphone turning speech into the draft. Teal, apart from
/// the blue of a live voice call, so the two never read as the same thing
/// when both are on screen.
Color dictationColor(ColorScheme scheme) =>
    scheme.brightness == Brightness.light
    ? const Color(0xFF0B7A83)
    : const Color(0xFF52C6CE);

/// Ink on [dictationColor].
Color onDictationColor(ColorScheme scheme) =>
    scheme.brightness == Brightness.light
    ? Colors.white
    : const Color(0xFF00363A);

/// Additions, in a diff or a change count. `+`/`−` is a convention older than
/// any palette — a diff whose additions aren't green reads wrong. Its
/// counterpart is `ColorScheme.error`.
Color additionColor(ColorScheme scheme) => scheme.brightness == Brightness.light
    ? const Color(0xFF1A7F37)
    : const Color(0xFF57C27A);

/// Caution — degraded but not failed: reconnecting, plan mode, a risky
/// permission, a quota running low. Genuine failure uses `ColorScheme.error`.
Color cautionColor(ColorScheme scheme) => scheme.brightness == Brightness.light
    ? const Color(0xFF9A5B00)
    : const Color(0xFFE0A647);

/// Healthy — a service online, a subscription alive, a host running. Kept a
/// separate function rather than calling [additionColor] at the status sites,
/// because a diff's additions and a service's health are different meanings —
/// retuning one must not move the other.
Color successColor(ColorScheme scheme) => additionColor(scheme);

/// Informational — a log line that is neither a problem nor a result.
Color infoColor(ColorScheme scheme) => scheme.brightness == Brightness.light
    ? const Color(0xFF1F63BC)
    : const Color(0xFF74A9EC);

/// A thin, rounded scrollbar shared by both themes — the macOS overlay style
/// rather than Material's chunky default.
final _scrollbarTheme = ScrollbarThemeData(
  thickness: WidgetStateProperty.resolveWith(
    (states) => states.contains(WidgetState.hovered) ? 8.0 : 6.0,
  ),
  radius: const Radius.circular(4),
  crossAxisMargin: 2,
  mainAxisMargin: 2,
);

/// The window/scaffold background: the page itself, opaque in both themes.
Color surfaceBackground(ColorScheme scheme) => scheme.surface;

/// An opaque raised panel shared by cards, sheets, menus and the composer.
Color surfacePanel(ColorScheme scheme) => scheme.surfaceBright;

/// The plate behind a code block: a half step off the page.
Color codeSurface(ColorScheme scheme) => scheme.brightness == Brightness.light
    ? const Color(0xFFF3F3F1)
    : const Color(0xFF202022);

/// A grouped card's ground (settings groups, device cards): a soft fill with
/// no outline, so groups read as calm plates on the page.
Color cardFill(ColorScheme scheme) => scheme.brightness == Brightness.light
    ? const Color(0xFFF3F3F1)
    : scheme.surfaceContainer;

/// A plate set inside a [cardFill] group: the page's own white in light, a
/// lifted tone in dark.
Color insetPlate(ColorScheme scheme) => scheme.brightness == Brightness.light
    ? Colors.white
    : scheme.surfaceContainerHigh;

/// The sidebar ground: a step off the page, like a macOS source list.
Color surfaceSidebar(ColorScheme scheme) => scheme.surfaceContainerLow;

/// Selected row in a list laid on the backdrop or a grouped sheet: a pane of
/// chrome glass (see [GlassDepth.chrome]) — white and lit in light, a faint
/// lift in dark. Selection is position, not status, so it takes no colour.
Color surfaceSelection(ColorScheme scheme) =>
    scheme.brightness == Brightness.light
    ? Colors.white.withValues(alpha: 0.82)
    : Colors.white.withValues(alpha: 0.09);

/// A highlighted row in a picker: the same neutral plate as a selection.
Color selectedRowColor(ColorScheme scheme) => scheme.surfaceContainerHigh;

/// The open conversation in the sidebar: the same glass pane as
/// [surfaceSelection], raised off the backdrop by [sidebarSelectionShadow]
/// and lit along [sidebarSelectionEdge].
Color sidebarSelection(ColorScheme scheme) => surfaceSelection(scheme);

/// The lit rim of [sidebarSelection].
Color sidebarSelectionEdge(ColorScheme scheme) =>
    scheme.brightness == Brightness.light
    ? Colors.white
    : Colors.white.withValues(alpha: 0.08);

/// The shadow under [sidebarSelection].
Color sidebarSelectionShadow(ColorScheme scheme) =>
    scheme.brightness == Brightness.light
    ? Colors.black.withValues(alpha: 0.16)
    : Colors.black.withValues(alpha: 0.8);

/// The pointer's wash over a row on the backdrop: the row brightens toward
/// glass rather than greying.
Color backdropHover(ColorScheme scheme) => scheme.brightness == Brightness.light
    ? Colors.white.withValues(alpha: 0.5)
    : Colors.white.withValues(alpha: 0.05);

/// A search or filter well laid on the backdrop: frosted, not grey.
Color backdropFieldFill(ColorScheme scheme) =>
    scheme.brightness == Brightness.light
    ? Colors.white.withValues(alpha: 0.5)
    : Colors.white.withValues(alpha: 0.06);

/// A faint neutral wash: a highlighted option, a selected step, a chip that
/// is "on" without being a status.
Color softWash(ColorScheme scheme, {double strength = 1}) =>
    scheme.onSurface.withValues(
      alpha: (scheme.brightness == Brightness.light ? 0.06 : 0.09) * strength,
    );

/// Ink for inline code in prose: the text's own ink, a shade softer. The
/// monospace face and the plate already set an identifier apart; a coloured
/// ink repeated through a technical answer only adds noise.
Color inlineCodeColor(ColorScheme scheme) =>
    scheme.brightness == Brightness.light
    ? const Color(0xFF3A3A3D)
    : const Color(0xFFDADADC);

/// The plate behind inline code: a neutral container step, not a tint.
Color inlineCodeWash(ColorScheme scheme) => scheme.surfaceContainerHigh;

/// The user's own turn: a soft neutral bubble, one container step off the
/// page.
Color userBubbleColor(ColorScheme scheme) =>
    scheme.brightness == Brightness.light
    ? const Color(0xFFEDEDEB)
    : const Color(0xFF262628);

/// The well of a text field: a step darker than both the page and cards, so
/// a field reads without an outline on either.
Color fieldFill(ColorScheme scheme) => scheme.brightness == Brightness.light
    ? const Color(0xFFEAEAE8)
    : const Color(0xFF29292C);

/// The ground of everything that floats over the page: popovers, menus and
/// dialogs.
Color floatingSurface(ColorScheme scheme) =>
    scheme.brightness == Brightness.light
    ? Colors.white
    : scheme.surfaceContainerHigh;

/// The two-layer shadow under floating surfaces: a wide, soft ambient layer
/// for lift plus a tight contact layer that keeps the edge crisp on a light
/// page (a single blur either smudges or vanishes).
List<BoxShadow> floatingShadows(ColorScheme scheme, {double lift = 1}) {
  final light = scheme.brightness == Brightness.light;
  return [
    BoxShadow(
      color: Colors.black.withValues(alpha: (light ? 0.10 : 0.40) * lift),
      blurRadius: 32 * lift,
      offset: Offset(0, 12 * lift),
    ),
    BoxShadow(
      color: Colors.black.withValues(alpha: light ? 0.06 : 0.30),
      blurRadius: 3,
      offset: const Offset(0, 1),
    ),
  ];
}

/// The hairline that outlines floating surfaces in dark mode, where shadows
/// alone disappear into the ground.
Color floatingEdge(ColorScheme scheme) => scheme.brightness == Brightness.light
    ? Colors.black.withValues(alpha: 0.05)
    : Colors.white.withValues(alpha: 0.07);

/// The window's own ground, behind the sidebar and the content sheet: a
/// neutral a step below the page, lit from above by [backdropGlows] so the
/// glass laid over it has light to catch.
Color backdropBase(ColorScheme scheme) => scheme.brightness == Brightness.light
    ? const Color(0xFFEAEAE8)
    : const Color(0xFF0F0F10);

/// Soft light painted on [backdropBase]: brighter at the top, fading below.
/// Light only, never a hue — colour pooled in the corner of the eye for a
/// whole session is what makes a screen tiring to look at. Each is a radial
/// wash whose radius is a fraction of the window's shorter side.
List<({Alignment center, double radius, Color color})> backdropGlows(
  ColorScheme scheme,
) => scheme.brightness == Brightness.light
    ? const [
        (center: Alignment(-1.0, -1.15), radius: 1.2, color: Color(0x73FFFFFF)),
        (center: Alignment(1.1, -0.9), radius: 0.9, color: Color(0x40FFFFFF)),
      ]
    : const [
        (center: Alignment(-1.0, -1.15), radius: 1.2, color: Color(0x0FFFFFFF)),
      ];

/// The content sheet laid over the backdrop: white for reading (the chat),
/// a grouped grey for pages of cards (settings, services) so their white
/// cards lift off it.
Color sheetColor(ColorScheme scheme, {bool grouped = false}) =>
    scheme.brightness == Brightness.light
    ? (grouped ? const Color(0xFFF4F4F2) : scheme.surface)
    : (grouped ? const Color(0xFF151517) : scheme.surface);

/// The hairline that keeps the sheet's edge crisp against the backdrop.
Color sheetEdge(ColorScheme scheme) => scheme.brightness == Brightness.light
    ? Colors.black.withValues(alpha: 0.06)
    : Colors.white.withValues(alpha: 0.07);

/// The sheet's lift off the backdrop: a contact shadow plus a wide ambient
/// one.
List<BoxShadow> sheetShadows(ColorScheme scheme) =>
    scheme.brightness == Brightness.light
    ? [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.05),
          blurRadius: 2,
          offset: const Offset(0, 1),
        ),
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.07),
          blurRadius: 30,
          offset: const Offset(0, 10),
        ),
      ]
    : [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.5),
          blurRadius: 30,
          offset: const Offset(0, 12),
        ),
      ];

/// A white card on a grouped sheet: the card itself.
Color raisedCardColor(ColorScheme scheme) =>
    scheme.brightness == Brightness.light
    ? Colors.white
    : const Color(0xFF212124);

/// The hairline around a [raisedCardColor] card.
Color raisedCardEdge(ColorScheme scheme) =>
    scheme.brightness == Brightness.light
    ? Colors.black.withValues(alpha: 0.05)
    : Colors.white.withValues(alpha: 0.06);

/// The soft lift under a [raisedCardColor] card.
List<BoxShadow> raisedCardShadows(ColorScheme scheme) =>
    scheme.brightness == Brightness.light
    ? [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.04),
          blurRadius: 2,
          offset: const Offset(0, 1),
        ),
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.045),
          blurRadius: 16,
          offset: const Offset(0, 4),
        ),
      ]
    : [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.35),
          blurRadius: 12,
          offset: const Offset(0, 4),
        ),
      ];

/// The type scale, mapped onto Material's roles.
///
/// Five steps do nearly all the work — 11 (captions), 12 (secondary), 13
/// (controls and rows), 14 (reading), 15 (the composer) — with titles above.
/// Paragraphs use generous line height; single-line controls stay compact.
///
/// The `label` roles are deliberately left at Material's defaults: `labelLarge`
/// is what every Material button renders its text in, and the button themes
/// are measured for it.
///
/// Tracking is set on every other role: Material's defaults (0.25-0.5 on
/// body text) are tuned for Roboto and spread Google Sans Flex and CJK text
/// apart. Every bare `TextStyle(fontSize: …)` inherits `bodyMedium`'s.
TextTheme _textTheme(ColorScheme scheme) {
  TextStyle t(
    double size,
    double height, [
    FontWeight w = FontWeight.w400,
    double tracking = 0,
  ]) => TextStyle(
    fontSize: size,
    height: height,
    fontWeight: w,
    letterSpacing: tracking,
  );

  return TextTheme(
    displayLarge: t(48, 1.12, FontWeight.w400, -0.5),
    displayMedium: t(40, 1.15, FontWeight.w400, -0.4),
    displaySmall: t(34, 1.18, FontWeight.w400, -0.3),
    headlineLarge: t(30, 1.2, FontWeight.w600, -0.3),
    headlineMedium: t(26, 1.22, FontWeight.w600, -0.2),
    headlineSmall: t(22, 1.25, FontWeight.w600, -0.1),
    titleLarge: t(19, 1.3, FontWeight.w600, -0.1),
    titleMedium: t(16, 1.35, FontWeight.w600),
    titleSmall: t(13, 1.4, FontWeight.w600),
    bodyLarge: t(15, 1.6),
    bodyMedium: t(14, 1.5),
    bodySmall: t(12, 1.45, FontWeight.w400, 0.1),
  ).apply(
    fontFamily: uiFontFamily,
    fontFamilyFallback: uiCjkFallback,
    bodyColor: scheme.onSurface,
    displayColor: scheme.onSurface,
  );
}

/// Base Material 3 theme for [scheme] — shared by mobile and desktop; the
/// desktop layer re-tunes density/hover on top (see `desktop_theme.dart`).
///
/// Shape language: every button is a pill, every icon button a circle,
/// panels are generously rounded and lift by tone rather than by outline.
ThemeData _base(ColorScheme scheme) {
  final background = surfaceBackground(scheme);
  final panel = surfacePanel(scheme);
  final radius = BorderRadius.circular(kPanelRadius);
  final light = scheme.brightness == Brightness.light;
  TextStyle ui(
    double size, {
    FontWeight weight = FontWeight.w500,
    Color? color,
  }) => TextStyle(
    fontSize: size,
    fontWeight: weight,
    color: color,
    letterSpacing: 0.1,
    fontFamily: uiFontFamily,
    fontFamilyFallback: uiCjkFallback,
  );
  const pill = StadiumBorder();
  final floatShadow = Colors.black.withValues(alpha: light ? 0.14 : 0.5);
  final menuColor = floatingSurface(scheme);
  final menuShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(kMenuRadius),
    side: BorderSide(color: floatingEdge(scheme)),
  );
  final fieldRadius = BorderRadius.circular(kFieldRadius);
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    fontFamily: uiFontFamily,
    fontFamilyFallback: uiCjkFallback,
    textTheme: _textTheme(scheme),
    scaffoldBackgroundColor: background,
    canvasColor: background,
    pageTransitionsTheme: appPageTransitions,
    splashFactory: InkSparkle.constantTurbulenceSeedSplashFactory,
    hoverColor: scheme.onSurface.withValues(alpha: 0.05),
    highlightColor: scheme.onSurface.withValues(alpha: 0.06),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant,
      thickness: 1,
      space: 1,
    ),
    // Buttons are lit capsules: the fill comes from the variant (ink for the
    // filled action, a container tone for tonal), and [LitFace] lays a sheen
    // and a top highlight over it, with a soft shadow that rises on hover and
    // settles when pressed, so the control reads as a raised piece of glass
    // rather than a flat shape.
    filledButtonTheme: FilledButtonThemeData(
      style:
          FilledButton.styleFrom(
            minimumSize: const Size(48, 46),
            padding: const EdgeInsets.symmetric(horizontal: 22),
            shape: pill,
            textStyle: ui(14.5, weight: FontWeight.w600),
          ).copyWith(
            elevation: WidgetStateProperty.resolveWith(
              (states) =>
                  states.contains(WidgetState.disabled) ||
                      states.contains(WidgetState.pressed)
                  ? 0
                  : states.contains(WidgetState.hovered)
                  ? 3
                  : 1,
            ),
            shadowColor: WidgetStatePropertyAll(
              light ? Colors.black.withValues(alpha: 0.38) : Colors.black,
            ),
            backgroundBuilder: (context, states, child) =>
                LitFace(states: states, child: child),
          ),
    ),
    // The secondary action is a pane of chrome glass: translucent white, lit
    // along its rim, edged by a hairline so it holds on a white card too.
    outlinedButtonTheme: OutlinedButtonThemeData(
      style:
          OutlinedButton.styleFrom(
            minimumSize: const Size(48, 46),
            padding: const EdgeInsets.symmetric(horizontal: 20),
            foregroundColor: scheme.onSurface,
            shape: pill,
            textStyle: ui(14.5),
          ).copyWith(
            backgroundColor: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.disabled)) {
                return Colors.transparent;
              }
              final strong =
                  states.contains(WidgetState.hovered) ||
                  states.contains(WidgetState.pressed);
              return light
                  ? Colors.white.withValues(alpha: strong ? 0.95 : 0.7)
                  : Colors.white.withValues(alpha: strong ? 0.12 : 0.07);
            }),
            side: WidgetStateProperty.resolveWith(
              (states) => BorderSide(
                color: states.contains(WidgetState.disabled)
                    ? scheme.outlineVariant
                    : light
                    ? Colors.black.withValues(alpha: 0.09)
                    : Colors.white.withValues(alpha: 0.12),
              ),
            ),
            elevation: WidgetStateProperty.resolveWith(
              (states) =>
                  states.contains(WidgetState.hovered) &&
                      !states.contains(WidgetState.pressed)
                  ? 2
                  : 0,
            ),
            shadowColor: WidgetStatePropertyAll(
              light ? Colors.black.withValues(alpha: 0.22) : Colors.black,
            ),
            overlayColor: WidgetStateProperty.resolveWith(
              (states) => states.contains(WidgetState.pressed)
                  ? scheme.onSurface.withValues(alpha: 0.06)
                  : Colors.transparent,
            ),
            backgroundBuilder: (context, states, child) =>
                LitFace(states: states, glass: true, child: child),
          ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(48, 44),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        foregroundColor: scheme.onSurface,
        shape: pill,
        textStyle: ui(14.5),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        minimumSize: const Size(48, 46),
        elevation: 0,
        backgroundColor: scheme.surfaceContainerHigh,
        foregroundColor: scheme.onSurface,
        shape: pill,
        textStyle: ui(14.5),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        minimumSize: const Size(44, 44),
        foregroundColor: scheme.onSurfaceVariant,
        shape: const CircleBorder(),
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        shape: pill,
        side: BorderSide(color: scheme.outlineVariant),
        selectedBackgroundColor: scheme.surfaceContainerHigh,
        selectedForegroundColor: scheme.onSurface,
        foregroundColor: scheme.onSurfaceVariant,
        textStyle: ui(13),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: Colors.transparent,
      selectedColor: scheme.surfaceContainerHigh,
      checkmarkColor: scheme.onSurface,
      side: BorderSide(color: scheme.outlineVariant),
      shape: pill,
      // An explicit style replaces the theme's font, so it carries the UI
      // family and CJK fallback itself (chip labels such as the hosting
      // provider picker otherwise render in the platform default).
      labelStyle: ui(12.5, weight: FontWeight.w500, color: scheme.onSurface),
      padding: const EdgeInsets.symmetric(horizontal: 6),
    ),
    // Fields are soft filled wells with no outline at rest; focus draws a
    // firm ink ring. One look for every form, search and prompt field.
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: fieldFill(scheme),
      hoverColor: scheme.onSurface.withValues(alpha: 0.03),
      // Filled, not outlined: a floating label stays inside the fill.
      border: FieldBorder(borderRadius: fieldRadius),
      enabledBorder: FieldBorder(borderRadius: fieldRadius),
      disabledBorder: FieldBorder(borderRadius: fieldRadius),
      focusedBorder: FieldBorder(
        borderRadius: fieldRadius,
        borderSide: BorderSide(
          color: scheme.onSurface.withValues(alpha: light ? 0.5 : 0.55),
          width: 1.5,
        ),
        glow: scheme.tertiary.withValues(alpha: light ? 0.16 : 0.28),
      ),
      errorBorder: FieldBorder(
        borderRadius: fieldRadius,
        borderSide: BorderSide(color: scheme.error.withValues(alpha: 0.7)),
      ),
      focusedErrorBorder: FieldBorder(
        borderRadius: fieldRadius,
        borderSide: BorderSide(color: scheme.error, width: 1.5),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      hintStyle: TextStyle(color: onSurfaceMuted(scheme), fontSize: 14),
      labelStyle: TextStyle(color: scheme.onSurfaceVariant),
      floatingLabelStyle: TextStyle(
        color: scheme.onSurfaceVariant,
        fontWeight: FontWeight.w500,
      ),
      helperStyle: TextStyle(
        color: scheme.onSurfaceVariant,
        fontSize: 12.5,
        height: 1.45,
      ),
      errorStyle: TextStyle(color: scheme.error, fontSize: 12.5, height: 1.45),
      // A field's problem wraps rather than ending in an ellipsis.
      helperMaxLines: 3,
      errorMaxLines: 3,
      prefixIconColor: scheme.onSurfaceVariant,
      suffixIconColor: scheme.onSurfaceVariant,
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: scheme.onSurface,
      selectionColor: scheme.tertiary.withValues(alpha: light ? 0.22 : 0.35),
      selectionHandleColor: scheme.tertiary,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: scheme.onSurfaceVariant,
      linearTrackColor: scheme.surfaceContainerHighest,
      circularTrackColor: Colors.transparent,
      borderRadius: BorderRadius.circular(4),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? scheme.onPrimary
            : scheme.outline,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? scheme.primary
            : scheme.surfaceContainerHighest,
      ),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      thumbIcon: const WidgetStatePropertyAll(null),
    ),
    checkboxTheme: CheckboxThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
      side: BorderSide(color: scheme.outline, width: 1.5),
    ),
    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? scheme.primary
            : scheme.outline,
      ),
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: scheme.primary,
      inactiveTrackColor: scheme.surfaceContainerHighest,
      thumbColor: scheme.primary,
      trackHeight: 4,
    ),
    listTileTheme: ListTileThemeData(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kControlRadius),
      ),
      iconColor: scheme.onSurfaceVariant,
      titleTextStyle: ui(
        14.5,
        weight: FontWeight.w400,
        color: scheme.onSurface,
      ),
      subtitleTextStyle: ui(
        12.5,
        weight: FontWeight.w400,
        color: scheme.onSurfaceVariant,
      ),
      minLeadingWidth: 20,
    ),
    // Dialogs open over a blurred, dimmed page (see `showAppDialog`), so a
    // slightly translucent body reads as frosted glass; the rim is lit.
    dialogTheme: DialogThemeData(
      backgroundColor: light
          ? Colors.white.withValues(alpha: 0.9)
          : const Color(0xFF252528).withValues(alpha: 0.92),
      surfaceTintColor: Colors.transparent,
      elevation: 24,
      shadowColor: floatShadow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kDialogRadius),
        side: BorderSide(
          color: light ? Colors.white : Colors.white.withValues(alpha: 0.1),
        ),
      ),
      titleTextStyle: ui(18, weight: FontWeight.w600, color: scheme.onSurface),
      contentTextStyle: ui(
        14,
        weight: FontWeight.w400,
        color: scheme.onSurfaceVariant,
      ).copyWith(height: 1.55),
      actionsPadding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
      insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
    ),
    popupMenuTheme: PopupMenuThemeData(
      elevation: 10,
      shadowColor: floatShadow,
      color: menuColor,
      surfaceTintColor: Colors.transparent,
      shape: menuShape,
      menuPadding: const EdgeInsets.all(6),
      textStyle: ui(14, weight: FontWeight.w400, color: scheme.onSurface),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        elevation: const WidgetStatePropertyAll(10),
        shadowColor: WidgetStatePropertyAll(floatShadow),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        backgroundColor: WidgetStatePropertyAll(menuColor),
        shape: WidgetStatePropertyAll(menuShape),
        padding: const WidgetStatePropertyAll(EdgeInsets.all(6)),
      ),
    ),
    menuButtonTheme: MenuButtonThemeData(
      style: MenuItemButton.styleFrom(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(kControlRadius),
        ),
        minimumSize: const Size(0, 40),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        textStyle: ui(14, weight: FontWeight.w400),
      ),
    ),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 450),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: scheme.inverseSurface,
        borderRadius: BorderRadius.circular(8),
      ),
      textStyle: ui(
        12,
        weight: FontWeight.w500,
        color: scheme.onInverseSurface,
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: light ? Colors.white : scheme.surfaceContainer,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      dragHandleColor: scheme.outline,
      dragHandleSize: const Size(36, 4),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
    ),
    scrollbarTheme: _scrollbarTheme,
    // A flat app bar that blends into the content: same colour as the
    // scaffold, no Material-3 scroll tint, no elevation. With the native title
    // bar hidden on desktop, the app bar reads as part of the window itself.
    appBarTheme: AppBarTheme(
      backgroundColor: background,
      foregroundColor: scheme.onSurface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: ui(17, weight: FontWeight.w600, color: scheme.onSurface),
    ),
    // Cards are white panes raised off a grouped sheet (see `ContentSheet`),
    // edged by a hairline; `GroupCard` adds their soft shadow.
    cardTheme: CardThemeData(
      elevation: 0,
      color: raisedCardColor(scheme),
      surfaceTintColor: Colors.transparent,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kCardRadius),
        side: BorderSide(color: raisedCardEdge(scheme)),
      ),
    ),
    drawerTheme: DrawerThemeData(
      backgroundColor: surfaceSidebar(scheme),
      surfaceTintColor: Colors.transparent,
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: Colors.transparent,
      indicatorColor: scheme.surfaceContainerHigh,
      indicatorShape: pill,
      selectedIconTheme: IconThemeData(color: scheme.onSurface, size: 20),
      unselectedIconTheme: IconThemeData(
        color: scheme.onSurfaceVariant,
        size: 20,
      ),
      selectedLabelTextStyle: ui(
        12,
        weight: FontWeight.w600,
        color: scheme.onSurface,
      ),
      unselectedLabelTextStyle: ui(
        12,
        weight: FontWeight.w400,
        color: scheme.onSurfaceVariant,
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: panel,
      surfaceTintColor: Colors.transparent,
      indicatorColor: scheme.surfaceContainerHigh,
      indicatorShape: pill,
      elevation: 0,
    ),
    iconTheme: IconThemeData(color: scheme.onSurfaceVariant, size: 20),
    // A fallback for any snack bar raised outside `app_toast.dart`, which draws
    // its own surface and ignores this.
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: radius),
    ),
  );
}

/// Add desktop density and pointer feedback to the shared touch-ready theme.
ThemeData _forPlatform(ThemeData base) => isDesktop ? desktopize(base) : base;

/// Light theme (desktop-tuned on desktop).
ThemeData lightTheme() => _forPlatform(_base(_flowScheme(Brightness.light)));

/// Dark theme (desktop-tuned on desktop).
ThemeData darkTheme() => _forPlatform(_base(_flowScheme(Brightness.dark)));
