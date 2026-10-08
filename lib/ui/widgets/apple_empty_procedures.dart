import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

// Match `empty_state_apple_redesign.html` palette (same library scope for sibling widgets).
const Color _separator = Color(0xFFD1D1D6);
const Color _muted = Color(0xFF8E8E93);
const Color _muted2 = Color(0xFFAEAEB2);
/// Matches homepage Procedures stat tile (`_StatCardDark`) and primary app ink.
const Color _glowInk = Color(0xFF1A1A2E);
const Color _secondaryInk = Color(0xFF3A3A3C);
const Color _fill = Color(0xFFE5E5EA);
const Color _hairline = Color(0xFFC7C7CC);

/// iOS-style empty state modeled on `empty_state_apple_redesign.html`.
class AppleEmptyProcedures extends StatelessWidget {
  const AppleEmptyProcedures({
    super.key,
    required this.onAddProcedure,
    required this.onBrowseTypes,
    this.headerTitle = 'My Timeline',
    this.compact = false,
    this.title = 'No procedures yet',
    this.subtitle = 'Start logging your treatments to build a complete picture of your aesthetic journey.',
    this.accentInk = const Color(0xFF1A1A2E),
    this.onAccent = const Color(0xFFF0EDF8),
  });

  final VoidCallback onAddProcedure;
  final VoidCallback onBrowseTypes;

  /// Top bar title (mock uses "My Journal"; app timeline uses "My Timeline").
  final String headerTitle;

  /// When true, fits the homepage Timeline preview slot (smaller illustration, no feature grid).
  final bool compact;

  final String title;
  final String subtitle;

  /// Dark brand tone (homepage: use procedures stat card navy, `0xFF1A1A2E`).
  final Color accentInk;

  /// Text/icon on top of [accentInk] (default matches homepage pills / stat card contrast).
  final Color onAccent;

