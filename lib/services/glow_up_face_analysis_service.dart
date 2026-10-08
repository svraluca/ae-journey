import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

import 'face_landmark_service.dart';
import 'glow_up/clinic_prompt_builder.dart';
import 'openai_image_edit_service.dart';

/// One aesthetic observation from vision analysis.
@immutable
class FaceFinding {
  const FaceFinding({
    required this.area,
    required this.status,
    required this.note,
    this.severity = 'none',
    this.recommendEdit = false,
  });

  factory FaceFinding.fromJson(Map<String, dynamic> json) {
    return FaceFinding(
      area: (json['area'] as String? ?? '').trim(),
      status: (json['status'] as String? ?? 'ok').trim(),
      note: (json['note'] as String? ?? '').trim(),
      severity: (json['severity'] as String? ?? 'none').trim(),
      recommendEdit: json['recommend_edit'] == true,
    );
  }

  final String area;
  final String status;
  final String note;
  final String severity;
  final bool recommendEdit;

  String get areaLabel {
    switch (area.toLowerCase()) {
      case 'filler':
        return 'Filler balance';
      case 'cheeks':
        return 'Cheeks';
      case 'nose':
        return 'Nose';
      case 'lips':
        return 'Lips';
      case 'brows':
        return 'Brows';
      case 'eyes':
        return 'Eyes';
      case 'skin':
        return 'Skin';
      case 'wrinkles':
        return 'Wrinkles';
      case 'jaw':
        return 'Jawline';
      default:
        return area.isEmpty ? 'General' : area;
    }
  }

  /// Note explicitly cites injected filler or unmistakable filler morphology.
  bool get hasFillerEvidence {
    final n = note.toLowerCase();
    return n.contains('filler') ||
        n.contains('injected') ||
        n.contains('hyaluronic') ||
        n.contains('duck lip') ||
        n.contains('duck-lip') ||
        n.contains('ballooned lip') ||
        n.contains('pillow face') ||
        n.contains('chipmunk') ||
        n.contains('malar over') ||
        n.contains('masseter filler') ||
        n.contains('migrated filler');
  }

  /// True only when status AND note support real over-filler — not aging/sagging.
  bool get isConfirmedFillerOverfill {
    final area = this.area.toLowerCase();
    if (!{'lips', 'jaw', 'cheeks', 'filler'}.contains(area)) return false;
    if (showsNaturalAging) return false;
    if (!hasFillerEvidence) return false;
    final s = status.toLowerCase();
    return s.contains('over') ||
        s.contains('excess') ||
        (s.contains('wide') && area == 'jaw') ||
        (s.contains('large') && area != 'jaw');
  }

  /// Jowls, laxity, thin lips, folds — not injectable overfill.
  bool get showsNaturalAging {
    final s = status.toLowerCase();
    final n = note.toLowerCase();
    if (s.contains('sag') ||
        s.contains('lax') ||
        s.contains('jowl') ||
        s.contains('thin') ||
        s.contains('hollow') ||
        s.contains('volume_loss') ||
        s.contains('deficient') ||
        s.contains('natural_aging') ||
        s.contains('aging')) {
      return true;
    }
    const agingPhrases = [
      'sag',
      'jowl',
      'laxity',
      'lax ',
      'marionette',
      'nasolabial',
      'skin fold',
      'loose skin',
      'gravit',
      'volume loss',
      'hollow cheek',
      'thin lip',
      'deflated',
      'wrinkled lip',
      'aged appearance',
      'signs of aging',
      'natural aging',
      'elderly',
      'older patient',
    ];
    return agingPhrases.any(n.contains);
  }

  bool get isConcern {
    final s = status.toLowerCase();
    if (recommendEdit && !showsNaturalAging) return true;
    if ({'ok', 'good', 'balanced', 'none', 'natural'}.contains(s)) {
      return false;
    }
    if (showsNaturalAging) {
      return s.contains('visible') ||
          s.contains('needs') ||
          s.contains('severe') ||
          s.contains('moderate');
    }
    if (isConfirmedFillerOverfill) return true;
    return s.contains('visible') ||
        s.contains('needs') ||
        s.contains('deficient') ||
        s.contains('asym') && hasFillerEvidence;
  }

  bool get mentionsAsymmetry {
    final s = status.toLowerCase();
    final n = note.toLowerCase();
    return s.contains('asym') ||
        n.contains('asymmetr') ||
        n.contains('uneven') && (n.contains('brow') || n.contains('eye') || n.contains('lip') || n.contains('jaw') || n.contains('cheek'));
  }

  /// Nose finding warrants a rhinoplasty preview (not "ok" / natural).
  bool get noseNeedsRhinoplasty {
    if (area.toLowerCase() != 'nose') return false;
    final s = status.toLowerCase();
    if ({'ok', 'good', 'balanced', 'natural', 'none'}.contains(s)) {
      return false;
    }
    final n = note.toLowerCase();
    return recommendEdit ||
        s.contains('needs') ||
        s.contains('refine') ||
        s.contains('bump') ||
        s.contains('crooked') ||
        s.contains('deviat') ||
        s.contains('prominent') ||
        s.contains('wide') ||
        s.contains('asym') ||
        s.contains('visible') ||
        n.contains('rhinoplast') ||
        n.contains('bridge') && n.contains('bump') ||
        n.contains('tip') && (n.contains('droopy') || n.contains('bulbous') || n.contains('wide'));
  }

  String get statusLabel {
    final s = status.toLowerCase();
    if (isConfirmedFillerOverfill) {
      return s.contains('asym') ? 'Overfilled · asymmetric' : 'Overfilled';
    }
    if (mentionsAsymmetry && !isConfirmedFillerOverfill) {
      return 'Asymmetric';
    }
    if (s.contains('sag') || s.contains('lax') || s.contains('jowl')) {
      return 'Sagging';
    }
    if (s.contains('thin') || s.contains('hollow') || s.contains('volume_loss')) {
      return 'Volume loss';
    }
    if (s.contains('excess') && showsNaturalAging) return 'Sagging';
    if (s == 'ok' || s == 'good' || s == 'balanced' || s == 'natural') {
      return 'Looks natural';
    }
    if (s.contains('visible')) return 'Visible';
    if (s.contains('needs')) return 'Needs care';
    return status.isEmpty ? '—' : status;
  }
}

/// One aesthetic procedure simulated in the glow-up preview.
@immutable
class GlowUpProcedure {
  const GlowUpProcedure({
    required this.name,
    required this.zone,
    required this.change,
  });

  factory GlowUpProcedure.fromJson(Map<String, dynamic> json) {
    return GlowUpProcedure(
      name: (json['name'] as String? ?? '').trim(),
      zone: (json['zone'] as String? ?? '').trim(),
      change: (json['change'] as String? ?? '').trim(),
    );
  }

  final String name;
  final String zone;
  final String change;
}

/// Vision assessment of left–right balance (disclosed in the UI + preview).
@immutable
class FaceAsymmetryAssessment {
  const FaceAsymmetryAssessment({
    this.severity = 'none',
    this.observed = '',
    this.correctedInPreview = '',
  });

