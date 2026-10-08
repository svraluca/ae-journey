import 'package:dotted_border/dotted_border.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../procedure_selection_theme.dart';
import '../procedure_icon_resolver.dart';

/// Frosted-glass shell: backdrop blur, directional light, layered ambient depth.
class ProcedureGlassSurface extends StatelessWidget {
  const ProcedureGlassSurface({
    super.key,
    required this.borderRadius,
    required this.child,
    this.selected = false,
    this.blur = true,
    this.compact = false,
    this.illuminated = false,
  });

  final BorderRadius borderRadius;
  final Widget child;
  final bool selected;
  final bool blur;
  final bool compact;
  final bool illuminated;

  @override
  Widget build(BuildContext context) {
    final fillColor = selected
        ? null
        : (illuminated ? ProcedureSelectionTheme.cardIlluminated : ProcedureSelectionTheme.cardInner);

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow: selected
            ? const []
            : [
                ...ProcedureGlassDecorations.neonFrameGlow(
                  compact: compact,
                ),
                ...ProcedureGlassDecorations.shadows(
                  compact: compact,
                  elevated: illuminated,
                ),
              ],
      ),
      child: ClipRRect(
        borderRadius: borderRadius,
        child: Stack(
          fit: StackFit.passthrough,
          children: [
            // Glass blur + fill — background layer only via `glass` package.
            Positioned.fill(
              child: selected
                  ? const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            ProcedureSelectionTheme.cardSelectedTop,
                            ProcedureSelectionTheme.cardSelectedMid,
                            ProcedureSelectionTheme.cardSelectedBottom,
                          ],
                          stops: [0.0, 0.48, 1.0],
                        ),
                      ),
                    )
                  : _ProcedureGlassLayer(
                      borderRadius: borderRadius,
                      blur: blur,
                      fillColor: fillColor,
                      selected: false,
                    ),
            ),
            // Foreground content — always painted above the glass layers.
            child,
            if (!selected)
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _NeonRimPainter(
                      borderRadius: borderRadius,
                      compact: compact,
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

/// Crisp neon-white border drawn on the card edge.
class _NeonRimPainter extends CustomPainter {
  const _NeonRimPainter({
    required this.borderRadius,
    required this.compact,
  });

  final BorderRadius borderRadius;
  final bool compact;

  @override
  void paint(Canvas canvas, Size size) {
    final inset = compact ? 0.75 : 1.0;
    final rect = Rect.fromLTWH(inset, inset, size.width - inset * 2, size.height - inset * 2);
    final rrect = borderRadius.toRRect(rect).deflate(0.25);

    final glow = Paint()
      ..color = Colors.white.withValues(alpha: 0.28)
      ..style = PaintingStyle.stroke
      ..strokeWidth = compact ? 3.2 : 3.8;

    final rim = Paint()
      ..color = Colors.white.withValues(alpha: 0.82)
      ..style = PaintingStyle.stroke
      ..strokeWidth = compact ? 1.1 : 1.4;

    // Soft rim without MaskFilter.blur (Impeller / iOS Simulator safe).
    canvas.drawRRect(rrect, glow);
    canvas.drawRRect(rrect, rim);
  }

  @override
  bool shouldRepaint(covariant _NeonRimPainter oldDelegate) {
    return oldDelegate.compact != compact || oldDelegate.borderRadius != borderRadius;
  }
}

/// Background-only frosted glass using the `glass` package — content stays outside.
class _ProcedureGlassLayer extends StatelessWidget {
  const _ProcedureGlassLayer({
    required this.borderRadius,
    required this.blur,
    required this.fillColor,
    required this.selected,
  });

  final BorderRadius borderRadius;
  final bool blur;
  final Color? fillColor;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final layer = DecoratedBox(
      decoration: BoxDecoration(
        color: fillColor ?? Colors.white.withValues(alpha: selected ? 0.0 : 0.22),
        gradient: selected ? ProcedureGlassDecorations.selectedGradient() : null,
      ),
      child: const SizedBox.expand(),
    );

    if (!blur) return layer;

    // Avoid `asGlass` / BackdropFilter — Impeller Gaussian blur crashes iOS Simulator.
    return DecoratedBox(
      decoration: BoxDecoration(
        color: (fillColor ?? Colors.white).withValues(alpha: selected ? 0.0 : 0.55),
        gradient: selected ? ProcedureGlassDecorations.selectedGradient() : null,
        border: Border.all(color: Colors.white.withValues(alpha: 0.55)),
      ),
      child: const SizedBox.expand(),
    );
  }
}

