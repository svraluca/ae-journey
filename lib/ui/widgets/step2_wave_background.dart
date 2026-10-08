import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Atmospheric step-2 background: static glass texture + soft gradient motion.
///
/// Avoids [ImageFilter.blur] and [MaskFilter.blur] — those crash iOS Simulator
/// Metal (Impeller GaussianBlur on the raster thread).
class Step2WaveBackground extends StatefulWidget {
  const Step2WaveBackground({super.key});

  @override
  State<Step2WaveBackground> createState() => _Step2WaveBackgroundState();
}

class _Step2WaveBackgroundState extends State<Step2WaveBackground> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 40),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: RepaintBoundary(
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.asset(
              'assets/backgroundstep2.png',
              fit: BoxFit.cover,
              filterQuality: FilterQuality.medium,
              gaplessPlayback: true,
            ),
            AnimatedBuilder(
              animation: _controller,
              builder: (context, _) {
                return CustomPaint(
                  painter: _SoftGlassOverlayPainter(progress: _controller.value),
                  child: const SizedBox.expand(),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

// ── Motion (gradient-only blobs, no blur) ─────────────────────────────────────

class _BlobSpec {
  const _BlobSpec({
    required this.anchorX,
    required this.anchorY,
    required this.radius,
    required this.driftX,
    required this.driftY,
    required this.phase,
    required this.speed,
    required this.alpha,
  });

  final double anchorX;
  final double anchorY;
  final double radius;
  final double driftX;
  final double driftY;
  final double phase;
  final double speed;
  final double alpha;
}

class _SoftGlassOverlayPainter extends CustomPainter {
  _SoftGlassOverlayPainter({required this.progress});

  final double progress;

  static const _blobs = [
    _BlobSpec(
      anchorX: 0.78, anchorY: 0.18, radius: 0.55,
      driftX: 0.04, driftY: 0.03, phase: 0.0, speed: 1.0, alpha: 0.18,
    ),
    _BlobSpec(
      anchorX: 0.22, anchorY: 0.32, radius: 0.58,
      driftX: 0.035, driftY: 0.028, phase: 1.4, speed: 0.85, alpha: 0.16,
    ),
    _BlobSpec(
      anchorX: 0.52, anchorY: 0.55, radius: 0.62,
      driftX: 0.03, driftY: 0.032, phase: 2.8, speed: 0.92, alpha: 0.14,
    ),
    _BlobSpec(
      anchorX: 0.12, anchorY: 0.72, radius: 0.50,
      driftX: 0.032, driftY: 0.026, phase: 4.2, speed: 0.78, alpha: 0.15,
    ),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    final bounds = Offset.zero & size;
    final wave = progress * math.pi * 2;

    _paintDirectionalSheen(canvas, bounds, wave);

    for (final blob in _blobs) {
      final t = wave * blob.speed + blob.phase;
      final cx = size.width * (blob.anchorX + math.sin(t) * blob.driftX);
      final cy = size.height * (blob.anchorY + math.cos(t * 0.9) * blob.driftY);
      final r = size.width * blob.radius * (1.0 + 0.03 * math.sin(t * 0.7));
      final breathe = blob.alpha * (0.85 + 0.15 * math.sin(t * 0.5));

      _paintSoftOrb(
        canvas,
        Offset(cx, cy),
        r,
        breathe,
        highlight: Offset(-r * 0.22, -r * 0.26),
      );
    }
  }

  void _paintDirectionalSheen(Canvas canvas, Rect bounds, double wave) {
    final shift = 0.04 * math.sin(wave * 0.35);
    canvas.drawRect(
      bounds,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(bounds.left + bounds.width * shift, bounds.top),
          Offset(bounds.right, bounds.bottom * 0.65),
          [
            const Color(0xFFFFFFFF).withValues(alpha: 0.12),
            Colors.transparent,
            const Color(0xFFE8E6E3).withValues(alpha: 0.06),
          ],
          const [0.0, 0.42, 1.0],
        ),
    );
  }

  /// Soft edge via wide radial gradient stops — no GPU blur pass.
  void _paintSoftOrb(
    Canvas canvas,
    Offset center,
    double radius,
    double alpha, {
    required Offset highlight,
  }) {
    final lightCenter = center + highlight;

    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = ui.Gradient.radial(
          lightCenter,
          radius,
          [
            const Color(0xFFE0DDD9).withValues(alpha: alpha * 1.1),
            const Color(0xFFF0EFED).withValues(alpha: alpha * 0.65),
            const Color(0xFFF7F7F6).withValues(alpha: alpha * 0.2),
            Colors.transparent,
          ],
          const [0.0, 0.35, 0.72, 1.0],
        ),
    );

    canvas.drawCircle(
      center + Offset(radius * 0.08, radius * 0.06),
      radius * 0.42,
      Paint()
        ..shader = ui.Gradient.radial(
          center + Offset(-radius * 0.12, -radius * 0.14),
          radius * 0.42,
          [
            const Color.fromRGBO(255, 255, 255, 0.14),
            Colors.transparent,
          ],
        ),
    );
  }

  @override
  bool shouldRepaint(covariant _SoftGlassOverlayPainter oldDelegate) {
    return oldDelegate.progress != progress;
  }
}
