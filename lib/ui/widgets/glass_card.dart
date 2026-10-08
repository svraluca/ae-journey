import 'dart:ui';

import 'package:flutter/material.dart';

class GlassCard extends StatelessWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.borderRadius = 24,
    this.padding,
    this.sigma = 18,
    this.fillColor = const Color(0xFFFFFFFF),
    this.fillOpacity = 0.80,
    this.borderColor = const Color(0xFFFFFFFF),
    this.borderOpacity = 0.72,
    this.borderWidth = 1,
    this.shadowColor = const Color(0xFF0B1220),
    this.shadowOpacity = 0.05,
    this.shadowBlur = 24,
    this.shadowOffset = const Offset(0, 10),
  });

  final Widget child;
  final double borderRadius;
  final EdgeInsetsGeometry? padding;

  final double sigma;
  final Color fillColor;
  final double fillOpacity;

  final Color borderColor;
  final double borderOpacity;
  final double borderWidth;

  final Color shadowColor;
  final double shadowOpacity;
  final double shadowBlur;
  final Offset shadowOffset;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: fillColor.withValues(alpha: fillOpacity),
            borderRadius: BorderRadius.circular(borderRadius),
            border: Border.all(
              color: borderColor.withValues(alpha: borderOpacity),
              width: borderWidth,
            ),
            boxShadow: [
              BoxShadow(
                color: shadowColor.withValues(alpha: shadowOpacity),
                blurRadius: shadowBlur,
                offset: shadowOffset,
              ),
            ],
          ),
          child: child,
        ),
      ),
    );
  }
}

