import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../data/procedure_repository.dart';
import 'login_screen.dart';
import 'signup_screen.dart';

const _cardInk = Color(0xFF0A080C);
const _beforeAsset = 'assets/beforew.png';
const _afterAsset = 'assets/afterw.png';
const _photoScale = 1.18;
// Positive = move photo lower (and keep dots aligned).
const _photoLift = 80.0;
// Must match `_ComparisonImage` alignment, otherwise dots drift vertically.
const _photoContentAlignY = 0.18;
// Extra Y offset just for the face points (relative to the photo).
const _featureDotYOffset = 0.0;
const _sheetHeightFraction = 0.38;

double _photoContentHeight(double height) => height / _photoScale;

double _photoContentTopOffset(double height) {
  final contentH = _photoContentHeight(height);
  // Alignment.y: -1 = top, 1 = bottom.
  final t = ((_photoContentAlignY + 1) / 2).clamp(0.0, 1.0);
  return (height - contentH) * t;
}

double _photoY(double normalizedY, double height) =>
    _photoContentTopOffset(height) + normalizedY * _photoContentHeight(height) + _photoLift;

double _welcomePhotoHeight(double availableH) =>
    (availableH * 0.70).clamp(320.0, 720.0);
/// Left = before only; right = tap feature dots to reveal that section of after.
const _rightRegionStart = 0.48;

enum _FeatureId { forehead, eyes, smile }

class _FeatureSpot {
  const _FeatureSpot({
    required this.id,
    required this.dotX,
    required this.dotY,
    required this.rX1,
    required this.rY1,
    required this.rX2,
    required this.rY2,
  });

  final _FeatureId id;
  final double dotX;
  final double dotY;
  final double rX1;
  final double rY1;
  final double rX2;
  final double rY2;

  Rect _clampToBounds(Rect r, double width, double height) {
    final bounded = r.intersect(Rect.fromLTWH(0, 0, width, height));
    if (bounded.width <= 1 || bounded.height <= 1) {
      // Fallback to a minimal safe rect instead of disappearing.
      return Rect.fromLTWH(0, 0, width, height).deflate(1);
    }
    return bounded;
  }

  Rect revealRect(double width, double height) {
    final left = width * _rightRegionStart;
    final raw = Rect.fromLTRB(
      (rX1 * width).clamp(left, width),
      _photoY(rY1, height),
      rX2 * width,
      _photoY(rY2, height),
    );
    // Ensure the reveal region stays within the visible photo area.
    return _clampToBounds(raw, width, height);
  }

  /// Compact vertical zone for scan animation (centered on tap point).
  Rect scanRect(double width, double height) {
    final r = revealRect(width, height);
    final cy = _photoY(dotY + _featureDotYOffset, height);
    final halfH = switch (id) {
      _FeatureId.forehead => height * 0.055,
      _FeatureId.eyes => height * 0.058,
      _FeatureId.smile => height * 0.052,
    };
    final insetX = r.width * 0.06;
    final raw = Rect.fromLTRB(
      r.left + insetX,
      (cy - halfH).clamp(r.top, r.bottom - 1),
      r.right - insetX,
      (cy + halfH).clamp(r.top + 1, r.bottom),
    );
    return _clampToBounds(raw, width, height);
  }
}

const _features = <_FeatureSpot>[
  // Forehead — right half, mid-forehead
  _FeatureSpot(id: _FeatureId.forehead, dotX: 0.64, dotY: 0.24, rX1: 0.52, rY1: 0.14, rX2: 0.80, rY2: 0.34),
  // Eyes / under-eye
  _FeatureSpot(id: _FeatureId.eyes, dotX: 0.68, dotY: 0.39, rX1: 0.52, rY1: 0.30, rX2: 0.84, rY2: 0.48),
  // Mouth / lips
  _FeatureSpot(id: _FeatureId.smile, dotX: 0.64, dotY: 0.66, rX1: 0.52, rY1: 0.56, rX2: 0.80, rY2: 0.76),
];

/// Portrait face boundary — right side of the face only (scan lives on after half).
Path _portraitHeadClip(double width, double height) {
  double y(double v) => _photoY(v, height);
  return Path()
    ..moveTo(width * 0.50, y(0.12))
    ..cubicTo(width * 0.68, y(0.08), width * 0.84, y(0.18), width * 0.85, y(0.38))
    ..cubicTo(width * 0.86, y(0.56), width * 0.78, y(0.74), width * 0.60, y(0.82))
    ..lineTo(width * 0.50, y(0.82))
    ..close();
}

