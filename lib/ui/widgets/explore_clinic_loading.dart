import 'dart:math' as math;

import 'package:flutter/material.dart';

/// A single search caption and lightweight placeholders. Only the small
/// canvas repaints each frame; the map, text and card tree stay untouched.
class ExploreClinicLoading extends StatefulWidget {
  const ExploreClinicLoading({
    super.key,
    required this.city,
    this.compact = false,
  });
  final String city;
  final bool compact;

  @override
  State<ExploreClinicLoading> createState() => _ExploreClinicLoadingState();
}

class _ExploreClinicLoadingState extends State<ExploreClinicLoading>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context) || !TickerMode.of(context)) {
      _pulse.stop();
    } else if (!_pulse.isAnimating) {
      _pulse.repeat();
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final city = widget.city.trim();
    final caption = widget.compact
        ? 'Checking more published prices'
        : city.isEmpty
        ? 'Finding clinics'
        : 'Finding clinics in $city';
    return Semantics(
      liveRegion: true,
      label: caption,
      child: ExcludeSemantics(
        child: RepaintBoundary(
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: widget.compact ? 8 : 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SizedBox(
                      width: 34,
                      height: 34,
                      child: CustomPaint(painter: _SearchPulse(_pulse)),
                    ),
                    const SizedBox(width: 12),
                    Flexible(
                      child: Text(
                        caption,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF1A1A2E),
                        ),
                      ),
                    ),
                  ],
                ),
                if (!widget.compact) ...[
                  const SizedBox(height: 6),
                  const Text(
                    'Matching treatments with published prices',
                    style: TextStyle(fontSize: 12, color: Color(0xFF85858F)),
                  ),
                  const SizedBox(height: 20),
                  for (final width in [0.78, 0.62, 0.7])
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Row(
                        children: [
                          Container(
                            width: 34,
                            height: 34,
                            decoration: BoxDecoration(
                              color: const Color(0x0D1A1A2E),
                              borderRadius: BorderRadius.circular(11),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                FractionallySizedBox(
                                  widthFactor: width,
                                  child: Container(
                                    height: 8,
                                    decoration: BoxDecoration(
                                      color: const Color(0x0D1A1A2E),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 7),
                                FractionallySizedBox(
                                  widthFactor: width * 0.6,
                                  child: Container(
                                    height: 6,
                                    decoration: BoxDecoration(
                                      color: const Color(0x081A1A2E),
                                      borderRadius: BorderRadius.circular(3),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SearchPulse extends CustomPainter {
  _SearchPulse(this.progress) : super(repaint: progress);
  final Animation<double> progress;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final ink = Paint()
      ..color = const Color(0xFF1A1A2E)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6;
    canvas.drawCircle(center - const Offset(2, 2), 6, ink);
    canvas.drawLine(
      center + const Offset(2.5, 2.5),
      center + const Offset(7, 7),
      ink,
    );
    ink.color = const Color(0x241A1A2E);
    canvas.drawCircle(center, 15, ink);
    final angle = progress.value * math.pi * 2;
    ink
      ..color = const Color(0xFF1A1A2E)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(
      center + Offset(math.cos(angle), math.sin(angle)) * 15,
      2.4,
      ink,
    );
  }

  @override
  bool shouldRepaint(_SearchPulse oldDelegate) =>
      oldDelegate.progress != progress;
}
