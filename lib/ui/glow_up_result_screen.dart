import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../services/glow_up_history_store.dart';
import '../services/glow_up_job.dart';
import '../services/glow_up_pipeline.dart';
import 'clinics_for_procedure_screen.dart';
import 'glow_up_history_screen.dart';
import 'photo_storage.dart';

// glow_up_select_procedure.html — photo frame matches before_after_comparison_screen.dart
const _bg = Color(0xFF0C0C0E);
const _surface = Color(0xFF111115);
const _surface2 = Color(0xFF1A1A1F);
const _border = Color(0xFF1E1E24);
const _photoBefore = Color(0xFF0E0E12);
const _faceBg = Color(0xFF1A1A20);
const _cyan = Color(0xFF22D3EE);
const _cyanMid = Color(0xFF0EA5E9);
const _indigo = Color(0xFF6366F1);
const _indigoLight = Color(0xFF818CF8);
const _pageH = 12.0;
const _frameMarginH = 0.0;
const _frameRadius = 16.0;
abstract final class _Type {
  static const _fonts = <String>['.SF Pro Display', 'Helvetica Neue', 'Arial'];

  static TextStyle _s(
    double size, {
    FontWeight weight = FontWeight.w400,
    Color? color,
    double? letterSpacing,
    double? height,
  }) => TextStyle(
    fontFamily: '.SF Pro Display',
    fontFamilyFallback: _fonts,
    fontSize: size,
    fontWeight: weight,
    color: color,
    letterSpacing: letterSpacing,
    height: height,
  );

  static TextStyle get navEye => _s(
    11,
    color: Colors.white.withValues(alpha: 0.28),
    letterSpacing: 1.2,
    height: 1.2,
  );

  static TextStyle get navTitle =>
      _s(15, weight: FontWeight.w500, color: Colors.white, height: 1.2);

  static TextStyle get scoreLbl => _s(
    9,
    color: Colors.white.withValues(alpha: 0.24),
    letterSpacing: 0.5,
    height: 1.2,
  );

  static TextStyle get scoreVal => _s(
    12,
    weight: FontWeight.w500,
    color: Colors.white.withValues(alpha: 0.38),
    height: 1.2,
  );

  static TextStyle get scoreValHi =>
      _s(12, weight: FontWeight.w500, color: Colors.white, height: 1.2);

  static TextStyle get scoreDelta => _s(
    10,
    weight: FontWeight.w500,
    color: Colors.white.withValues(alpha: 0.42),
    height: 1.2,
  );

  static TextStyle get scoreDeltaHi =>
      _s(10, weight: FontWeight.w500, color: _cyan, height: 1.2);

  static TextStyle get sectionTitle =>
      _s(13, weight: FontWeight.w500, color: Colors.white, height: 1.2);

  static TextStyle get sectionHint =>
      _s(11, color: Colors.white.withValues(alpha: 0.24), height: 1.2);

  static TextStyle get areasTitle =>
      _s(14, weight: FontWeight.w500, color: Colors.white, height: 1.2);

  static TextStyle get areasSub =>
      _s(11, color: Colors.white.withValues(alpha: 0.32), height: 1.3);

  static TextStyle get areasLegend =>
      _s(10, color: Colors.white.withValues(alpha: 0.28), height: 1.2);

  static TextStyle get zoneNameGood => _s(
    10,
    color: Colors.white.withValues(alpha: 0.32),
    letterSpacing: 0.6,
    height: 1.2,
  );

  static TextStyle get zoneNameNeeds =>
      _s(10, color: Color(0xFFFB7185), letterSpacing: 0.6, height: 1.2);

  static TextStyle get zoneValGood => _s(
    20,
    weight: FontWeight.w500,
    color: Colors.white.withValues(alpha: 0.55),
    height: 1.1,
  );

  static TextStyle get zoneValNeeds =>
      _s(20, weight: FontWeight.w500, color: Color(0xFFFB7185), height: 1.1);

  static TextStyle get procName => _s(
    13,
    weight: FontWeight.w500,
    color: Colors.white.withValues(alpha: 0.72),
    height: 1.25,
  );

  static TextStyle get procNameSel =>
      _s(13, weight: FontWeight.w500, color: Colors.white, height: 1.25);

  static TextStyle get procSub =>
      _s(11, color: Colors.white.withValues(alpha: 0.28), height: 1.35);

  static TextStyle get procPts => _s(
    12,
    weight: FontWeight.w500,
    color: Colors.white.withValues(alpha: 0.35),
    height: 1.2,
  );

  static TextStyle get procPtsSel =>
      _s(12, weight: FontWeight.w500, color: _cyan, height: 1.2);

  static TextStyle get cardTitle =>
      _s(13, weight: FontWeight.w500, color: Colors.white, height: 1.25);

  static TextStyle get cardBody =>
      _s(11, color: Colors.white.withValues(alpha: 0.28), height: 1.35);

  static TextStyle get metricName =>
      _s(11, color: Colors.white.withValues(alpha: 0.28), height: 1.25);

  static TextStyle get metricVal => _s(
    11,
    weight: FontWeight.w500,
    color: Colors.white.withValues(alpha: 0.42),
    height: 1.25,
  );

  static TextStyle get ctaLabel =>
      _s(11, color: Colors.white.withValues(alpha: 0.32), height: 1.2);

  static TextStyle get ctaProc =>
      _s(12, weight: FontWeight.w500, color: _cyan, height: 1.2);

  static TextStyle get ctaBtn =>
      _s(15, weight: FontWeight.w500, color: Colors.white, height: 1.2);

  static TextStyle get dissolveSectionLbl => _s(
    10,
    weight: FontWeight.w500,
    color: Colors.white.withValues(alpha: 0.32),
    letterSpacing: 0.4,
    height: 1.2,
  );

  static TextStyle get dissolveZoneName =>
      _s(12, weight: FontWeight.w500, color: Colors.white, height: 1.2);

  static TextStyle get dissolveZoneNote =>
      _s(11, color: Colors.white.withValues(alpha: 0.28), height: 1.35);
}

const _needsWorkPink = Color(0xFFFB7185);
const _needsWorkCellBg = Color(0xFF1A1014);
const _zoneGridBg = Color(0xFF111115);
const _zoneGridBorder = Color(0xFF1E1E24);

class _SuggestedProcedure {
  const _SuggestedProcedure({
    required this.name,
    required this.subtitle,
    required this.points,
    required this.icon,
  });

  final String name;
  final String subtitle;
  final String points;
  final IconData icon;
}

class _SkinMetricView {
  const _SkinMetricView(this.name, this.value, this.fill, this.gradient);
  final String name;
  final String value;
  final double fill;
  final List<Color> gradient;
}

const _skinMetricGradients = <String, List<Color>>{
  'Pore size': [_cyan, _cyanMid],
  'Brightness': [_indigoLight, _indigo],
  'Evenness': [Color(0xFF34D399), Color(0xFF059669)],
  'Hydration': [Color(0xFFFB923C), Color(0xFFEA580C)],
};