class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key, required this.repo});

  final ProcedureRepository repo;

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> with TickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat(reverse: true);

  final Set<_FeatureId> _revealed = {};
  final Map<_FeatureId, AnimationController> _revealControllers = {};
  final Map<_FeatureId, AnimationController> _scanControllers = {};
  final Map<_FeatureId, AnimationController> _dotTapControllers = {};
  int _revealGeneration = 0;
  bool _sheetRevealed = false;
  bool _photoRevealed = false;
  bool _showSlider = false;
  double _split = 0.5;

  static const _revealDuration = Duration(milliseconds: 720);
  static const _scanDuration = Duration(milliseconds: 2600);
  static const _dotTapPulseDuration = Duration(milliseconds: 500);
  static const _sheetEnterDuration = Duration(milliseconds: 600);
  static const _photoEnterDuration = Duration(milliseconds: 700);

  @override
  void initState() {
    super.initState();
    Future<void>.delayed(const Duration(milliseconds: 80), () {
      if (!mounted) return;
      setState(() => _sheetRevealed = true);
    });
    Future<void>.delayed(const Duration(milliseconds: 720), () {
      if (!mounted) return;
      setState(() => _photoRevealed = true);
    });
  }

  @override
  void dispose() {
    _pulse.dispose();
    for (final c in _revealControllers.values) {
      c.dispose();
    }
    for (final c in _scanControllers.values) {
      c.dispose();
    }
    for (final c in _dotTapControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  double _revealProgress(_FeatureId id) {
    final controller = _revealControllers[id];
    if (controller != null) {
      return Curves.easeOutCubic.transform(controller.value);
    }
    return _revealed.contains(id) ? 1.0 : 0.0;
  }

  void _onRevealFinished(bool willComplete) {
    if (!willComplete) return;
    Future<void>.delayed(const Duration(milliseconds: 180), () {
      if (!mounted) return;
      setState(() {
        _showSlider = true;
        _split = 0.5;
        _pulse.stop();
      });
    });
  }

  void _revealFeature(_FeatureId id) {
    if (_revealed.contains(id)) return;
    final willComplete = _revealed.length + 1 >= _features.length;

    final controller = AnimationController(vsync: this, duration: _revealDuration);
    _revealControllers[id] = controller;

    final scan = AnimationController(vsync: this, duration: _scanDuration);
    _scanControllers[id] = scan;

    final dotTap = AnimationController(vsync: this, duration: _dotTapPulseDuration);
    _dotTapControllers[id] = dotTap;

    setState(() {
      _revealed.add(id);
      _revealGeneration++;
    });

    void tick() {
      if (mounted) setState(() {});
    }

    controller.addListener(tick);
    scan.addListener(tick);
    dotTap.addListener(tick);

    scan.forward().then((_) {
      if (!mounted) return;
      scan.dispose();
      setState(() => _scanControllers.remove(id));
    });

    dotTap.forward().then((_) {
      if (!mounted) return;
      dotTap.dispose();
      setState(() => _dotTapControllers.remove(id));
    });

    Future<void>.delayed(const Duration(milliseconds: 280)).then((_) async {
      if (!mounted) return;
      await controller.forward();
      if (!mounted) return;
      controller.dispose();
      setState(() {
        _revealControllers.remove(id);
        _revealGeneration++;
      });
      _onRevealFinished(willComplete);
    });
  }

  double _dotTapScale(_FeatureId id) {
    final controller = _dotTapControllers[id];
    if (controller == null) return 1.0;
    return TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween(begin: 1.0, end: 1.5).chain(CurveTween(curve: Curves.easeOut)),
        weight: 50,
      ),
      TweenSequenceItem(
        tween: Tween(begin: 1.5, end: 1.0).chain(CurveTween(curve: Curves.easeIn)),
        weight: 50,
      ),
    ]).evaluate(controller);
  }

  void _setSplitFromDx(double dx, double width) {
    final x = (dx / width).clamp(0.12, 0.88);
    if (_split != x) setState(() => _split = x);
  }

  void _openSignUp(BuildContext context) {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => SignUpScreen(repo: widget.repo),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.paddingOf(context);
    final screenH = MediaQuery.sizeOf(context).height;
    final safeH = (screenH - pad.top - pad.bottom).clamp(0.0, double.infinity);
    final sheetMinHeight = math.max(220.0, safeH * _sheetHeightFraction);
    final photoH = math.max(260.0, math.min(_welcomePhotoHeight(safeH), screenH - sheetMinHeight));
    final inter = GoogleFonts.inter;
    final playfair = GoogleFonts.playfairDisplay;
    const sheetRadius = BorderRadius.vertical(top: Radius.circular(28));

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: photoH,
            child: AnimatedOpacity(
            duration: _photoEnterDuration,
            curve: Curves.easeOutCubic,
            opacity: _photoRevealed ? 1 : 0,
            child: AnimatedSlide(
              duration: _photoEnterDuration,
              curve: Curves.easeOutCubic,
              offset: _photoRevealed ? Offset.zero : const Offset(0, 0.05),
              child: LayoutBuilder(
            builder: (context, constraints) {
              final w = constraints.maxWidth;
              final h = constraints.maxHeight;

              final splitX = w * _split;

              return AnimatedSwitcher(
                duration: const Duration(milliseconds: 450),
                child: _showSlider
                    ? GestureDetector(
                        key: const ValueKey('slider'),
                        behavior: HitTestBehavior.opaque,
                        onHorizontalDragUpdate: (d) {
                          _setSplitFromDx(_split * w + d.delta.dx, w);
                        },
                        onTapDown: (d) => _setSplitFromDx(d.localPosition.dx, w),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            Positioned.fill(
                              child: _ComparisonImage(asset: _afterAsset, width: w, height: h),
                            ),
                            Positioned.fill(
                              child: ClipRect(
                                clipper: _LeftSplitClipper(fraction: _split),
                                child: _ComparisonImage(asset: _beforeAsset, width: w, height: h),
                              ),
                            ),
                            Positioned.fill(child: _photoGradient(story: true)),
                            Positioned(
                              left: splitX - 0.75,
                              top: 0,
                              bottom: 0,
                              child: Container(
                                width: 1.5,
                                color: Colors.white.withValues(alpha: 0.6),
                              ),
                            ),
                            Positioned(
                              left: splitX - 14,
                              top: h / 2 - 14,
                              child: GestureDetector(
                                onHorizontalDragUpdate: (d) {
                                  _setSplitFromDx(_split * w + d.delta.dx, w);
                                },
                                child: const _SliderHandle(),
                              ),
                            ),
                            const Positioned(
                              top: 14,
                              left: 14,
                              child: _SliderCornerLabel(text: 'BEFORE'),
                            ),
                            const Positioned(
                              top: 14,
                              right: 14,
                              child: _SliderCornerLabel(text: 'AFTER', bright: true),
                            ),
                          ],
                        ),
                      )
                    : Stack(
                        key: const ValueKey('dots'),
                        fit: StackFit.expand,
                        children: [
                          Positioned.fill(
                            child: _ComparisonImage(asset: _beforeAsset, width: w, height: h),
                          ),
                          if (_revealed.isNotEmpty)
                            Positioned.fill(
                              child: ClipPath(
                                clipper: _AnimatedFeatureRectsClipper(
                                  revealed: _revealed,
                                  progress: {
                                    for (final id in _revealed) id: _revealProgress(id),
                                  },
                                  width: w,
                                  height: h,
                                  generation: _revealGeneration,
                                ),
                                child: Opacity(
                                  opacity: () {
                                    final t = _revealed
                                        .map(_revealProgress)
                                        .fold(0.0, (a, b) => a > b ? a : b);
                                    return (0.25 + 0.75 * t).clamp(0.0, 1.0);
                                  }(),
                                  child: _ComparisonImage(asset: _afterAsset, width: w, height: h),
                                ),
                              ),
                            ),
                          for (final spot in _features)
                            if (_scanControllers.containsKey(spot.id))
                              _FaceScanOverlay(
                                spot: spot,
                                width: w,
                                height: h,
                                animation: _scanControllers[spot.id]!,
                              ),
                          Positioned.fill(child: _photoGradient(story: true)),
                          for (final spot in _features) ...[
                            if (!_revealed.contains(spot.id) || _revealProgress(spot.id) < 1.0)
                              _FeatureDot(
                                spot: spot,
                                width: w,
                                height: h,
                                pulse: _pulse,
                                tapScale: _dotTapScale(spot.id),
                                opacity: !_revealed.contains(spot.id)
                                    ? 1.0
                                    : (1.0 - _revealProgress(spot.id)).clamp(0.0, 1.0),
                                onTap: () => _revealFeature(spot.id),
                              ),
                            if (!_revealed.contains(spot.id) && _photoRevealed)
                              _DotTapHint(
                                spot: spot,
                                width: w,
                                height: h,
                                pulse: _pulse,
                              ),
                          ],
                        ],
                      ),
              );
            },
          ),
            ),
          ),
          ),
          // Fade behind the sheet only (prevents "double shadow" bands).
          Positioned(
            top: math.max(0.0, screenH - sheetMinHeight - 60),
            left: 0,
            right: 0,
            bottom: 0,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.0),
                      Colors.black.withValues(alpha: 0.55),
                      Colors.black.withValues(alpha: 0.9),
                      Colors.black,
                    ],
                    stops: const [0.0, 0.35, 0.78, 1.0],
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            top: pad.top + 10,
            left: 0,
            right: 0,
            child: AnimatedOpacity(
              duration: _photoEnterDuration,
              curve: Curves.easeOutCubic,
              opacity: _photoRevealed ? 1 : 0,
              child: const Center(child: _LogoPill()),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: AnimatedOpacity(
              duration: _sheetEnterDuration,
              curve: Curves.easeOutCubic,
              opacity: _sheetRevealed ? 1 : 0,
              child: AnimatedSlide(
                duration: _sheetEnterDuration,
                curve: Curves.easeOutCubic,
                offset: _sheetRevealed ? Offset.zero : const Offset(0, 0.08),
                child: ClipRRect(
                  borderRadius: sheetRadius,
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 40, sigmaY: 40),
                    child: SafeArea(
                      top: false,
                      child: Container(
                        width: double.infinity,
                        constraints: BoxConstraints(minHeight: sheetMinHeight),
                        padding: const EdgeInsets.fromLTRB(22, 28, 22, 18),
                        decoration: BoxDecoration(
                          color: const Color(0xFF08060A).withValues(alpha: 0.78),
                          borderRadius: sheetRadius,
                          border: Border.all(color: Colors.white.withValues(alpha: 0.08), width: 0.5),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.35),
                              blurRadius: 24,
                              offset: const Offset(0, -8),
                            ),
                          ],
                        ),
                        child: SingleChildScrollView(
                          padding: EdgeInsets.only(bottom: 10 + pad.bottom),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    child: Text.rich(
                                      TextSpan(
                                        style: playfair(
                                          fontSize: 28,
                                          fontWeight: FontWeight.w700,
                                          color: Colors.white,
                                          height: 1.1,
                                          letterSpacing: -0.3,
                                        ),
                                        children: [
                                          const TextSpan(text: 'Welcome to\nyour '),
                                          TextSpan(
                                            text: 'beauty\n',
                                            style: playfair(
                                              fontSize: 28,
                                              fontWeight: FontWeight.w600,
                                              fontStyle: FontStyle.italic,
                                              color: Colors.white.withValues(alpha: 0.55),
                                              height: 1.1,
                                              letterSpacing: -0.3,
                                            ),
                                          ),
                                          TextSpan(
                                            text: 'journey',
                                            style: playfair(
                                              fontSize: 28,
                                              fontWeight: FontWeight.w600,
                                              fontStyle: FontStyle.italic,
                                              color: Colors.white.withValues(alpha: 0.55),
                                              height: 1.1,
                                              letterSpacing: -0.3,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  _SheetStartAction(
                                    onTap: () => _openSignUp(context),
                                    pulse: _pulse,
                                  ),
                                ],
                              ),
                              const SizedBox(height: 18),
                              Divider(
                                height: 1,
                                thickness: 0.5,
                                color: Colors.white.withValues(alpha: 0.12),
                              ),
                              const SizedBox(height: 14),
                              Text(
                                _showSlider
                                    ? 'Drag the slider to compare your before & after.'
                                    : 'Tap each scan point on the face to reveal your transformation',
                                style: inter(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w300,
                                  color: Colors.white.withValues(alpha: 0.38),
                                  height: 1.6,
                                ),
                              ),
                              const SizedBox(height: 16),
                              Center(
                                child: _SignInLink(
                                  onTap: () {
                                    Navigator.of(context).pushReplacement(
                                      MaterialPageRoute<void>(
                                        builder: (_) => LoginScreen(repo: widget.repo),
                                      ),
                                    );
                                  },
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LeftSplitClipper extends CustomClipper<Rect> {
  const _LeftSplitClipper({required this.fraction});

  final double fraction;

  @override
  Rect getClip(Size size) => Rect.fromLTWH(0, 0, size.width * fraction, size.height);

  @override
  bool shouldReclip(_LeftSplitClipper old) => old.fraction != fraction;
}

Widget _photoGradient({bool story = false}) {
  return IgnorePointer(
    child: DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.transparent,
            Colors.transparent,
            Colors.black.withValues(alpha: story ? 0.22 : 0.55),
            Colors.black.withValues(alpha: story ? 0.62 : 0.88),
            Colors.black.withValues(alpha: story ? 0.96 : 0.96),
          ],
          stops: story ? const [0.0, 0.58, 0.82, 0.93, 1.0] : const [0.0, 0.45, 0.68, 0.85, 1.0],
        ),
      ),
    ),
  );
}

class _SliderHandle extends StatelessWidget {
  const _SliderHandle();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white,
        border: Border.all(color: Colors.black, width: 2),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.35), blurRadius: 8, offset: const Offset(0, 2)),
        ],
      ),
      child: const Icon(Icons.swap_horiz, size: 12, color: Colors.black),
    );
  }
}

