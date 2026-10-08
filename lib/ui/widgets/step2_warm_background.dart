import 'package:flutter/material.dart';

import '../procedure_selection_theme.dart';

/// Wizard steps 2–4 — soft white ambient light behind the glass UI.
///
/// Avoids [ImageFilter.blur] — Impeller Gaussian blur crashes iOS Simulator Metal.
class Step2WarmBackground extends StatelessWidget {
  const Step2WarmBackground({super.key});

  @override
  Widget build(BuildContext context) {
    return const Positioned.fill(child: _AmbientPearlBackground());
  }
}

class _SoftOrb extends StatelessWidget {
  const _SoftOrb({
    this.top,
    this.left,
    this.right,
    this.bottom,
    required this.width,
    required this.height,
    required this.colors,
    this.stops,
  });

  final double? top;
  final double? left;
  final double? right;
  final double? bottom;
  final double width;
  final double height;
  final List<Color> colors;
  final List<double>? stops;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: top,
      left: left,
      right: right,
      bottom: bottom,
      child: IgnorePointer(
        child: Container(
          width: width,
          height: height,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              colors: colors,
              stops: stops,
            ),
          ),
        ),
      ),
    );
  }
}

class _AmbientPearlBackground extends StatelessWidget {
  const _AmbientPearlBackground();

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                ProcedureSelectionTheme.pageBackgroundTop,
                ProcedureSelectionTheme.pageBackground,
                ProcedureSelectionTheme.pageBackgroundBottom,
              ],
              stops: [0.0, 0.45, 1.0],
            ),
          ),
        ),
        _SoftOrb(
          top: -180,
          left: -60,
          right: -60,
          width: 560,
          height: 440,
          colors: [
            const Color(0xFFF8F8FA).withValues(alpha: 0.85),
            const Color(0xFFF2F2F2).withValues(alpha: 0.30),
            Colors.transparent,
          ],
          stops: const [0.0, 0.35, 1.0],
        ),
        _SoftOrb(
          top: 80,
          left: -140,
          width: 360,
          height: 360,
          colors: [
            const Color(0xFFF5F5F7).withValues(alpha: 0.35),
            Colors.transparent,
          ],
        ),
        _SoftOrb(
          top: 240,
          right: -120,
          width: 320,
          height: 320,
          colors: [
            const Color(0xFFF0F0F2).withValues(alpha: 0.28),
            Colors.transparent,
          ],
        ),
        _SoftOrb(
          bottom: 0,
          left: 40,
          right: 40,
          width: 400,
          height: 200,
          colors: [
            const Color(0xFFF5F5F7).withValues(alpha: 0.18),
            Colors.transparent,
          ],
        ),
      ],
    );
  }
}