List<_SkinMetricView> _viewMetricsFrom(List<SkinMetric> metrics) {
  return [
    for (final m in metrics)
      _SkinMetricView(
        m.name,
        m.display,
        m.fill,
        _skinMetricGradients[m.name] ?? const [_cyan, _cyanMid],
      ),
  ];
}

const _procedures = [
  _SuggestedProcedure(
    name: 'Lip filler',
    subtitle: 'Volume · biggest score impact',
    points: '+22 pts',
    icon: Icons.favorite_border,
  ),
  _SuggestedProcedure(
    name: 'Skin booster',
    subtitle: 'Hydration + radiance',
    points: '+14 pts',
    icon: Icons.water_drop_outlined,
  ),
  _SuggestedProcedure(
    name: 'Cheek filler',
    subtitle: 'Lift + contour',
    points: '+9 pts',
    icon: Icons.wb_sunny_outlined,
  ),
  _SuggestedProcedure(
    name: 'Botox — forehead',
    subtitle: 'Smooth lines · preventative',
    points: '+6 pts',
    icon: Icons.medical_services_outlined,
  ),
  _SuggestedProcedure(
    name: 'Polynucleotides',
    subtitle: 'Under-eye · regenerative',
    points: '+8 pts',
    icon: Icons.auto_awesome_outlined,
  ),
  _SuggestedProcedure(
    name: 'Rhinoplasty',
    subtitle: 'Nose shape · surgical preview',
    points: '+11 pts',
    icon: Icons.face_retouching_natural_outlined,
  ),
];

// Dissolve recommendations are now computed live from MediaPipe asymmetry
// in GlowUpPipeline — see [DissolveZone] / [DissolveConfidence] in
// glow_up_pipeline.dart.

/// Step 3: glow report with selectable procedure (glow_up_select_procedure.html).
class GlowUpResultScreen extends StatefulWidget {
  const GlowUpResultScreen({
    super.key,
    this.photoPath,
    this.analysis,
    this.fromHistory = false,
  });

  final String? photoPath;

  /// Result of the Replicate + MediaPipe Face Mesh pipeline. When null the
  /// screen falls back to a synthetic analysis seeded from [photoPath] so
  /// older callers (and the back-button path) still render.
  final GlowAnalysisResult? analysis;

  /// When true, skips auto-save (entry already exists in history).
  final bool fromHistory;

  @override
  State<GlowUpResultScreen> createState() => _GlowUpResultScreenState();
}

class _GlowUpResultScreenState extends State<GlowUpResultScreen> {
  int _selectedProcedure = 0;

  late final GlowAnalysisResult _analysis =
      widget.analysis ??
      GlowAnalysisResult.fallback(originalPath: widget.photoPath);

  @override
  void initState() {
    super.initState();
    _selectedProcedure = _initialProcedureIndex(_analysis.faceReport);
    if (!widget.fromHistory) {
      _persistHistory();
    }
  }

  /// Avoid defaulting to "Lip filler" when lips are confirmed overfilled.
  int _initialProcedureIndex(FaceAnalysisReport? report) {
    if (report == null) return 0;
    if (report.plansNoseRhinoplasty) {
      final i = _procedures.indexWhere(
        (p) => p.name.toLowerCase().contains('rhino'),
      );
      if (i >= 0) return i;
    }
    if (report.plansUnderEyeTreatment) {
      final i = _procedures.indexWhere(
        (p) =>
            p.name.toLowerCase().contains('polynucleotide') ||
            p.subtitle.toLowerCase().contains('under-eye'),
      );
      if (i >= 0) return i;
    }
    final lips = report.findings.where((f) => f.area.toLowerCase() == 'lips');
    if (lips.any((f) => f.isConfirmedFillerOverfill)) {
      return 1; // Skin booster — not more filler
    }
    final jawSagging = report.findings.where((f) => f.area.toLowerCase() == 'jaw');
    if (jawSagging.any((f) => f.showsNaturalAging)) {
      return 3; // Botox / lines — common for aging lower face
    }
    return 0;
  }

  Future<void> _persistHistory() async {
    final before = _analysis.originalPath.trim().isNotEmpty
        ? _analysis.originalPath
        : (widget.photoPath?.trim() ?? '');
    if (before.isEmpty) return;
    final scores = _analysis.scores;
    final entry = await GlowUpHistoryStore.createEntry(
      beforeSource: before,
      afterSource: _analysis.enhancedUrl,
      sliderBeforeSource: _analysis.sliderBeforePath,
      sliderAfterSource: _analysis.sliderAfterPath,
      glowScore: scores.glowScore,
      potentialScore: scores.potentialScore,
      analysis: _analysis,
    );
    await GlowUpHistoryStore.add(entry);
  }

  void _openHistory() {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const GlowUpHistoryScreen()),
    );
  }

  void _openClinicsForSelected() {
    final proc = _procedures[_selectedProcedure];
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ClinicsForProcedureScreen(
          procedureName: proc.name,
          city: 'London',
          aliases: [proc.name],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final selected = _procedures[_selectedProcedure];
    final scores = _analysis.scores;
    final skinView = _viewMetricsFrom(scores.skinMetrics);

    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop && !widget.fromHistory) {
          unawaited(GlowUpJobController.instance.reset());
        }
      },
      child: Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(bottom: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _NavBar(
                      onBack: () {
                        if (!widget.fromHistory) {
                          unawaited(GlowUpJobController.instance.reset());
                        }
                        Navigator.of(context).pop();
                      },
                      onHistory: _openHistory,
                    ),
                    if (_analysis.error != null && !_analysis.hasEnhanced)
                      _PipelineDebugBanner(error: _analysis.error!),
                    _GlowCompareFrame(
                      photoPath: _analysis.originalPath.isNotEmpty
                          ? _analysis.originalPath
                          : widget.photoPath,
                      enhancedUrl: _analysis.enhancedUrl,
                      sliderBeforePath: _analysis.sliderBeforePath,
                      sliderAfterPath: _analysis.sliderAfterPath,
                      sliderSideBySidePath: _analysis.sliderSideBySidePath,
                      scores: scores,
                    ),
                    if (_analysis.faceReport != null) ...[
                      if (_analysis.faceReport!.hasGlowUpPlan) ...[
                        const SizedBox(height: 14),
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: _pageH + _frameMarginH,
                          ),
                          child: _GlowUpPlanSection(
                            report: _analysis.faceReport!,
                            hasAfterImage: _analysis.hasEnhanced,
                          ),
                        ),
                      ],
                      const SizedBox(height: 14),
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: _pageH + _frameMarginH,
                        ),
                        child: _FaceAnalysisSection(
                          report: _analysis.faceReport!,
                          skinMetrics: skinView,
                        ),
                      ),
                      const SizedBox(height: 14),
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: _pageH + _frameMarginH,
                        ),
                        child: _ZoneScoreGrid(zones: scores.zones),
                      ),
                      const SizedBox(height: 14),
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: _pageH + _frameMarginH,
                        ),
                        child: _FillerSymmetrySection(
                          report: _analysis.faceReport!,
                        ),
                      ),
                    ] else ...[
                      const SizedBox(height: 14),
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: _pageH + _frameMarginH,
                        ),
                        child: _ZoneScoreGrid(zones: scores.zones),
                      ),
                    ],
                    const SizedBox(height: 14),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: _pageH + _frameMarginH,
                      ),
                      child: _ProceduresSection(
                        selectedIndex: _selectedProcedure,
                        onSelect: (i) => setState(() => _selectedProcedure = i),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: _pageH + _frameMarginH,
                      ),
                      child: _DissolveRow(zones: _analysis.dissolveZones),
                    ),
                  ],
                ),
              ),
            ),
            _StickyCta(
              procedureName: selected.name,
              onFindClinics: _openClinicsForSelected,
            ),
          ],
        ),
      ),
      ),
    );
  }
}