class _SliderCornerLabel extends StatelessWidget {
  const _SliderCornerLabel({required this.text, this.bright = false});

  final String text;
  final bool bright;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 8,
          letterSpacing: 1,
          fontWeight: FontWeight.w500,
          color: bright ? Colors.white.withValues(alpha: 0.6) : Colors.white.withValues(alpha: 0.4),
        ),
      ),
    );
  }
}

Rect _animatedRevealRect(_FeatureSpot spot, double t, double width, double height) {
  final full = spot.revealRect(width, height);
  if (t >= 1.0) return full;

  final center = Offset(
    spot.dotX * width,
    _photoY(spot.dotY + _featureDotYOffset, height),
  );
  final animated = Rect.fromCenter(
    center: center,
    width: full.width * t,
    height: full.height * t,
  );
  return animated.intersect(full);
}

class _AnimatedFeatureRectsClipper extends CustomClipper<Path> {
  const _AnimatedFeatureRectsClipper({
    required this.revealed,
    required this.progress,
    required this.width,
    required this.height,
    required this.generation,
  });

  final Set<_FeatureId> revealed;
  final Map<_FeatureId, double> progress;
  final double width;
  final double height;
  final int generation;

  @override
  Path getClip(Size size) {
    if (revealed.isEmpty) return Path();

    var path = Path();
    var first = true;

    for (final spot in _features) {
      if (!revealed.contains(spot.id)) continue;
      final t = progress[spot.id] ?? 1.0;
      if (t <= 0) continue;
      final patch = Path()..addRect(_animatedRevealRect(spot, t, width, height));
      path = first ? patch : Path.combine(PathOperation.union, path, patch);
      first = false;
    }

    return path;
  }