/// Uppercase letter-spaced section header (e.g. INJECTABLES).
class ProcedureSectionLabel extends StatelessWidget {
  const ProcedureSectionLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: GoogleFonts.plusJakartaSans(
        fontSize: 10,
        fontWeight: FontWeight.w800,
        letterSpacing: 2.4,
        height: 1.0,
        color: ProcedureSelectionTheme.sectionLabel,
      ),
    );
  }
}

/// Illuminated glass panel for treatment zone / product sections.
class ProcedureSelectionPanel extends StatelessWidget {
  const ProcedureSelectionPanel({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.compactTitle = false,
    this.illuminated = false,
  });

  final String title;
  final String? subtitle;
  final Widget child;
  final bool compactTitle;
  final bool illuminated;

  @override
  Widget build(BuildContext context) {
    final titleStyle = compactTitle
        ? ProcedureSelectionTypography.display(size: 13)
        : GoogleFonts.plusJakartaSans(
            fontSize: 14,
            fontWeight: FontWeight.w800,
            color: ProcedureSelectionTheme.ink,
            height: 1.1,
          );

    return ProcedureGlassSurface(
      borderRadius: BorderRadius.circular(ProcedureSelectionTheme.cardRadius),
      illuminated: illuminated,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: titleStyle),
            if (subtitle != null) ...[
              const SizedBox(height: 6),
              Text(
                subtitle!,
                style: ProcedureSelectionTypography.body(size: 11),
              ),
            ],
            SizedBox(height: subtitle != null ? 12 : 14),
            child,
          ],
        ),
      ),
    );
  }
}

/// Selectable procedure tile with premium glass + subtle selection scale.
class ProcedureCard extends StatefulWidget {
  const ProcedureCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.emoji,
    required this.selected,
    required this.onTap,
    this.iconAsset,
  });

  final String title;
  final String subtitle;
  final String emoji;
  final String? iconAsset;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<ProcedureCard> createState() => _ProcedureCardState();
}

class _ProcedureCardState extends State<ProcedureCard> {
  bool _pressed = false;

  Widget _iconBadge(double size) {
    final asset = widget.iconAsset ?? presetIconByName[widget.title];

    if (widget.selected) {
      return _SelectedGlassIconBadge(
        size: size,
        iconAsset: asset,
        emoji: widget.emoji,
      );
    }

    return Container(
      width: size,
      height: size,
      decoration: ProcedureGlassDecorations.iconBadge(selected: false),
      alignment: Alignment.center,
      child: asset != null
          ? ColorFiltered(
              colorFilter: const ColorFilter.mode(
                ProcedureSelectionTheme.ink,
                BlendMode.srcIn,
              ),
              child: Image.asset(
                asset,
                width: size * 0.68,
                height: size * 0.68,
                fit: BoxFit.contain,
                filterQuality: FilterQuality.high,
              ),
            )
          : Text(widget.emoji, style: TextStyle(fontSize: size * 0.46)),
    );
  }