  @override
  Widget build(BuildContext context) {
    final ui = GoogleFonts.inter();
    final ink = accentInk;

    // Full layout targets ~HTML scale; compact is only for tight embeds.
    final outerFull = compact ? 120.0 : 168.0;

    Widget illoWrap(double outer) {
      final pipD = outer * (24 / 190);
      final iconInPip = (13 * outer / 190).clamp(12.0, 15.0);
      return SizedBox(
          width: outer,
          height: outer,
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              _Ring(size: outer, borderColor: _separator),
              _Ring(size: outer * (148 / 190), borderColor: _hairline),
              _Ring(size: outer * (108 / 190), borderColor: _hairline, fill: _fill),
              Container(
                width: outer * (72 / 190),
                height: outer * (72 / 190),
                decoration: BoxDecoration(
                  color: ink,
                  borderRadius: BorderRadius.circular(22 * outer / 190),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CustomPaint(
                      size: Size(28 * outer / 190, 28 * outer / 190),
                      painter: _DropletPainter(),
                    ),
                    SizedBox(height: outer * 0.02),
                    Text(
                      'EMPTY',
                      style: ui.copyWith(
                        fontSize: (8 * outer / 190).clamp(7.0, 9.0),
                        fontWeight: FontWeight.w600,
                        color: _muted,
                        letterSpacing: 0.07 * 10,
                      ),
                    ),
                  ],
                ),
              ),
              Positioned(
                top: outer * (8 / 190),
                right: outer * (22 / 190),
                child: _Pip(icon: Icons.star_rounded, iconColor: _hairline, diameter: pipD, iconSize: iconInPip),
              ),
              Positioned(
                bottom: outer * (16 / 190),
                right: outer * (8 / 190),
                child: _Pip(icon: Icons.check_box_outline_blank_rounded, iconColor: _muted, diameter: pipD, iconSize: iconInPip),
              ),
              Positioned(
                bottom: outer * (16 / 190),
                left: outer * (8 / 190),
                child: _Pip(icon: Icons.article_outlined, iconColor: _muted, diameter: pipD, iconSize: iconInPip),
              ),
            ],
          ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!compact) ...[
          Row(
            children: [
              Expanded(
                child: Text(
                  headerTitle,
                  style: ui.copyWith(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.3,
                    color: ink,
                  ),
                ),
              ),
              Material(
                color: _fill,
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: onBrowseTypes,
                  child: SizedBox(
                    width: compact ? 32 : 34,
                    height: compact ? 32 : 34,
                    child: Icon(Icons.info_outline_rounded, size: compact ? 17 : 18, color: _secondaryInk),
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: compact ? 14 : 20),
        ],
        Center(child: illoWrap(outerFull)),
        SizedBox(height: compact ? 14 : 18),
        Text(
          title,
          textAlign: TextAlign.center,
          style: ui.copyWith(
            fontSize: compact ? 19 : 24,
            fontWeight: FontWeight.w700,
            height: 1.2,
            letterSpacing: -0.4,
            color: ink,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          subtitle,
          textAlign: TextAlign.center,
          maxLines: compact ? 3 : 4,
          overflow: TextOverflow.ellipsis,
          style: ui.copyWith(
            fontSize: compact ? 12 : 13,
            fontWeight: FontWeight.w400,
            height: 1.5,
            color: _muted,
          ),
        ),
        SizedBox(height: compact ? 14 : 22),
        _PrimaryCta(
          label: '+ Add procedure',
          compact: compact,
          backgroundColor: ink,
          foregroundColor: onAccent,
          onPressed: onAddProcedure,
        ),
        if (compact) ...[
          const SizedBox(height: 8),
          Center(
            child: TextButton(
              onPressed: onBrowseTypes,
              style: TextButton.styleFrom(
                foregroundColor: ink,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(
                'Browse procedure types',
                style: ui.copyWith(fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ],
        if (!compact) ...[
          const SizedBox(height: 10),
          _SecondaryCta(label: 'Browse procedure types', foregroundColor: ink, onPressed: onBrowseTypes),
          const SizedBox(height: 14),
          _FeaturesGrid(font: ui, titleInk: ink),
        ],
      ],
    );
  }
}

class _PrimaryCta extends StatelessWidget {
  const _PrimaryCta({
    required this.label,
    required this.onPressed,
    required this.compact,
    required this.backgroundColor,
    required this.foregroundColor,
  });
  final String label;
  final VoidCallback onPressed;
  final bool compact;
  final Color backgroundColor;
  final Color foregroundColor;

  @override
  Widget build(BuildContext context) {
    final vPad = compact ? 12.0 : 15.0;
    final font = compact ? 14.0 : 15.0;
    return FilledButton(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: backgroundColor,
        foregroundColor: foregroundColor,
        padding: EdgeInsets.symmetric(vertical: vPad),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: GoogleFonts.inter(fontSize: font, fontWeight: FontWeight.w600, letterSpacing: -0.1),
      ),
      child: Text(label),
    );
  }
}

class _SecondaryCta extends StatelessWidget {
  const _SecondaryCta({required this.label, required this.onPressed, required this.foregroundColor});
  final String label;
  final VoidCallback onPressed;
  final Color foregroundColor;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: foregroundColor,
        backgroundColor: Colors.white,
        side: const BorderSide(color: _fill),
        padding: const EdgeInsets.symmetric(vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w500),
      ),
      child: Text(label),
    );
  }
}

class _Ring extends StatelessWidget {
  const _Ring({required this.size, required this.borderColor, this.fill});
  final double size;
  final Color borderColor;
  final Color? fill;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: fill,
        border: Border.all(color: borderColor),
      ),
    );
  }
}

class _Pip extends StatelessWidget {
  const _Pip({required this.icon, required this.iconColor, required this.diameter, required this.iconSize});
  final IconData icon;
  final Color iconColor;
  final double diameter;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: diameter,
      height: diameter,
      decoration: BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
        border: Border.all(color: _separator),
      ),
      child: Icon(icon, size: iconSize, color: iconColor),
    );
  }
}