  factory FaceAsymmetryAssessment.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const FaceAsymmetryAssessment();
    return FaceAsymmetryAssessment(
      severity: (json['severity'] as String? ?? 'none').trim().toLowerCase(),
      observed: (json['observed'] as String? ?? '').trim(),
      correctedInPreview: (json['corrected_in_preview'] as String? ?? '').trim(),
    );
  }

  final String severity;
  final String observed;
  final String correctedInPreview;

  bool get hasMeaningfulAsymmetry =>
      severity != 'none' &&
      severity != 'ok' &&
      (observed.isNotEmpty || correctedInPreview.isNotEmpty);
}

/// Per-zone filler verdict (lips, cheeks, jaw, overall balance).
@immutable
class FillerZoneVerdict {
  const FillerZoneVerdict({
    required this.area,
    required this.verdict,
    required this.note,
  });

  factory FillerZoneVerdict.fromJson(Map<String, dynamic> json) {
    return FillerZoneVerdict(
      area: (json['area'] as String? ?? '').trim(),
      verdict: (json['verdict'] as String? ?? 'natural').trim(),
      note: (json['note'] as String? ?? '').trim(),
    );
  }

  final String area;
  final String verdict;
  final String note;

  String get areaLabel {
    switch (area.toLowerCase()) {
      case 'lips':
        return 'Lips';
      case 'cheeks':
        return 'Cheeks';
      case 'jaw':
        return 'Jawline';
      case 'filler':
        return 'Overall filler';
      default:
        return area.isEmpty ? 'Zone' : area;
    }
  }

  String get verdictLabel {
    final v = verdict.toLowerCase();
    if (v.contains('overfill') || v == 'overfilled') return 'Possible overfill';
    if (v.contains('asym')) return 'Asymmetric volume';
    if (v.contains('thin') || v.contains('aging')) return 'Thin / aging';
    if (v.contains('natural') || v == 'ok') return 'Looks natural';
    return verdict.isEmpty ? '—' : verdict;
  }

  bool get suggestsOverfill {
    final v = verdict.toLowerCase();
    return v.contains('overfill') || v.contains('excess') || v.contains('asym');
  }
}

@immutable
class FillerAssessment {
  const FillerAssessment({
    this.summary = '',
    this.zones = const [],
  });

  factory FillerAssessment.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const FillerAssessment();
    final raw = json['zones'];
    final zones = raw is List
        ? [
            for (final item in raw)
              if (item is Map<String, dynamic>) FillerZoneVerdict.fromJson(item),
          ]
        : const <FillerZoneVerdict>[];
    return FillerAssessment(
      summary: (json['summary'] as String? ?? '').trim(),
      zones: zones,
    );
  }

  final String summary;
  final List<FillerZoneVerdict> zones;

  List<FillerZoneVerdict> get overfillZones =>
      zones.where((z) => z.suggestsOverfill).toList();

  FillerZoneVerdict? zone(String area) {
    final key = area.toLowerCase();
    for (final z in zones) {
      if (z.area.toLowerCase() == key) return z;
    }
    return null;
  }
}

/// Structured face report used for the glow UI and edit prompt.
@immutable
class FaceAnalysisReport {
  const FaceAnalysisReport({
    required this.overview,
    required this.overallScore,
    required this.findings,
    this.glowUpExplanation,
    this.proceduresSimulated = const [],
    this.imageEditPrompt,
    this.asymmetryAssessment,
    this.fillerAssessment,
  });

  factory FaceAnalysisReport.fromJson(Map<String, dynamic> json) {
    final raw = json['findings'];
    final list = raw is List
        ? [
            for (final item in raw)
              if (item is Map<String, dynamic>)
                FaceFinding.fromJson(item),
          ]
        : const <FaceFinding>[];
    final preview = _parseGlowUpPreview(json);
    final asymmetry = FaceAsymmetryAssessment.fromJson(
      json['asymmetry_assessment'] is Map<String, dynamic>
          ? json['asymmetry_assessment'] as Map<String, dynamic>
          : null,
    );
    final filler = FillerAssessment.fromJson(
      json['filler_assessment'] is Map<String, dynamic>
          ? json['filler_assessment'] as Map<String, dynamic>
          : null,
    );
    return sanitizeMisclassifiedFiller(
      FaceAnalysisReport(
        overview: (json['overview'] as String? ?? '').trim(),
        overallScore:
            (json['overall_score'] as num?)?.round().clamp(0, 100) ?? 70,
        findings: list,
        glowUpExplanation: preview.$1,
        proceduresSimulated: preview.$2,
        imageEditPrompt: preview.$3,
        asymmetryAssessment: asymmetry,
        fillerAssessment: filler,
      ),
    );
  }

  static (String?, List<GlowUpProcedure>, String?) _parseGlowUpPreview(
    Map<String, dynamic> json,
  ) {
    final g = json['glow_up_preview'];
    if (g is! Map<String, dynamic>) return (null, const [], null);
    final rawProcs = g['procedures'];
    final procedures = rawProcs is List
        ? [
            for (final item in rawProcs)
              if (item is Map<String, dynamic>)
                GlowUpProcedure.fromJson(item),
          ]
        : const <GlowUpProcedure>[];
    return (
      (g['explanation'] as String? ?? '').trim().isEmpty
          ? null
          : (g['explanation'] as String).trim(),
      procedures,
      (g['image_edit_prompt'] as String? ?? '').trim().isEmpty
          ? null
          : (g['image_edit_prompt'] as String).trim(),
    );
  }

  /// Corrects common vision mistakes: aging/jowls labeled as lip or jaw filler.
  static FaceAnalysisReport sanitizeMisclassifiedFiller(FaceAnalysisReport raw) {
    final fixed = [
      for (final f in raw.findings) _sanitizeFinding(f, raw.findings),
    ];
    final overview = _sanitizeOverview(raw.overview, fixed);
    final score = _sanitizeScore(raw.overallScore, fixed);
    return _enrichClinicalPlan(
      FaceAnalysisReport(
        overview: overview,
        overallScore: score,
        findings: fixed,
        glowUpExplanation: raw.glowUpExplanation,
        proceduresSimulated: raw.proceduresSimulated,
        imageEditPrompt: raw.imageEditPrompt,
        asymmetryAssessment: raw.asymmetryAssessment,
        fillerAssessment: raw.fillerAssessment,
      ),
    );
  }

