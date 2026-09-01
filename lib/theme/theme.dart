/// House style: monochrome zinc, square corners, JetBrains Mono headings.
///
/// Lifted from `calculus-lab-app/lib/theme.dart`, which is the workspace house
/// style already expressed in Flutter — see `Dev/DESIGN.md`. Every colour lives
/// here as a token and is read through `SillageTokens.of(context)`, so nothing
/// downstream hardcodes a Color and retheming is a change to this file alone.
/// Light and dark are both first-class.
library;

import 'package:flutter/material.dart';

/// Zinc scale, matching `design-system/src/index.css`.
abstract final class Zinc {
  static const c50 = Color(0xFFFAFAFA);
  static const c100 = Color(0xFFF4F4F5);
  static const c200 = Color(0xFFE4E4E7);
  static const c300 = Color(0xFFD4D4D8);
  static const c400 = Color(0xFFA1A1AA);
  static const c500 = Color(0xFF71717A);
  static const c600 = Color(0xFF52525B);
  static const c700 = Color(0xFF3F3F46);
  static const c800 = Color(0xFF27272A);
  static const c900 = Color(0xFF18181B);
  static const c950 = Color(0xFF09090B);
  static const white = Color(0xFFFFFFFF);
}

/// The only chromatic token in the system.
abstract final class Destructive {
  static const light = Color(0xFFDC2626);
  static const dark = Color(0xFFEF4444);
}

@immutable
class SillageTokens extends ThemeExtension<SillageTokens> {
  const SillageTokens({
    required this.background,
    required this.surface,
    required this.foreground,
    required this.mutedForeground,
    required this.border,
    required this.borderStrong,
    required this.destructive,
  });

  final Color background;
  final Color surface;
  final Color foreground;
  final Color mutedForeground;
  final Color border;
  final Color borderStrong;
  final Color destructive;

  static const light = SillageTokens(
    background: Zinc.white,
    surface: Zinc.c50,
    foreground: Zinc.c950,
    mutedForeground: Zinc.c500,
    border: Zinc.c200,
    borderStrong: Zinc.c400,
    destructive: Destructive.light,
  );

  static const dark = SillageTokens(
    background: Zinc.c950,
    surface: Zinc.c900,
    foreground: Zinc.c50,
    mutedForeground: Zinc.c400,
    border: Zinc.c800,
    borderStrong: Zinc.c600,
    destructive: Destructive.dark,
  );

  static SillageTokens of(BuildContext context) =>
      Theme.of(context).extension<SillageTokens>()!;

  @override
  SillageTokens copyWith({
    Color? background,
    Color? surface,
    Color? foreground,
    Color? mutedForeground,
    Color? border,
    Color? borderStrong,
    Color? destructive,
  }) {
    return SillageTokens(
      background: background ?? this.background,
      surface: surface ?? this.surface,
      foreground: foreground ?? this.foreground,
      mutedForeground: mutedForeground ?? this.mutedForeground,
      border: border ?? this.border,
      borderStrong: borderStrong ?? this.borderStrong,
      destructive: destructive ?? this.destructive,
    );
  }

  @override
  SillageTokens lerp(SillageTokens? other, double t) {
    if (other == null) return this;
    return SillageTokens(
      background: Color.lerp(background, other.background, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      foreground: Color.lerp(foreground, other.foreground, t)!,
      mutedForeground: Color.lerp(mutedForeground, other.mutedForeground, t)!,
      border: Color.lerp(border, other.border, t)!,
      borderStrong: Color.lerp(borderStrong, other.borderStrong, t)!,
      destructive: Color.lerp(destructive, other.destructive, t)!,
    );
  }
}

const String fontHeading = 'JetBrainsMono';
const String fontBody = 'Inter';

/// Square corners everywhere. The house style's one exception is a true circle,
/// which is drawn as a circle rather than via a radius.
const BorderRadius squareRadius = BorderRadius.zero;

/// Spacing scale.
///
/// DESIGN.md requires inner padding to clear the corner radius. At `--radius: 0`
/// that reduces to a plain scale, but the rule is named here so it survives if
/// the radius ever moves off zero.
abstract final class Space {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 24.0;
  static const xxl = 32.0;