  @override
  bool shouldReclip(_AnimatedFeatureRectsClipper old) =>
      old.generation != generation ||
      old.width != width ||
      old.height != height ||
      old.progress != progress;
}

/// Soft icy scan accents — pale cyan / white only (no lavender haze).
const _scanCyan = Color(0xFFD4ECFA);
const _scanWhite = Color(0xFFF2F9FF);
const _scanGridDim = Color(0xFFB8C8DC);
const _scanGridBright = Color(0xFFF8FCFF);

class _FaceScanOverlay extends StatelessWidget {
  const _FaceScanOverlay({
    required this.spot,
    required this.width,
    required this.height,
    required this.animation,
  });

  final _FeatureSpot spot;
  final double width;
  final double height;
  final Animation<double> animation;

  @override
  Widget build(BuildContext context) {
    final scanRegion = spot.scanRect(width, height);

    return Positioned.fill(
      child: IgnorePointer(
        child: AnimatedBuilder(
          animation: animation,
          builder: (context, _) => CustomPaint(
            painter: _FaceScanMeshPainter(
              region: scanRegion,
              screenWidth: width,
              screenHeight: height,
              feature: spot.id,
              progress: Curves.easeInOutCubic.transform(animation.value),
            ),
          ),
        ),
      ),
    );
  }
}