  /// Ensures rhinoplasty and other clinic procedures appear when findings require them.
  static FaceAnalysisReport _enrichClinicalPlan(FaceAnalysisReport raw) {
    final procs = List<GlowUpProcedure>.from(raw.proceduresSimulated);
    final noseMatches =
        raw.findings.where((f) => f.area.toLowerCase() == 'nose').toList();
    final nose = noseMatches.isEmpty ? null : noseMatches.first;

    if (nose != null &&
        nose.noseNeedsRhinoplasty &&
        !procs.any((p) => p.name.toLowerCase().contains('rhino'))) {
      procs.insert(
        0,
        const GlowUpProcedure(
          name: 'Rhinoplasty',
          zone: 'nose',
          change:
              'Subtle surgical rhinoplasty preview — refined bridge and tip, '
              'balanced nostrils, natural proportions, same person',
        ),
      );
    }

    return FaceAnalysisReport(
      overview: raw.overview,
      overallScore: raw.overallScore,
      findings: raw.findings,
      glowUpExplanation: raw.glowUpExplanation,
      proceduresSimulated: procs,
      imageEditPrompt: raw.imageEditPrompt,
      asymmetryAssessment: raw.asymmetryAssessment,
      fillerAssessment: raw.fillerAssessment,
    );
  }

  static FaceFinding _sanitizeFinding(
    FaceFinding f,
    List<FaceFinding> all,
  ) {
    final area = f.area.toLowerCase();
    if (!{'lips', 'jaw', 'cheeks', 'filler'}.contains(area)) return f;

    final s = f.status.toLowerCase();
    final falselyOverfilled = (s.contains('over') ||
            s.contains('excess') ||
            s.contains('wide') ||
            s.contains('large')) &&
        !f.isConfirmedFillerOverfill;

    if (!falselyOverfilled) return f;

    final agingHeavy = _reportShowsAging(all, f);
    if (!agingHeavy && f.hasFillerEvidence) return f;

    return FaceFinding(
      area: f.area,
      status: switch (area) {
        'lips' => 'thin',
        'cheeks' => 'volume_loss',
        'jaw' => 'sagging',
        _ => 'natural',
      },
      severity: f.severity == 'none' ? 'mild' : f.severity,
      note: switch (area) {
        'lips' =>
          'Lips look thin or lined from age — not overfilled. Hydration or subtle enhancement may help if desired.',
        'cheeks' =>
          'Cheek volume loss and soft tissue descent — typical aging, not cheek filler excess.',
        'jaw' =>
          'Jowls and lower-face laxity from skin sagging — not a wide jaw from filler.',
        _ =>
          'No clear sign of excess filler — features read as natural aging rather than over-treatment.',
      },
      recommendEdit: area == 'wrinkles' || area == 'eyes' || area == 'skin',
    );
  }

  static bool _reportShowsAging(List<FaceFinding> all, FaceFinding trigger) {
    if (trigger.showsNaturalAging) return true;
    for (final f in all) {
      final a = f.area.toLowerCase();
      if (a == 'wrinkles' || a == 'skin' || a == 'eyes') {
        final s = f.status.toLowerCase();
        if (f.isConcern ||
            s.contains('visible') ||
            s.contains('severe') ||
            s.contains('moderate')) {
          return true;
        }
      }
    }
    final text = all.map((e) => '${e.area} ${e.note}').join(' ').toLowerCase();
    return text.contains('wrinkle') ||
        text.contains('sag') ||
        text.contains('jowl') ||
        text.contains('marionette') ||
        text.contains('nasolabial');
  }

  static String _sanitizeOverview(String overview, List<FaceFinding> findings) {
    final lower = overview.toLowerCase();
    final anyRealOverfill =
        findings.any((f) => f.isConfirmedFillerOverfill);
    if (anyRealOverfill) return overview;

    if (lower.contains('overfill') ||
        lower.contains('excess filler') ||
        lower.contains('prior filler') && !lower.contains('no sign')) {
      final aging = findings.any((f) => f.showsNaturalAging);
      if (aging ||
          (findings.isNotEmpty &&
              _reportShowsAging(findings, findings.first))) {
        return 'Natural aging is the main story here: jowls, smile lines, '
            'and skin laxity — not excess cosmetic filler. Focus on skin quality, '
            'lines, and optional lift or volume where hollow — not dissolving filler.';
      }
    }
    return overview;
  }

  static int _sanitizeScore(int score, List<FaceFinding> findings) {
    if (findings.any((f) => f.isConfirmedFillerOverfill)) return score;
    if (findings.any(
      (f) =>
          {'lips', 'jaw', 'cheeks'}.contains(f.area.toLowerCase()) &&
          f.showsNaturalAging,
    )) {
      return score.clamp(62, 88);
    }
    return score;
  }

  factory FaceAnalysisReport.fallback({int seed = 0}) {
    final s = seed == 0 ? 1 : seed;
    return FaceAnalysisReport(
      overview:
          'OpenAI analysis is temporarily unavailable — using a standard anti-aging glow plan for your preview.',
      overallScore: 65 + (s % 12),
      findings: const [
        FaceFinding(
          area: 'filler',
          status: 'natural',
          severity: 'none',
          note: 'No obvious excess filler — features read as natural for age.',
          recommendEdit: false,
        ),
        FaceFinding(
          area: 'lips',
          status: 'thin',
          severity: 'mild',
          note: 'Lips may benefit from subtle hydration and volume in preview.',
          recommendEdit: true,
        ),
        FaceFinding(
          area: 'cheeks',
          status: 'volume_loss',
          severity: 'mild',
          note: 'Mild midface softness from age — not cheek filler excess.',
          recommendEdit: false,
        ),
        FaceFinding(
          area: 'jaw',
          status: 'sagging',
          severity: 'mild',
          note: 'Lower-face softness from laxity — not jaw filler width.',
          recommendEdit: false,
        ),
        FaceFinding(
          area: 'skin',
          status: 'needs_work',
          severity: 'mild',
          note: 'Uneven tone or texture may benefit from skincare.',
          recommendEdit: true,
        ),
        FaceFinding(
          area: 'wrinkles',
          status: 'visible',
          severity: 'moderate',
          note: 'Lines on forehead and around the eyes.',
          recommendEdit: true,
        ),
        FaceFinding(
          area: 'eyes',
          status: 'visible',
          severity: 'moderate',
          note: 'Dark circles or under-eye hollowness.',
          recommendEdit: true,
        ),
        FaceFinding(
          area: 'nose',
          status: 'asymmetric',
          severity: 'moderate',
          note:
              'Nasal tip deviates slightly from midline — center tip in rhinoplasty preview.',
          recommendEdit: true,
        ),
      ],
      asymmetryAssessment: const FaceAsymmetryAssessment(
        severity: 'mild',
        observed:
            'Nasal tip and lower nose slightly off the facial midline.',
        correctedInPreview:
            'Center nasal tip and refine bridge for left–right balance',
      ),
      fillerAssessment: const FillerAssessment(
        summary:
            'Lips, cheeks, and jawline read as natural aging rather than excess filler.',
        zones: [
          FillerZoneVerdict(
            area: 'lips',
            verdict: 'natural',
            note: 'Proportionate lip volume.',
          ),
          FillerZoneVerdict(
            area: 'cheeks',
            verdict: 'volume_loss',
            note: 'Hollowing from age, not pillow-face filler.',
          ),
          FillerZoneVerdict(
            area: 'jaw',
            verdict: 'sagging',
            note: 'Jowl laxity — not masseter overfill.',
          ),
          FillerZoneVerdict(
            area: 'filler',
            verdict: 'natural',
            note: 'No clear migrated or excess injectable volume.',
          ),
        ],
      ),
      glowUpExplanation:
          'This preview simulates a typical anti-aging package: brighter under-eyes, '
          'softer forehead and smile lines, subtle cheek support, and clearer skin — '
          'matched to what clinics often recommend for your age range.',
      proceduresSimulated: const [
        GlowUpProcedure(
          name: 'Lip filler',
          zone: 'lips',
          change: 'Subtle volume only — keep natural neutral lip color',
        ),
        GlowUpProcedure(
          name: 'Under-eye / tear-trough',
          zone: 'eyes',
          change: 'Reduce dark circles and eye bags',
        ),
        GlowUpProcedure(
          name: 'Botox — forehead & crow\'s feet',
          zone: 'wrinkles',
          change: 'Soften forehead lines and crow\'s feet',
        ),
        GlowUpProcedure(
          name: 'Cheek filler',
          zone: 'cheeks',
          change: 'Subtle midface volume and lift',
        ),
        GlowUpProcedure(
          name: 'Skin quality',
          zone: 'skin',
          change: 'Even tone and refined texture',
        ),
        GlowUpProcedure(
          name: 'Rhinoplasty preview',
          zone: 'nose',
          change: 'Straighten bridge and center nasal tip on midline',
        ),
      ],
    );
  }