  /// Fixed bars reserve their own height plus the safe-area inset PLUS this
  /// gutter, so the last control never sits flush against the bottom nav.
  /// DESIGN.md: "always room at the bottom".
  static const bottomBarGutter = 16.0;
}

ThemeData buildTheme(Brightness brightness) {
  final tokens = brightness == Brightness.dark
      ? SillageTokens.dark
      : SillageTokens.light;

  final textTheme = TextTheme(
    displayLarge: TextStyle(fontFamily: fontHeading, color: tokens.foreground),
    headlineMedium: TextStyle(
      fontFamily: fontHeading,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.5,
      color: tokens.foreground,
    ),
    headlineSmall: TextStyle(
      fontFamily: fontHeading,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.3,
      color: tokens.foreground,
    ),
    titleMedium: TextStyle(
      fontFamily: fontHeading,
      fontWeight: FontWeight.w600,
      color: tokens.foreground,
    ),
    titleSmall: TextStyle(
      fontFamily: fontHeading,
      fontWeight: FontWeight.w600,
      color: tokens.foreground,
    ),
    labelLarge: TextStyle(
      fontFamily: fontHeading,
      fontWeight: FontWeight.w600,
      color: tokens.foreground,
    ),
    labelSmall: TextStyle(
      fontFamily: fontHeading,
      fontWeight: FontWeight.w500,
      letterSpacing: 0.4,
      color: tokens.mutedForeground,
    ),
    bodyLarge: TextStyle(fontFamily: fontBody, color: tokens.foreground),
    bodyMedium: TextStyle(fontFamily: fontBody, color: tokens.foreground),
    bodySmall: TextStyle(fontFamily: fontBody, color: tokens.mutedForeground),
  );

  return ThemeData(
    brightness: brightness,
    scaffoldBackgroundColor: tokens.background,
    fontFamily: fontBody,
    textTheme: textTheme,
    // Built by hand rather than seeded: fromSeed derives a tonal palette with
    // real chroma in it, which is exactly what the house style rules out.
    colorScheme: ColorScheme(
      brightness: brightness,
      primary: tokens.foreground,
      onPrimary: tokens.background,
      secondary: tokens.mutedForeground,
      onSecondary: tokens.background,
      surface: tokens.background,
      onSurface: tokens.foreground,
      surfaceContainerHighest: tokens.surface,
      outline: tokens.border,
      outlineVariant: tokens.borderStrong,
      error: tokens.destructive,
      onError: Zinc.white,
    ),
    // Square corners are enforced at the theme layer so no component has to
    // remember. Every shape below resolves through `squareRadius`.
    cardTheme: CardThemeData(
      shape: const RoundedRectangleBorder(borderRadius: squareRadius),
      color: tokens.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
    ),
    dialogTheme: DialogThemeData(
      shape: const RoundedRectangleBorder(borderRadius: squareRadius),
      backgroundColor: tokens.background,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      shape: const RoundedRectangleBorder(borderRadius: squareRadius),
      backgroundColor: tokens.background,
      surfaceTintColor: Colors.transparent,
    ),
    inputDecorationTheme: InputDecorationThemeData(
      border: OutlineInputBorder(
        borderRadius: squareRadius,
        borderSide: BorderSide(color: tokens.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: squareRadius,
        borderSide: BorderSide(color: tokens.border),
      ),
      // One cohesive focus indicator: the border thickens and lifts to
      // borderStrong. No second ring is ever drawn on top of it.
      // See DESIGN.md, "Focus states".
      focusedBorder: OutlineInputBorder(
        borderRadius: squareRadius,
        borderSide: BorderSide(color: tokens.borderStrong, width: 2),
      ),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: Space.lg,
        vertical: Space.md,
      ),
      filled: true,
      fillColor: tokens.surface,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: const RoundedRectangleBorder(borderRadius: squareRadius),
        backgroundColor: tokens.foreground,
        foregroundColor: tokens.background,
        textStyle: textTheme.labelLarge,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: const RoundedRectangleBorder(borderRadius: squareRadius),
        foregroundColor: tokens.foreground,
        side: BorderSide(color: tokens.border),
        textStyle: textTheme.labelLarge,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        shape: const RoundedRectangleBorder(borderRadius: squareRadius),
        foregroundColor: tokens.foreground,
        textStyle: textTheme.labelLarge,
      ),
    ),
    dividerTheme: DividerThemeData(color: tokens.border, thickness: 1, space: 1),
    extensions: [tokens],
  );
}