class _NavBar extends StatelessWidget {
  const _NavBar({
    required this.onBack,
    required this.onHistory,
  });

  final VoidCallback onBack;
  final VoidCallback onHistory;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
      child: Row(
        children: [
          _NavCircleBtn(icon: Icons.chevron_left, onTap: onBack),
          Expanded(
            child: Column(
              children: [
                Text('GLOW UP AI', style: _Type.navEye),
                const SizedBox(height: 2),
                Text('Your glow report', style: _Type.navTitle),
              ],
            ),
          ),
          _NavCircleBtn(icon: Icons.history_rounded, onTap: onHistory),
          const SizedBox(width: 8),
          _NavCircleBtn(icon: Icons.share_outlined, onTap: () {}),
        ],
      ),
    );
  }
}

class _NavCircleBtn extends StatelessWidget {
  const _NavCircleBtn({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: _surface2,
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: 32,
          height: 32,
          child: Icon(
            icon,
            size: 16,
            color: Colors.white.withValues(alpha: 0.5),
          ),
        ),
      ),
    );
  }
}

/// Small amber strip surfaced when the Replicate pipeline reported one or
/// more stage errors. Lets the user see *why* the AFTER side fell back to
/// the original photo instead of silently rendering an unchanged image.
class _PipelineDebugBanner extends StatelessWidget {
  const _PipelineDebugBanner({required this.error});

  final String error;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(_frameMarginH, 0, _frameMarginH, 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF1F140A),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: const Color(0xFFFBBF24).withValues(alpha: 0.3),
          width: 0.5,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.info_outline,
            size: 14,
            color: Color(0xFFFBBF24),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              error,
              style: TextStyle(
                fontSize: 10,
                height: 1.35,
                color: Colors.white.withValues(alpha: 0.65),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _GlowCompareFrame extends StatefulWidget {
  const _GlowCompareFrame({
    required this.photoPath,
    required this.enhancedUrl,
    this.sliderBeforePath,
    this.sliderAfterPath,
    this.sliderSideBySidePath,
    required this.scores,
  });

  final String? photoPath;
  final String? enhancedUrl;
  final String? sliderBeforePath;
  final String? sliderAfterPath;
  final String? sliderSideBySidePath;
  final GlowScores scores;

  @override
  State<_GlowCompareFrame> createState() => _GlowCompareFrameState();
}

class _GlowCompareFrameState extends State<_GlowCompareFrame> {
  bool _useSlider = true;

  bool get _useMatchedFraming {
    bool matched(String? p) {
      if (p == null || p.trim().isEmpty) return false;
      return p.contains('glow_slider_') ||
          p.contains('slider_before') ||
          p.contains('slider_after') ||
          p.contains('side_by_side') ||
          p.contains('glow_history');
    }

    return matched(widget.sliderBeforePath) ||
        matched(widget.sliderAfterPath) ||
        matched(widget.sliderSideBySidePath);
  }

  @override
  Widget build(BuildContext context) {
    final beforePath = widget.sliderBeforePath ??
        (widget.photoPath != null && widget.photoPath!.isNotEmpty
            ? widget.photoPath
            : null);
    final afterPath =
        widget.sliderAfterPath ?? widget.enhancedUrl ?? widget.photoPath;
    final matchedFraming = _useMatchedFraming ||
        beforePath?.contains('glow_history') == true ||
        afterPath?.contains('glow_history') == true;

    return Container(
      margin: const EdgeInsets.only(top: 4),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(_frameRadius),
        border: Border.all(color: _border, width: 0.5),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 10, 10, 0),
            child: Align(
              alignment: Alignment.centerRight,
              child: _CompareModeToggle(
                useSlider: _useSlider,
                onChanged: (v) => setState(() => _useSlider = v),
              ),
            ),
          ),
          LayoutBuilder(
            builder: (context, constraints) {
              final h = (MediaQuery.sizeOf(context).height * 0.44)
                  .clamp(340.0, 500.0);
              return Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
                child: SizedBox(
                  height: h,
                  width: constraints.maxWidth,
                  child: _useSlider
                      ? _GlowSliderCompare(
                          beforePath: beforePath,
                          afterPath: afterPath,
                          useMatchedFraming: matchedFraming,
                        )
                      : _GlowSideBySideCompare(
                          beforePath: beforePath,
                          afterPath: afterPath,
                          stripPath: widget.sliderSideBySidePath,
                          useMatchedFraming: matchedFraming,
                        ),
                ),
              );
            },
          ),
          _GlowScoreStrip(scores: widget.scores),
        ],
      ),
    );
  }
}

class _CompareModeToggle extends StatelessWidget {
  const _CompareModeToggle({required this.useSlider, required this.onChanged});