  final String overview;
  final int overallScore;
  final List<FaceFinding> findings;

  /// What the AFTER preview simulates — written by vision AI for the patient.
  final String? glowUpExplanation;

  /// Clinic-style procedures applied in the preview (Botox, filler, etc.).
  final List<GlowUpProcedure> proceduresSimulated;

  /// Full prompt for gpt-image-1 / FLUX generated from the face exam.
  final String? imageEditPrompt;

  final FaceAsymmetryAssessment? asymmetryAssessment;
  final FillerAssessment? fillerAssessment;

  FaceAsymmetryAssessment get asymmetry =>
      asymmetryAssessment ?? const FaceAsymmetryAssessment();

  FillerAssessment get filler =>
      fillerAssessment ?? const FillerAssessment();

  bool get hasFillerAssessment =>
      (filler.summary.isNotEmpty) || filler.zones.isNotEmpty;

  bool get hasAsymmetryAssessment => asymmetry.hasMeaningfulAsymmetry;

  bool get hasFillerOverfillSignal =>
      findings.any((f) => f.isConfirmedFillerOverfill) ||
      filler.overfillZones.isNotEmpty;

  bool get hasGlowUpPlan =>
      (glowUpExplanation ?? '').isNotEmpty ||
      proceduresSimulated.isNotEmpty ||
      (imageEditPrompt ?? '').length > 80;

  /// Stage 3 should produce a visible before/after (not identical slider).
  bool get needsVisiblePreview =>
      hasGlowUpPlan ||
      plansUnderEyeTreatment ||
      plansNoseRhinoplasty ||
      plansSmileLineTreatment ||
      plansLipEnhancement ||
      findings.any((f) => f.recommendEdit && f.area.toLowerCase() != 'brows');

  /// Report or plan calls for lip filler / hydration in the AFTER preview.
  /// Lip or mouth left–right imbalance should show in the AFTER preview.
  bool get plansLipSymmetry {
    final asymText =
        '${asymmetry.observed} ${asymmetry.correctedInPreview}'.toLowerCase();
    if (asymText.contains('lip') ||
        asymText.contains('mouth') ||
        asymText.contains('vermillion') ||
        asymText.contains('cupid')) {
      return true;
    }
    if (findings.any((f) {
      if (f.area.toLowerCase() != 'lips') return false;
      final t = '${f.status} ${f.note}'.toLowerCase();
      return f.mentionsAsymmetry ||
          t.contains('asym') ||
          t.contains('uneven') ||
          t.contains('lopsided');
    })) {
      return true;
    }
    final lipVerdict = filler.zone('lips')?.verdict.toLowerCase() ?? '';
    return lipVerdict.contains('asymmetric');
  }

  bool get plansLipEnhancement {
    if (proceduresSimulated.any((p) {
      final z = p.zone.toLowerCase();
      final n = p.name.toLowerCase();
      final t = '${p.name} ${p.change}'.toLowerCase();
      return z == 'lips' ||
          n.contains('lip') ||
          t.contains('russian') ||
          t.contains('vermillion');
    })) {
      return true;
    }
    if (findings.any(
      (f) =>
          f.area.toLowerCase() == 'lips' &&
          f.recommendEdit &&
          !f.isConfirmedFillerOverfill,
    )) {
      return true;
    }
    final verdict = filler.zone('lips')?.verdict.toLowerCase() ?? '';
    return verdict.contains('thin') || verdict.contains('volume');
  }

  /// Tear-trough / under-eye filler or brightening in the preview.
  bool get plansUnderEyeTreatment {
    if (proceduresSimulated.any((p) {
      final t = '${p.name} ${p.zone} ${p.change}'.toLowerCase();
      return t.contains('tear') ||
          t.contains('under-eye') ||
          t.contains('under eye') ||
          t.contains('polynucleotide') ||
          (p.zone.toLowerCase() == 'eyes' &&
              (t.contains('hollow') || t.contains('fuller') || t.contains('filler')));
    })) {
      return true;
    }
    return findings.any(
      (f) =>
          f.area.toLowerCase() == 'eyes' &&
          f.recommendEdit &&
          !f.isConfirmedFillerOverfill,
    );
  }

  /// Nose needs work — include rhinoplasty in preview and clinic CTA.
  bool get plansNoseRhinoplasty {
    if (proceduresSimulated.any((p) {
      final n = p.name.toLowerCase();
      final z = p.zone.toLowerCase();
      return n.contains('rhino') || (z == 'nose' && n.contains('nose'));
    })) {
      return true;
    }
    return findings.any((f) => f.noseNeedsRhinoplasty);
  }

  /// Report calls for visible smile-line / lower-face line softening.
  bool get plansSmileLineTreatment {
    if (proceduresSimulated.any((p) {
      final t = '${p.name} ${p.change}'.toLowerCase();
      return t.contains('smile') ||
          t.contains('nasolabial') ||
          t.contains('marionette') ||
          t.contains('fold') ||
          t.contains('line');
    })) {
      return true;
    }
    return findings.any(
          (f) => f.area.toLowerCase() == 'wrinkles' && f.recommendEdit,
        ) ||
        _isAgingFace;
  }

  List<FaceFinding> get concerns =>
      findings.where((f) => f.isConcern && f.note.isNotEmpty).toList();

  /// All areas in stable order for the report UI (not only "concerns").
  /// Image editors must not touch brows (report may still mention brow asymmetry in text).
  static const preserveBrowsInImageEdit =
      'EYEBROWS (critical): leave eyebrows completely untouched — identical thickness, '
      'density, arch, position, and natural hair color as the input. '
      'Do NOT thin, pluck, lift, reshape, fill, tint, bleach, wax, or redraw brows. '
      'No brow makeup, no microblading, no laminated brow look.';

