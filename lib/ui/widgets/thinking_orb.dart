import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:google_fonts/google_fonts.dart';

/// Flutter port of the [thinking-orbs](https://orbs.jakubantalik.com) **working**
/// state (particles on tilted orbits) — monochrome, canvas-style.
class ThinkingWorkingOrb extends StatefulWidget {
  const ThinkingWorkingOrb({
    super.key,
    this.size = 96,
    this.speed = 1.0,
    this.darkInk = true,
  });

  final double size;
  final double speed;

  /// Dark dots on light backgrounds (matches `theme="light"` on the web orb).
  final bool darkInk;

  @override
  State<ThinkingWorkingOrb> createState() => _ThinkingWorkingOrbState();
}

class _ThinkingWorkingOrbState extends State<ThinkingWorkingOrb>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Duration _elapsed = Duration.zero;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((elapsed) {
      setState(() => _elapsed = elapsed);
    })..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Web preset for size 64: speed 1.885
    final t = _elapsed.inMicroseconds / 1e6 * 1.885 * widget.speed;
    return Semantics(
      label: 'Working',
      child: CustomPaint(
        size: Size.square(widget.size),
        painter: _OrbitsPainter(
          time: t,
          darkInk: widget.darkInk,
        ),
      ),
    );
  }
}

/// Flutter port of the [thinking-orbs](https://orbs.jakubantalik.com) **breathing**
/// state (face-on morphing ring).
class ThinkingBreathingOrb extends StatefulWidget {
  const ThinkingBreathingOrb({
    super.key,
    this.size = 96,
    this.speed = 1.0,
    this.darkInk = true,
  });

  final double size;
  final double speed;
  final bool darkInk;

  @override
  State<ThinkingBreathingOrb> createState() => _ThinkingBreathingOrbState();
}

class _ThinkingBreathingOrbState extends State<ThinkingBreathingOrb>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Duration _elapsed = Duration.zero;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((elapsed) {
      setState(() => _elapsed = elapsed);
    })..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  double _presetSpeed(double n) {
    // thinking-orbs ring presets (64 → 3.24, 20 → 3.78).
    if (n <= 20) return 3.78;
    if (n >= 64) return 3.24;
    return 3.78 + (n - 20) * (3.24 - 3.78) / 44;
  }

  @override
  Widget build(BuildContext context) {
    final t = _elapsed.inMicroseconds / 1e6 * _presetSpeed(widget.size) * widget.speed;
    return Semantics(
      label: 'Agent breathing',
      child: CustomPaint(
        size: Size.square(widget.size),
        painter: _BreathingRingPainter(
          time: t,
          darkInk: widget.darkInk,
        ),
      ),
    );
  }
}

/// Compact orb + label used while clinic prices are still streaming in.
class AgentBreathingIndicator extends StatelessWidget {
  const AgentBreathingIndicator({
    super.key,
    this.orbSize = 22,
    this.label = 'Uploading prices',
    this.mutedColor = const Color(0xFF8A8A93),
  });

  final double orbSize;
  final String label;
  final Color mutedColor;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        ThinkingBreathingOrb(size: orbSize),
        const SizedBox(height: 4),
        Text(
          label,
          style: GoogleFonts.jetBrainsMono(
            fontSize: 8.5,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.35,
            color: mutedColor,
            height: 1,
          ),
          textAlign: TextAlign.right,
        ),
      ],
    );
  }
}

/// Flutter port of the [thinking-orbs](https://orbs.jakubantalik.com) **solving**
/// state (rubik bands scramble in quarter turns, then click back).
class ThinkingSolvingOrb extends StatefulWidget {
  const ThinkingSolvingOrb({
    super.key,
    this.size = 96,
    this.speed = 1.0,
    this.darkInk = true,
  });

  final double size;
  final double speed;
  final bool darkInk;

  @override
  State<ThinkingSolvingOrb> createState() => _ThinkingSolvingOrbState();
}

class _ThinkingSolvingOrbState extends State<ThinkingSolvingOrb>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Duration _elapsed = Duration.zero;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((elapsed) {
      setState(() => _elapsed = elapsed);
    })..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  double _presetSpeed(double n) {
    if (n <= 20) return 1.95;
    if (n >= 64) return 1.82;
    return 1.95 + (n - 20) * (1.82 - 1.95) / 44;
  }

  @override
  Widget build(BuildContext context) {
    final t = _elapsed.inMicroseconds / 1e6 * _presetSpeed(widget.size) * widget.speed;
    return Semantics(
      label: 'Solving',
      child: CustomPaint(
        size: Size.square(widget.size),
        painter: _RubikPainter(
          time: t,
          darkInk: widget.darkInk,
        ),
      ),
    );
  }
}

