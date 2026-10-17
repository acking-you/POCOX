import 'package:flutter/material.dart';
import 'package:pocket_codex/src/theme.dart';

/// The POCOX brand mark: the bare "cloud terminal" glyph.
///
/// Two theme-matched variants ship in the bundle (drawn from the vector mark
/// by `test/gen_icon_test.dart`): `glyph_light.png` (ink cloud, blue arcs) for
/// light themes and `glyph_dark.png` (white cloud, pale blue arcs) for dark
/// themes. The glyph carries no tile — a rounded launcher
/// tile dropped into a page reads as a pasted app icon, while the bare glyph
/// sits on any surface like an ordinary illustration.
class BrandLogo extends StatelessWidget {
  /// Default constructor.
  const BrandLogo({super.key, this.size = 96});

  /// Edge length of the (square) widget.
  final double size;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Image.asset(
      dark ? 'assets/logo/glyph_dark.png' : 'assets/logo/glyph_light.png',
      width: size,
      height: size,
      filterQuality: FilterQuality.medium,
    );
  }
}

/// A headline painted in the brand spectrum — the greeting on a first-run or
/// sign-in page. Reserved for those moments; ordinary titles stay in ink.
class BrandHeadline extends StatelessWidget {
  /// Paints [text] in the brand gradient.
  const BrandHeadline(this.text, {super.key, this.style, this.textAlign});

  /// The words.
  final String text;

  /// Overrides the default headline style (colour is ignored).
  final TextStyle? style;

  /// Alignment within the line.
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final gradient = brandGradient(theme.colorScheme);
    return ShaderMask(
      blendMode: BlendMode.srcIn,
      shaderCallback: gradient.createShader,
      child: Text(
        text,
        textAlign: textAlign,
        style: (style ?? theme.textTheme.headlineMedium)?.copyWith(
          color: Colors.white,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.4,
        ),
      ),
    );
  }
}