  static const preserveEyesNoMakeup =
      'EYES (critical): copy the input exactly — ZERO makeup. No eyeshadow, eyeliner, mascara, '
      'lash tint, smokey lid, or darkened eyelids. Same natural lid skin tone, lashes, and iris. '
      'Keep existing catchlights — do NOT paint new white or glowing highlights in the pupil. '
      'No new moles, dark spots, or stains beside the outer eye corners. '
      'Under-eye treatment ONLY in the tear trough below the lash line — never on lids or lashes.';

  static const preserveCheeksNoConcealer =
      'CHEEKS / SMILE LINES: soften creases in place — do NOT add bright oval patches, '
      'concealer blobs, or highlights below the smile lines.';

  static const preserveLipsNaturalColor =
      'LIPS: keep the exact natural lip color from the before photo — neutral nude/mauve tone. '
      'No red, pink, coral, stain, gloss, or lipstick. Volume/shape change only if listed below.';

  static const lipFillerPreview =
      'LIP VOLUME (required): +15–20% fuller vermillion and cupid\'s bow — same neutral lip COLOR '
      'as input, no new hue or saturation. No duck lip.';

  static const liftInImageEdit =
      'If lift is needed: subtle cheek/midface/jaw support only (max visible lift) — '
      'never by changing brows, eyes, or bone structure.';

  static const softCaptureImageEdit =
      'Soft-focus input — do NOT sharpen or add crisp micro-detail. Visible clinical preview: '
      'neutral lip volume only, brighter under-eyes (no lid makeup), softer smile lines, smoother skin.';

  List<GlowUpProcedure> get imageEditProcedures => proceduresSimulated
      .where((p) {
        final z = p.zone.toLowerCase();
        final n = p.name.toLowerCase();
        return z != 'brows' && !n.contains('brow');
      })
      .toList();

  List<FaceFinding> get orderedFindings {
    const order = [
      'filler',
      'lips',
      'jaw',
      'cheeks',
      'nose',
      'brows',
      'eyes',
      'skin',
      'wrinkles',
    ];
    final byArea = {
      for (final f in findings) f.area.toLowerCase(): f,
    };
    return [
      for (final key in order)
        if (byArea.containsKey(key)) byArea[key]!,
    ];
  }

  /// Prompt for stage 3 — prefers GPT's full-face aesthetic plan.
  String toGlowUpImagePrompt() {
    final custom = imageEditPrompt?.trim() ?? '';
    if (custom.length > 80) {
      return '''
Subtle clinical retouch on pure black studio (#000000). Same person, pose, framing, hair.

$custom

Keep pores and skin texture. Gentle ~15–20% correction only — still looks like the same real photo.
Do not change eye shape or add fox-eye. $preserveBrowsInImageEdit
$liftInImageEdit
No cartoon, filter, or contrast boost.
'''.trim();
    }
    if (imageEditProcedures.isNotEmpty) {
      final buf = StringBuffer(
        'Treatment preview on black studio. Same person and pose.\n\n'
        'Simulate these visibly (photorealistic, patient must see the change):\n',
      );
      for (final p in imageEditProcedures) {
        buf.writeln('- ${p.name} (${p.zone}): ${p.change}');
      }
      _appendMandatoryTreatmentGoals(buf);
      buf.writeln(
        '\n$preserveBrowsInImageEdit\n$liftInImageEdit\n'
        'Keep identity, pores, and eye shape. Not plastic or cartoon.',
      );
      return buf.toString().trim();
    }
    return toWrinkleRemovalPrompt();
  }

  /// Meitu image-edit (gummy_pro) — portrait-focused, concise English prompt.
  String toMeituEditPrompt({bool softCapture = false}) {
    final parts = <String>[
      if (softCapture) softCaptureImageEdit,
      'Clinical treatment preview on black studio — photorealistic, not beauty makeup filter.',
      'Same person, pose, and framing.',
      preserveBrowsInImageEdit,
      preserveEyesNoMakeup,
      preserveLipsNaturalColor,
      if (plansLipEnhancement) lipFillerPreview,
      'Clearly soften forehead horizontal wrinkles and crow\'s feet — visibly smoother than before.',
      if (plansUnderEyeTreatment)
        'Reduce tear-trough hollowness below the lash line only — do not tint upper eyelids.',
      if (plansSmileLineTreatment)
        'Soften nasolabial folds and marionette lines — visible but natural.',
      if (plansNoseRhinoplasty)
        'Subtle rhinoplasty preview: refined nose bridge and tip, balanced nostrils, natural.',
      if (plansUnderEyeTreatment || plansSmileLineTreatment || plansNoseRhinoplasty)
        'Patient must see a clear difference vs before — visible treatment preview, not identical.',
      if (!plansUnderEyeTreatment)
        'Lighten under-eye shadows; subtle cheek/midface lift only if sagging — natural.',
      liftInImageEdit,
      'Keep eye shape and identity. Photorealistic skin, not plastic or blurry.',
    ];
    if (imageEditProcedures.isNotEmpty) {
      for (final p in imageEditProcedures.take(4)) {
        parts.add('${p.name}: ${p.change}');
      }
    }
    return parts.join(' ');
  }

  /// Brief prompt for FLUX Kontext — must stay short; never pass the full GPT plan.
  String toReplicateEditPrompt({
    bool softCapture = false,
    FaceGlowMap? landmarks,
  }) {
    final noseFromLandmarks =
        landmarks != null && FaceLandmarkService.noseNeedsCorrection(landmarks);
    final noseHint = landmarks != null
        ? FaceLandmarkService.replicateNoseAsymmetryPrompt(landmarks)
        : '';

    final parts = <String>[
      preserveBrowsInImageEdit,
      preserveEyesNoMakeup,
      preserveLipsNaturalColor,
      'Do NOT thin, pluck, or redraw eyebrows — keep original brow thickness and hair.',
      if (softCapture) softCaptureImageEdit,
      'Same crop on pure black studio. Visible photorealistic treatment PREVIEW (~25% change).',
      preserveCheeksNoConcealer,
      if (plansLipEnhancement || proceduresSimulated.any((p) => p.zone == 'lips'))
        lipFillerPreview,
      if (plansSmileLineTreatment || plansUnderEyeTreatment)
        'MUST deeply soften nasolabial folds — creases visibly shallower and smoother than before, '
        'natural skin (not erased, no bright oval patches on cheeks).',
      if (plansUnderEyeTreatment)
        'MUST brighten under-eyes and reduce dark circles / tear-trough bags — same eye shape.',
      'Smoother, more even skin texture — natural pores, not plastic.',
      if (plansNoseRhinoplasty || noseFromLandmarks)
        'RHINOPLASTY PREVIEW (required): correct visible nasal asymmetry — straight bridge, '
        'tip centered on midline, balanced nostrils, natural proportions.',
      if (noseHint.isNotEmpty) noseHint,
      if (asymmetry.hasMeaningfulAsymmetry && asymmetry.correctedInPreview.isNotEmpty)
        'SYMMETRY: ${asymmetry.correctedInPreview} — preview only, natural.',
      liftInImageEdit,
      'Keep iris and eye shape. No cartoon.',
    ];
    return parts.join(' ');
  }