/// Flutter port of the [thinking-orbs](https://orbs.jakubantalik.com) **composing**
/// state (undulating multi-band sash with ghost sphere).
class ThinkingComposingOrb extends StatefulWidget {
  const ThinkingComposingOrb({
    super.key,
    this.size = 96,
    this.speed = 1.0,
    this.darkInk = true,
    this.neon = false,
  });

  final double size;
  final double speed;
  final bool darkInk;

  /// Brighter white particles with a soft glow (best on a dark backdrop).
  final bool neon;

  @override
  State<ThinkingComposingOrb> createState() => _ThinkingComposingOrbState();
}

class _ThinkingComposingOrbState extends State<ThinkingComposingOrb>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Duration _elapsed = Duration.zero;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((elapsed) {
      setState(() => _elapsed = elapsed);
    })..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  double _presetSpeed(double n) {
    if (n <= 20) return 3.12;
    if (n >= 64) return 2.34;
    return 3.12 + (n - 20) * (2.34 - 3.12) / 44;
  }

  @override
  Widget build(BuildContext context) {
    final t = _elapsed.inMicroseconds / 1e6 * _presetSpeed(widget.size) * widget.speed;
    return Semantics(
      label: 'Loading',
      child: CustomPaint(
        size: Size.square(widget.size),
        painter: _ComposingRibbonPainter(
          time: t,
          darkInk: widget.darkInk,
          neon: widget.neon,
        ),
      ),
    );
  }
}

/// Compact composing orb + label while AI comparison is loading.
class AgentWorkingIndicator extends StatelessWidget {
  const AgentWorkingIndicator({
    super.key,
    this.orbSize = 40,
    this.label = 'Loading',
    this.mutedColor = const Color(0xFF8A8A93),
    this.centered = true,
  });

  final double orbSize;
  final String label;
  final Color mutedColor;
  final bool centered;

  @override
  Widget build(BuildContext context) {
    final column = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment:
          centered ? CrossAxisAlignment.center : CrossAxisAlignment.end,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF1A1A1F).withValues(alpha: 0.12),
                blurRadius: 16,
                spreadRadius: 0,
                offset: const Offset(0, 4),
              ),
              BoxShadow(
                color: const Color(0xFF1A1A1F).withValues(alpha: 0.06),
                blurRadius: 28,
                spreadRadius: 2,
              ),
            ],
          ),
          child: ThinkingComposingOrb(
            size: orbSize,
            darkInk: true,
            neon: false,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          label,
          style: GoogleFonts.jetBrainsMono(
            fontSize: 10,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.35,
            color: mutedColor,
            height: 1,
          ),
          textAlign: centered ? TextAlign.center : TextAlign.right,
        ),
      ],
    );
    if (!centered) return column;
    return Center(child: column);
  }
}

class _Dot {
  _Dot({
    required this.x,
    required this.y,
    required this.z,
    required this.r,
    required this.white,
    this.a = 1,
  });

  final double x;
  final double y;
  final double z;
  final double r;
  final double white;
  final double a;
}

class _OrbitsPainter extends CustomPainter {
  _OrbitsPainter({required this.time, required this.darkInk});

  final double time;
  final bool darkInk;

  static double _hash(int x, double y) {
    final s = math.sin(x * 12.9898 + y * 78.233) * 43758.5453;
    return s - s.floorToDouble();
  }

  static double _rs(double n, double pow) => math.pow(n / 300, pow).toDouble();