  @override
  Widget build(BuildContext context) {
    const badgeSize = 38.0;
    const cardHeight = 58.0;
    const cardRadius = 10.0;

    final titleColor = widget.selected ? Colors.white : ProcedureSelectionTheme.ink;
    final subtitleColor = widget.selected
        ? Colors.white.withValues(alpha: 0.82)
        : ProcedureSelectionTheme.muted;

    final cardBody = SizedBox(
      height: cardHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Stack(
          children: [
            Row(
              children: [
                _iconBadge(badgeSize),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        widget.title,
                        style: GoogleFonts.plusJakartaSans(
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          color: titleColor,
                          height: 1.1,
                          letterSpacing: -0.1,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 1),
                      Text(
                        widget.subtitle,
                        style: GoogleFonts.plusJakartaSans(
                          fontSize: 8.5,
                          fontWeight: FontWeight.w500,
                          color: subtitleColor,
                          height: 1.15,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (widget.selected)
              Positioned(
                top: 8,
                right: 8,
                child: Container(
                  width: 18,
                  height: 18,
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: const Icon(Icons.check, size: 12, color: Colors.black),
                ),
              ),
          ],
        ),
      ),
    );

    return Material(
      color: Colors.transparent,
      child: GestureDetector(
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _pressed ? 0.97 : (widget.selected ? 1.02 : 1.0),
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          child: ProcedureGlassSurface(
            borderRadius: BorderRadius.circular(cardRadius),
            selected: widget.selected,
            blur: !widget.selected,
            child: cardBody,
          ),
        ),
      ),
    );
  }
}

/// Step 1 type/area tile — same frosted glass vibe as [ProcedureCard], vertical layout.
class Step1CategoryCard extends StatefulWidget {
  const Step1CategoryCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.iconAsset,
    required this.selected,
    required this.onTap,
    this.iconScale = 0.88,
  });

  final String title;
  final String subtitle;
  final String iconAsset;
  final bool selected;
  final VoidCallback onTap;
  final double iconScale;

  @override
  State<Step1CategoryCard> createState() => _Step1CategoryCardState();
}

class _Step1CategoryCardState extends State<Step1CategoryCard> {
  bool _pressed = false;

  Widget _iconBadge(double size) {
    final scale = widget.iconScale;
    if (widget.selected) {
      return _SelectedGlassIconBadge(
        size: size,
        iconAsset: widget.iconAsset,
        emoji: '',
        iconScale: scale,
      );
    }

    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(
        color: Color(0xFFB8B8BE),
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: ColorFiltered(
        colorFilter: const ColorFilter.mode(
          Colors.white,
          BlendMode.srcIn,
        ),
        child: Image.asset(
          widget.iconAsset,
          width: size * scale,
          height: size * scale,
          fit: BoxFit.contain,
          filterQuality: FilterQuality.high,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    const badgeSize = 38.0;
    const cardRadius = 20.0;

    final titleColor = widget.selected ? Colors.white : ProcedureSelectionTheme.ink;
    final subtitleColor = widget.selected
        ? Colors.white.withValues(alpha: 0.82)
        : ProcedureSelectionTheme.muted;

    final cardBody = Padding(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      child: Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _iconBadge(badgeSize),
              const SizedBox(height: 10),
              Text(
                widget.title,
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: titleColor,
                  height: 1.1,
                  letterSpacing: -0.1,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                widget.subtitle,
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 10,
                  fontWeight: FontWeight.w500,
                  color: subtitleColor,
                  height: 1.25,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
          if (widget.selected)
            Positioned(
              top: 0,
              right: 0,
              child: Container(
                width: 22,
                height: 22,
                decoration: const BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: const Icon(Icons.check, size: 13, color: Colors.black),
              ),
            ),
        ],
      ),
    );

    return Material(
      color: Colors.transparent,
      child: GestureDetector(
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _pressed ? 0.97 : (widget.selected ? 1.02 : 1.0),
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          child: ProcedureGlassSurface(
            borderRadius: BorderRadius.circular(cardRadius),
            selected: widget.selected,
            blur: !widget.selected,
            child: cardBody,
          ),
        ),
      ),
    );
  }
}

/// Category / preset icon — matches wizard step 1–2 pickers.
class ProcedureCategoryIconBadge extends StatelessWidget {
  const ProcedureCategoryIconBadge({
    super.key,
    required this.iconAsset,
    required this.selected,
    this.size = 34,
    this.iconScale = 0.88,
  });