class _FaceScanMeshPainter extends CustomPainter {
  _FaceScanMeshPainter({
    required this.region,
    required this.screenWidth,
    required this.screenHeight,
    required this.feature,
    required this.progress,
  });

  final Rect region;
  final double screenWidth;
  final double screenHeight;
  final _FeatureId feature;
  final double progress;

  static const _cols = 8;
  static const _rows = 7;
  static const _colT = [0.0, 0.14, 0.29, 0.43, 0.57, 0.71, 0.86, 1.0];
  static const _rowT = [0.0, 0.17, 0.33, 0.5, 0.67, 0.83, 1.0];

  /// Soft face curvature — keeps the grid sitting on skin, not a flat rectangle.
  double _widthAt(double v) {
    return switch (feature) {
      _FeatureId.forehead => 0.78 + 0.18 * Curves.easeOut.transform(v),
      _FeatureId.eyes => 0.86 + 0.10 * math.sin(v * math.pi),
      _FeatureId.smile => 0.72 + 0.22 * (1 - (v - 0.5).abs() * 2).clamp(0.0, 1.0),
    };
  }

  double _centerU(double v) {
    return switch (feature) {
      _FeatureId.forehead => 0.42 + 0.03 * v,
      _FeatureId.eyes => 0.40 + 0.04 * math.sin(v * math.pi),
      _FeatureId.smile => 0.44 + 0.02 * v,
    };
  }