  static void _drawDots(
    Canvas canvas,
    List<_Dot> dots,
    bool darkInk, {
    double rMin = 0.3,
    bool lightShine = false,
    bool neonGlow = false,
  }) {
    dots.sort((a, b) => a.z.compareTo(b.z));
    final paint = Paint()..style = PaintingStyle.fill;
    for (final t in dots) {
      final alpha = t.a;
      if (alpha < 0.02) continue;
      final white = t.white.clamp(0.0, 1.0);
      final radius = math.max(rMin, t.r);
      if (neonGlow) {
        final shine = (1.0 - white).clamp(0.0, 1.0);
        final glowAlpha = (alpha * (0.35 + 0.55 * shine)).clamp(0.0, 1.0);
        paint.maskFilter = const MaskFilter.blur(BlurStyle.normal, 3.5);
        paint.color = Color.fromARGB(
          (glowAlpha * 180).round().clamp(0, 255),
          255,
          255,
          255,
        );
        canvas.drawCircle(Offset(t.x, t.y), radius * 1.65, paint);
        paint.maskFilter = null;
        final coreAlpha = (alpha * (0.75 + 0.25 * shine)).clamp(0.0, 1.0);
        paint.color = Color.fromARGB(
          (coreAlpha * 255).round().clamp(0, 255),
          255,
          255,
          255,
        );
        canvas.drawCircle(Offset(t.x, t.y), radius * 1.15, paint);
      } else if (lightShine) {
        final shine = (1.0 - white).clamp(0.0, 1.0);
        final core = (215 + 40 * shine).round().clamp(0, 255);
        final a = (alpha * (0.5 + 0.5 * shine)).clamp(0.0, 1.0);
        paint.color = Color.fromARGB((a * 255).round().clamp(0, 255), core, core, core);
        canvas.drawCircle(Offset(t.x, t.y), radius, paint);
      } else {
        final shade = darkInk ? white : (1.0 - white);
        final g = (shade * 255).round().clamp(0, 255);
        paint.color = Color.fromARGB((alpha * 255).round().clamp(0, 255), g, g, g);
        canvas.drawCircle(Offset(t.x, t.y), radius, paint);
      }
    }
  }

  /// Camera project: yaw/pitch around center.
  static List<double> Function(double, double, double) _cam(
    double yaw,
    double pitch,
    double cx,
    double cy,
    double scale,
  ) {
    final se = math.sin(pitch);
    final ce = math.cos(pitch);
    final sy = math.sin(yaw);
    final cyw = math.cos(yaw);
    return (v, b, x) {
      final g = v * cyw + x * sy;
      final u = -v * sy + x * cyw;
      final h = b * ce - u * se;
      final r = b * se + u * ce;
      return [cx + g * scale, cy - h * scale, r];
    };
  }

  @override
  void paint(Canvas canvas, Size size) {
    final n = size.shortestSide;
    final e = n / 2;
    final c = n / 2;
    final r = n / 2 * 0.82;
    final project = _cam(time * 0.12, 0.3, e, c, 1);
    final v = _rs(n, 0.6);
    final dots = <_Dot>[];

    const orbitN = 12;
    const ghostN = 40;
    const particles = 3;

    for (var h = 0; h < orbitN; h++) {
      final R = _hash(h, 1.7);
      final k = _hash(h, 5.2);
      final D = _hash(h, 8.9);
      final i = r * (0.45 + 0.52 * R);
      final d = R * 2 * math.pi;
      final y = math.acos(2 * k - 1);
      final p = math.sin(y) * math.cos(d);
      final f = math.cos(y);
      final P = math.sin(y) * math.sin(d);
      var m = -f;
      var w = p;
      const M = 0.0;
      final S = math.max(1e-6, math.sqrt(m * m + w * w));
      m /= S;
      w /= S;
      final N = f * M - P * w;
      final E = P * m - p * M;
      final I = p * w - f * m;
      final O = (0.25 + 0.55 * D) * (D > 0.5 ? 1 : -1);

      for (var A = 0; A < ghostN; A++) {
        final L = A / ghostN * 2 * math.pi;
        final projected = project(
          (m * math.cos(L) + N * math.sin(L)) * i,
          (w * math.cos(L) + E * math.sin(L)) * i,
          (M * math.cos(L) + I * math.sin(L)) * i,
        );
        final T = (projected[2] / i + 1) / 2;
        dots.add(
          _Dot(
            x: projected[0],
            y: projected[1],
            z: projected[2],
            r: 0.9 * v,
            white: 0.72,
            a: 0.5 * (0.4 + 0.6 * T),
          ),
        );
      }

      for (var A = 0; A < particles; A++) {
        final L = time * O + A / particles * 2 * math.pi + k * 6;
        final projected = project(
          (m * math.cos(L) + N * math.sin(L)) * i,
          (w * math.cos(L) + E * math.sin(L)) * i,
          (M * math.cos(L) + I * math.sin(L)) * i,
        );
        final T = (projected[2] / i + 1) / 2;
        dots.add(
          _Dot(
            x: projected[0],
            y: projected[1],
            z: projected[2],
            r: (1.2 + 1.6 * T) * v,
            white: 0.3 - 0.22 * T,
          ),
        );
      }
    }

    dots.sort((a, b) => a.z.compareTo(b.z));
    _drawDots(canvas, dots, darkInk);
  }

