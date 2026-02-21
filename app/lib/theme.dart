import 'dart:ui';
import 'package:flutter/material.dart';

// ── Talkye Meet Design System — Dark Only, Purple Accent, Elevation-based ──

class C {
  // Accent (purple/violet brand)
  static const accent = Color(0xFF8B5CF6);
  static const accentLight = Color(0xFFA78BFA);
  static const accentDark = Color(0xFF7C3AED);

  // Elevation levels (no borders — differentiate by shade)
  static const bg = Color(0xFF1E1F22);         // base (0dp)
  static const level1 = Color(0xFF252629);      // sidebar, cards (1dp)
  static const level2 = Color(0xFF2C2D32);      // elevated cards, hover (3dp)
  static const level3 = Color(0xFF323438);      // active, dialogs (6dp)
  static const level4 = Color(0xFF393C41);      // tooltips, popovers (8dp)

  // Glass
  static Color glass = const Color(0xFF1E1F22).withAlpha(170); // ~67% opacity

  // Text
  static const text = Color(0xFFE8E8ED);
  static const textSub = Color(0xFF9898A8);
  static const textMuted = Color(0xFF5A5A6E);

  // Status (green = status only, NOT accent)
  static const success = Color(0xFF4ADE80);
  static const error = Color(0xFFEF4444);
  static const warning = Color(0xFFF59E0B);
  static const info = Color(0xFF60A5FA);
  static const orange = Color(0xFFF97316);

  // Glass blur
  static ImageFilter blur = ImageFilter.blur(sigmaX: 20, sigmaY: 20);
}

final appTheme = ThemeData(
  brightness: Brightness.dark,
  useMaterial3: true,
  scaffoldBackgroundColor: C.bg,
  colorScheme: const ColorScheme.dark(
    primary: C.accent,
    surface: C.bg,
    onSurface: C.text,
    error: C.error,
  ),
);
