import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../data/procedure_repository.dart';
import 'login_screen.dart';
import 'procedure_selection_theme.dart';
import 'signup_screen.dart';
import 'widgets/step1_background.dart';

/// Light welcome — orbit of procedure photos + Step 1 aura light.
class WelcomeScreen2 extends StatefulWidget {
  const WelcomeScreen2({super.key, required this.repo});

  final ProcedureRepository repo;

  @override
  State<WelcomeScreen2> createState() => _WelcomeScreen2State();
}

class _WelcomeScreen2State extends State<WelcomeScreen2>
    with TickerProviderStateMixin {
  late final AnimationController _orbit = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 32000),
  )..repeat();

  late final AnimationController _aura = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 9000),
  )..repeat();

  late final AnimationController _enter = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 780),
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _enter.forward();
    });
  }

  @override
  void dispose() {
    _orbit.dispose();
    _aura.dispose();
    _enter.dispose();
    super.dispose();
  }

  void _openSignup() {
    Navigator.of(context).push(
      _SoftAuthRoute(
        page: SignUpScreen(repo: widget.repo),
      ),
    );
  }

  void _openLogin() {
    Navigator.of(context).push(
      _SoftAuthRoute(
        page: LoginScreen(repo: widget.repo),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.paddingOf(context);
    final size = MediaQuery.sizeOf(context);
    final orbitSize = (size.width * 1.05).clamp(320.0, 460.0);

    final enter = CurvedAnimation(parent: _enter, curve: Curves.easeOutCubic);

    return Scaffold(
      backgroundColor: ProcedureSelectionTheme.pageBackground,
      body: Stack(
        children: [
          const Step1Background(),
          SafeArea(
            child: Padding(
              padding: EdgeInsets.fromLTRB(22, 6, 22, 10 + pad.bottom * 0.12),
              child: AnimatedBuilder(
                animation: enter,
                builder: (context, _) {
                  final t = enter.value;
                  return Opacity(
                    opacity: t,
                    child: Transform.translate(
                      offset: Offset(0, (1 - t) * 14),
                      child: Column(
                        children: [
                          const SizedBox(height: 4),
                          const _AeGlowUpPill(),
                          const SizedBox(height: 8),
                          Expanded(
                            child: Center(
                              child: SizedBox(
                                width: orbitSize,
                                height: orbitSize,
                                child: _ProcedureOrbit(
                                  orbit: _orbit,
                                  aura: _aura,
                                ),
                              ),
                            ),
                          ),
                          Text(
                            'From inspiration to transformation',
                            textAlign: TextAlign.center,
                            style: GoogleFonts.plusJakartaSans(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w500,
                              height: 1.45,
                              color: ProcedureSelectionTheme.muted,
                            ),
                          ),
                          const SizedBox(height: 22),
                          _StartJourneyButton(onTap: _openSignup),
                          const SizedBox(height: 16),
                          _SignInRow(onSignIn: _openLogin),
                          const SizedBox(height: 4),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _OrbitItem {
  const _OrbitItem({required this.asset, required this.label});

  final String asset;
  final String label;
}

const _orbitItems = <_OrbitItem>[
  _OrbitItem(asset: 'assets/jelofiller.png', label: 'LIP FILLER'),
  _OrbitItem(asset: 'assets/rhinoplastyjello.png', label: 'RHINOPLASTY'),
  _OrbitItem(asset: 'assets/botoxjelli.png', label: 'BOTOX'),
  _OrbitItem(asset: 'assets/hairtranspantjelo.png', label: 'HAIR TRANSPLANT'),
  _OrbitItem(asset: 'assets/jellomicronedeling.png', label: 'MICRONEEDLING'),
  _OrbitItem(asset: 'assets/blapherojellli.png', label: 'SKIN BOOSTER'),
];

const _outerOrbitItems = <_OrbitItem>[
  _OrbitItem(asset: 'assets/scarremoverjelli.png', label: 'SCAR REMOVAL'),
  _OrbitItem(asset: 'assets/blapheroplastyjelli.png', label: 'BLEPHAROPLASTY'),
  _OrbitItem(asset: 'assets/boobjobjelli.png', label: 'BREAST'),
  _OrbitItem(asset: 'assets/tummytuckjelly.png', label: 'TUMMY TUCK'),
  _OrbitItem(asset: 'assets/jawlinejelli.png', label: 'JAWLINE'),
  _OrbitItem(asset: 'assets/faceliftjelli.png', label: 'FACELIFT'),
  _OrbitItem(asset: 'assets/cheekfillerjelli.png', label: 'CHEEK FILLER'),
];

class _ProcedureOrbit extends StatelessWidget {
  const _ProcedureOrbit({
    required this.orbit,
    required this.aura,
  });

  final AnimationController orbit;
  final AnimationController aura;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([orbit, aura]),
      builder: (context, _) {
        return LayoutBuilder(
          builder: (context, constraints) {
            final side = math.min(constraints.maxWidth, constraints.maxHeight);
            final canvasSide = side * 1.55;
            final center = Offset(canvasSide / 2, canvasSide / 2);
            final ringRadius = side * 0.34;
            final outerRingRadius = side * 0.56;
            final photoSize = side * 0.20;
            final outerPhotoSize = side * 0.135;
            final turn = orbit.value * math.pi * 2;

            // Concentric aura rings — photo orbits + larger animated circles.
            final auraRings = <({double radius, double phase, bool soft})>[
              (radius: side * 0.20, phase: 0.55, soft: true),
              (radius: ringRadius, phase: 0.35, soft: false),
              (radius: outerRingRadius, phase: 0.0, soft: true),
              (radius: side * 0.66, phase: 0.18, soft: true),
              (radius: side * 0.76, phase: 0.72, soft: true),
            ];

            List<Widget> orbitNodes({
              required List<_OrbitItem> items,
              required double radius,
              required double size,
              required double phaseOffset,
              bool flipLabelOnBottom = false,
            }) {
              const glowPad = 20.0;
              const labelSpace = 14.0;
              return List.generate(items.length, (i) {
                final item = items[i];
                final angle = turn +
                    phaseOffset +
                    (i / items.length) * math.pi * 2 -
                    math.pi / 2;
                // Outer ring only: lower half → label under the photo.
                final labelBelow =
                    flipLabelOnBottom && math.sin(angle) > 0.08;
                final nodeW = size + glowPad;
                final nodeH = size + glowPad + labelSpace;
                final photoCx = center.dx + radius * math.cos(angle);
                final photoCy = center.dy + radius * math.sin(angle);
                final photoCenterFromTop = labelBelow
                    ? glowPad / 2 + size / 2
                    : labelSpace + glowPad / 2 + size / 2;
                final x = photoCx - nodeW / 2;
                final y = photoCy - photoCenterFromTop;
                return Positioned(
                  left: x,
                  top: y,
                  width: nodeW,
                  height: nodeH,
                  child: _OrbitPhoto(
                    asset: item.asset,
                    label: item.label,
                    size: size,
                    labelBelow: labelBelow,
                  ),
                );
              });
            }

            return OverflowBox(
              alignment: Alignment.center,
              maxWidth: canvasSide,
              maxHeight: canvasSide,
              child: SizedBox(
                width: canvasSide,
                height: canvasSide,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    // Soft cream glow disc (Step 1 light language).
                    Positioned.fill(
                      child: IgnorePointer(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: RadialGradient(
                              colors: [
                                const Color(0xFFEAE6E5).withValues(alpha: 0.45),
                                const Color(0xFFEAE6E5).withValues(alpha: 0.12),
                                Colors.transparent,
                              ],
                              stops: const [0.0, 0.42, 1.0],
                            ),
                          ),
                        ),
                      ),
                    ),
                    // Animated cream/white light circles.
                    for (final ring in auraRings)
                      IgnorePointer(
                        child: CustomPaint(
                          size: Size(canvasSide, canvasSide),
                          painter: _WelcomeAuraPainter(
                            center: center,
                            radius: ring.radius,
                            progress: (aura.value + ring.phase) % 1.0,
                            soft: ring.soft,
                          ),
                        ),
                      ),
                    // Orbit guide rings.
                    IgnorePointer(
                      child: CustomPaint(
                        size: Size(canvasSide, canvasSide),
                        painter: _OrbitGuidePainter(
                          center: center,
                          radius: ringRadius,
                        ),
                      ),
                    ),
                    IgnorePointer(
                      child: CustomPaint(
                        size: Size(canvasSide, canvasSide),
                        painter: _OrbitGuidePainter(
                          center: center,
                          radius: outerRingRadius,
                        ),
                      ),
                    ),
                    // Outer ring — smaller photos; labels flip under at the bottom.
                    ...orbitNodes(
                      items: _outerOrbitItems,
                      radius: outerRingRadius,
                      size: outerPhotoSize,
                      phaseOffset: math.pi / _outerOrbitItems.length,
                      flipLabelOnBottom: true,
                    ),
                    // Inner ring — main procedure photos (labels always above).
                    ...orbitNodes(
                      items: _orbitItems,
                      radius: ringRadius,
                      size: photoSize,
                      phaseOffset: 0,
                    ),
                    // Center headline.
                    Align(
                      alignment: Alignment.center,
                      child: _OrbitCenter(
                        maxWidth: side * 0.52,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _OrbitPhoto extends StatelessWidget {
  const _OrbitPhoto({
    required this.asset,
    required this.label,
    required this.size,
    this.labelBelow = false,
  });

  final String asset;
  final String label;
  final double size;
  final bool labelBelow;

  @override
  Widget build(BuildContext context) {
    const glowPad = 20.0;
    final labelText = Text(
      label,
      textAlign: TextAlign.center,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: GoogleFonts.plusJakartaSans(
        fontSize: size < 56 ? 7 : 8,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.6,
        color: ProcedureSelectionTheme.ink.withValues(alpha: 0.72),
        height: 1,
      ),
    );

    final photo = SizedBox(
      width: size + glowPad,
      height: size + glowPad,
      child: Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          IgnorePointer(
            child: CustomPaint(
              size: Size(size + glowPad, size + glowPad),
              painter: _PhotoDiffuseLightPainter(photoRadius: size / 2),
            ),
          ),
          ClipOval(
            child: SizedBox(
              width: size,
              height: size,
              child: Image.asset(
                asset,
                fit: BoxFit.cover,
                filterQuality: FilterQuality.high,
              ),
            ),
          ),
        ],
      ),
    );

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.max,
      children: labelBelow
          ? [photo, const SizedBox(height: 3), labelText]
          : [labelText, const SizedBox(height: 3), photo],
    );
  }
}

class _PhotoDiffuseLightPainter extends CustomPainter {
  const _PhotoDiffuseLightPainter({required this.photoRadius});

  final double photoRadius;

  static const _cream = Color(0xFFEAE6E5);

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);

    // Compact soft outer bloom.
    for (var i = 8; i >= 1; i--) {
      final t = i / 8;
      final r = photoRadius + 1.5 + i * 1.05;
      canvas.drawCircle(
        c,
        r,
        Paint()
          ..color = Color.lerp(
            Colors.white,
            _cream,
            0.28,
          )!.withValues(alpha: 0.06 + 0.08 * t),
      );
    }

    // Soft white band near the edge.
    for (var i = 5; i >= 1; i--) {
      final t = i / 5;
      canvas.drawCircle(
        c,
        photoRadius + i * 0.85,
        Paint()..color = Colors.white.withValues(alpha: 0.10 + 0.14 * t),
      );
    }

    // Subtle cream wash hugging the crop.
    for (var i = 3; i >= 1; i--) {
      final t = i / 3;
      canvas.drawCircle(
        c,
        photoRadius + 0.6 + i * 0.7,
        Paint()..color = _cream.withValues(alpha: 0.08 + 0.12 * t),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _PhotoDiffuseLightPainter oldDelegate) {
    return oldDelegate.photoRadius != photoRadius;
  }
}

class _OrbitCenter extends StatelessWidget {
  const _OrbitCenter({required this.maxWidth});

  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: maxWidth,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Discover.\nDecide.\nGlow.',
            textAlign: TextAlign.center,
            style: GoogleFonts.plusJakartaSans(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              height: 1.2,
              letterSpacing: -0.3,
              color: ProcedureSelectionTheme.ink,
            ),
          ),
        ],
      ),
    );
  }
}

/// Outlined pill mark — Aesthetic Journey badge.
class _AeGlowUpPill extends StatelessWidget {
  const _AeGlowUpPill();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: ProcedureSelectionTheme.ink.withValues(alpha: 0.78),
          width: 0.9,
        ),
      ),
      child: Text(
        'ÆSTHETIC JOURNEY',
        style: GoogleFonts.inter(
          fontSize: 9.5,
          fontWeight: FontWeight.w500,
          letterSpacing: 1.4,
          height: 1,
          color: ProcedureSelectionTheme.ink,
        ),
      ),
    );
  }
}

class _OrbitGuidePainter extends CustomPainter {
  const _OrbitGuidePainter({required this.center, required this.radius});

  final Offset center;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = const Color(0xFF1A1A1F).withValues(alpha: 0.08)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.1,
    );
  }

  @override
  bool shouldRepaint(covariant _OrbitGuidePainter oldDelegate) {
    return oldDelegate.center != center || oldDelegate.radius != radius;
  }
}

/// Step 1–style cream aura ring with traveling light points (no MaskFilter blur).
class _WelcomeAuraPainter extends CustomPainter {
  const _WelcomeAuraPainter({
    required this.center,
    required this.radius,
    required this.progress,
    this.soft = false,
  });

  final Offset center;
  final double radius;
  final double progress;
  final bool soft;

  static const _cream = Color(0xFFEAE6E5);
  static const _movingPoints = 5;
  static const _trail = 7;

  Offset _pointOnRing(double angle) {
    return Offset(
      center.dx + radius * math.cos(angle),
      center.dy + radius * math.sin(angle),
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final ringAlpha = soft ? 0.12 : 0.18;
    final midAlpha = soft ? 0.20 : 0.30;
    final strokeWide = soft ? 20.0 : 14.0;
    final strokeMid = soft ? 7.0 : 5.5;

    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = _cream.withValues(alpha: ringAlpha)
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWide
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = _cream.withValues(alpha: midAlpha)
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeMid
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = Colors.white.withValues(alpha: soft ? 0.45 : 0.70)
        ..style = PaintingStyle.stroke
        ..strokeWidth = soft ? 1.1 : 1.3
        ..strokeCap = StrokeCap.round,
    );

    final points = soft ? 4 : _movingPoints;
    for (var i = 0; i < points; i++) {
      final base = progress + i / points;
      final speed = 1.0 + (i % 3) * 0.12;
      final headT = (base * speed) % 1.0;
      final headAngle = headT * math.pi * 2 - math.pi / 2;

      for (var t = 0; t < _trail; t++) {
        final trailT = t / (_trail - 1);
        final angle = headAngle - trailT * 0.42;
        final p = _pointOnRing(angle);
        final fade = 1.0 - trailT;
        final scale = soft ? 0.8 : 1.0;

        canvas.drawCircle(
          p,
          (5.0 * fade + 1.2) * scale,
          Paint()..color = Colors.white.withValues(alpha: 0.08 + 0.16 * fade),
        );
        canvas.drawCircle(
          p,
          (2.6 * fade + 0.7) * scale,
          Paint()..color = _cream.withValues(alpha: 0.14 + 0.26 * fade),
        );
        canvas.drawCircle(
          p,
          (1.0 + 1.6 * fade) * scale,
          Paint()..color = Colors.white.withValues(alpha: 0.32 + 0.42 * fade),
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _WelcomeAuraPainter oldDelegate) {
    return oldDelegate.center != center ||
        oldDelegate.radius != radius ||
        oldDelegate.progress != progress ||
        oldDelegate.soft != soft;
  }
}

class _StartJourneyButton extends StatefulWidget {
  const _StartJourneyButton({required this.onTap});

  final VoidCallback onTap;

  @override
  State<_StartJourneyButton> createState() => _StartJourneyButtonState();
}

class _StartJourneyButtonState extends State<_StartJourneyButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _press = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  );

  Future<void> _handleTap() async {
    if (_press.isAnimating) return;
    await _press.forward();
    if (!mounted) return;
    widget.onTap();
    // Reset after navigation so returning feels fresh.
    await Future<void>.delayed(const Duration(milliseconds: 120));
    if (mounted) _press.reset();
  }

  @override
  void dispose() {
    _press.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _press,
      builder: (context, child) {
        final t = Curves.easeOutCubic.transform(_press.value);
        final scale = 1.0 - 0.035 * math.sin(t * math.pi);
        final glow = 0.18 + 0.35 * math.sin(t * math.pi);
        return Transform.scale(
          scale: scale,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFFEAE6E5).withValues(alpha: glow),
                  blurRadius: 22 + 18 * t,
                  spreadRadius: 1 + 2 * t,
                ),
              ],
            ),
            child: child,
          ),
        );
      },
      child: Material(
        color: ProcedureSelectionTheme.buttonPrimary,
        borderRadius: BorderRadius.circular(999),
        child: InkWell(
          onTap: _handleTap,
          borderRadius: BorderRadius.circular(999),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 17, horizontal: 22),
            child: Center(
              child: Text(
                'Get Started',
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                  height: 1.0,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Soft cream wash + fade/slide into auth screens.
class _SoftAuthRoute<T> extends PageRouteBuilder<T> {
  _SoftAuthRoute({required Widget page})
      : super(
          opaque: false,
          barrierColor: Colors.transparent,
          transitionDuration: const Duration(milliseconds: 780),
          reverseTransitionDuration: const Duration(milliseconds: 420),
          pageBuilder: (context, animation, secondaryAnimation) => page,
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            final enter = CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
              reverseCurve: Curves.easeInCubic,
            );
            final veil = TweenSequence<double>([
              TweenSequenceItem(
                tween: Tween(begin: 0.0, end: 1.0)
                    .chain(CurveTween(curve: Curves.easeOut)),
                weight: 40,
              ),
              TweenSequenceItem(
                tween: Tween(begin: 1.0, end: 0.0)
                    .chain(CurveTween(curve: Curves.easeIn)),
                weight: 60,
              ),
            ]).animate(animation);

            final slide = Tween<Offset>(
              begin: const Offset(0, 0.08),
              end: Offset.zero,
            ).animate(enter);
            final scale = Tween<double>(begin: 0.94, end: 1.0).animate(enter);
            final fade = Tween<double>(begin: 0.0, end: 1.0).animate(
              CurvedAnimation(
                parent: animation,
                curve: const Interval(0.12, 1.0, curve: Curves.easeOut),
              ),
            );

            return Stack(
              fit: StackFit.expand,
              children: [
                FadeTransition(
                  opacity: fade,
                  child: SlideTransition(
                    position: slide,
                    child: ScaleTransition(
                      scale: scale,
                      child: child,
                    ),
                  ),
                ),
                IgnorePointer(
                  child: AnimatedBuilder(
                    animation: veil,
                    builder: (context, _) {
                      final v = veil.value;
                      if (v <= 0.01) return const SizedBox.shrink();
                      return DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: RadialGradient(
                            center: const Alignment(0, 0.55),
                            radius: 1.15,
                            colors: [
                              Colors.white.withValues(alpha: 0.72 * v),
                              const Color(0xFFEAE6E5).withValues(alpha: 0.55 * v),
                              const Color(0xFFEAE6E5).withValues(alpha: 0.0),
                            ],
                            stops: const [0.0, 0.45, 1.0],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            );
          },
        );
}

class _SignInRow extends StatelessWidget {
  const _SignInRow({required this.onSignIn});

  final VoidCallback onSignIn;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      alignment: WrapAlignment.center,
      children: [
        Text(
          'I already have an account — ',
          style: GoogleFonts.plusJakartaSans(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: ProcedureSelectionTheme.muted,
          ),
        ),
        GestureDetector(
          onTap: onSignIn,
          child: Text(
            'Sign in',
            style: GoogleFonts.plusJakartaSans(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: ProcedureSelectionTheme.ink,
              decoration: TextDecoration.underline,
              decorationColor: ProcedureSelectionTheme.ink.withValues(alpha: 0.35),
            ),
          ),
        ),
      ],
    );
  }
}
