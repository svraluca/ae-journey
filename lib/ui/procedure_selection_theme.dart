import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Visual tokens for wizard steps 2–4 — VisionOS-inspired warm glass.
abstract final class ProcedureSelectionTheme {
  static const primaryText = Color(0xFF1A1A1F);
  static const secondaryText = Color(0xFF8A8A93);
  static const sectionLabel = Color(0xFF8A8580);

  static const pageBackgroundTop = Color(0xFFF5F5F7);
  static const pageBackground = Color(0xFFF2F2F2);
  static const pageBackgroundBottom = Color(0xFFEDEDED);

  /// White-light glass — opaque enough to block shadow bleed-through.
  static const cardInner = Color(0x66FFFFFF);
  static const cardIlluminated = Color(0x73FFFFFF);
  static const card = Color(0x66FFFFFF);

  // Dark glass for selected cards — closer to true black.
  static const cardSelectedTop = Color(0xFF18181A);
  static const cardSelectedMid = Color(0xFF09090B);
  static const cardSelectedBottom = Color(0xFF020203);
  static const cardSelected = Color(0xFF050507);

  static const cardBorder = Color(0x8CFFFFFF);
  static const cardRadius = 24.0;
  static const ink = Color(0xFF1A1A1F);
  static const muted = Color(0xFF8A8A93);
  static const iconBadge = Color(0xFAFFFFFF);
  static const fieldFill = Color(0x45FFFFFF);
  static const fieldFillLight = Color(0x38FFFFFF);
  static const stepperButton = Color(0x42FFFFFF);
  static const customButtonFill = Color(0x30FFFFFF);
  static const legendTrack = Color(0x30FFFFFF);
  static const legendActive = Color(0x4DFFFFFF);
  static const buttonPrimary = Color(0xFF111214);

  /// Ambient depth shadow — neutral grey so it does not warm the page.
  static const ambientShadow = Color(0x14000000);
  static const glassShadow = ambientShadow;
  static const glassBloom = Color(0x33FFFFFF);
  static const glassGlow = Color(0xB3FFFFFF);

  static const blurSigma = 24.0;
  static const blurSigmaHeavy = 30.0;
}

/// Frosted-glass decorations — ambient light, bloom, directional borders.
abstract final class ProcedureGlassDecorations {
  static Border glassBorder({bool selected = false, bool bright = false}) {
    if (selected) {
      return Border(
        top: BorderSide(color: Colors.white.withValues(alpha: 0.92), width: 1.2),
        left: BorderSide(color: Colors.white.withValues(alpha: 0.55), width: 1.2),
        right: BorderSide(color: Colors.white.withValues(alpha: 0.28), width: 1.2),
        bottom: BorderSide(color: Colors.white.withValues(alpha: 0.12), width: 1.2),
      );
    }
    return Border(
      top: BorderSide(color: Colors.white.withValues(alpha: bright ? 0.98 : 0.95), width: 1.2),
      left: BorderSide(color: Colors.white.withValues(alpha: bright ? 0.72 : 0.65), width: 1.2),
      right: BorderSide(color: Colors.white.withValues(alpha: bright ? 0.38 : 0.32), width: 1.2),
      bottom: BorderSide(color: Colors.white.withValues(alpha: 0.14), width: 1.2),
    );
  }

  /// Bright neon-white outer glow for the card frame.
  static List<BoxShadow> neonFrameGlow({bool compact = false, bool selected = false}) {
    if (selected) {
      return const [];
    }

    final core = 0.78;
    return [
      BoxShadow(
        color: Colors.white.withValues(alpha: core),
        blurRadius: compact ? 5 : 6,
        spreadRadius: 0,
        offset: const Offset(0, -1),
      ),
      BoxShadow(
        color: Colors.white.withValues(alpha: 0.68),
        blurRadius: compact ? 11 : 16,
        spreadRadius: 0,
        offset: const Offset(0, -1),
      ),
      BoxShadow(
        color: Colors.white.withValues(alpha: 0.48),
        blurRadius: compact ? 20 : 28,
        spreadRadius: 0,
        offset: const Offset(0, -1),
      ),
    ];
  }

  /// Ambient depth — external shadows only, nothing that bleeds into the glass fill.
  static List<BoxShadow> shadows({
    bool selected = false,
    bool compact = false,
    bool elevated = false,
  }) {
    return depthShadow(compact: compact, elevated: elevated, selected: selected);
  }