  void _appendMandatoryTreatmentGoals(StringBuffer buf) {
    if (plansUnderEyeTreatment) {
      buf.writeln(
        '- UNDER-EYES (required): visibly brighter tear troughs and less hollowness — '
        'fuller under-eye area, same eye shape and size (no fox-eye)',
      );
    }
    if (plansNoseRhinoplasty) {
      buf.writeln(
        '- RHINOPLASTY PREVIEW (required): subtle surgical rhinoplasty simulation — '
        'refined bridge, tip, and nostril balance (~15–20%), natural, same person',
      );
    }
    if (plansSmileLineTreatment) {
      buf.writeln(
        '- SMILE LINES (required): clearly soften nasolabial folds and marionette '
        'lines — noticeably smoother than the before photo, still natural (not erased, '
        'not plastic)',
      );
    }
    if (plansLipEnhancement) {
      buf.writeln(
        '- LIPS (required): visible lip filler / hydration preview — fuller upper and '
        'lower lip, softer lip lines, hydrated gloss, +12–18% volume, same lip outline '
        '(no duck lip, no cartoon)',
      );
    }
  }

  /// Mandatory goals appended to the short ChatGPT-style stage-3 prompt.
  String chatGptTreatmentMusts() {
    final parts = <String>[
      'MUST remove under-eye dark circles — brighter tear trough, identical eye shape (no fox-eye, no lid makeup). '
      'No moles, beauty marks, or dark spots beside the outer eye corners.',
      'SMILE LINES (required): softer nasolabial folds — natural, not erased. SKIN: even tone on forehead and cheeks — no brown blotches, spots, mottling, or marks under eyes.',
      preserveCheeksNoConcealer,
    ];
    if (plansNoseRhinoplasty) {
      parts.add(
        'RHINOPLASTY PREVIEW (required — this nose refinement is explicitly allowed): subtly '
        'reshape the nose like a natural surgical preview — straighter, smoother bridge, remove any '
        'dorsal bump, a more defined and slightly lifted tip, and narrower, balanced nostrils/base. '
        'Center any visibly deviated or crooked nose toward the facial midline (~15-25% change). '
        'Keep it realistic and clearly the same person; change ONLY the nose, nothing else on the face.',
      );
    } else {
      parts.add('Nose: keep the nose shape exactly as the input (no rhinoplasty).');
    }
    if (plansLipSymmetry ||
        plansLipEnhancement ||
        hasAsymmetryAssessment ||
        findings.any((f) => f.area.toLowerCase() == 'lips')) {
      parts.add(
        'Balance lip volume, cupid\'s bow, and mouth corner height — natural left–right symmetry, same lip color, no duck lip.',
      );
    }
    if (asymmetry.hasMeaningfulAsymmetry &&
        asymmetry.correctedInPreview.isNotEmpty) {
      parts.add(
        'Gentle jaw/midface symmetry: ${asymmetry.correctedInPreview} — '
        'do not reshape eyes or brows.',
      );
    } else if (findings.any((f) => f.mentionsAsymmetry && f.area != 'brows')) {
      parts.add(
        'Subtle balance of mouth, jawline, and midface asymmetry — max 4%, same person.',
      );
    }
    return parts.join('\n');
  }

  /// Stage-3 OpenAI — deterministic premium clinic prompt.
  String toOpenAiEditPrompt({bool softCapture = false}) =>
      ClinicPromptBuilder.build(
        this,
        intensity: ClinicPromptBuilder.intensityFromEnv(),
        softCapture: softCapture,
      );

  static bool get _symmetryInImageEdit {
    final v = (dotenv.env['GLOW_UP_SYMMETRY_EDIT'] ?? 'false').trim().toLowerCase();
    return v == 'true' || v == '1';
  }

  void _appendFillerAndSymmetryEdits(StringBuffer buf) {
    for (final z in filler.overfillZones) {
      buf.writeln(
        '- ${z.areaLabel}: reduce obvious filler volume toward natural balance '
        '(max subtle, keep identity)',
      );
    }
    for (final f in findings.where((f) => f.isConfirmedFillerOverfill)) {
      if (filler.zone(f.area) != null) continue;
      final line = _editLineFor(f);
      if (line != null) buf.writeln('- $line');
    }

    if (_symmetryInImageEdit) {
      if (asymmetry.hasMeaningfulAsymmetry) {
        final fix = asymmetry.correctedInPreview.isNotEmpty
            ? asymmetry.correctedInPreview
            : 'gentle left–right balance of mouth corners and midface — never brows or eyes';
        buf.writeln(
          '- SYMMETRY (preview only — patient will be told): $fix — '
          'max 4% bilateral balance, no new bone structure or fox-eye',
        );
      } else {
        for (final f in findings.where((f) => f.mentionsAsymmetry)) {
          if (f.isConfirmedFillerOverfill) continue;
          if (f.area.toLowerCase() == 'brows') continue;
          buf.writeln(
            '- Very subtle balance for ${f.areaLabel}: ${f.note} (max 3%, preview only)',
          );
        }
      }
    }
  }

  /// Stronger retry when the first OpenAI pass is too subtle (higher clinic intensity).
  String toOpenAiBoostPrompt() {
    final base = ClinicPromptBuilder.intensityFromEnv();
    return ClinicPromptBuilder.build(
      this,
      intensity: (base + 0.15).clamp(0.0, 0.85),
      softCapture: false,
    );
  }

  /// OpenAI clinic prompt (same builder as primary edit).
  String toClinicalOpenAiPrompt({bool softCapture = false}) =>
      ClinicPromptBuilder.build(
        this,
        intensity: ClinicPromptBuilder.intensityFromEnv(),
        softCapture: softCapture,
      );

  /// Short, imperative prompt for image editors — wrinkles/eyes/lines only.
  String toWrinkleRemovalPrompt() {
    return '''
Same person, pose, crop, black studio unchanged. No zoom out.

Gently lighten under-eye circles; mildly soften forehead, crow's feet, smile lines.
Even mild redness/discoloration. Keep pores and eye shape (no fox-eye).

Subtle only — should look like the same photo, not a filter.
'''.trim();
  }

