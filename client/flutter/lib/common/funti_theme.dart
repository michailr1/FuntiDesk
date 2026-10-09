// FUNTIDESK: product design tokens.
//
// Single source of truth for the FuntiDesk colour palette. Neutrals are
// taken from Funtik's silver-beige fur, the accent from the FuntiDesk shield
// mark, the "online" green is a muted natural green. Both themes are defined
// here; widgets read them through `FuntiTokens.of(context)` and never
// hard-code colours, so light and dark mode always stay consistent.
//
// Upstream widgets do not know about this extension: they pick the palette
// up through `MyTheme.lightTheme` / `MyTheme.darkTheme`, which are built from
// the `FuntiPalette` constants below.

import 'package:flutter/material.dart';

/// Raw palette constants. Prefer [FuntiTokens.of] in widgets; these exist so
/// that `MyTheme` (a static, context-free ThemeData) can use the same values.
class FuntiPalette {
  FuntiPalette._();

  // Brand (from design/brand/funtidesk-mark.svg and the lockup wordmark).
  static const Color brandBlue = Color(0xFF1267EF);
  static const Color brandBlueDark = Color(0xFF064BEB);
  static const Color brandNavy = Color(0xFF102249);

  // Light theme.
  /// Scaffold of upstream screens: they draw panels in `cardColor` on top of
  /// the scaffold, so the scaffold must stay lighter than [lightSurface2].
  static const Color lightCanvas = Color(0xFFFBF8F4);
  static const Color lightBg = Color(0xFFF4F1EC);
  static const Color lightChrome = Color(0xFFFAF8F5);
  static const Color lightSurface = Color(0xFFFFFFFF);
  static const Color lightSurface2 = Color(0xFFF1EDE7);
  static const Color lightBanner = Color(0xFFFBF8F4);
  static const Color lightStroke = Color(0xFFE3DDD4);
  static const Color lightRowStroke = Color(0xFFEEE9E2);
  static const Color lightText = brandNavy;
  static const Color lightMuted = Color(0xFF5F5950);
  static const Color lightHint = Color(0xFF8C857A);
  static const Color lightLink = Color(0xFF0F5AD6);
  static const Color lightInputStroke = Color(0xFFCFC7BB);

  /// Hover on top of [lightSurface2] cards; keeps upstream's hover contrast.
  static const Color lightHover = Color(0xFFE6E0D7);
  static const Color lightOkBg = Color(0xFFECF3E3);
  static const Color lightOkText = Color(0xFF355F18);
  static const Color lightOk = Color(0xFF6BA33A);
  static const Color lightOff = Color(0xFFABA397);
  static const Color lightStar = Color(0xFFB07A12);
  static const Color lightRaised = Color(0xFFFFFFFF);

  // Dark theme.
  static const Color darkBg = Color(0xFF14130F);
  static const Color darkChrome = Color(0xFF100F0C);
  static const Color darkSurface = Color(0xFF1D1B17);
  static const Color darkSurface2 = Color(0xFF26231E);
  static const Color darkBanner = Color(0xFF1A1814);
  static const Color darkStroke = Color(0xFF35302A);
  static const Color darkRowStroke = Color(0xFF2B2823);
  static const Color darkText = Color(0xFFEEEAE3);
  static const Color darkMuted = Color(0xFFABA397);
  static const Color darkHint = Color(0xFF857E73);
  static const Color darkAccent = Color(0xFF2A73F0);
  static const Color darkLink = Color(0xFF7DB2FF);
  static const Color darkInput = Color(0xFF1A1814);
  static const Color darkInputStroke = Color(0xFF453F37);
  static const Color darkHover = Color(0xFF2E2A24);
  static const Color darkOkBg = Color(0xFF1F2B16);
  static const Color darkOkText = Color(0xFFA9D97F);
  static const Color darkOk = Color(0xFF86C24F);
  static const Color darkOff = Color(0xFF6A6358);
  static const Color darkStar = Color(0xFFE8B455);
  static const Color darkRaised = Color(0xFF38332C);
}