  final String iconAsset;
  final bool selected;
  final double size;
  final double iconScale;

  @override
  Widget build(BuildContext context) {
    if (selected) {
      return _SelectedGlassIconBadge(
        size: size,
        iconAsset: iconAsset,
        emoji: '',
        iconScale: iconScale,
      );
    }

    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(
        color: Color(0xFFB8B8BE),
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: ColorFiltered(
        colorFilter: const ColorFilter.mode(Colors.white, BlendMode.srcIn),
        child: Image.asset(
          iconAsset,
          width: size * iconScale,
          height: size * iconScale,
          fit: BoxFit.contain,
          filterQuality: FilterQuality.medium,
        ),
      ),
    );
  }
}

/// Grey circular tray for Material icons — matches step 2 field rows.
class ProcedureFieldIconTray extends StatelessWidget {
  const ProcedureFieldIconTray({super.key, required this.icon, this.size = 34});

  final IconData icon;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(
        color: Color(0xFFB8B8BE),
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Icon(icon, size: size * 0.47, color: Colors.white),
    );
  }
}

/// Polished glass icon sphere for selected procedure cards — white icon + rim sparkles.
class _SelectedGlassIconBadge extends StatelessWidget {
  const _SelectedGlassIconBadge({
    required this.size,
    required this.emoji,
    this.iconAsset,
    this.iconScale = 0.68,
  });

  final double size;
  final String? iconAsset;
  final String emoji;
  final double iconScale;

  static const _topRightSparkle = Alignment(0.88, -0.58);
  static const _bottomLeftSparkle = Alignment(-0.86, 0.78);

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Colors.white.withValues(alpha: 0.14),
                  Colors.white.withValues(alpha: 0.06),
                  Colors.white.withValues(alpha: 0.03),
                ],
              ),
            ),
            child: Center(
              child: iconAsset != null
                  ? ColorFiltered(
                      colorFilter: const ColorFilter.mode(Colors.white, BlendMode.srcIn),
                      child: Image.asset(
                        iconAsset!,
                        width: size * iconScale,
                        height: size * iconScale,
                        fit: BoxFit.contain,
                        filterQuality: FilterQuality.high,
                      ),
                    )
                  : Text(
                      emoji,
                      style: TextStyle(fontSize: size * 0.46, color: Colors.white),
                    ),
            ),
          ),
          Align(
            alignment: _topRightSparkle,
            child: Icon(
              Icons.auto_awesome,
              size: size * 0.19,
              color: Colors.white.withValues(alpha: 0.95),
            ),
          ),
          Align(
            alignment: _bottomLeftSparkle,
            child: Icon(
              Icons.auto_awesome,
              size: size * 0.12,
              color: Colors.white.withValues(alpha: 0.88),
            ),
          ),
        ],
      ),
    );
  }
}