  /// Builds the image-edit prompt from detected issues only.
  String toEditPrompt() {
    final aging = _isAgingFace;
    final buf = StringBuffer(
      'Professional aesthetic portrait retouch on black studio background. '
      'Keep the same person, pose, and framing.\n\n',
    );
    final edits = <String>[];
    for (final f in findings.where((f) => f.recommendEdit)) {
      final line = _editLineFor(f);
      if (line != null) edits.add(line);
    }
    if (aging) {
      edits.addAll(const [
        'Lighten under-eye dark circles and bags — exact eye shape and size, no fox-eye',
        'Clearly soften nasolabial folds (smile lines), marionette lines, forehead, and crow\'s feet — visible reduction',
        'Reduce redness and mild discoloration — keep visible pores, photorealistic',
      ]);
    }
    if (edits.isEmpty) {
      buf.writeln('''
Apply only:
- Remove under-eye dark circles
- Soften smile lines and fine wrinkles
- Slightly even skin texture and mild discoloration (keep natural pores)
Do not change eye shape, lip size, brows, or face width${plansNoseRhinoplasty ? '' : '; leave nose unchanged'}.
''');
    } else {
      buf.writeln('Apply these retouch edits:');
      for (final e in edits.toSet()) {
        buf.writeln('- $e');
      }
    }
    buf.writeln('''
Do not add changes beyond this list.
Eyes: lighten under-eyes only — do not enlarge, reshape, or change eye color.
Skin: natural texture refinement — not airbrushed or porcelain.
${plansNoseRhinoplasty ? 'Nose: rhinoplasty preview only as listed above — natural proportions.' : 'Nose: leave unchanged unless explicitly listed above.'}
''');
    return buf.toString().trim();
  }

  bool get _isAgingFace {
    if (overview.toLowerCase().contains('aging') ||
        overview.toLowerCase().contains('sagging') ||
        overview.toLowerCase().contains('jowl')) {
      return true;
    }
    return findings.any((f) => f.showsNaturalAging);
  }

  static String? _editLineFor(FaceFinding f) {
    final area = f.area.toLowerCase();
    final status = f.status.toLowerCase();
    switch (area) {
      case 'filler':
        if (f.isConfirmedFillerOverfill) {
          return 'Reduce overfilled or puffy filler areas to natural proportions';
        }
        return null;
      case 'jaw':
        if (status.contains('sag') ||
            status.contains('lax') ||
            status.contains('jowl') ||
            f.showsNaturalAging) {
          return 'Tighten and refine jawline when sagging — subtle lift/firmness only, no face shape change';
        }
        if (f.isConfirmedFillerOverfill) {
          return 'Softly reduce jaw/masseter filler volume — lower face reads too wide from injection';
        }
        return null;
      case 'nose':
        if (f.noseNeedsRhinoplasty) {
          return 'Subtle rhinoplasty preview: refine bridge, tip, and nostril balance — '
              'visible ~15–20% improvement, natural, same person';
        }
        return null;
      case 'lips':
        if (f.isConfirmedFillerOverfill) {
          return 'Reduce lip volume from over-filler toward natural proportion';
        }
        if (status.contains('thin') ||
            status.contains('flat') ||
            f.showsNaturalAging) {
          return 'Visible lip filler preview: fuller upper/lower lip, hydrated, +12–18% volume, natural outline';
        }
        return null;
      case 'cheeks':
        if (f.isConfirmedFillerOverfill) {
          return 'Softly reduce cheek filler volume — cheeks read as overfilled';
        }
        if (status.contains('volume_loss') ||
            status.contains('sag') ||
            f.showsNaturalAging) {
          return 'Visible cheek lift and apple volume for hollow/sagging midface — natural lift, not pillowy';
        }
        if (status.contains('flat') || status.contains('hollow')) {
          return 'Add very subtle cheek definition only where flat';
        }
        return null;
      case 'brows':
        // Brows: clinic report text only — never send to image editors (avoids painted brows).
        return null;
      case 'eyes':
        if (status.contains('tired') ||
            status.contains('hood') ||
            status.contains('circle') ||
            status.contains('dark') ||
            status.contains('visible') ||
            f.showsNaturalAging) {
          return 'Remove under-eye dark circles; soften crow\'s feet — keep eye shape and size identical';
        }
        return null;
      case 'wrinkles':
        if (status.contains('visible') ||
            status.contains('needs') ||
            f.showsNaturalAging) {
          return 'Clearly soften nasolabial folds, marionette lines, and forehead lines — visible but natural';
        }
        return null;
      case 'skin':
        if (status.contains('discolor') ||
            status.contains('spot') ||
            status.contains('uneven')) {
          return 'Even discoloration and redness; refine skin texture naturally (visible pores OK)';
        }
        return 'Refine skin texture and clarity naturally — soft but realistic, not filtered';
      default:
        if (f.note.isNotEmpty) return f.note;
        return null;
    }
  }
}

/// Vision analysis via OpenAI chat (gpt-4o recommended for full-face glow plans).
class GlowUpFaceAnalysisService {
  GlowUpFaceAnalysisService({http.Client? client, String? apiKey})
      : _client = client ?? http.Client(),
        _apiKey = (apiKey ?? dotenv.env['OPENAI_API_KEY'] ?? '').trim();

  final http.Client _client;
  final String _apiKey;

  String get _model {
    final fromEnv = (dotenv.env['GLOW_ANALYSIS_MODEL'] ?? '').trim();
    if (fromEnv.isNotEmpty) return fromEnv;
    return 'gpt-4o';
  }

  bool get hasKey => _apiKey.isNotEmpty;

  static bool billingBlocked = false;

  bool get canAnalyze => hasKey && !billingBlocked;

  Future<FaceAnalysisReport> analyze(String imagePath) async {
    if (!hasKey) {
      return FaceAnalysisReport.fallback(seed: imagePath.hashCode);
    }

    final bytes = await File(imagePath).readAsBytes();
    final b64 = base64Encode(bytes);
    const mime = 'image/jpeg';

    final body = <String, Object?>{
      'model': _model,
      'temperature': 0.25,
      'max_tokens': 2200,
      'response_format': {'type': 'json_object'},
      'messages': [
        {
          'role': 'system',
          'content': _systemPrompt,
        },
        {
          'role': 'user',
          'content': [
            {
              'type': 'text',
              'text':
                  'Examine this entire face for an aesthetic clinic glow report. '
                  'Diagnose aging vs filler excess on lips, cheeks, and jawline. Assess left–right '
                  'asymmetry (brows, eyes, mouth, jaw). Design a subtle photorealistic PREVIEW. '
                  'filler_assessment and asymmetry_assessment. In the explanation, describe '
                  'any asymmetry observed. image_edit_prompt must NEVER change eye shape, '
                  'brows, or brow color. If lips or mouth are asymmetric, MUST balance lip volume '
                  'and mouth corners subtly in the preview (same lip color). Brow/eye asymmetry is text-only. '
                  'Only skin, smile lines, lips, cheeks, under-eyes, jaw lift. '
                  'Keep pores, identity, exact eye shape and natural brows.',
            },
            {
              'type': 'image_url',
              'image_url': {
                'url': 'data:$mime;base64,$b64',
                'detail': 'high',
              },
            },
          ],
        },
      ],
    };

    final res = await _client.post(
      Uri.parse('https://api.openai.com/v1/chat/completions'),
      headers: {
        'Authorization': 'Bearer $_apiKey',
        'Content-Type': 'application/json',
      },
      body: jsonEncode(body),
    );

    if (res.statusCode < 200 || res.statusCode >= 300) {
      debugPrint('[FaceAnalysis] API ${res.statusCode}: ${res.body}');
      if (res.statusCode == 429 ||
          res.body.contains('insufficient_quota') ||
          res.body.contains('billing')) {
        billingBlocked = true;
      }
      return FaceAnalysisReport.fallback(seed: imagePath.hashCode);
    }

    final decoded = jsonDecode(res.body) as Map<String, dynamic>;
    final choices = decoded['choices'] as List?;
    if (choices == null || choices.isEmpty) {
      return FaceAnalysisReport.fallback(seed: imagePath.hashCode);
    }
    final content =
        (choices.first as Map)['message']?['content'] as String? ?? '';
    try {
      final json = jsonDecode(content) as Map<String, dynamic>;
      final report = FaceAnalysisReport.fromJson(json);
      debugPrint(
        '[FaceAnalysis] model=$_model score=${report.overallScore} '
        'concerns=${report.concerns.length} '
        'procedures=${report.proceduresSimulated.length} '
        'plan=${report.hasGlowUpPlan}',
      );
      billingBlocked = false;
      OpenAIImageEditService.billingBlocked = false;
      return report;
    } catch (e) {
      debugPrint('[FaceAnalysis] parse error: $e');
      return FaceAnalysisReport.fallback(seed: imagePath.hashCode);
    }
  }