  @override
  bool shouldRepaint(covariant _OrbitsPainter oldDelegate) {
    return oldDelegate.time != time || oldDelegate.darkInk != darkInk;
  }
}

class _BreathingRingPainter extends CustomPainter {
  _BreathingRingPainter({required this.time, required this.darkInk});

  final double time;
  final bool darkInk;

  static List<double> Function(double, double, double) _cam(
    double yaw,
    double pitch,
    double cx,
    double cy,
    double scale,
  ) {
    final se = math.sin(pitch);
    final ce = math.cos(pitch);
    final sy = math.sin(yaw);
    final cyw = math.cos(yaw);
    return (v, b, x) {
      final g = v * cyw + x * sy;
      final u = -v * sy + x * cyw;
      final h = b * ce - u * se;
      final r = b * se + u * ce;
      return [cx + g * scale, cy - h * scale, r];
    };
  }

  @override
  void paint(Canvas canvas, Size size) {
    final n = size.shortestSide;
    final e = n / 2;
    final c = n / 2;
    final radius = n / 2 * 0.78;
    const pitch = 0.3;
    const lanes = 5;
    const segs = 88;
    const bandMul = 3.627;
    const wobMul = 0.368;
    const rBase = 1.1;
    const rDepth = 1.7;
    const rsPow = 0.6;
    const rMin = 0.3;

    final project = _cam(0, pitch, e, c, 1);
    final v = _OrbitsPainter._rs(n, rsPow);
    final dots = <_Dot>[];

    const R = -pitch;
    const k = 1.0;
    const D = 0.0;
    const i = 0.0;
    final d = -i * math.sin(R);
    final y = math.cos(R);
    final p = k * math.sin(R);
    final f = D * p - i * y;
    final P = i * d - k * p;
    final m = k * y - D * d;
    const w = 0.23 * wobMul;
    final M = radius / (1 + 0.85 * w);
    final E = math.max(1, (lanes * bandMul).round());

    for (var I = 0; I < E; I++) {
      final O = (I - (E - 1) / 2) * 0.075;
      final A = (I - (E - 1) / 2).abs() / math.max(1, (E - 1) / 2);
      for (var L = 0; L < segs; L++) {
        final z = L / segs * 2 * math.pi;
        final C = (0.16 * math.sin(z * 3 - time * 1.7 + I * 0.22) +
                0.07 * math.sin(z * 5 + time * 1.1)) *
            wobMul;
        final F = 1 + C;
        final W = k * math.cos(z) + d * math.sin(z) + f * O;
        final j = D * math.cos(z) + y * math.sin(z) + P * O;
        final Y = i * math.cos(z) + p * math.sin(z) + m * O;
        final K = math.sqrt(W * W + j * j + Y * Y);
        final U = M * F;
        final projected = project(W / K * U, j / K * U, Y / K * U);
        final G = (projected[2] / radius + 1) / 2;
        dots.add(
          _Dot(
            x: projected[0],
            y: projected[1],
            z: projected[2],
            r: (rBase + rDepth * G) * (1 - 0.25 * A) * v,
            white: 0.52 - 0.44 * G + 0.18 * A,
            a: 0.4 + 0.6 * G,
          ),
        );
      }
    }

    _OrbitsPainter._drawDots(canvas, dots, darkInk, rMin: rMin);
  }

  @override
  bool shouldRepaint(covariant _BreathingRingPainter oldDelegate) {
    return oldDelegate.time != time || oldDelegate.darkInk != darkInk;
  }
}

class _ComposingRibbonPainter extends CustomPainter {
  _ComposingRibbonPainter({
    required this.time,
    required this.darkInk,
    this.neon = false,
  });

  final double time;
  final bool darkInk;
  final bool neon;

  static List<double> _fibSphere(int i, int n) {
    final golden = math.pi * (3 - math.sqrt(5));
    final y = 1 - 2 * (i + 0.5) / n;
    final r = math.sqrt(math.max(0, 1 - y * y));
    final theta = i * golden;
    return [r * math.cos(theta), y, r * math.sin(theta)];
  }