  final bool useSlider;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _border, width: 0.5),
      ),
      padding: const EdgeInsets.all(2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _toggleChip(
            label: 'Slider',
            icon: Icons.swap_horiz,
            selected: useSlider,
            onTap: () => onChanged(true),
          ),
          _toggleChip(
            label: 'Side by side',
            icon: Icons.view_agenda_outlined,
            selected: !useSlider,
            onTap: () => onChanged(false),
          ),
        ],
      ),
    );
  }

  Widget _toggleChip({
    required String label,
    required IconData icon,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? _cyan.withValues(alpha: 0.18) : Colors.transparent,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: selected
                ? _cyan.withValues(alpha: 0.55)
                : Colors.transparent,
            width: 0.5,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 12,
              color: selected
                  ? _cyan
                  : Colors.white.withValues(alpha: 0.55),
            ),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                fontSize: 10,
                letterSpacing: 0.4,
                fontWeight: FontWeight.w600,
                color: selected
                    ? Colors.white
                    : Colors.white.withValues(alpha: 0.55),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GlowSideBySideCompare extends StatelessWidget {
  const _GlowSideBySideCompare({
    required this.beforePath,
    required this.afterPath,
    this.stripPath,
    this.useMatchedFraming = false,
  });

  final String? beforePath;
  final String? afterPath;
  final String? stripPath;
  final bool useMatchedFraming;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final strip = (stripPath ?? '').trim();
          if (strip.isNotEmpty) {
            return _GlowSideBySideStripView(path: strip);
          }

          if (useMatchedFraming) {
            return _GlowMatchedSideBySideCompare(
              beforePath: beforePath,
              afterPath: afterPath,
            );
          }

          final halfW = (constraints.maxWidth - 1) / 2;
          final h = constraints.maxHeight;
          return Row(
            children: [
              _SideBySideHalf(
                path: beforePath,
                width: halfW,
                height: h,
                label: 'BEFORE',
                bright: false,
                useMatchedFraming: false,
              ),
              const SizedBox(width: 1),
              _SideBySideHalf(
                path: afterPath,
                width: halfW,
                height: h,
                label: 'AFTER',
                bright: true,
                useMatchedFraming: false,
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Pre-rendered 2048×1024 strip — faces meet at the center (no black gutter).
class _GlowSideBySideStripView extends StatelessWidget {
  const _GlowSideBySideStripView({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: LayoutBuilder(
        builder: (context, constraints) {
          return Stack(
            fit: StackFit.expand,
            children: [
              Center(
                child: AspectRatio(
                  aspectRatio: 2,
                  child: _GlowComparisonImage(
                    photoPath: path,
                    width: constraints.maxWidth,
                    height: constraints.maxHeight,
                    fit: BoxFit.contain,
                    alignment: Alignment.center,
                  ),
                ),
              ),
              const Positioned(
                top: 10,
                left: 10,
                child: _CompareCornerLabel(text: 'BEFORE', bright: false),
              ),
              const Positioned(
                top: 10,
                right: 10,
                child: _CompareCornerLabel(text: 'AFTER', bright: true),
              ),
              Center(
                child: Container(
                  width: 0.5,
                  color: Colors.white.withValues(alpha: 0.35),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Fallback: two 1024 tiles on one square (split at center).
class _GlowMatchedSideBySideCompare extends StatelessWidget {
  const _GlowMatchedSideBySideCompare({
    required this.beforePath,
    required this.afterPath,
  });

  static const double _canvas = 1024;

  final String? beforePath;
  final String? afterPath;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final side = math.min(constraints.maxWidth, constraints.maxHeight);
          return Stack(
            fit: StackFit.expand,
            children: [
              Center(
                child: SizedBox(
                  width: side,
                  height: side,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Positioned.fill(
                        child: Align(
                          alignment: Alignment.centerRight,
                          widthFactor: 0.5,
                          child: _CompareCanvasImage(path: afterPath),
                        ),
                      ),
                      Positioned.fill(
                        child: Align(
                          alignment: Alignment.centerLeft,
                          widthFactor: 0.5,
                          child: _CompareCanvasImage(path: beforePath),
                        ),
                      ),
                      Center(
                        child: Container(
                          width: 0.5,
                          color: Colors.white.withValues(alpha: 0.35),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const Positioned(
                top: 10,
                left: 10,
                child: _CompareCornerLabel(text: 'BEFORE', bright: false),
              ),
              const Positioned(
                top: 10,
                right: 10,
                child: _CompareCornerLabel(text: 'AFTER', bright: true),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _SideBySideCanvasTile extends StatelessWidget {
  const _SideBySideCanvasTile({
    required this.path,
    required this.label,
    required this.bright,
  });

  final String? path;
  final String label;
  final bool bright;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Stack(
        fit: StackFit.expand,
        children: [
          _CompareCanvasImage(path: path),
          Positioned(
            top: 8,
            left: 8,
            child: _CompareCornerLabel(text: label, bright: bright),
          ),
        ],
      ),
    );
  }
}

class _SideBySideHalf extends StatelessWidget {
  const _SideBySideHalf({
    required this.path,
    required this.width,
    required this.height,
    required this.label,
    required this.bright,
    this.useMatchedFraming = false,
  });

  final String? path;
  final double width;
  final double height;
  final String label;
  final bool bright;
  final bool useMatchedFraming;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: ColoredBox(
        color: Colors.black,
        child: SizedBox(
          width: width,
          height: height,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Positioned.fill(
                child: _GlowComparisonImage(
                  photoPath: path,
                  width: width,
                  height: height,
                  fit: useMatchedFraming ? BoxFit.contain : BoxFit.cover,
                  alignment: Alignment.center,
                ),
              ),
              Positioned(
                top: 8,
                left: 8,
                child: _CompareCornerLabel(text: label, bright: bright),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GlowSliderCompare extends StatefulWidget {
  const _GlowSliderCompare({
    required this.beforePath,
    required this.afterPath,
    this.useMatchedFraming = false,
  });

  final String? beforePath;
  final String? afterPath;
  final bool useMatchedFraming;

  @override
  State<_GlowSliderCompare> createState() => _GlowSliderCompareState();
}

class _GlowSliderCompareState extends State<_GlowSliderCompare> {
  double _split = 0.5;

  void _setSplitFraction(double fraction) {
    final x = fraction.clamp(0.12, 0.88);
    if (_split != x) setState(() => _split = x);
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (widget.useMatchedFraming) {
            return _GlowMatchedSliderCompare(
              beforePath: widget.beforePath,
              afterPath: widget.afterPath,
              split: _split,
              maxWidth: constraints.maxWidth,
              maxHeight: constraints.maxHeight,
              onSplitFraction: _setSplitFraction,
            );
          }

          final w = constraints.maxWidth;
          final h = constraints.maxHeight;
          final splitX = w * _split;
          final layer = _GlowComparisonLayer(
            width: w,
            height: h,
            useMatchedFraming: false,
          );

          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragUpdate: (d) =>
                _setSplitFraction(_split + d.delta.dx / w),
            onTapDown: (d) => _setSplitFraction(d.localPosition.dx / w),
            child: ColoredBox(
              color: Colors.black,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Positioned.fill(
                    child: layer.withPhotoPath(widget.afterPath),
                  ),
                  Positioned.fill(
                    child: ClipRect(
                      clipper: _GlowLeftSplitClipper(fraction: _split),
                      child: layer.withPhotoPath(widget.beforePath),
                    ),
                  ),
                  Positioned(
                    left: splitX - 0.75,
                    top: 0,
                    bottom: 0,
                    child: Container(
                      width: 1.5,
                      color: Colors.white.withValues(alpha: 0.55),
                    ),
                  ),
                  Positioned(
                    left: splitX - 14,
                    top: h / 2 - 14,
                    child: GestureDetector(
                      onHorizontalDragUpdate: (d) =>
                          _setSplitFraction(_split + d.delta.dx / w),
                      child: const _GlowSliderHandle(),
                    ),
                  ),
                  const Positioned(
                    top: 10,
                    left: 10,
                    child: _CompareCornerLabel(text: 'BEFORE', bright: false),
                  ),
                  const Positioned(
                    top: 10,
                    right: 10,
                    child: _CompareCornerLabel(text: 'AFTER', bright: true),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Matched 1024² pair — after fixed; before clipped on the left at [split].
class _GlowMatchedSliderCompare extends StatelessWidget {
  const _GlowMatchedSliderCompare({
    required this.beforePath,
    required this.afterPath,
    required this.split,
    required this.maxWidth,
    required this.maxHeight,
    required this.onSplitFraction,
  });

  static const double _canvas = 1024;

  final String? beforePath;
  final String? afterPath;
  final double split;
  final double maxWidth;
  final double maxHeight;
  final ValueChanged<double> onSplitFraction;

  @override
  Widget build(BuildContext context) {
    final side = math.min(maxWidth, maxHeight);
    final offsetX = (maxWidth - side) / 2;
    final splitX = offsetX + side * split;

    double fractionFromLocalDx(double localX) =>
        ((localX - offsetX) / side).clamp(0.12, 0.88);

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragUpdate: (d) =>
          onSplitFraction((split + d.delta.dx / side).clamp(0.12, 0.88)),
      onTapDown: (d) => onSplitFraction(fractionFromLocalDx(d.localPosition.dx)),
      child: ColoredBox(
        color: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Center(
              child: SizedBox(
                width: side,
                height: side,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Positioned.fill(
                      child: _CompareCanvasImage(path: afterPath),
                    ),
                    Positioned.fill(
                      child: ClipRect(
                        clipper: _GlowLeftSplitClipper(fraction: split),
                        child: _CompareCanvasImage(path: beforePath),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              left: splitX - 0.75,
              top: 0,
              bottom: 0,
              child: Container(
                width: 1.5,
                color: Colors.white.withValues(alpha: 0.55),
              ),
            ),
            Positioned(
              left: splitX - 14,
              top: maxHeight / 2 - 14,
              child: GestureDetector(
                onHorizontalDragUpdate: (d) =>
                    onSplitFraction((split + d.delta.dx / side).clamp(0.12, 0.88)),
                child: const _GlowSliderHandle(),
              ),
            ),
            const Positioned(
              top: 10,
              left: 10,
              child: _CompareCornerLabel(text: 'BEFORE', bright: false),
            ),
            const Positioned(
              top: 10,
              right: 10,
              child: _CompareCornerLabel(text: 'AFTER', bright: true),
            ),
          ],
        ),
      ),
    );
  }
}

/// Fills the 1024² compare canvas (paired with [_GlowMatchedSliderCompare]).
class _CompareCanvasImage extends StatelessWidget {
  const _CompareCanvasImage({required this.path});

  final String? path;

  @override
  Widget build(BuildContext context) {
    return _GlowComparisonImage(
      photoPath: path,
      width: _GlowMatchedSliderCompare._canvas,
      height: _GlowMatchedSliderCompare._canvas,
      fit: BoxFit.fill,
      alignment: Alignment.center,
    );
  }
}

class _GlowLeftSplitClipper extends CustomClipper<Rect> {
  const _GlowLeftSplitClipper({required this.fraction});

  final double fraction;

  @override
  Rect getClip(Size size) => Rect.fromLTWH(0, 0, size.width * fraction, size.height);

  @override
  bool shouldReclip(_GlowLeftSplitClipper old) => old.fraction != fraction;
}

class _GlowSliderHandle extends StatelessWidget {
  const _GlowSliderHandle();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white,
        border: Border.all(color: _bg, width: 3),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: const Icon(Icons.swap_horiz, size: 13, color: Colors.black),
    );
  }
}

/// Matched 1024² slider JPEGs — identical [BoxFit] on both layers at the seam.
class _GlowComparisonLayer extends StatelessWidget {
  const _GlowComparisonLayer({
    this.photoPath,
    required this.width,
    required this.height,
    this.useMatchedFraming = false,
  });

  final String? photoPath;
  final double width;
  final double height;
  final bool useMatchedFraming;

  _GlowComparisonLayer withPhotoPath(String? path) {
    return _GlowComparisonLayer(
      photoPath: path,
      width: width,
      height: height,
      useMatchedFraming: useMatchedFraming,
    );
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: height,
      child: _GlowComparisonImage(
        photoPath: photoPath,
        width: width,
        height: height,
        fit: BoxFit.cover,
        alignment: Alignment.center,
      ),
    );
  }
}

class _GlowComparisonImage extends StatelessWidget {
  const _GlowComparisonImage({
    required this.photoPath,
    required this.width,
    required this.height,
    this.fit = BoxFit.fill,
    this.alignment = Alignment.center,
  });

  final String? photoPath;
  final double width;
  final double height;
  final BoxFit fit;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    final hasPhoto = _photoExists(photoPath);
    if (!hasPhoto) {
      return Center(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final ph = constraints.maxHeight;
            final iconH = (ph * 0.42).clamp(100.0, 160.0);
            final iconW = iconH * 0.75;
            return Container(
              width: iconW,
              height: iconH,
              decoration: BoxDecoration(
                color: _faceBg,
                borderRadius: BorderRadius.circular(iconH / 2),
                border: Border.all(color: const Color(0xFF222228), width: 0.5),
              ),
              child: Icon(
                Icons.person_outline,
                size: iconH * 0.28,
                color: const Color(0xFF222228),
              ),
            );
          },
        ),
      );
    }

    return Image(
      key: ValueKey(photoPath),
      image: _imageProvider(photoPath!),
      width: width,
      height: height,
      fit: fit,
      alignment: alignment,
      gaplessPlayback: true,
      filterQuality: FilterQuality.high,
    );
  }
}

class _CompareCornerLabel extends StatelessWidget {
  const _CompareCornerLabel({required this.text, this.bright = false});

  final String text;
  final bool bright;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(20),
        border: bright
            ? Border.all(color: _cyan.withValues(alpha: 0.25), width: 0.5)
            : null,
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 9,
          letterSpacing: 1.1,
          fontWeight: FontWeight.w500,
          color: bright
              ? _cyan.withValues(alpha: 0.95)
              : Colors.white.withValues(alpha: 0.45),
        ),
      ),
    );
  }
}

class _GlowScoreStrip extends StatelessWidget {
  const _GlowScoreStrip({required this.scores});

  final GlowScores scores;

  @override
  Widget build(BuildContext context) {
    final glow = scores.glowScore.toString();
    final potential = scores.potentialScore.toString();
    final delta = scores.deltaPercent;
    return Container(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: _border, width: 0.5)),
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Container(
                decoration: const BoxDecoration(
                  border: Border(right: BorderSide(color: _border, width: 0.5)),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 16,
                ),
                child: _GlowScoreHalf(
                  score: glow,
                  highlight: false,
                  label: 'GLOW SCORE',
                  value: '$glow / 100',
                  delta: 'Original',
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 16,
                ),
                child: _GlowScoreHalf(
                  score: potential,
                  highlight: true,
                  label: 'POTENTIAL',
                  value: '$potential / 100',
                  delta: delta > 0 ? '+$delta%' : '$delta%',
                  showTrend: true,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GlowScoreHalf extends StatelessWidget {
  const _GlowScoreHalf({
    required this.score,
    required this.highlight,
    required this.label,
    required this.value,
    required this.delta,
    this.showTrend = false,
  });

  final String score;
  final bool highlight;
  final String label;
  final String value;
  final String delta;
  final bool showTrend;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: highlight
                  ? _cyan.withValues(alpha: 0.35)
                  : Colors.white.withValues(alpha: 0.12),
              width: 0.5,
            ),
          ),
          alignment: Alignment.center,
          child: Text(
            score,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w500,
              color: highlight
                  ? Colors.white
                  : Colors.white.withValues(alpha: 0.38),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label, style: _Type.scoreLbl),
              const SizedBox(height: 4),
              Text(value, style: highlight ? _Type.scoreValHi : _Type.scoreVal),
              const SizedBox(height: 4),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (showTrend) ...[
                    Icon(
                      Icons.trending_up,
                      size: 11,
                      color: _cyan.withValues(alpha: 0.7),
                    ),
                    const SizedBox(width: 4),
                  ],
                  Flexible(
                    child: Text(
                      delta,
                      style: highlight ? _Type.scoreDeltaHi : _Type.scoreDelta,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _GlowUpPlanSection extends StatelessWidget {
  const _GlowUpPlanSection({
    required this.report,
    required this.hasAfterImage,
  });

  final FaceAnalysisReport report;
  final bool hasAfterImage;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            _cyan.withValues(alpha: 0.12),
            _indigo.withValues(alpha: 0.08),
          ],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _cyan.withValues(alpha: 0.35), width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.auto_awesome,
                size: 16,
                color: _cyan.withValues(alpha: 0.9),
              ),
              const SizedBox(width: 8),
              Text('Your glow-up preview', style: _Type.areasTitle),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            hasAfterImage
                ? 'What we simulated in your AFTER photo'
                : 'Planned treatments (preview image unavailable)',
            style: _Type.areasSub,
          ),
          if ((report.glowUpExplanation ?? '').isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(report.glowUpExplanation!, style: _Type.dissolveZoneNote),
          ],
          if (report.proceduresSimulated.isNotEmpty) ...[
            const SizedBox(height: 12),
            for (final p in report.proceduresSimulated)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      margin: const EdgeInsets.only(top: 5),
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: _cyan.withValues(alpha: 0.85),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(p.name, style: _Type.dissolveZoneName),
                          if (p.change.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Text(p.change, style: _Type.areasSub),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _FillerSymmetrySection extends StatelessWidget {
  const _FillerSymmetrySection({required this.report});

  final FaceAnalysisReport report;

  @override
  Widget build(BuildContext context) {
    final fillerZones = report.filler.zones.isNotEmpty
        ? report.filler.zones
        : [
            for (final f in report.orderedFindings)
              if (['filler', 'lips', 'cheeks', 'jaw'].contains(f.area.toLowerCase()))
                FillerZoneVerdict(
                  area: f.area,
                  verdict: f.isConfirmedFillerOverfill
                      ? 'overfilled'
                      : (f.showsNaturalAging ? 'thin_aging' : 'natural'),
                  note: f.note,
                ),
          ];

    final showFiller = report.hasFillerAssessment || fillerZones.isNotEmpty;
    final showAsym = report.hasAsymmetryAssessment ||
        report.findings.any((f) => f.mentionsAsymmetry);

    if (!showFiller && !showAsym) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showFiller) ...[
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: _surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: _border, width: 0.5),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.water_drop_outlined,
                      size: 16,
                      color: report.hasFillerOverfillSignal
                          ? _needsWorkPink
                          : _cyan.withValues(alpha: 0.85),
                    ),
                    const SizedBox(width: 8),
                    Text('Filler check', style: _Type.areasTitle),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'Lips · cheeks · jawline · overall balance',
                  style: _Type.areasSub,
                ),
                if (report.filler.summary.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(report.filler.summary, style: _Type.dissolveZoneNote),
                ],
                if (fillerZones.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  for (final z in fillerZones)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            margin: const EdgeInsets.only(top: 5),
                            width: 6,
                            height: 6,
                            decoration: BoxDecoration(
                              color: z.suggestsOverfill
                                  ? _needsWorkPink
                                  : Colors.white.withValues(alpha: 0.35),
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Text(z.areaLabel, style: _Type.dissolveZoneName),
                                    const SizedBox(width: 8),
                                    Text(
                                      z.verdictLabel.toUpperCase(),
                                      style: _Type.areasLegend.copyWith(
                                        color: z.suggestsOverfill
                                            ? _needsWorkPink
                                            : Colors.white.withValues(alpha: 0.4),
                                        fontSize: 8,
                                        letterSpacing: 0.8,
                                      ),
                                    ),
                                  ],
                                ),
                                if (z.note.isNotEmpty) ...[
                                  const SizedBox(height: 2),
                                  Text(z.note, style: _Type.dissolveZoneNote),
                                ],
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
        ],
        if (showFiller && showAsym) const SizedBox(height: 12),
        if (showAsym)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: _surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: _cyan.withValues(alpha: 0.28),
                width: 0.5,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.balance_outlined,
                      size: 16,
                      color: _cyan.withValues(alpha: 0.9),
                    ),
                    const SizedBox(width: 8),
                    Text('Symmetry in your preview', style: _Type.areasTitle),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'We note imbalance and gently balance it in the AFTER photo only.',
                  style: _Type.areasSub,
                ),
                if (report.asymmetry.observed.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(
                    'Observed: ${report.asymmetry.observed}',
                    style: _Type.dissolveZoneNote,
                  ),
                ],
                if (report.asymmetry.correctedInPreview.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    'In your AFTER preview: ${report.asymmetry.correctedInPreview}',
                    style: _Type.dissolveZoneNote.copyWith(
                      color: _cyan.withValues(alpha: 0.75),
                    ),
                  ),
                ] else ...[
                  for (final f in report.findings.where((f) => f.mentionsAsymmetry))
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        '${f.areaLabel}: ${f.note}',
                        style: _Type.dissolveZoneNote,
                      ),
                    ),
                ],
                const SizedBox(height: 8),
                Text(
                  'This is a simulation — not surgery. Your bone structure is unchanged.',
                  style: _Type.cardBody.copyWith(fontSize: 10, height: 1.35),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _FaceAnalysisSection extends StatelessWidget {
  const _FaceAnalysisSection({
    required this.report,
    this.skinMetrics = const <_SkinMetricView>[],
  });

  final FaceAnalysisReport report;
  final List<_SkinMetricView> skinMetrics;

  @override
  Widget build(BuildContext context) {
    final items = report.orderedFindings;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _zoneGridBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _zoneGridBorder, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('AI face analysis', style: _Type.areasTitle),
          const SizedBox(height: 4),
          Text(
            'Filler · lips · jaw · cheeks checked first',
            style: _Type.areasSub,
          ),
          const SizedBox(height: 6),
          if (report.overview.isNotEmpty)
            Text(report.overview, style: _Type.areasSub),
          if (items.isNotEmpty) ...[
            const SizedBox(height: 12),
            for (final f in items)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      margin: const EdgeInsets.only(top: 5),
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: f.isConcern
                            ? _needsWorkPink
                            : Colors.white.withValues(alpha: 0.35),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(
                                f.areaLabel,
                                style: _Type.dissolveZoneName,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                f.statusLabel.toUpperCase(),
                                style: _Type.areasLegend.copyWith(
                                  color: f.isConcern
                                      ? _needsWorkPink
                                      : Colors.white.withValues(alpha: 0.4),
                                  fontSize: 8,
                                  letterSpacing: 0.8,
                                ),
                              ),
                            ],
                          ),
                          if (f.note.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Text(f.note, style: _Type.dissolveZoneNote),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ],
          if (skinMetrics.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              height: 0.5,
              color: Colors.white.withValues(alpha: 0.06),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Icon(
                  Icons.document_scanner_outlined,
                  size: 13,
                  color: _indigoLight,
                ),
                const SizedBox(width: 6),
                Text(
                  'Skin metrics',
                  style: _Type.areasTitle.copyWith(fontSize: 13),
                ),
              ],
            ),
            const SizedBox(height: 10),
            for (var i = 0; i < skinMetrics.length; i++) ...[
              if (i > 0) const SizedBox(height: 7),
              _SkinMetricRow(metric: skinMetrics[i]),
            ],
          ],
        ],
      ),
    );
  }
}

class _ZoneScoreGrid extends StatelessWidget {
  const _ZoneScoreGrid({required this.zones});

  final List<ZoneScore> zones;

  @override
  Widget build(BuildContext context) {
    final rows = <List<ZoneScore>>[];
    for (var i = 0; i < zones.length; i += 3) {
      rows.add(zones.sublist(i, (i + 3).clamp(0, zones.length)));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Areas detected by AI', style: _Type.areasTitle),
                  const SizedBox(height: 4),
                  Text(
                    'Red areas need the most improvement',
                    style: _Type.areasSub,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                _AreasLegendItem(dotColor: _needsWorkPink, label: 'Needs work'),
                const SizedBox(height: 6),
                _AreasLegendItem(
                  dotColor: Colors.white.withValues(alpha: 0.28),
                  label: 'Good',
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 12),
        Container(
          decoration: BoxDecoration(
            color: _zoneGridBg,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: _zoneGridBorder, width: 0.5),
          ),
          clipBehavior: Clip.antiAlias,
          child: Table(
            columnWidths: const {
              0: FlexColumnWidth(),
              1: FlexColumnWidth(),
              2: FlexColumnWidth(),
            },
            defaultVerticalAlignment: TableCellVerticalAlignment.middle,
            border: const TableBorder(
              horizontalInside: BorderSide(color: _zoneGridBorder, width: 0.5),
              verticalInside: BorderSide(color: _zoneGridBorder, width: 0.5),
            ),
            children: [
              for (final row in rows)
                TableRow(
                  children: [
                    for (var i = 0; i < 3; i++)
                      if (i < row.length)
                        _ZoneCell(zone: row[i])
                      else
                        const SizedBox(height: 92),
                  ],
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _AreasLegendItem extends StatelessWidget {
  const _AreasLegendItem({required this.dotColor, required this.label});

  final Color dotColor;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(label, style: _Type.areasLegend),
      ],
    );
  }
}

class _ZoneCell extends StatelessWidget {
  const _ZoneCell({required this.zone});

  final ZoneScore zone;

  static const _cellHeight = 92.0;

  @override
  Widget build(BuildContext context) {
    final needsWork = zone.needsWork;
    final barColor = needsWork
        ? _needsWorkPink
        : Colors.white.withValues(alpha: 0.18);

    return SizedBox(
      height: _cellHeight,
      child: ColoredBox(
        color: needsWork ? _needsWorkCellBg : _zoneGridBg,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    zone.name,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: needsWork ? _Type.zoneNameNeeds : _Type.zoneNameGood,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    zone.display,
                    textAlign: TextAlign.center,
                    style: needsWork ? _Type.zoneValNeeds : _Type.zoneValGood,
                  ),
                  const SizedBox(height: 8),
                  Container(
                    width: 22,
                    height: 3,
                    decoration: BoxDecoration(
                      color: barColor,
                      borderRadius: BorderRadius.circular(1.5),
                    ),
                  ),
                ],
              ),
            ),
            if (needsWork)
              const Positioned(
                top: 8,
                right: 8,
                child: SizedBox(
                  width: 5,
                  height: 5,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: _needsWorkPink,
                      shape: BoxShape.circle,
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

class _ProceduresSection extends StatelessWidget {
  const _ProceduresSection({
    required this.selectedIndex,
    required this.onSelect,
  });

  final int selectedIndex;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Container(
              width: 4,
              height: 4,
              decoration: BoxDecoration(
                color: _cyan,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(color: _cyan.withValues(alpha: 0.7), blurRadius: 6),
                ],
              ),
            ),
            const SizedBox(width: 6),
            Text('Suggested procedures', style: _Type.sectionTitle),
            const Spacer(),
            Text('Tap one to find clinics', style: _Type.sectionHint),
          ],
        ),
        const SizedBox(height: 8),
        Column(
          children: [
            for (var i = 0; i < _procedures.length; i++) ...[
              if (i > 0) const SizedBox(height: 4),
              _ProcedureCard(
                proc: _procedures[i],
                selected: i == selectedIndex,
                onTap: () => onSelect(i),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

class _ProcedureCard extends StatelessWidget {
  const _ProcedureCard({
    required this.proc,
    required this.selected,
    required this.onTap,
  });

  final _SuggestedProcedure proc;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          children: [
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: selected
                      ? const Color(0xFF050F18)
                      : const Color(0xFF060D14),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: selected
                        ? _cyan.withValues(alpha: 0.3)
                        : const Color(0xFF0D1A24),
                    width: 0.5,
                  ),
                ),
              ),
            ),
            if (selected)
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                child: Container(
                  width: 2,
                  decoration: const BoxDecoration(
                    borderRadius: BorderRadius.horizontal(
                      left: Radius.circular(2),
                    ),
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [_cyan, _cyanMid],
                    ),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: selected
                          ? _cyan.withValues(alpha: 0.1)
                          : Colors.white.withValues(alpha: 0.03),
                      borderRadius: BorderRadius.circular(9),
                      border: Border.all(
                        color: selected
                            ? _cyan.withValues(alpha: 0.2)
                            : Colors.white.withValues(alpha: 0.07),
                        width: 0.5,
                      ),
                    ),
                    child: Icon(
                      proc.icon,
                      size: 18,
                      color: selected
                          ? _cyan
                          : Colors.white.withValues(alpha: 0.22),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          proc.name,
                          style: selected ? _Type.procNameSel : _Type.procName,
                        ),
                        const SizedBox(height: 2),
                        Text(proc.subtitle, style: _Type.procSub),
                      ],
                    ),
                  ),
                  Text(
                    proc.points,
                    style: selected ? _Type.procPtsSel : _Type.procPts,
                  ),
                  const SizedBox(width: 12),
                  Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: selected
                          ? _cyan.withValues(alpha: 0.15)
                          : Colors.transparent,
                      border: Border.all(
                        color: selected
                            ? _cyan
                            : Colors.white.withValues(alpha: 0.1),
                        width: 1.5,
                      ),
                    ),
                    child: selected
                        ? const Icon(Icons.check, size: 13, color: _cyan)
                        : null,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DissolveRow extends StatefulWidget {
  const _DissolveRow({required this.zones});

  final List<DissolveZone> zones;

  @override
  State<_DissolveRow> createState() => _DissolveRowState();
}

class _DissolveRowState extends State<_DissolveRow> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final zones = widget.zones;
    final hasZones = zones.isNotEmpty;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: hasZones ? () => setState(() => _expanded = !_expanded) : null,
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: const Color(0xFF030B0D),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: _expanded
                        ? _cyan.withValues(alpha: 0.22)
                        : _cyan.withValues(alpha: 0.1),
                    width: 0.5,
                  ),
                ),
              ),
            ),
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              child: Container(
                width: 2,
                decoration: const BoxDecoration(
                  borderRadius: BorderRadius.horizontal(
                    left: Radius.circular(2),
                  ),
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [_cyan, Color(0xFF06B6D4)],
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: _cyan.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(9),
                          border: Border.all(
                            color: _cyan.withValues(alpha: 0.18),
                            width: 0.5,
                          ),
                        ),
                        child: const Icon(
                          Icons.unfold_less,
                          size: 18,
                          color: _cyan,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    'Dissolve assessment',
                                    style: _Type.cardTitle,
                                  ),
                                ),
                                if (hasZones)
                                  AnimatedRotation(
                                    turns: _expanded ? 0.5 : 0,
                                    duration: const Duration(milliseconds: 200),
                                    curve: Curves.easeOut,
                                    child: Icon(
                                      Icons.keyboard_arrow_down,
                                      size: 22,
                                      color: _cyan.withValues(alpha: 0.55),
                                    ),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 2),
                            Text(
                              hasZones
                                  ? 'AI flagged ${zones.length} zone${zones.length == 1 ? '' : 's'} that may have excess filler — consider dissolving before new volume.'
                                  : 'No excess filler flagged on lips, cheeks, or jaw — safe to plan new treatments.',
                              style: _Type.cardBody,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  AnimatedSize(
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOut,
                    alignment: Alignment.topCenter,
                    child: _expanded && hasZones
                        ? Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Container(
                                  height: 0.5,
                                  color: _cyan.withValues(alpha: 0.12),
                                ),
                                const SizedBox(height: 10),
                                Text(
                                  'ZONES TO DISSOLVE',
                                  style: _Type.dissolveSectionLbl,
                                ),
                                const SizedBox(height: 8),
                                for (var i = 0; i < zones.length; i++) ...[
                                  if (i > 0) const SizedBox(height: 6),
                                  _DissolveZoneTile(zone: zones[i]),
                                ],
                                const SizedBox(height: 10),
                                Text(
                                  'Dissolving first can improve symmetry and help your glow-up score. Consult a licensed provider before treatment.',
                                  style: _Type.cardBody.copyWith(
                                    fontSize: 10,
                                    height: 1.4,
                                  ),
                                ),
                              ],
                            ),
                          )
                        : const SizedBox(width: double.infinity),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DissolveZoneTile extends StatelessWidget {
  const _DissolveZoneTile({required this.zone});

  final DissolveZone zone;

  @override
  Widget build(BuildContext context) {
    final isHigh = zone.confidence == DissolveConfidence.high;
    final badgeColor = isHigh
        ? const Color(0xFFFB7185)
        : const Color(0xFFFBBF24);
    final badgeLabel = isHigh ? 'High' : 'Medium';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _cyan.withValues(alpha: 0.12), width: 0.5),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 6,
            height: 6,
            margin: const EdgeInsets.only(top: 5),
            decoration: BoxDecoration(
              color: badgeColor.withValues(alpha: 0.85),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(zone.zone, style: _Type.dissolveZoneName),
                const SizedBox(height: 3),
                Text(zone.note, style: _Type.dissolveZoneNote),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: badgeColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: badgeColor.withValues(alpha: 0.28),
                width: 0.5,
              ),
            ),
            child: Text(
              badgeLabel,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: badgeColor.withValues(alpha: 0.9),
                height: 1.1,
              ),
            ),
          ),
        ],
      ),
    );
  }
}