  Offset _map(double u, double v) {
    final widthFactor = _widthAt(v);
    final centerX = region.left + region.width * _centerU(v);
    final halfW = region.width * 0.5 * widthFactor;
    // Gentle cheek / temple warp (X only) so vertical lines stay even.
    final cheek = region.width *
        0.045 *
        math.exp(-math.pow((v - 0.55) / 0.28, 2)) *
        math.exp(-math.pow((u - 0.9) / 0.35, 2));
    final temple = -region.width *
        0.02 *
        math.exp(-math.pow((u - 0.08) / 0.22, 2)) *
        math.exp(-math.pow((v - 0.25) / 0.28, 2));
    final x = centerX + (u - 0.5) * 2 * halfW + cheek + temple;
    final y = region.top + region.height * v;
    return Offset(x, y);
  }

  List<List<Offset>> _meshPoints() {
    return List.generate(
      _rows,
      (row) => List.generate(
        _cols,
        (col) => _map(_colT[col], _rowT[row]),
      ),
    );
  }

  double _illuminationAt(double y, double lightY) {
    final sigma = region.height * 0.28;
    final beam = math.exp(-math.pow(y - lightY, 2) / (2 * sigma * sigma));
    return (0.18 + 0.82 * beam).clamp(0.0, 1.0);
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;

    final points = _meshPoints();
    final gridIn = Curves.easeOutCubic.transform((progress / 0.28).clamp(0.0, 1.0));
    final scanT = Curves.easeInOut.transform(((progress - 0.06) / 0.88).clamp(0.0, 1.0));
    // Sweep top → bottom across the feature band.
    final lightY = region.top + region.height * scanT;

    canvas.save();
    canvas.clipPath(_portraitHeadClip(screenWidth, screenHeight));

    _drawSoftLightSweep(canvas, points, lightY, scanT);
    _drawMeshCells(canvas, points, gridIn, lightY);
    _drawGrid(canvas, points, gridIn, lightY);
    _drawNodes(canvas, points, gridIn, lightY);

    canvas.restore();
  }

  void _drawMeshCells(
    Canvas canvas,
    List<List<Offset>> points,
    double gridIn,
    double lightY,
  ) {
    if (gridIn <= 0) return;
    final fill = Paint()..style = PaintingStyle.fill;

    for (var row = 0; row < _rows - 1; row++) {
      for (var col = 0; col < _cols - 1; col++) {
        final p00 = points[row][col];
        final p10 = points[row][col + 1];
        final p01 = points[row + 1][col];
        final p11 = points[row + 1][col + 1];
        final midY = (p00.dy + p11.dy) * 0.5;
        final glow = gridIn * _illuminationAt(midY, lightY);
        if (glow <= 0.08) continue;

        fill.color = Color.lerp(_scanCyan, _scanWhite, glow * 0.55)!
            .withValues(alpha: 0.08 * glow);
        canvas.drawPath(
          Path()
            ..moveTo(p00.dx, p00.dy)
            ..lineTo(p10.dx, p10.dy)
            ..lineTo(p11.dx, p11.dy)
            ..lineTo(p01.dx, p01.dy)
            ..close(),
          fill,
        );
      }
    }
  }