/// Dashed pill button on the step-2 light background.
class ProcedureCustomButton extends StatelessWidget {
  const ProcedureCustomButton({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onPressed,
        child: DottedBorder(
          options: RoundedRectDottedBorderOptions(
            radius: const Radius.circular(999),
            dashPattern: const <double>[5, 4],
            strokeWidth: 1.2,
            color: ProcedureSelectionTheme.ink.withValues(alpha: 0.35),
            padding: EdgeInsets.zero,
          ),
          child: ProcedureGlassSurface(
            borderRadius: BorderRadius.circular(999),
            compact: true,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
              child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.add, size: 18, color: ProcedureSelectionTheme.ink.withValues(alpha: 0.88)),
                const SizedBox(width: 8),
                Text(
                  'Add custom procedure',
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: ProcedureSelectionTheme.ink,
                  ),
                ),
              ],
            ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Volume row with circular +/- stepper controls.
class ProcedureStepperControl extends StatelessWidget {
  const ProcedureStepperControl({
    super.key,
    required this.label,
    required this.value,
    required this.onDecrement,
    required this.onIncrement,
    this.valueText,
    this.onWarmBackground = false,
  });

  final String label;
  final String value;
  final VoidCallback onDecrement;
  final VoidCallback onIncrement;
  final String? valueText;
  final bool onWarmBackground;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(
          label,
          style: ProcedureSelectionTypography.body(
            size: 12,
            weight: FontWeight.w600,
            color: onWarmBackground
                ? ProcedureSelectionTheme.muted
                : ProcedureSelectionTheme.muted,
          ),
        ),
        const Spacer(),
        Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: ProcedureSelectionTheme.fieldFillLight,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _StepperCircleButton(icon: Icons.remove_rounded, onTap: onDecrement),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 4,
                      height: 4,
                      decoration: BoxDecoration(
                        color: ProcedureSelectionTheme.muted.withValues(alpha: 0.55),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 7),
                    Text(
                      valueText ?? value,
                      style: ProcedureSelectionTypography.label(
                        size: 14,
                        weight: FontWeight.w600,
                        color: ProcedureSelectionTheme.ink.withValues(alpha: 0.88),
                      ),
                    ),
                  ],
                ),
              ),
              _StepperCircleButton(icon: Icons.add_rounded, onTap: onIncrement),
            ],
          ),
        ),
      ],
    );
  }
}

class _StepperCircleButton extends StatelessWidget {
  const _StepperCircleButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: ProcedureSelectionTheme.stepperButton,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 28,
          height: 28,
          child: Icon(icon, size: 15, color: ProcedureSelectionTheme.ink.withValues(alpha: 0.82)),
        ),
      ),
    );
  }
}

/// Segmented legend below the face map.
class ProcedureFaceMapLegend extends StatelessWidget {
  const ProcedureFaceMapLegend({super.key});

  @override
  Widget build(BuildContext context) {
    Widget segment({
      required String label,
      required bool active,
      required BorderRadius radius,
    }) {
      return Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 11),
          decoration: BoxDecoration(
            color: active ? ProcedureSelectionTheme.legendActive : Colors.transparent,
            borderRadius: radius,
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: GoogleFonts.plusJakartaSans(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: ProcedureSelectionTheme.ink.withValues(alpha: 0.78),
            ),
          ),
        ),
      );
    }

    return ProcedureGlassSurface(
      borderRadius: BorderRadius.circular(12),
      compact: true,
      child: IntrinsicHeight(
        child: Row(
          children: [
            segment(
              active: true,
              radius: const BorderRadius.horizontal(left: Radius.circular(12)),
              label: 'Selected',
            ),
            VerticalDivider(
              width: 1,
              thickness: 1,
              color: ProcedureSelectionTheme.ink.withValues(alpha: 0.08),
            ),
            segment(
              active: false,
              radius: const BorderRadius.horizontal(right: Radius.circular(12)),
              label: 'Tap to select',
            ),
          ],
        ),
      ),
    );
  }
}

/// Tappable face-zone chips synced with the head map.
class ProcedureFaceZoneList extends StatelessWidget {
  const ProcedureFaceZoneList({
    super.key,
    required this.zones,
    required this.isSelected,
    required this.onToggle,
  });

  final List<String> zones;
  final bool Function(String zone) isSelected;
  final ValueChanged<String> onToggle;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final zone in zones)
          _ProcedureFaceZoneChip(
            label: zone,
            selected: isSelected(zone),
            onTap: () => onToggle(zone),
          ),
      ],
    );
  }
}