  @override
  void paint(Canvas canvas, Size size) {
    final n = size.shortestSide;
    final cx = n / 2;
    final cy = n / 2;
    final radius = n / 2 * 0.78;
    const pitchBase = 0.3;
    const lanes = 5;
    const segs = 88;
    const bandMul = 3.9;
    const wobMul = 1.0;
    const rBase = 1.1;
    const rDepth = 1.7;
    const rsPow = 0.6;
    const rMin = 0.3;
    const ghostN = 150;
    final ghostAlphaMul = neon ? 1.8 : 1.0;
    final bandAlphaMul = neon ? 1.25 : 1.0;
    final dotScale = neon ? 1.12 : 1.0;

    final pitch = 0.55 + 0.3 * math.sin(time * 0.18);
    final yaw = time * 0.24;
    final project = _BreathingRingPainter._cam(yaw, pitch, cx, cy, 1);
    final scale = _OrbitsPainter._rs(n, rsPow);
    final dots = <_Dot>[];

    for (var i = 0; i < ghostN; i++) {
      final sphere = _fibSphere(i, ghostN);
      final projected = project(
        sphere[0] * radius,
        sphere[1] * radius,
        sphere[2] * radius,
      );
      final depth = (projected[2] / radius + 1) / 2;
      dots.add(
        _Dot(
          x: projected[0],
          y: projected[1],
          z: projected[2],
          r: 0.8 * scale * dotScale,
          white: 0.78,
          a: (0.1 + 0.22 * depth) * ghostAlphaMul,
        ),
      );
    }

    final R = -pitchBase;
    const k = 1.0;
    const D = 0.0;
    const iVal = 0.0;
    final d = -iVal * math.sin(R);
    final y = math.cos(R);
    final p = k * math.sin(R);
    final f = D * p - iVal * y;
    final P = iVal * d - k * p;
    final m = k * y - D * d;
    const w = 0.23 * wobMul;
    final M = radius / (1 + 0.85 * w);
    final bandCount = math.max(1, (lanes * bandMul).round());

    for (var band = 0; band < bandCount; band++) {
      final O = (band - (bandCount - 1) / 2) * 0.075;
      final edge = (band - (bandCount - 1) / 2).abs() /
          math.max(1, (bandCount - 1) / 2);
      for (var seg = 0; seg < segs; seg++) {
        final z = seg / segs * 2 * math.pi;
        final C = (0.16 * math.sin(z * 3 - time * 1.7 + band * 0.22) +
                0.07 * math.sin(z * 5 + time * 1.1)) *
            wobMul;
        final T = O + C;
        final W = k * math.cos(z) + d * math.sin(z) + f * T;
        final j = D * math.cos(z) + y * math.sin(z) + P * T;
        final Y = iVal * math.cos(z) + p * math.sin(z) + m * T;
        final len = math.sqrt(W * W + j * j + Y * Y);
        final projected = project(W / len * M, j / len * M, Y / len * M);
        final depth = (projected[2] / radius + 1) / 2;
        dots.add(
          _Dot(
            x: projected[0],
            y: projected[1],
            z: projected[2],
            r: (rBase + rDepth * depth) * (1 - 0.25 * edge) * scale * dotScale,
            white: 0.52 - 0.44 * depth + 0.18 * edge,
            a: (0.4 + 0.6 * depth) * bandAlphaMul,
          ),
        );
      }
    }

    _OrbitsPainter._drawDots(
      canvas,
      dots,
      darkInk,
      rMin: neon ? 0.45 : rMin,
      lightShine: !darkInk && !neon,
      neonGlow: neon,
    );
  }

  @override
  bool shouldRepaint(covariant _ComposingRibbonPainter oldDelegate) {
    return oldDelegate.time != time ||
        oldDelegate.darkInk != darkInk ||
        oldDelegate.neon != neon;
  }
}

class _RubikSlice {
  const _RubikSlice({
    required this.axis,
    required this.lo,
    required this.hi,
    required this.ang,
  });

  final int axis;
  final double lo;
  final double hi;
  final double ang;
}

class _RubikMoveState {
  const _RubikMoveState({required this.amount, required this.active});

  final List<double> amount;
  final int active;
}

class _RubikPainter extends CustomPainter {
  _RubikPainter({required this.time, required this.darkInk});

  final double time;
  final bool darkInk;

  static List<_RubikSlice> _slices(int moveCount) {
    final slices = <_RubikSlice>[];
    for (var s = 0; s < moveCount; s++) {
      final axis =
          math.min(2, (_OrbitsPainter._hash(s, 2.3) * 3).floor());
      final lo =
          -1 + 0.5 * math.min(3, (_OrbitsPainter._hash(s, 5.9) * 4).floor());
      final ang = _OrbitsPainter._hash(s, 7.7) < 0.5 ? 1 : -1;
      slices.add(
        _RubikSlice(axis: axis, lo: lo, hi: lo + 0.5, ang: ang * math.pi / 2),
      );
    }
    return slices;
  }