  Rect _meshBounds(List<List<Offset>> points) {
    var minX = points[0][0].dx;
    var maxX = minX;
    var minY = points[0][0].dy;
    var maxY = minY;
    for (final row in points) {
      for (final p in row) {
        minX = math.min(minX, p.dx);
        maxX = math.max(maxX, p.dx);
        minY = math.min(minY, p.dy);
        maxY = math.max(maxY, p.dy);
      }
    }
    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  Path _meshHullPath(List<List<Offset>> points) {
    final path = Path()..moveTo(points[0][0].dx, points[0][0].dy);
    for (var col = 1; col < _cols; col++) {
      path.lineTo(points[0][col].dx, points[0][col].dy);
    }
    for (var row = 1; row < _rows; row++) {
      path.lineTo(points[row][_cols - 1].dx, points[row][_cols - 1].dy);
    }
    for (var col = _cols - 2; col >= 0; col--) {
      path.lineTo(points[_rows - 1][col].dx, points[_rows - 1][col].dy);
    }
    for (var row = _rows - 2; row >= 1; row--) {
      path.lineTo(points[row][0].dx, points[row][0].dy);
    }
    return path..close();
  }

  void _drawGrid(
    Canvas canvas,
    List<List<Offset>> points,
    double gridIn,
    double lightY,
  ) {
    if (gridIn <= 0) return;
    final linePaint = Paint()..style = PaintingStyle.stroke;

    for (var row = 0; row < _rows; row++) {
      final midY = (points[row][0].dy + points[row][_cols - 1].dy) * 0.5;
      final rowOpacity = gridIn * _illuminationAt(midY, lightY);
      linePaint
        ..color = Color.lerp(_scanGridDim, _scanGridBright, rowOpacity)!.withValues(alpha: 0.2 + 0.55 * rowOpacity)
        ..strokeWidth = 0.7 + 0.35 * rowOpacity;
      final path = Path()..moveTo(points[row][0].dx, points[row][0].dy);
      for (var col = 1; col < _cols; col++) {
        path.lineTo(points[row][col].dx, points[row][col].dy);
      }
      canvas.drawPath(path, linePaint);
    }

    for (var col = 0; col < _cols; col++) {
      final midY = (points[0][col].dy + points[_rows - 1][col].dy) * 0.5;
      final colOpacity = gridIn * _illuminationAt(midY, lightY);
      linePaint
        ..color = Color.lerp(_scanGridDim, _scanGridBright, colOpacity)!.withValues(alpha: 0.16 + 0.5 * colOpacity)
        ..strokeWidth = 0.7 + 0.35 * colOpacity;
      final path = Path()..moveTo(points[0][col].dx, points[0][col].dy);
      for (var row = 1; row < _rows; row++) {
        path.lineTo(points[row][col].dx, points[row][col].dy);
      }
      canvas.drawPath(path, linePaint);
    }
  }

  void _drawNodes(
    Canvas canvas,
    List<List<Offset>> points,
    double gridIn,
    double lightY,
  ) {
    if (gridIn <= 0) return;
    for (var row = 0; row < _rows; row++) {
      for (var col = 0; col < _cols; col++) {
        final p = points[row][col];
        final pulse = gridIn * _illuminationAt(p.dy, lightY);
        if (pulse < 0.12) continue;
        canvas.drawCircle(
          p,
          1.2 + pulse * 0.7,
          Paint()..color = _scanGridBright.withValues(alpha: 0.4 + 0.55 * pulse),
        );
      }
    }
  }

  void _drawSoftLightSweep(
    Canvas canvas,
    List<List<Offset>> points,
    double lightY,
    double scanT,
  ) {
    if (scanT <= 0) return;
    final bounds = _meshBounds(points);
    final beamHalf = bounds.height * 0.38;
    final washRect = Rect.fromLTRB(
      bounds.left,
      math.max(lightY - beamHalf, bounds.top),
      bounds.right,
      math.min(lightY + beamHalf, bounds.bottom),
    );
    if (washRect.height <= 1) return;

    canvas.save();
    canvas.clipPath(_meshHullPath(points));

    final a = scanT.clamp(0.0, 1.0);
    canvas.drawRect(
      washRect,
      Paint()
        ..blendMode = BlendMode.screen
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            _scanCyan.withValues(alpha: 0),
            _scanCyan.withValues(alpha: 0.16 * a),
            _scanWhite.withValues(alpha: 0.42 * a),
            _scanCyan.withValues(alpha: 0.16 * a),
            _scanCyan.withValues(alpha: 0),
          ],
          stops: const [0.0, 0.28, 0.5, 0.72, 1.0],
        ).createShader(washRect)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 22),
    );

    canvas.restore();
  }

  @override
  bool shouldRepaint(_FaceScanMeshPainter old) =>
      old.progress != progress ||
      old.region != region ||
      old.feature != feature ||
      old.screenWidth != screenWidth ||
      old.screenHeight != screenHeight;
}

class _DotTapHint extends StatelessWidget {
  const _DotTapHint({
    required this.spot,
    required this.width,
    required this.height,
    required this.pulse,
  });

  final _FeatureSpot spot;
  final double width;
  final double height;
  final Animation<double> pulse;

  @override
  Widget build(BuildContext context) {
    final cx = spot.dotX * width;
    final cy = _photoY(spot.dotY + _featureDotYOffset, height);
    const hintW = 56.0;

    return Positioned(
      left: (cx - hintW - 20).clamp(10.0, width - hintW - 10),
      top: cy - 7,
      width: hintW,
      child: AnimatedBuilder(
        animation: pulse,
        builder: (context, child) {
          final t = pulse.value;
          final opacity = 0.4 + 0.6 * t;
          return Opacity(
            opacity: opacity,
            child: Transform.translate(
              offset: Offset(4 * (1 - t), 0),
              child: child,
            ),
          );
        },
        child: Text(
          'Scan here',
          textAlign: TextAlign.right,
          style: GoogleFonts.inter(
            fontSize: 10,
            fontWeight: FontWeight.w500,
            color: Colors.white.withValues(alpha: 0.9),
            letterSpacing: 0.2,
          ),
        ),
      ),
    );
  }
}

