import 'dart:ui';

import 'package:flutter/material.dart';

/// iOS AirDrop-style light sweep (shared by post-auth splash & glow-up loading).
class AirdropLightField extends StatelessWidget {
  const AirdropLightField({
    super.key,
    required this.progress,
    this.paperReveal = 0,
  });

  final double progress;
  final double paperReveal;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return CustomPaint(
          painter: AirdropLightPainter(
            progress: progress,
            paperReveal: paperReveal,
          ),
          child: const SizedBox.expand(),
        );
      },
    );
  }
}

class AirdropLightPainter extends CustomPainter {
  AirdropLightPainter({
    required this.progress,
    required this.paperReveal,
  });

  final double progress;
  final double paperReveal;

  static const _purple = Color(0xFFBF5AF2);
  static const _violet = Color(0xFF7B61FF);
  static const _blue = Color(0xFF5AC8FA);
  static const _pink = Color(0xFFFF6BD6);

  @override
  void paint(Canvas canvas, Size canvasSize) {
    final blackFade = (1.0 - Curves.easeIn.transform(((progress - 0.48) / 0.38).clamp(0.0, 1.0)))
        .clamp(0.0, 1.0);
    final backdropAlpha = (blackFade * (1.0 - paperReveal * 0.85)).clamp(0.0, 1.0);
    if (backdropAlpha > 0.01) {
      canvas.drawRect(
        Offset.zero & canvasSize,
        Paint()..color = Colors.black.withValues(alpha: backdropAlpha),
      );
    }

    final rise = Curves.easeInOutCubic.transform(progress.clamp(0.0, 1.0));
    final sweepY = canvasSize.height * (1.15 - rise * 1.35);
    final bloom = Curves.easeOut.transform(((progress - 0.08) / 0.55).clamp(0.0, 1.0));

    canvas.saveLayer(
      Offset.zero & canvasSize,
      Paint()..imageFilter = ImageFilter.blur(sigmaX: 55, sigmaY: 55),
    );

    _drawGlowOrb(
      canvas,
      center: Offset(canvasSize.width * 0.35, sweepY + canvasSize.height * 0.18),
      radius: canvasSize.width * (0.45 + bloom * 0.25),
      inner: _purple.withValues(alpha: 0.55 * bloom),
      outer: Colors.transparent,
    );
    _drawGlowOrb(
      canvas,
      center: Offset(canvasSize.width * 0.72, sweepY + canvasSize.height * 0.08),
      radius: canvasSize.width * (0.38 + bloom * 0.2),
      inner: _violet.withValues(alpha: 0.48 * bloom),
      outer: Colors.transparent,
    );
    _drawGlowOrb(
      canvas,
      center: Offset(canvasSize.width * 0.52, sweepY - canvasSize.height * 0.05),
      radius: canvasSize.width * (0.32 + bloom * 0.15),
      inner: _blue.withValues(alpha: 0.35 * bloom),
      outer: Colors.transparent,
    );
    _drawGlowOrb(
      canvas,
      center: Offset(canvasSize.width * 0.22, sweepY + canvasSize.height * 0.02),
      radius: canvasSize.width * 0.28,
      inner: _pink.withValues(alpha: 0.28 * bloom),
      outer: Colors.transparent,
    );

    _drawLightSweep(canvas, canvasSize, sweepY, bloom);

    final flare = Curves.easeIn.transform(((progress - 0.45) / 0.4).clamp(0.0, 1.0));
    if (flare > 0) {
      _drawGlowOrb(
        canvas,
        center: Offset(canvasSize.width * 0.5, canvasSize.height * (0.25 - rise * 0.15)),
        radius: canvasSize.width * (0.55 + flare * 0.35),
        inner: Colors.white.withValues(alpha: 0.35 * flare),
        outer: Colors.transparent,
      );
    }

    canvas.restore();
  }

  void _drawGlowOrb(
    Canvas canvas, {
    required Offset center,
    required double radius,
    required Color inner,
    required Color outer,
  }) {
    final paint = Paint()
      ..shader = RadialGradient(
        colors: [inner, outer],
      ).createShader(Rect.fromCircle(center: center, radius: radius))
      ..blendMode = BlendMode.plus;
    canvas.drawCircle(center, radius, paint);
  }

  void _drawLightSweep(Canvas canvas, Size canvasSize, double sweepY, double intensity) {
    if (intensity <= 0) return;

    final bandH = canvasSize.height * 0.55;
    final rect = Rect.fromLTWH(-canvasSize.width * 0.1, sweepY - bandH * 0.35, canvasSize.width * 1.2, bandH);

    final sweepPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.bottomCenter,
        end: Alignment.topCenter,
        colors: [
          Colors.transparent,
          _purple.withValues(alpha: 0.35 * intensity),
          _violet.withValues(alpha: 0.5 * intensity),
          Colors.white.withValues(alpha: 0.65 * intensity),
          _blue.withValues(alpha: 0.4 * intensity),
          _pink.withValues(alpha: 0.25 * intensity),
          Colors.transparent,
        ],
        stops: const [0.0, 0.32, 0.48, 0.58, 0.72, 0.88, 1.0],
      ).createShader(rect)
      ..blendMode = BlendMode.plus;

    canvas.drawRect(rect, sweepPaint);

    final ribbonRect = Rect.fromLTWH(0, sweepY - 40, canvasSize.width, 120);
    final ribbon = Paint()
      ..shader = LinearGradient(
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
        colors: [
          Colors.transparent,
          _blue.withValues(alpha: 0.2 * intensity),
          Colors.white.withValues(alpha: 0.5 * intensity),
          _purple.withValues(alpha: 0.35 * intensity),
          Colors.transparent,
        ],
      ).createShader(ribbonRect)
      ..blendMode = BlendMode.screen;
    canvas.drawRect(ribbonRect, ribbon);
  }

  @override
  bool shouldRepaint(AirdropLightPainter old) =>
      old.progress != progress || old.paperReveal != paperReveal;
}