class _ProcedureFaceZoneChip extends StatelessWidget {
  const _ProcedureFaceZoneChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: ProcedureGlassSurface(
          borderRadius: BorderRadius.circular(999),
          selected: selected,
          compact: true,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (selected) ...[
                  Icon(Icons.check_rounded, size: 14, color: Colors.white.withValues(alpha: 0.92)),
                  const SizedBox(width: 4),
                ],
                Text(
                  label,
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: selected ? Colors.white : ProcedureSelectionTheme.ink.withValues(alpha: 0.88),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Product name field styled for the reference card.
class ProcedureProductField extends StatelessWidget {
  const ProcedureProductField({
    super.key,
    required this.controller,
    required this.label,
  });

  final TextEditingController controller;
  final String label;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      keyboardAppearance: Brightness.light,
      textCapitalization: TextCapitalization.sentences,
      style: ProcedureSelectionTypography.label(
        size: 13,
        weight: FontWeight.w600,
        color: ProcedureSelectionTheme.ink.withValues(alpha: 0.90),
      ),
      decoration: InputDecoration(
        hintText: label,
        hintStyle: ProcedureSelectionTypography.body(
          size: 13,
          weight: FontWeight.w500,
          color: ProcedureSelectionTheme.muted.withValues(alpha: 0.85),
        ),
        filled: true,
        fillColor: ProcedureSelectionTheme.fieldFillLight,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: ProcedureSelectionTheme.cardBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: ProcedureSelectionTheme.ink.withValues(alpha: 0.18)),
        ),
        prefixIcon: Padding(
          padding: const EdgeInsets.only(left: 12, right: 6),
          child: Icon(Icons.sell_outlined, size: 16, color: ProcedureSelectionTheme.muted.withValues(alpha: 0.75)),
        ),
        prefixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
      ),
    );
  }
}

/// Soft ambient wash behind the face map.
/// Kept very light and white-only — grey discs read as dirty shadows without blur.
class ProcedureFaceAmbientGlow extends StatelessWidget {
  const ProcedureFaceAmbientGlow({super.key});

  @override
  Widget build(BuildContext context) {
    return const IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(0, -0.05),
            radius: 0.85,
            colors: [
              Color(0x14FFFFFF),
              Color(0x00FFFFFF),
            ],
          ),
        ),
        child: SizedBox.expand(),
      ),
    );
  }
}

/// Soft highlight under the chin on the face map.
class ProcedureFaceUnderNeonGlow extends StatelessWidget {
  const ProcedureFaceUnderNeonGlow({super.key});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;

        return IgnorePointer(
          child: Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: EdgeInsets.only(bottom: h * 0.02),
              child: Container(
                width: w * 0.72,
                height: h * 0.12,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(999),
                  gradient: RadialGradient(
                    center: Alignment.topCenter,
                    radius: 1.0,
                    colors: [
                      Colors.white.withValues(alpha: 0.28),
                      Colors.white.withValues(alpha: 0.0),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Premium polished-glass primary action button.
class ProcedurePremiumContinueButton extends StatelessWidget {
  const ProcedurePremiumContinueButton({
    super.key,
    required this.label,
    required this.onPressed,
  });

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    const radius = 32.0;
    final labelStyle = GoogleFonts.plusJakartaSans(
      fontSize: 14,
      fontWeight: FontWeight.w700,
      color: Colors.white,
      height: 1.0,
    );

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        boxShadow: [
          ...ProcedureGlassDecorations.neonFrameGlow(),
          ...ProcedureGlassDecorations.depthShadow(elevated: true, selected: true),
        ],
      ),
      child: SizedBox(
        width: double.infinity,
        child: FilledButton(
          onPressed: onPressed,
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF111214),
            foregroundColor: Colors.white,
            disabledBackgroundColor: const Color(0xFF111214).withValues(alpha: 0.42),
            disabledForegroundColor: Colors.white.withValues(alpha: 0.78),
            elevation: 0,
            shadowColor: Colors.transparent,
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 15),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
          ),
          child: Text(label, textAlign: TextAlign.center, style: labelStyle),
        ),
      ),
    );
  }
}