class _ScanTargetPainter extends CustomPainter {
  const _ScanTargetPainter({required this.ring, required this.glow});

  final double ring;
  final double glow;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final r = 10.0 * ring;
    final alpha = 0.28 + 0.18 * glow;

    final halo = Paint()
      ..color = _scanWhite.withValues(alpha: 0.12 * glow)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);
    canvas.drawCircle(center, r + 4, halo);

    canvas.drawCircle(
      center,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8
        ..color = _scanWhite.withValues(alpha: alpha),
    );

    canvas.drawCircle(
      center,
      2,
      Paint()..color = Colors.white.withValues(alpha: 0.7 + 0.2 * glow),
    );
  }

  @override
  bool shouldRepaint(_ScanTargetPainter old) => old.ring != ring || old.glow != glow;
}

class _FeatureDot extends StatelessWidget {
  const _FeatureDot({
    required this.spot,
    required this.width,
    required this.height,
    required this.pulse,
    required this.tapScale,
    required this.opacity,
    required this.onTap,
  });

  final _FeatureSpot spot;
  final double width;
  final double height;
  final Animation<double> pulse;
  final double tapScale;
  final double opacity;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cx = spot.dotX * width;
    final cy = _photoY(spot.dotY + _featureDotYOffset, height);
    const hit = 44.0;

    return Positioned(
      left: cx - hit / 2,
      top: cy - hit / 2,
      width: hit,
      height: hit,
      child: Opacity(
        opacity: opacity,
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: AnimatedBuilder(
          animation: pulse,
          builder: (context, child) {
            final ring = 1.0 + pulse.value * 0.22;
            final glow = 0.35 + pulse.value * 0.25;
            return Center(
              child: Transform.scale(
                scale: tapScale,
                child: CustomPaint(
                  size: const Size(36, 36),
                  painter: _ScanTargetPainter(ring: ring, glow: glow),
                ),
              ),
            );
          },
        ),
        ),
      ),
    );
  }
}

class _ComparisonImage extends StatelessWidget {
  const _ComparisonImage({
    required this.asset,
    required this.width,
    required this.height,
  });

  final String asset;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final zoomH = height / _photoScale;

    return Transform.translate(
      offset: const Offset(0, _photoLift),
      child: SizedBox(
        width: width,
        height: height,
        child: ClipRect(
          child: OverflowBox(
            maxWidth: width,
            minWidth: width,
            maxHeight: zoomH,
            minHeight: zoomH,
            // Slightly bias down to avoid chin cutoff on iPhones.
            alignment: const Alignment(0, _photoContentAlignY),
            child: Image.asset(
              asset,
              width: width,
              height: zoomH,
              fit: BoxFit.cover,
              alignment: const Alignment(0, _photoContentAlignY),
              gaplessPlayback: true,
            ),
          ),
        ),
      ),
    );
  }
}

class _LogoPill extends StatelessWidget {
  const _LogoPill();

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.35),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.white.withValues(alpha: 0.22), width: 0.5),
          ),
          child: Text(
            'ÆSTHETIC JOURNEY',
            style: GoogleFonts.inter(
              fontSize: 9.5,
              fontWeight: FontWeight.w500,
              letterSpacing: 2.5,
              color: Colors.white.withValues(alpha: 0.9),
            ),
          ),
        ),
      ),
    );
  }
}

class _SheetStartAction extends StatelessWidget {
  const _SheetStartAction({required this.onTap, required this.pulse});

  final VoidCallback onTap;
  final Animation<double> pulse;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(28),
      child: Padding(
        padding: const EdgeInsets.only(left: 4, top: 8, bottom: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Get started',
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: Colors.white,
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              width: 64,
              height: 64,
              child: AnimatedBuilder(
                animation: pulse,
                builder: (context, child) {
                  final scale = 0.9 + 0.1 * pulse.value;
                  return Center(child: Transform.scale(scale: scale, child: child));
                },
                child: Material(
                  color: Colors.white,
                  shape: const CircleBorder(),
                  child: const SizedBox(
                    width: 56,
                    height: 56,
                    child: Icon(Icons.arrow_forward_rounded, size: 22, color: _cardInk),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SignInLink extends StatelessWidget {
  const _SignInLink({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
        child: Text(
          'I already have an account — Sign in',
          textAlign: TextAlign.center,
          style: GoogleFonts.inter(
            fontSize: 12.5,
            fontWeight: FontWeight.w400,
            color: Colors.white.withValues(alpha: 0.45),
          ),
        ),
      ),
    );
  }
}