  static _RubikMoveState _moveAmount(double time, int moveCount) {
    const step = 0.42;
    const pause = 1.2;
    final cycle = 2 * moveCount * step + pause;
    final elapsed = time % cycle;
    final amount = List<double>.filled(moveCount, 0);
    var active = -1;
    if (elapsed < 2 * moveCount * step) {
      final moveIndex = (elapsed / step).floor();
      final progress = (elapsed - moveIndex * step) / step;
      final eased = 1 - math.pow(1 - math.min(1, progress / 0.7), 3).toDouble();
      if (moveIndex < moveCount) {
        for (var i = 0; i < moveIndex; i++) {
          amount[i] = 1;
        }
        amount[moveIndex] = eased;
        active = moveIndex;
      } else {
        final reverseIndex = 2 * moveCount - 1 - moveIndex;
        for (var i = 0; i < reverseIndex; i++) {
          amount[i] = 1;
        }
        amount[reverseIndex] = 1 - eased;
        active = reverseIndex;
      }
    }
    return _RubikMoveState(amount: amount, active: active);
  }

  static List<dynamic> _rotate(
    List<double> pos,
    List<_RubikSlice> slices,
    _RubikMoveState state,
  ) {
    var x = pos[0];
    var y = pos[1];
    var z = pos[2];
    var onActiveSlice = false;
    for (var i = 0; i < slices.length; i++) {
      if (state.amount[i] <= 0) continue;
      final slice = slices[i];
      final coord = slice.axis == 0 ? x : slice.axis == 1 ? y : z;
      if (coord < slice.lo || coord >= slice.hi) continue;
      if (i == state.active) onActiveSlice = true;
      final angle = slice.ang * state.amount[i];
      final cosA = math.cos(angle);
      final sinA = math.sin(angle);
      if (slice.axis == 0) {
        final ny = y * cosA - z * sinA;
        z = y * sinA + z * cosA;
        y = ny;
      } else if (slice.axis == 1) {
        final nx = x * cosA + z * sinA;
        z = -x * sinA + z * cosA;
        x = nx;
      } else {
        final nx = x * cosA - y * sinA;
        y = x * sinA + y * cosA;
        x = nx;
      }
    }
    return [x, y, z, onActiveSlice];
  }

  @override
  void paint(Canvas canvas, Size size) {
    final n = size.shortestSide;
    final cx = n / 2;
    final cy = n / 2;
    final radius = n / 2 * 0.82;
    final pitch = 0.35 + 0.1 * math.sin(time * 0.9);
    final project = _OrbitsPainter._cam(time * 0.55, pitch, cx, cy, radius);
    final scale = _OrbitsPainter._rs(n, 0.6);
    const moveCount = 14;
    const latRings = 15;
    const lonDensity = 40;
    const rBase = 0.6;
    const rDepth = 1.7;
    const rActive = 0.3;
    const inkFar = 0.62;
    const inkSpan = 0.54;
    const rMin = 0.3;

    final slices = _slices(moveCount);
    final moveState = _moveAmount(time, moveCount);
    final dots = <_Dot>[];

    for (var ring = 0; ring <= latRings; ring++) {
      final lat = -math.pi / 2 + ring / latRings * math.pi;
      final cosLat = math.cos(lat);
      final sinLat = math.sin(lat);
      final lonCount = math.max(1, (cosLat.abs() * lonDensity).round());
      for (var lon = 0; lon < lonCount; lon++) {
        final lonAngle = lon / lonCount * 2 * math.pi;
        final rotated = _rotate(
          [cosLat * math.cos(lonAngle), sinLat, cosLat * math.sin(lonAngle)],
          slices,
          moveState,
        );
        final px = rotated[0] as double;
        final py = rotated[1] as double;
        final pz = rotated[2] as double;
        final active = rotated[3] as bool;
        final projected = project(px, py, pz);
        final depth = (projected[2] + 1) / 2;
        dots.add(
          _Dot(
            x: projected[0],
            y: projected[1],
            z: projected[2],
            r: (rBase + rDepth * depth + (active ? rActive : 0)) * scale,
            white: inkFar - inkSpan * depth - (active ? 0.14 : 0),
          ),
        );
      }
    }

    _OrbitsPainter._drawDots(canvas, dots, darkInk, rMin: rMin);
  }

  @override
  bool shouldRepaint(covariant _RubikPainter oldDelegate) {
    return oldDelegate.time != time || oldDelegate.darkInk != darkInk;
  }
}