/// Semantic colour tokens for FuntiDesk-owned screens.
@immutable
class FuntiTokens extends ThemeExtension<FuntiTokens> {
  const FuntiTokens({
    required this.bg,
    required this.chrome,
    required this.surface,
    required this.surface2,
    required this.banner,
    required this.stroke,
    required this.rowStroke,
    required this.text,
    required this.muted,
    required this.accent,
    required this.onAccent,
    required this.link,
    required this.input,
    required this.inputStroke,
    required this.okBg,
    required this.okText,
    required this.ok,
    required this.off,
    required this.star,
    required this.raised,
  });

  /// Window background behind cards.
  final Color bg;

  /// Title bar and status bar.
  final Color chrome;

  /// Card surface.
  final Color surface;

  /// Secondary surface: icon tiles, segmented controls, secondary buttons.
  final Color surface2;

  /// Welcome banner background.
  final Color banner;

  /// Card and control borders.
  final Color stroke;

  /// Dividers between list rows.
  final Color rowStroke;

  /// Primary text.
  final Color text;

  /// Secondary text: labels, captions, hints that must stay readable.
  final Color muted;

  /// Primary action fill.
  final Color accent;

  /// Text and icons on top of [accent].
  final Color onAccent;

  /// Text links and outlined actions.
  final Color link;

  /// Text field fill.
  final Color input;

  /// Text field border.
  final Color inputStroke;

  /// "Online" pill background.
  final Color okBg;

  /// "Online" pill text.
  final Color okText;

  /// "Online" status dot.
  final Color ok;

  /// "Offline" status dot.
  final Color off;

  /// Favourite star.
  final Color star;

  /// Selected segment of a segmented control drawn on [surface2].
  final Color raised;

  static const light = FuntiTokens(
    bg: FuntiPalette.lightBg,
    chrome: FuntiPalette.lightChrome,
    surface: FuntiPalette.lightSurface,
    surface2: FuntiPalette.lightSurface2,
    banner: FuntiPalette.lightBanner,
    stroke: FuntiPalette.lightStroke,
    rowStroke: FuntiPalette.lightRowStroke,
    text: FuntiPalette.lightText,
    muted: FuntiPalette.lightMuted,
    accent: FuntiPalette.brandBlue,
    onAccent: Colors.white,
    link: FuntiPalette.lightLink,
    input: FuntiPalette.lightSurface,
    inputStroke: FuntiPalette.lightInputStroke,
    okBg: FuntiPalette.lightOkBg,
    okText: FuntiPalette.lightOkText,
    ok: FuntiPalette.lightOk,
    off: FuntiPalette.lightOff,
    star: FuntiPalette.lightStar,
    raised: FuntiPalette.lightRaised,
  );

  static const dark = FuntiTokens(
    bg: FuntiPalette.darkBg,
    chrome: FuntiPalette.darkChrome,
    surface: FuntiPalette.darkSurface,
    surface2: FuntiPalette.darkSurface2,
    banner: FuntiPalette.darkBanner,
    stroke: FuntiPalette.darkStroke,
    rowStroke: FuntiPalette.darkRowStroke,
    text: FuntiPalette.darkText,
    muted: FuntiPalette.darkMuted,
    accent: FuntiPalette.darkAccent,
    onAccent: Colors.white,
    link: FuntiPalette.darkLink,
    input: FuntiPalette.darkInput,
    inputStroke: FuntiPalette.darkInputStroke,
    okBg: FuntiPalette.darkOkBg,
    okText: FuntiPalette.darkOkText,
    ok: FuntiPalette.darkOk,
    off: FuntiPalette.darkOff,
    star: FuntiPalette.darkStar,
    raised: FuntiPalette.darkRaised,
  );