  /// Neutral drop shadow beneath the card — no warm brown bleed on the page.
  static List<BoxShadow> depthShadow({
    bool compact = false,
    bool elevated = false,
    bool selected = false,
  }) {
    final mainLift = elevated ? 24.0 : (compact ? 14.0 : 18.0);
    final mainBlur = elevated ? 56.0 : (compact ? 36.0 : 48.0);

    return [
      BoxShadow(
        color: const Color(0x1A000000),
        blurRadius: mainBlur,
        offset: Offset(0, mainLift),
      ),
      BoxShadow(
        color: const Color(0x0F000000),
        blurRadius: compact ? 16.0 : 22.0,
        offset: Offset(0, compact ? 8.0 : 10.0),
      ),
    ];
  }

  static Gradient selectedGradient() {
    return const LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        ProcedureSelectionTheme.cardSelectedTop,
        ProcedureSelectionTheme.cardSelectedMid,
        ProcedureSelectionTheme.cardSelectedBottom,
      ],
      stops: [0.0, 0.48, 1.0],
    );
  }

  static Gradient innerHighlightGradient({double opacity = 0.12}) {
    return LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        Colors.white.withValues(alpha: opacity),
        Colors.white.withValues(alpha: opacity * 0.4),
        Colors.transparent,
      ],
      stops: const [0.0, 0.30, 0.70],
    );
  }

  /// Soft glossy reflection across top of polished dark glass.
  static Gradient polishSheenGradient({double opacity = 0.10}) {
    return LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        Colors.white.withValues(alpha: opacity),
        Colors.white.withValues(alpha: opacity * 0.35),
        Colors.transparent,
      ],
      stops: const [0.0, 0.18, 0.50],
    );
  }

  static List<BoxShadow> iconBadgeShadows({bool selected = false}) {
    return [
      BoxShadow(
        color: Colors.white.withValues(alpha: selected ? 0.55 : 0.40),
        blurRadius: 14,
        spreadRadius: 1.5,
      ),
      BoxShadow(
        color: Colors.white.withValues(alpha: 0.22),
        blurRadius: 6,
        spreadRadius: -1,
        offset: const Offset(0, -1),
      ),
      BoxShadow(
        color: ProcedureSelectionTheme.ambientShadow,
        blurRadius: 10,
        offset: const Offset(0, 4),
      ),
    ];
  }

  static BoxDecoration iconBadge({bool selected = false}) {
    return BoxDecoration(
      color: Colors.white,
      shape: BoxShape.circle,
      border: Border.all(
        color: Colors.white.withValues(alpha: selected ? 0.85 : 0.95),
      ),
      boxShadow: iconBadgeShadows(selected: selected),
    );
  }

  static BoxDecoration primaryButton({double radius = 32}) {
    // borderRadius requires uniform BorderSide colors — per-side alphas crash paint().
    return BoxDecoration(
      gradient: selectedGradient(),
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: Colors.white.withValues(alpha: 0.16), width: 1),
      boxShadow: ProcedureGlassDecorations.depthShadow(elevated: true, selected: true),
    );
  }
}

/// Plus Jakarta Sans typography for wizard step 2.
abstract final class ProcedureSelectionTypography {
  static TextStyle display({double size = 24, FontWeight weight = FontWeight.w800, Color? color}) {
    return GoogleFonts.plusJakartaSans(fontSize: size, fontWeight: weight, color: color ?? ProcedureSelectionTheme.ink, height: 1.15);
  }

  static TextStyle body({double size = 14, FontWeight weight = FontWeight.w500, Color? color}) {
    return GoogleFonts.plusJakartaSans(fontSize: size, fontWeight: weight, color: color ?? ProcedureSelectionTheme.muted, height: 1.35);
  }

  static TextStyle label({double size = 11, FontWeight weight = FontWeight.w600, Color? color}) {
    return GoogleFonts.plusJakartaSans(fontSize: size, fontWeight: weight, color: color ?? ProcedureSelectionTheme.ink, height: 1.1);
  }

  static TextStyle chip({double size = 12, FontWeight weight = FontWeight.w700, Color? color}) {
    return GoogleFonts.plusJakartaSans(fontSize: size, fontWeight: weight, color: color ?? ProcedureSelectionTheme.ink);
  }
}