  void close() => _client.close();

  static const _systemPrompt = '''
You are a senior aesthetic medicine consultant. Examine the FULL face, write an honest
report, then design a glow-up PREVIEW as if the patient had appropriate clinic treatments.
Return ONLY valid JSON (no markdown):
{
  "overview": "2-3 sentences — what you see now",
  "overall_score": number 0-100,
  "findings": [
    {
      "area": "filler|cheeks|nose|lips|brows|eyes|skin|wrinkles|jaw",
      "status": "ok|natural|overfilled|thin|sagging|volume_loss|visible|...",
      "severity": "none|mild|moderate|severe",
      "note": "1-2 sentences for the patient",
      "recommend_edit": boolean
    }
  ],
  "glow_up_preview": {
    "explanation": "3-5 sentences in plain language: what the AFTER preview simulates and why — like a doctor explaining treatments done",
    "procedures": [
      {
        "name": "e.g. Botox — forehead, Tear-trough filler, Cheek filler, Lip hydration",
        "zone": "forehead|eyes|cheeks|lips|jaw|nose|skin|wrinkles",
        "change": "What should look different in the AFTER image"
      }
    ],
    "image_edit_prompt": "Treatment PREVIEW instructions: same person, black studio. MUST visibly soften nasolabial/smile lines if aging. If tear-trough or under-eye filler is planned, MUST show visibly fuller brighter under-eyes. If nose status is not ok, include subtle rhinoplasty preview (refined bridge/tip). Lip/cheek filler when listed. Never paint brows. ~30% visible correction so the patient sees the plan."
  },
  "filler_assessment": {
    "summary": "2-3 sentences: lips, cheeks, jawline — natural vs possible overfill vs aging/sagging (not filler)",
    "zones": [
      {"area": "lips", "verdict": "natural|thin_aging|possible_overfill|overfilled|asymmetric_overfill", "note": "1-2 sentences"},
      {"area": "cheeks", "verdict": "natural|volume_loss|possible_overfill|overfilled|asymmetric_overfill", "note": "..."},
      {"area": "jaw", "verdict": "natural|sagging|possible_overfill|overfilled|asymmetric_overfill", "note": "..."},
      {"area": "filler", "verdict": "natural|possible_overfill|overfilled", "note": "overall injectable balance"}
    ]
  },
  "asymmetry_assessment": {
    "severity": "none|mild|moderate",
    "observed": "What is uneven (brows, eyes, lips, jaw, nose) — be specific",
    "corrected_in_preview": "What the AFTER image gently balanced (preview simulation only — patient must be told)"
  }
}

CRITICAL — aging vs filler (read this first):
Many older patients have SAGGING, JOWLS, MARIONETTE LINES, NASOLABIAL FOLDS, THIN LIPS,
and HOLLOW CHEEKS. That is gravity and skin laxity — NOT lip/jaw/cheek filler overfill.

Do NOT use status "overfilled", "excess", "too_wide", or "too_large" for:
- Jowls or loose skin hanging along the jaw
- A wider-appearing lower face caused by skin laxity (not smooth masseter bulk)
- Thin, lined, or deflated lips
- Flat or descended cheeks (volume LOSS)
- Deep wrinkles and folds

ONLY flag overfilled when you see CLEAR filler morphology AND mention "filler" in the note:
- LIPS: smooth ballooned lips, duck-lip projection, erased vermillion border, unnatural puffiness
- JAW: smooth masseter/mandibular bulge from injection (younger aesthetic look), not jowls
- CHEEKS: firm round malar pillows / pillow face — not hollow or sagging midface
- FILLER: migrated product, obvious asymmetric injectable volume

When aging applies, use instead:
- lips → status "thin" or "natural", note thin/lined lips from age
- jaw → status "sagging" or "laxity", note jowls and lower-face laxity
- cheeks → status "volume_loss" or "sagging", note descent or hollowing
- filler → status "natural" or "ok", note no obvious excess filler

Other areas:
- Nose, brows, eyes, skin, wrinkles — assess on their own merits.

Scoring:
- Older faces with aging only: overall_score often 58-75; do not punish for fake "overfiller".
- Drop score only when true overfiller is visible.

recommend_edit:
- Set true for wrinkles, eyes, skin when aging signs are present (lines, bags, laxity).
- Set true for lips/cheeks only when thin/hollow/volume_loss — NOT when sagging jowls alone.
- Set false for filler/lips/jaw/cheeks when no real overfiller is visible.

Rules:
- Include exactly one finding per area: filler, lips, jaw, cheeks, nose, brows, eyes, skin, wrinkles.
- filler_assessment zones MUST cover lips, cheeks, jaw, and filler — call out overfill only with clear filler morphology.
- asymmetry_assessment: if any visible imbalance, severity mild or moderate; describe observed + what the AFTER preview balanced (lips/mouth may be corrected in the image; brows/eyes text-only).
- image_edit_prompt: never mention brows, brow lift, brow fill, or brow color — cheek/midface lift only if needed.
- If nose finding status is not ok/natural/good, add Rhinoplasty to procedures (zone nose) and describe bridge/tip refinement in image_edit_prompt.
- If lips are thin or asymmetric, add lip filler to procedures and describe Russian-style volume + symmetry in image_edit_prompt.
- recommend_edit: set true for nose when bump, asymmetry, width, or tip issues warrant rhinoplasty discussion.
- recommend_edit: set true for lips when thin, flat, or asymmetric — patient should see visible lip volume in the preview.
- glow_up_preview.explanation MUST mention filler verdicts and any asymmetry observed (text only — never imply eyes/brows were reshaped in the image).
- Overview must match findings — never claim prior filler if the face shows aging only.
- Be direct but respectful. Educational tone, not a medical diagnosis.
''';
}