  /// Tokens of the current theme. Falls back to [light] if a ThemeData was
  /// built without the extension, so a missing registration never crashes.
  static FuntiTokens of(BuildContext context) =>
      Theme.of(context).extension<FuntiTokens>() ?? light;

  @override
  FuntiTokens copyWith({
    Color? bg,
    Color? chrome,
    Color? surface,
    Color? surface2,
    Color? banner,
    Color? stroke,
    Color? rowStroke,
    Color? text,
    Color? muted,
    Color? accent,
    Color? onAccent,
    Color? link,
    Color? input,
    Color? inputStroke,
    Color? okBg,
    Color? okText,
    Color? ok,
    Color? off,
    Color? star,
    Color? raised,
  }) {
    return FuntiTokens(
      bg: bg ?? this.bg,
      chrome: chrome ?? this.chrome,
      surface: surface ?? this.surface,
      surface2: surface2 ?? this.surface2,
      banner: banner ?? this.banner,
      stroke: stroke ?? this.stroke,
      rowStroke: rowStroke ?? this.rowStroke,
      text: text ?? this.text,
      muted: muted ?? this.muted,
      accent: accent ?? this.accent,
      onAccent: onAccent ?? this.onAccent,
      link: link ?? this.link,
      input: input ?? this.input,
      inputStroke: inputStroke ?? this.inputStroke,
      okBg: okBg ?? this.okBg,
      okText: okText ?? this.okText,
      ok: ok ?? this.ok,
      off: off ?? this.off,
      star: star ?? this.star,
      raised: raised ?? this.raised,
    );
  }

  @override
  FuntiTokens lerp(ThemeExtension<FuntiTokens>? other, double t) {
    if (other is! FuntiTokens) {
      return this;
    }
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return FuntiTokens(
      bg: l(bg, other.bg),
      chrome: l(chrome, other.chrome),
      surface: l(surface, other.surface),
      surface2: l(surface2, other.surface2),
      banner: l(banner, other.banner),
      stroke: l(stroke, other.stroke),
      rowStroke: l(rowStroke, other.rowStroke),
      text: l(text, other.text),
      muted: l(muted, other.muted),
      accent: l(accent, other.accent),
      onAccent: l(onAccent, other.onAccent),
      link: l(link, other.link),
      input: l(input, other.input),
      inputStroke: l(inputStroke, other.inputStroke),
      okBg: l(okBg, other.okBg),
      okText: l(okText, other.okText),
      ok: l(ok, other.ok),
      off: l(off, other.off),
      star: l(star, other.star),
      raised: l(raised, other.raised),
    );
  }
}

/// Colours of the home-screen illustration that change with the theme.
/// Fixed colours of the illustration (Funtik's fur, the monitor, the plant)
/// stay inside the scene itself: they describe the drawing, not the theme.
@immutable
class FuntiSceneColors {
  const FuntiSceneColors({
    required this.home,
    required this.desk,
    required this.deskFront,
    required this.hoodie,
    required this.hood,
    required this.skin,
    required this.hair,
  });

  final Color home;
  final Color desk;
  final Color deskFront;
  final Color hoodie;
  final Color hood;
  final Color skin;
  final Color hair;

  static const light = FuntiSceneColors(
    home: Color(0xFFF1E8DD),
    desk: Color(0xFFD9C1A3),
    deskFront: Color(0xFFCBAE8C),
    hoodie: Color(0xFF1E6FEF),
    hood: Color(0xFF1557C9),
    skin: Color(0xFFF2C9A9),
    hair: Color(0xFF3A2F2B),
  );

  static const dark = FuntiSceneColors(
    home: Color(0xFF242019),
    desk: Color(0xFF4A3D30),
    deskFront: Color(0xFF3A3027),
    hoodie: Color(0xFF2A73F0),
    hood: Color(0xFF1B5BD0),
    skin: Color(0xFFE8BC9A),
    hair: Color(0xFF2A221F),
  );

  static FuntiSceneColors of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? dark : light;
}
