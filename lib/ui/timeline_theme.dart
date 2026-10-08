import 'package:flutter/material.dart';

/// Shared flat timeline / procedure-detail palette.
abstract final class TimelineTheme {
  static const bg = Color(0xFFF9F9F9);
  static const card = Color(0xFFFFFFFF);
  static const ink = Color(0xFF1A1A1A);
  static const muted = Color(0xFF8E8E93);
  static const mutedLight = Color(0xFFAEAEB2);
  static const border = Color(0xFFE8E8E8);
  static const iconBg = Color(0xFFF0F0F2);
  static const fill = Color(0xFFF5F5F7);
  static const cardRadius = 24.0;
  static const pageHorizontalPad = 20.0;

  static BoxDecoration cardDecoration({double radius = cardRadius}) {
    return BoxDecoration(
      color: card,
      borderRadius: BorderRadius.circular(radius),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.06),
          blurRadius: 20,
          offset: const Offset(0, 4),
        ),
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.03),
          blurRadius: 6,
          offset: const Offset(0, 2),
        ),
      ],
    );
  }

  static BoxDecoration iconBadgeDecoration({Color? color}) {
    return BoxDecoration(
      color: color ?? card,
      shape: BoxShape.circle,
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.08),
          blurRadius: 14,
          offset: const Offset(0, 4),
        ),
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.04),
          blurRadius: 4,
          offset: const Offset(0, 2),
        ),
      ],
    );
  }
}
