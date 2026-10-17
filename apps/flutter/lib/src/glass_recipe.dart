import 'package:flutter/material.dart';

/// How far a glass surface floats, which decides its recipe.
enum GlassDepth {
  /// Controls drawn on the backdrop or a sheet: a selected row, a capsule
  /// button. No blur; a light shadow.
  chrome,

  /// Controls floating over moving content: the composer, the
  /// jump-to-latest pill. Blurs what scrolls beneath.
  floating,

  /// Surfaces over the whole page: popovers and dialogs.
  overlay,
}

/// One glass surface's recipe: a translucent [fill], a [sheen] that brightens
/// its top, a rim lit from the top-left ([rimLight]) fading to [rimShade], an
/// outer [hairline] that keeps the edge on light ground, the backdrop
/// [blur], and the [shadows] cast outside it (never under it, where they
/// would grey the glass).
@immutable
class GlassRecipe {
  /// Creates a recipe.
  const GlassRecipe({
    required this.fill,
    required this.sheen,
    required this.rimLight,
    required this.rimShade,
    required this.hairline,
    required this.blur,
    required this.shadows,
  });

  /// The translucent body.
  final Color fill;

  /// The highlight washed down from the top edge.
  final Color sheen;

  /// The rim where the light catches it.
  final Color rimLight;

  /// The rim away from the light.
  final Color rimShade;

  /// The outermost edge.
  final Color hairline;

  /// Backdrop blur sigma; zero for none.
  final double blur;

  /// Shadows cast outside the surface.
  final List<BoxShadow> shadows;
}

/// The [GlassRecipe] for [depth] in [scheme]; [lift] scales the shadow.
GlassRecipe glassRecipe(
  ColorScheme scheme,
  GlassDepth depth, {
  double lift = 1,
}) {
  final light = scheme.brightness == Brightness.light;
  // Shadows stay neutral: a tinted shadow colours everything around a
  // floating control.
  BoxShadow shadow(double alpha, double blur, double y) => BoxShadow(
    color: Colors.black.withValues(alpha: alpha),
    blurRadius: blur,
    offset: Offset(0, y),
  );
  if (light) {
    return switch (depth) {
      GlassDepth.chrome => GlassRecipe(
        fill: Colors.white.withValues(alpha: 0.66),
        sheen: Colors.white.withValues(alpha: 0.5),
        rimLight: Colors.white.withValues(alpha: 0.95),
        rimShade: Colors.white.withValues(alpha: 0.35),
        hairline: Colors.black.withValues(alpha: 0.06),
        blur: 0,
        shadows: [
          shadow(0.05, 2, 1),
          shadow(0.045 * lift, 12 * lift, 3 * lift),
        ],
      ),
      GlassDepth.floating => GlassRecipe(
        fill: Colors.white.withValues(alpha: 0.6),
        sheen: Colors.white.withValues(alpha: 0.55),
        rimLight: Colors.white,
        rimShade: Colors.white.withValues(alpha: 0.4),
        hairline: Colors.black.withValues(alpha: 0.07),
        blur: 24,
        shadows: [
          shadow(0.05, 3, 1),
          shadow(0.09 * lift, 36 * lift, 14 * lift),
        ],
      ),
      GlassDepth.overlay => GlassRecipe(
        fill: Colors.white.withValues(alpha: 0.80),
        sheen: Colors.white.withValues(alpha: 0.6),
        rimLight: Colors.white,
        rimShade: Colors.white.withValues(alpha: 0.45),
        hairline: Colors.black.withValues(alpha: 0.08),
        blur: 28,
        shadows: [
          shadow(0.06, 4, 1),
          shadow(0.11 * lift, 48 * lift, 20 * lift),
        ],
      ),
    };
  }
  return switch (depth) {
    GlassDepth.chrome => GlassRecipe(
      fill: Colors.white.withValues(alpha: 0.075),
      sheen: Colors.white.withValues(alpha: 0.06),
      rimLight: Colors.white.withValues(alpha: 0.17),
      rimShade: Colors.white.withValues(alpha: 0.03),
      hairline: Colors.black.withValues(alpha: 0.35),
      blur: 0,
      shadows: [shadow(0.35 * lift, 10 * lift, 3 * lift)],
    ),
    GlassDepth.floating => GlassRecipe(
      fill: const Color(0xFF28282B).withValues(alpha: 0.62),
      sheen: Colors.white.withValues(alpha: 0.07),
      rimLight: Colors.white.withValues(alpha: 0.2),
      rimShade: Colors.white.withValues(alpha: 0.04),
      hairline: Colors.black.withValues(alpha: 0.55),
      blur: 26,
      shadows: [shadow(0.4, 6, 2), shadow(0.5 * lift, 40 * lift, 16 * lift)],
    ),
    GlassDepth.overlay => GlassRecipe(
      fill: const Color(0xFF252528).withValues(alpha: 0.84),
      sheen: Colors.white.withValues(alpha: 0.07),
      rimLight: Colors.white.withValues(alpha: 0.2),
      rimShade: Colors.white.withValues(alpha: 0.05),
      hairline: Colors.black.withValues(alpha: 0.6),
      blur: 30,
      shadows: [shadow(0.45, 6, 2), shadow(0.6 * lift, 56 * lift, 24 * lift)],
    ),
  };
}