class _SkinMetricRow extends StatelessWidget {
  const _SkinMetricRow({required this.metric});

  final _SkinMetricView metric;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(width: 64, child: Text(metric.name, style: _Type.metricName)),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(1),
            child: SizedBox(
              height: 1.5,
              child: Stack(
                children: [
                  ColoredBox(color: Colors.white.withValues(alpha: 0.05)),
                  FractionallySizedBox(
                    widthFactor: metric.fill.clamp(0.0, 1.0),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(colors: metric.gradient),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 24,
          child: Text(
            metric.value,
            textAlign: TextAlign.right,
            style: _Type.metricVal,
          ),
        ),
      ],
    );
  }
}

class _StickyCta extends StatelessWidget {
  const _StickyCta({required this.procedureName, required this.onFindClinics});

  final String procedureName;
  final VoidCallback onFindClinics;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(
        _pageH,
        10,
        _pageH,
        10 + MediaQuery.paddingOf(context).bottom,
      ),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, _bg, _bg],
          stops: const [0, 0.3, 1],
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: _cyan.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: _cyan.withValues(alpha: 0.2),
                width: 0.5,
              ),
            ),
            child: Row(
              children: [
                Text('Selected procedure', style: _Type.ctaLabel),
                const Spacer(),
                Text(procedureName, style: _Type.ctaProc),
              ],
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [_cyan, _indigo],
                ),
                boxShadow: [
                  BoxShadow(
                    color: _cyan.withValues(alpha: 0.2),
                    blurRadius: 24,
                  ),
                ],
              ),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: onFindClinics,
                  borderRadius: BorderRadius.circular(12),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(
                          Icons.place_outlined,
                          size: 18,
                          color: Colors.white,
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            'Find clinics for $procedureName',
                            style: _Type.ctaBtn,
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
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

bool _photoExists(String? path) {
  final p = (path ?? '').trim();
  if (p.isEmpty) return false;
  return isRemoteUrl(p) || File(p).existsSync();
}

ImageProvider _imageProvider(String path) {
  if (isRemoteUrl(path)) return NetworkImage(path);
  return FileImage(File(path));
}