class _DropletPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final strokeLight = Paint()
      ..color = _fill
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;
    final strokeGrey = Paint()
      ..color = _muted
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round;
    final fillDot = Paint()..color = _fill;

    final w = size.width;
    final h = size.height;
    final cx = w / 2;

    final drop = Path();
    drop.moveTo(cx, h * 0.14);
    drop.cubicTo(w * 0.29, h * 0.29, w * 0.29, h * 0.50, cx, h * 0.79);
    drop.cubicTo(w * 0.71, h * 0.50, w * 0.71, h * 0.29, cx, h * 0.14);
    drop.close();

    canvas.drawPath(drop, strokeLight);

    final curve = Path();
    curve.moveTo(w * 0.36, h * 0.50);
    curve.quadraticBezierTo(cx, h * 0.36, w * 0.64, h * 0.50);
    canvas.drawPath(curve, strokeGrey);

    canvas.drawCircle(Offset(cx, h * 0.50), 1.5, fillDot);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _FeaturesGrid extends StatelessWidget {
  const _FeaturesGrid({required this.font, required this.titleInk});
  final TextStyle font;
  final Color titleInk;

  @override
  Widget build(BuildContext context) {
    const gap = 10.0;
    return LayoutBuilder(
      builder: (context, c) {
        final tileW = (c.maxWidth - gap) / 2;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            SizedBox(width: tileW, child: _FeatureTile(icon: Icons.fact_check_outlined, title: 'Track procedures', desc: 'Botox, filler, laser & more', font: font, titleColor: titleInk)),
            SizedBox(width: tileW, child: _FeatureTile(icon: Icons.view_carousel_rounded, title: 'Before & after', desc: 'Photo progress timeline', font: font, titleColor: titleInk)),
            SizedBox(width: tileW, child: _FeatureTile(icon: Icons.show_chart_rounded, title: 'Recovery log', desc: 'Healing tracked over time', font: font, titleColor: titleInk)),
            SizedBox(width: tileW, child: _FeatureTile(icon: Icons.add_circle_outline_rounded, title: 'Doctor notes', desc: 'Save aftercare advice', font: font, titleColor: titleInk)),
          ],
        );
      },
    );
  }
}

class _FeatureTile extends StatelessWidget {
  const _FeatureTile({required this.icon, required this.title, required this.desc, required this.font, required this.titleColor});
  final IconData icon;
  final String title;
  final String desc;
  final TextStyle font;
  final Color titleColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _fill),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: _fill,
              borderRadius: BorderRadius.circular(9),
            ),
            alignment: Alignment.center,
            child: Icon(icon, size: 17, color: _hairline),
          ),
          const SizedBox(height: 8),
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: font.copyWith(fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: -0.1, color: titleColor),
          ),
          const SizedBox(height: 2),
          Text(
            desc,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: font.copyWith(fontSize: 10, fontWeight: FontWeight.w400, height: 1.4, color: _muted2),
          ),
        ],
      ),
    );
  }
}

void showBrowseProcedureTypesSheet(BuildContext context) {
  final ui = GoogleFonts.inter();
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
    ),
    builder: (context) {
      final items = <(String, String)>[
        ('Injectables', 'Filler, Botox, biostimulators & more'),
        ('Skin treatments', 'Microneedling, peels, boosters'),
        ('Laser & energy', 'Resurfacing, tightening, devices'),
        ('Surgery', 'Rhinoplasty, lifts, body contouring'),
        ('Body & recovery', 'Lymphatic massage, post-op care'),
      ];
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(color: _fill, borderRadius: BorderRadius.circular(99)),
                ),
              ),
              const SizedBox(height: 14),
              Text('Procedure types', style: ui.copyWith(fontSize: 18, fontWeight: FontWeight.w800, color: _glowInk)),
              const SizedBox(height: 14),
              ...items.map(
                (e) => Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.keyboard_arrow_right_rounded, color: _muted, size: 22),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(e.$1, style: ui.copyWith(fontSize: 15, fontWeight: FontWeight.w700, color: _glowInk)),
                            const SizedBox(height: 2),
                            Text(e.$2, style: ui.copyWith(fontSize: 12, color: _muted, height: 1.35)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: _glowInk,
                  foregroundColor: const Color(0xFFF0EDF8),
                  minimumSize: const Size.fromHeight(48),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                onPressed: () => Navigator.pop(context),
                child: Text('Got it', style: ui.copyWith(fontWeight: FontWeight.w700)),
              ),
            ],
          ),
        ),
      );
    },
  );
}
