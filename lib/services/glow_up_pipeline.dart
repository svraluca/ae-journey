import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:image/image.dart' as img;

import 'capture_sharpness.dart';
import 'glow_up_edit_composite.dart' show
    finalizeBlackStudio,
    healInpaintSpecksEnabled,
    prepareGlowUpSliderPair;
import 'glow_up_in_memory_post_process.dart';
import 'glow_up/clinic_prompt_builder.dart';
import 'glow_up_face_analysis_service.dart';
import 'local_glow_retouch.dart' show
    applyClinicLocalPolish,
    applyClinicVisibleFallback,
    applyLocalGlowRetouch;
import 'meitu_glow_up_edit_service.dart' show MeituGlowUpEditService, meituEditUserMessage;
import 'openai_image_edit_service.dart';
import 'photo_processor.dart';
import 'replicate_glow_up_edit_service.dart';
import 'replicate_service.dart';

export 'glow_up_face_analysis_service.dart'
    show
        FaceAnalysisReport,
        FaceAsymmetryAssessment,
        FaceFinding,
        FillerAssessment,
        FillerZoneVerdict,
        GlowUpProcedure;
export 'photo_processor.dart' show PhotoSource;

/// MediaPipe-style face-landmark model that returns landmark JSON. None of
/// the popular Replicate "mediapipe" models do this — most return an
/// annotated image instead. Point `REPLICATE_FACE_MESH_MODEL` in `.env` at
/// a slug whose output is `{landmarks: [[x,y], ...]}` (or similar) to enable
/// real per-zone symmetry scoring. When empty (default) the pipeline skips
/// the call and uses deterministic scores derived from the photo hash.
const _defaultFaceMeshSlug = '';

@immutable
class DissolveZone {
  const DissolveZone({
    required this.zone,
    required this.confidence,
    required this.note,
  });

  final String zone;
  final DissolveConfidence confidence;
  final String note;
}

enum DissolveConfidence { high, medium }

@immutable
class GlowAnalysisResult {
  const GlowAnalysisResult({
    required this.originalPath,
    required this.enhancedUrl,
    required this.scores,
    this.dissolveZones = const [],
    this.faceReport,
    this.rawPhotoPath,
    this.sliderBeforePath,
    this.sliderAfterPath,
    this.sliderSideBySidePath,
    this.error,
  });

  factory GlowAnalysisResult.fallback({String? originalPath, String? error}) {
    final seed = (originalPath ?? '').hashCode;
    final scores = GlowScores.synthetic(seed);
    return GlowAnalysisResult(
      originalPath: originalPath ?? '',
      rawPhotoPath: originalPath,
      enhancedUrl: null,
      scores: scores,
      faceReport: FaceAnalysisReport.fallback(seed: seed),
      dissolveZones: _syntheticDissolveZones(scores.zones),
      error: error,
    );
  }

  /// Black-studio "before" image shown in the slider (after stage 1).
  final String originalPath;

  /// Camera/library file before background normalization (optional).
  final String? rawPhotoPath;

  /// Full-resolution after edit (best quality for detail).
  final String? enhancedUrl;

  /// Matched 1024² slider JPEGs — aligned before/after for the compare UI.
  final String? sliderBeforePath;
  final String? sliderAfterPath;

  /// Single 2048×1024 strip — faces close at the center seam (side-by-side mode).
  final String? sliderSideBySidePath;
  final GlowScores scores;
  final FaceAnalysisReport? faceReport;
  final List<DissolveZone> dissolveZones;
  final String? error;

  bool get hasEnhanced => (enhancedUrl ?? '').isNotEmpty;
}

/// Stage 1 output — black-studio before image for user confirmation.
@immutable
class GlowStudioBeforeResult {
  const GlowStudioBeforeResult({
    required this.studioPath,
    required this.rawPhotoPath,
    this.error,
  });

  final String studioPath;
  final String rawPhotoPath;
  final String? error;
}

@immutable
class ZoneScore {
  const ZoneScore(
    this.name,
    this.score, {
    this.needsWork = false,
    this.asymmetry = 0.0,
  });

  final String name;
  final double score;
  final bool needsWork;

  /// MediaPipe-derived asymmetry residual normalized by face width.
  /// 0.0 = perfectly symmetric, ~0.10+ = visibly asymmetric.
  final double asymmetry;

  String get display => score.toStringAsFixed(1);
}

@immutable
class SkinMetric {
  const SkinMetric(this.name, this.value);
  final String name;
  final double value;

  String get display => value.toStringAsFixed(1);
  double get fill => (value / 10.0).clamp(0.0, 1.0);
}

@immutable
class GlowScores {
  const GlowScores({
    required this.glowScore,
    required this.potentialScore,
    required this.zones,
    required this.skinMetrics,
  });

  factory GlowScores.synthetic(int seed) {
    final rng = math.Random(seed == 0 ? 1 : seed);
    double s(double low, double high) => low + rng.nextDouble() * (high - low);

    final zones = <ZoneScore>[
      ZoneScore('FOREHEAD', s(6.5, 8.0), asymmetry: s(0.01, 0.04)),
      ZoneScore('EYES', s(6.2, 7.6), asymmetry: s(0.02, 0.05)),
      ZoneScore('SKIN', s(5.0, 7.0), asymmetry: s(0.01, 0.03)),
      ZoneScore('CHEEKS', s(6.0, 7.4), asymmetry: s(0.03, 0.08)),
      ZoneScore('LIPS', s(4.8, 6.8), asymmetry: s(0.03, 0.07)),
      ZoneScore('JAW', s(6.8, 8.2), asymmetry: s(0.02, 0.05)),
    ];
    final metrics = <SkinMetric>[
      SkinMetric('Pore size', s(5.5, 8.0)),
      SkinMetric('Brightness', s(4.5, 7.5)),
      SkinMetric('Evenness', s(5.0, 7.5)),
      SkinMetric('Hydration', s(4.0, 7.0)),
    ];
    final marked = _markNeedsWork(zones);
    return GlowScores(
      glowScore: _glowFromZones(marked),
      potentialScore: _potentialFromGlow(_glowFromZones(marked)),
      zones: marked,
      skinMetrics: metrics,
    );
  }

  final int glowScore;
  final int potentialScore;
  final List<ZoneScore> zones;
  final List<SkinMetric> skinMetrics;

  int get deltaPercent => glowScore == 0
      ? 0
      : (((potentialScore - glowScore) / glowScore) * 100).round();
}

List<ZoneScore> _markNeedsWork(List<ZoneScore> zones) {
  final sorted = [...zones]..sort((a, b) => a.score.compareTo(b.score));
  final weakest = sorted.take(2).map((z) => z.name).toSet();
  return [
    for (final z in zones)
      ZoneScore(
        z.name,
        z.score,
        needsWork: weakest.contains(z.name),
        asymmetry: z.asymmetry,
      ),
  ];
}

int _glowFromZones(List<ZoneScore> zones) {
  if (zones.isEmpty) return 0;
  final avg = zones.map((z) => z.score).reduce((a, b) => a + b) / zones.length;
  return (avg * 10).round().clamp(0, 100);
}

int _potentialFromGlow(int glow) =>
    (glow + (100 - glow) * 0.55).round().clamp(0, 100);

/// Asymmetric zones get flagged for possible hyaluronidase ("dissolve")
/// before any new filler. Lips and cheeks are the only zones where this
/// recommendation is medically meaningful, so we only surface those.
List<DissolveZone> _dissolveZonesFromScores(List<ZoneScore> zones) {
  const considered = {'LIPS', 'CHEEKS'};
  final out = <DissolveZone>[];
  for (final z in zones) {
    if (!considered.contains(z.name)) continue;
    if (z.asymmetry < 0.04) continue;
    final isHigh = z.asymmetry > 0.06;
    final pretty = z.name == 'LIPS' ? 'Lips' : 'Cheeks';
    out.add(
      DissolveZone(
        zone: pretty,
        confidence: isHigh
            ? DissolveConfidence.high
            : DissolveConfidence.medium,
        note: z.name == 'CHEEKS'
            ? 'Asymmetric volume · likely prior filler in malar area'
            : 'Border definition suggests existing product',
      ),
    );
  }
  return out;
}

List<DissolveZone> _syntheticDissolveZones(List<ZoneScore> zones) =>
    _dissolveZonesFromScores(zones);

/// Orchestrates: black studio prep → vision face report → targeted gpt-image-1
/// retouch for the "after" image. Replicate face mesh is optional fallback
/// for zone scores when vision is unavailable.
class GlowUpPipeline {
  GlowUpPipeline({
    ReplicateService? replicate,
    OpenAIImageEditService? editor,
    ReplicateGlowUpEditService? replicateEdit,
    MeituGlowUpEditService? meituEdit,
    GlowUpFaceAnalysisService? faceAnalysis,
  })  : _replicate = replicate ?? ReplicateService(),
        _editor = editor ?? OpenAIImageEditService(),
        _replicateEdit = replicateEdit ?? ReplicateGlowUpEditService(),
        _meituEdit = meituEdit ?? MeituGlowUpEditService(),
        _faceAnalysis = faceAnalysis ?? GlowUpFaceAnalysisService();

  final ReplicateService _replicate;
  final OpenAIImageEditService _editor;
  final ReplicateGlowUpEditService _replicateEdit;
  final MeituGlowUpEditService _meituEdit;
  final GlowUpFaceAnalysisService _faceAnalysis;

  bool get _useReplicateEdit => _replicateEdit.canRun;

  bool get _useOpenAiStudio => useOpenAiStudioOnly();

  String get _editMode =>
      (dotenv.env['GLOW_UP_EDIT_MODE'] ?? 'openai').trim().toLowerCase();

  bool get _preferLocalEdit => _editMode == 'local' || _editMode == 'landmark';

  bool get _landmarkOnlyEdit => _editMode == 'landmark';

  bool get _useMeituEdit => _editMode == 'meitu';

  /// FLUX/Replicate beauty edit — only when [GLOW_UP_EDIT_MODE]=replicate.
  bool get _allowReplicateBeauty => _editMode == 'replicate';

  /// Meitu beauty edit — only when [GLOW_UP_EDIT_MODE]=meitu.
  bool get _allowMeituBeauty => _editMode == 'meitu';

  /// When OpenAI fails, try Replicate FLUX with the same clinic prompt (if token set).
  bool get _openAiFailFallbackReplicate {
    final v =
        (dotenv.env['GLOW_UP_OPENAI_FAIL_FALLBACK_REPLICATE'] ?? 'true')
            .trim()
            .toLowerCase();
    return v != 'false' && v != '0';
  }

  /// FLUX fallback paints brows/eyelids like makeup — off by default in Meitu mode.
  bool get _skipFluxWhenMeituMode {
    final v =
        (dotenv.env['GLOW_UP_MEITU_SKIP_FLUX'] ?? 'true').trim().toLowerCase();
    return v != 'false' && v != '0';
  }

  /// Skip OpenAI when an alternate beauty editor is the primary mode.
  bool _skipOpenAiBeautyEdit(bool meituWillRun) =>
      _allowReplicateBeauty || (_allowMeituBeauty && meituWillRun);

  bool get _applyLocalPass {
    final v = (dotenv.env['GLOW_UP_LOCAL_PASS'] ?? 'false').trim().toLowerCase();
    return v == 'true' || v == '1';
  }

  bool get _useOpenAiBeforeLighting {
    final v =
        (dotenv.env['GLOW_UP_BEFORE_STUDIO_LIGHT'] ?? 'false').trim().toLowerCase();
    return v == 'true' || v == '1';
  }

  bool get _allowBoostEdit {
    final v = (dotenv.env['GLOW_UP_BOOST_EDIT'] ?? 'false').trim().toLowerCase();
    return v == 'true' || v == '1';
  }

  /// Second OpenAI pass when the first edit still looks too subtle (ChatGPT-style default on).
  bool get _autoBoostWhenSubtle {
    final v = (dotenv.env['GLOW_UP_AUTO_BOOST_SUBTLE'] ?? '').trim().toLowerCase();
    if (v == 'false' || v == '0' || v == 'off') return false;
    if (v == 'true' || v == '1' || v == 'on') return true;
    return _chatGptStyle;
  }

  /// Paste original eyebrow pixels after AI edit (FLUX often thins brows).
  bool get _preserveBrowsFromOriginal {
    final v =
        (dotenv.env['GLOW_UP_PRESERVE_BROWS'] ?? 'true').trim().toLowerCase();
    return v != 'false' && v != '0';
  }

  /// Restore natural eyes/lips from studio before (blocks FLUX makeup/lipstick).
  bool get _preserveEyesLipsNatural {
    final v =
        (dotenv.env['GLOW_UP_PRESERVE_EYES_LIPS'] ?? 'true').trim().toLowerCase();
    return v != 'false' && v != '0';
  }

  bool get _chatGptStyle => ClinicPromptBuilder.chatGptStyleFromEnv();

  bool get _harmonizeFaceColorEnabled {
    final v = (dotenv.env['GLOW_UP_HARMONIZE_FACE_COLOR'] ?? 'true')
        .trim()
        .toLowerCase();
    return v != 'false' && v != '0' && v != 'off';
  }

  /// Pull orange AI skin cast toward studio before (post OpenAI edit).
  bool get _neutralizeWarmAfterSkin {
    if (_chatGptStyle) return false;
    final v =
        (dotenv.env['GLOW_UP_NEUTRALIZE_WARM_CAST'] ?? 'true')
            .trim()
            .toLowerCase();
    return v != 'false' && v != '0';
  }

  String get _faceMeshSlug =>
      (dotenv.env['REPLICATE_FACE_MESH_MODEL'] ?? '').trim().isEmpty
      ? _defaultFaceMeshSlug
      : dotenv.env['REPLICATE_FACE_MESH_MODEL']!.trim();

  Future<GlowAnalysisResult> analyze(
    String photoPath, {
    PhotoSource source = PhotoSource.camera,
  }) async {
    final before = await prepareStudioBefore(photoPath, source: source);
    return completeGlowUp(
      studioPath: before.studioPath,
      rawPhotoPath: before.rawPhotoPath,
    );
  }

  /// Stage 1 only — black studio before photo for user confirmation.
  Future<GlowStudioBeforeResult> prepareStudioBefore(
    String photoPath, {
    PhotoSource source = PhotoSource.camera,
  }) async {
    if (!_faceAnalysis.hasKey &&
        !_editor.hasKey &&
        !_useReplicateEdit &&
        !(_useMeituEdit && await _meituEdit.canRun)) {
      return GlowStudioBeforeResult(
        studioPath: photoPath,
        rawPhotoPath: photoPath,
        error:
            'Missing API keys — add OPENAI_API_KEY, REPLICATE_API_TOKEN, and/or MEITU_OPENAPI_* keys.',
      );
    }

    final stageErrors = <String>[];
    var studioPath = photoPath;
    try {
      debugPrint(
        '[GlowUp] stage 1: studio (${studioBackgroundMode()})',
      );
      studioPath = await _normalizeStudioBefore(photoPath)
          .timeout(const Duration(minutes: 5));
      if (!_useOpenAiStudio) {
        studioPath = await polishStudioBeforeFile(
          studioPath,
          originalPhotoPath: photoPath,
          aiGeneratedStudio: isAiGeneratedStudioMode(),
        );
      } else {
        debugPrint(
          '[GlowUp] openai studio — using API output as-is (no rembg polish)',
        );
      }
    } catch (e) {
      debugPrint('[GlowUp] studio background failed: $e');
      stageErrors.add('Studio BG: $e');
    }

    if (!await looksLikeBlackStudioFile(studioPath)) {
      await _ensureBlackStudioFallback(photoPath, stageErrors, (path) {
        studioPath = path;
      });
      if (!_useOpenAiStudio && !await looksLikeBlackStudioFile(studioPath)) {
        try {
          studioPath = await enforceBlackStudioFile(studioPath);
        } catch (e) {
          debugPrint('[GlowUp] enforce black studio failed: $e');
        }
      }
    }

    if (await looksLikeBlackStudioFile(studioPath)) {
      stageErrors.removeWhere(
        (e) => e.contains('could not place portrait on black backdrop'),
      );
    }

    return GlowStudioBeforeResult(
      studioPath: studioPath,
      rawPhotoPath: photoPath,
      error: stageErrors.isEmpty ? null : stageErrors.join('  •  '),
    );
  }

  /// Stage 1 — OpenAI background-only by default; rembg only when env says so.
  Future<String> _normalizeStudioBefore(String photoPath) async {
    if (_useOpenAiStudio) {
      if (!_editor.canEdit) {
        throw StateError('Missing OPENAI_API_KEY for studio background');
      }
      return _editor.normalizeBlackStudio(photoPath);
    }
    if (useRembgStudioPipeline() && _replicateEdit.canRun) {
      return _replicateEdit.normalizeBlackStudio(photoPath);
    }
    if (!_editor.canEdit) {
      throw StateError('Missing OPENAI_API_KEY for studio background');
    }
    return _editor.normalizeBlackStudio(photoPath);
  }

  /// Stages 2–3 after the user confirms the before photo.
  Future<GlowAnalysisResult> completeGlowUp({
    required String studioPath,
    required String rawPhotoPath,
  }) async {
    final stageErrors = <String>[];

    FaceAnalysisReport faceReport;
    try {
      debugPrint('[GlowUp] stage 2: face analysis');
      faceReport = await _faceAnalysis
          .analyze(studioPath)
          .timeout(const Duration(minutes: 4));
    } catch (e) {
      debugPrint('[GlowUp] face analysis failed: $e');
      final msg = e.toString().contains('insufficient_quota') ||
              e.toString().contains('429')
          ? 'OpenAI quota exceeded — preview uses on-device retouch only.'
          : 'Analysis: $e';
      stageErrors.add(msg);
      faceReport = FaceAnalysisReport.fallback(seed: rawPhotoPath.hashCode);
    }

    final scores = _scoresFromFaceReport(faceReport);
    final softCapture = await isSoftCapture(studioPath);
    if (softCapture) {
      debugPrint('[GlowUp] soft/blurry capture — soften lines, skip sharpening');
    }

    final enhanced = await _buildEnhanced(
          studioPath,
          faceReport,
          stageErrors,
          softCapture: softCapture,
          rawPhotoPath: rawPhotoPath,
        )
        .timeout(const Duration(minutes: 6))
        .catchError((Object e, StackTrace _) {
          debugPrint('[GlowUp] enhancement failed: $e');
          stageErrors.add('Enhance: $e');
          return null;
        });

    var sliderBefore = studioPath;
    var sliderAfter = enhanced;
    String? sliderSideBySide;
    if (enhanced != null) {
      try {
        final useOpenAiBeforeLight = _useOpenAiBeforeLighting;
        final pair = await prepareGlowUpSliderPair(
          studioPath,
          enhanced,
          beforeLightEditor: _editor,
          useOpenAiBeforeLighting: useOpenAiBeforeLight,
          minimalPrep: _chatGptStyle,
        );
        sliderBefore = pair.before;
        sliderAfter = pair.after;
        sliderSideBySide = pair.sideBySide;
        debugPrint(
          '[GlowUp] preview: studio before + matched after '
          '(openAiLight=$useOpenAiBeforeLight, minimalPrep=$_chatGptStyle)',
        );
      } catch (e) {
        debugPrint('[GlowUp] slider pair failed: $e');
      }
    }

    return GlowAnalysisResult(
      originalPath: studioPath,
      rawPhotoPath: rawPhotoPath,
      enhancedUrl: enhanced,
      sliderBeforePath: enhanced != null ? sliderBefore : null,
      sliderAfterPath: enhanced != null ? sliderAfter : null,
      sliderSideBySidePath: enhanced != null ? sliderSideBySide : null,
      scores: scores,
      faceReport: faceReport,
      dissolveZones: _dissolveZonesFromFaceReport(faceReport),
      error: enhanced == null && stageErrors.isNotEmpty
          ? stageErrors.join('  •  ')
          : null,
    );
  }

  Future<String?> _buildEnhanced(
    String studioImagePath,
    FaceAnalysisReport report,
    List<String> errors, {
    bool softCapture = false,
    String? rawPhotoPath,
  }) async {
    final intensity = softCapture
        ? 0.35
        : ClinicPromptBuilder.intensityFromEnv().clamp(0.0, 0.55);
    final clinicPrompt = ClinicPromptBuilder.build(
      report,
      intensity: intensity,
      softCapture: softCapture,
      chatGptStyle: _chatGptStyle,
    );

    if (_landmarkOnlyEdit) {
      try {
        debugPrint('[GlowUp] stage 3: clinic local polish only (landmark mode)');
        return await applyClinicLocalPolish(
          studioImagePath,
          report: report,
          softCapture: softCapture,
        );
      } catch (e) {
        debugPrint('[GlowUp] clinic local polish failed: $e');
        errors.add('Retouch: $e');
        return null;
      }
    }

    Future<String?> tryOpenAi({required String logLabel}) async {
      if (_preferLocalEdit ||
          !_editor.canEdit ||
          OpenAIImageEditService.billingBlocked) {
        return null;
      }
      try {
        debugPrint(
          '[GlowUp] stage 3: openai clinic $logLabel '
          '(intensity=$intensity, chatGptStyle=$_chatGptStyle, '
          '${clinicPrompt.length} chars)',
        );
        final path = await _editor.editGlowUp(
          studioImagePath,
          customPrompt: clinicPrompt,
          compositeOnOriginal: false,
        );
        if (!await _editQualityOk(studioImagePath, path)) {
          debugPrint('[GlowUp] openai $logLabel rejected — quality check');
          try {
            await File(path).delete();
          } catch (_) {}
          return null;
        }
        if (await _outputTooSimilar(studioImagePath, path)) {
          debugPrint('[GlowUp] openai $logLabel too similar to studio');
          try {
            await File(path).delete();
          } catch (_) {}
          return null;
        }
        _clearNonFatalErrors(errors);
        var out = await _useEditedOutput(
          studioImagePath,
          path,
          report,
          softCapture: softCapture,
          rawPhotoPath: rawPhotoPath,
        );
        return _maybeBoostOpenAiEdit(studioImagePath, out, report);
      } catch (e) {
        debugPrint('[GlowUp] openai $logLabel failed: $e');
        if (!isOpenAiBillingError(e)) {
          errors.add(glowUpEditUserMessage(e));
        }
      }
      return null;
    }

    var replicateAttempted = false;
    Future<String?> tryReplicate(
      String logLabel, {
      bool force = false,
    }) async {
      if (replicateAttempted) return null;
      if (!force && !_allowReplicateBeauty) return null;
      replicateAttempted = true;
      return _attemptReplicateEdit(
        studioImagePath,
        clinicPrompt,
        report,
        errors,
        logLabel: logLabel,
        softCapture: softCapture,
        rawPhotoPath: rawPhotoPath,
        force: force,
      );
    }

    if (_allowReplicateBeauty) {
      final primary = await tryReplicate('primary');
      if (primary != null) return primary;
    }

    final meituWillRun = _allowMeituBeauty && await _meituEdit.canRun;
    if (meituWillRun) {
      try {
        debugPrint('[GlowUp] stage 3: meitu image-edit (explicit mode)');
        final path = await _meituEdit.editGlowUp(
          studioImagePath,
          customPrompt: clinicPrompt,
        );
        if (!await _outputTooSimilar(studioImagePath, path)) {
          _clearNonFatalErrors(errors);
          return _useEditedOutput(
            studioImagePath,
            path,
            report,
            softCapture: softCapture,
            rawPhotoPath: rawPhotoPath,
          );
        }
        try {
          await File(path).delete();
        } catch (_) {}
      } catch (e) {
        debugPrint('[GlowUp] meitu edit failed: $e');
        errors.add(meituEditUserMessage(e));
      }
    } else if (_allowMeituBeauty) {
      debugPrint('[GlowUp] meitu unavailable — trying openai/local');
    }

    if (!_skipOpenAiBeautyEdit(meituWillRun)) {
      final openAi = await tryOpenAi(logLabel: 'primary');
      if (openAi != null) return openAi;
    } else if (!_preferLocalEdit && OpenAIImageEditService.billingBlocked) {
      debugPrint('[GlowUp] stage 3: skipping openai (billing limit)');
    }

    if (_allowMeituBeauty && _useReplicateEdit && !replicateAttempted) {
      final afterMeitu = await tryReplicate('after meitu');
      if (afterMeitu != null) return afterMeitu;
    }

    if (_allowMeituBeauty && !_preferLocalEdit) {
      final openAiFallback = await tryOpenAi(logLabel: 'after meitu');
      if (openAiFallback != null) return openAiFallback;
    }

    if (_preferLocalEdit) {
      try {
        debugPrint('[GlowUp] stage 3: clinic visible local (mode=local)');
        return await applyClinicVisibleFallback(
          studioImagePath,
          report: report,
          softCapture: softCapture,
        );
      } catch (e) {
        debugPrint('[GlowUp] clinic local failed: $e');
        errors.add('Retouch: $e');
      }
    }

    if (_openAiFailFallbackReplicate && _useReplicateEdit && !replicateAttempted) {
      final flux = await tryReplicate('openai unavailable', force: true);
      if (flux != null) return flux;
    }

    try {
      debugPrint(
        '[GlowUp] stage 3 fallback: clinic visible local (openai unavailable)',
      );
      _clearNonFatalErrors(errors);
      final out = await applyClinicVisibleFallback(
        studioImagePath,
        report: report,
        softCapture: softCapture,
      );
      final delta = await _faceEditDeltaMean(studioImagePath, out);
      debugPrint('[GlowUp] visible local fallback delta mean=$delta');
      return out;
    } catch (e) {
      debugPrint('[GlowUp] clinic visible fallback failed: $e');
      errors.add('Retouch: $e');
    }

    return null;
  }

  static const _minEditDelta = 2.0;

  /// FLUX Kontext stage-3. Returns edited path or null if failed/too subtle.
  Future<String?> _attemptReplicateEdit(
    String studioImagePath,
    String replicatePrompt,
    FaceAnalysisReport report,
    List<String> errors, {
    required String logLabel,
    bool softCapture = false,
    String? rawPhotoPath,
    bool force = false,
  }) async {
    if ((!_useReplicateEdit && !force) || _preferLocalEdit) return null;
    try {
      debugPrint(
        '[GlowUp] stage 3: replicate $logLabel ${_replicateEdit.modelSlug} '
        '(${replicatePrompt.length} chars)',
      );
      final path = await _replicateEdit.editGlowUp(
        studioImagePath,
        customPrompt: replicatePrompt,
      );
      if (await _editQualityOk(studioImagePath, path) &&
          !await _outputTooSimilar(studioImagePath, path)) {
        _clearNonFatalErrors(errors);
        return _useEditedOutput(
          studioImagePath,
          path,
          report,
          forReplicate: true,
          softCapture: softCapture,
          rawPhotoPath: rawPhotoPath,
        );
      }
      debugPrint('[GlowUp] replicate $logLabel unsuitable — too subtle or quality');
      try {
        await File(path).delete();
      } catch (_) {}
    } catch (e) {
      debugPrint('[GlowUp] replicate $logLabel failed: $e');
      errors.add(glowUpEditUserMessage(e));
    }
    return null;
  }

  void _clearNonFatalErrors(List<String> errors) {
    errors.removeWhere(isOpenAiBillingError);
    errors.removeWhere((e) => e.contains('AI preview unavailable'));
  }

  /// Second OpenAI pass only when the first is clean and lines are still too subtle.
  Future<String> _maybeBoostOpenAiEdit(
    String studioPath,
    String editedPath,
    FaceAnalysisReport report,
  ) async {
    if (!_allowBoostEdit && !_autoBoostWhenSubtle) return editedPath;
    if (!report.plansLipEnhancement &&
        !report.plansSmileLineTreatment &&
        !report.plansUnderEyeTreatment &&
        !report.plansNoseRhinoplasty &&
        !await _linesStillTooSubtle(studioPath, editedPath)) {
      return editedPath;
    }

    final studioBytes = await File(studioPath).readAsBytes();
    final primaryBytes = await File(editedPath).readAsBytes();
    final primaryScore = glowUpEditCorruptScore(primaryBytes, studioBytes);
    if (primaryScore > 180 ||
        glowUpEditHasSevereInpaintHoles(primaryBytes, studioBytes)) {
      debugPrint(
        '[GlowUp] skip boost — primary hole score=$primaryScore (too damaged)',
      );
      return editedPath;
    }

    debugPrint('[GlowUp] treatment boost pass (lines/lips)');
    try {
      final boosted = await _editor.editGlowUp(
        studioPath,
        customPrompt: report.toOpenAiBoostPrompt(),
        compositeOnOriginal: false,
      );
      final boostedBytes = await File(boosted).readAsBytes();
      final boostScore = glowUpEditCorruptScore(boostedBytes, studioBytes);
      debugPrint(
        '[GlowUp] boost hole score=$boostScore (primary=$primaryScore)',
      );
      if (boostScore >= primaryScore ||
          boostScore > 180 ||
          glowUpEditHasSevereInpaintHoles(boostedBytes, studioBytes)) {
        debugPrint('[GlowUp] boost rejected — keeping primary edit');
        try {
          await File(boosted).delete();
        } catch (_) {}
        return editedPath;
      }
      try {
        await File(editedPath).delete();
      } catch (_) {}
      return _useEditedOutput(studioPath, boosted, report);
    } catch (e) {
      debugPrint('[GlowUp] boost edit failed: $e');
      return editedPath;
    }
  }

  Future<void> _ensureBlackStudioFallback(
    String photoPath,
    List<String> errors,
    void Function(String path) onSuccess,
  ) async {
    debugPrint('[GlowUp] before image not black studio — trying fallback cutout');

    Future<String?> tryReplicate() async {
      if (!_replicateEdit.canRun) return null;
      try {
        var path = await _replicateEdit.normalizeBlackStudio(photoPath);
        path = await finalizeBlackStudio(path);
        path = await enforceBlackStudioFile(path);
        if (await looksLikeBlackStudioFile(path)) return path;
      } catch (e) {
        debugPrint('[GlowUp] rembg studio fallback failed: $e');
      }
      return null;
    }

    Future<String?> tryOpenAi() async {
      if (!_editor.canEdit || OpenAIImageEditService.billingBlocked) return null;
      try {
        var path = await _editor.normalizeBlackStudio(photoPath);
        path = await finalizeBlackStudio(path);
        path = await enforceBlackStudioFile(path);
        if (await looksLikeBlackStudioFile(path)) return path;
      } catch (e) {
        debugPrint('[GlowUp] openai studio fallback failed: $e');
      }
      return null;
    }

    final path = _useOpenAiStudio
        ? (await tryOpenAi()) ?? (await tryReplicate())
        : (await tryReplicate()) ?? (await tryOpenAi());
    if (path != null) {
      onSuccess(path);
      debugPrint('[GlowUp] black studio fallback OK');
    } else {
      errors.add(
        'Studio BG: could not place portrait on black backdrop — before may show original background.',
      );
    }
  }

  bool get _useCompositeMerge {
    final v = (dotenv.env['GLOW_UP_COMPOSITE'] ?? 'false').trim().toLowerCase();
    return v == 'true' || v == '1';
  }

  /// Reject edits with severe inpaint holes (painted brows, gray patches).
  Future<bool> _editQualityOk(String studioPath, String editedPath) async {
    try {
      final studioBytes = await File(studioPath).readAsBytes();
      final outBytes = await File(editedPath).readAsBytes();
      if (glowUpEditHasSevereInpaintHoles(outBytes, studioBytes)) {
        final holes = glowUpEditCorruptScore(outBytes, studioBytes);
        debugPrint(
          '[GlowUp] rejecting edit — severe inpaint holes (score=$holes)',
        );
        return false;
      }
      return true;
    } catch (e) {
      debugPrint('[GlowUp] quality check failed: $e');
      return true;
    }
  }

  /// Resize/composite AI output; single in-memory pixel chain → one JPEG.
  Future<String> _useEditedOutput(
    String studioPath,
    String editedPath,
    FaceAnalysisReport report, {
    bool forReplicate = false,
    bool gentleLocalOnly = false,
    bool softCapture = false,
    String? rawPhotoPath,
  }) async {
    try {
      return await runPostAiEditPipeline(
        studioPath: studioPath,
        editedPath: editedPath,
        report: report,
        opts: GlowUpPostProcessOptions(
          chatGptStyle: _chatGptStyle,
          harmonizeFaceColor: _harmonizeFaceColorEnabled,
          neutralizeWarmAfterSkin: _neutralizeWarmAfterSkin,
          preserveBrows: _preserveBrowsFromOriginal,
          preserveEyesLips: _preserveEyesLipsNatural,
          applyLocalPass: _applyLocalPass,
          healInpaintSpecks: healInpaintSpecksEnabled(),
        ),
        softCapture: softCapture,
        rawPhotoPath: rawPhotoPath,
        minEditDelta: _minEditDelta,
        needsVisiblePreview: report.needsVisiblePreview,
      );
    } catch (e, st) {
      debugPrint('[GlowUp] in-memory post-AI failed: $e\n$st');
      return editedPath;
    }
  }

  Future<String> _applyLocalEnhancement(
    String imagePath,
    FaceAnalysisReport report, {
    bool force = false,
    bool gentle = false,
  }) async {
    if (!_applyLocalPass && !force) return imagePath;
    try {
      final lipVol = report.plansLipEnhancement;
      debugPrint(
        '[GlowUp] local enhancement pass'
        '${gentle ? ' (clinical' : ''}'
        '${gentle && lipVol ? ' + lips' : gentle ? '' : ''}'
        '${gentle ? ')' : ''}',
      );
      if (gentle) {
        return applyClinicLocalPolish(imagePath, report: report);
      }
      return await applyLocalGlowRetouch(
        imagePath,
        report: report,
        aggressiveVolume: !gentle,
        allowLipVolume: gentle && lipVol,
      );
    } catch (e) {
      debugPrint('[GlowUp] local pass failed: $e');
      return imagePath;
    }
  }

  /// True when smile-line / under-eye zones barely changed after AI + local.
  Future<bool> _linesStillTooSubtle(String beforePath, String afterPath) async {
    try {
      final before = img.decodeImage(await File(beforePath).readAsBytes());
      final after = img.decodeImage(await File(afterPath).readAsBytes());
      if (before == null || after == null) return false;

      final afterSized = after.width == before.width && after.height == before.height
          ? after
          : img.copyResize(after, width: before.width, height: before.height);

      final zones = <(double, double, double, double)>[
        (0.38, 0.54, 0.24, 0.14), // nasolabial L
        (0.62, 0.54, 0.24, 0.14), // nasolabial R
        (0.36, 0.40, 0.28, 0.10), // under-eye L
        (0.64, 0.40, 0.28, 0.10), // under-eye R
      ];

      for (final z in zones) {
        final d = _zoneDeltaMean(before, afterSized, z.$1, z.$2, z.$3, z.$4);
        if (d < 6) return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  double _zoneDeltaMean(
    img.Image before,
    img.Image after,
    double cx,
    double cy,
    double rw,
    double rh,
  ) {
    final px = before.width * cx;
    final py = before.height * cy;
    final rx = before.width * rw;
    final ry = before.height * rh;
    var sum = 0.0;
    var n = 0;
    for (var y = 0; y < before.height; y++) {
      for (var x = 0; x < before.width; x++) {
        final dx = (x - px) / rx;
        final dy = (y - py) / ry;
        if (dx * dx + dy * dy > 1) continue;
        final p0 = before.getPixel(x, y);
        final p1 = after.getPixel(x, y);
        sum += (p0.r - p1.r).abs() +
            (p0.g - p1.g).abs() +
            (p0.b - p1.b).abs();
        n++;
      }
    }
    return n == 0 ? 0 : sum / (n * 3);
  }

  /// Mean RGB delta in the central face oval (0 = identical).
  Future<double> _faceEditDeltaMean(String beforePath, String afterPath) async {
    try {
      final before = img.decodeImage(await File(beforePath).readAsBytes());
      final after = img.decodeImage(await File(afterPath).readAsBytes());
      if (before == null || after == null) return 0;

      final afterSized = after.width == before.width && after.height == before.height
          ? after
          : img.copyResize(
              after,
              width: before.width,
              height: before.height,
            );

      final cx = before.width * 0.5;
      final cy = before.height * 0.42;
      final rx = before.width * 0.28;
      final ry = before.height * 0.36;
      var sum = 0.0;
      var n = 0;
      for (var y = 0; y < before.height; y++) {
        for (var x = 0; x < before.width; x++) {
          final dx = (x - cx) / rx;
          final dy = (y - cy) / ry;
          if (dx * dx + dy * dy > 1) continue;
          final p0 = before.getPixel(x, y);
          final p1 = afterSized.getPixel(x, y);
          sum += (p0.r - p1.r).abs() +
              (p0.g - p1.g).abs() +
              (p0.b - p1.b).abs();
          n++;
        }
      }
      if (n == 0) return 0;
      return sum / (n * 3);
    } catch (e) {
      debugPrint('[GlowUp] delta check failed: $e');
      return 0;
    }
  }

  /// True when the edit barely changed the face (editors returned ~same image).
  Future<bool> _outputTooSimilar(String beforePath, String afterPath) async {
    final mean = await _faceEditDeltaMean(beforePath, afterPath);
    const threshold = 0.8;
    debugPrint('[GlowUp] edit delta mean=$mean (threshold $threshold)');
    return mean < threshold;
  }

  GlowScores _scoresFromFaceReport(FaceAnalysisReport report) {
    double zoneScore(String areaKey, {double defaultScore = 7.2}) {
      final match = report.findings.where(
        (f) => f.area.toLowerCase() == areaKey.toLowerCase(),
      );
      if (match.isEmpty) return defaultScore;
      final f = match.first;
      if (!f.isConcern) return 8.2;
      if (f.isConfirmedFillerOverfill) {
        return switch (f.severity.toLowerCase()) {
          'severe' => 3.8,
          'moderate' => 4.8,
          'mild' => 5.8,
          _ => 5.2,
        };
      }
      if (f.showsNaturalAging &&
          {'lips', 'jaw', 'cheeks'}.contains(areaKey.toLowerCase())) {
        return switch (f.severity.toLowerCase()) {
          'severe' => 5.2,
          'moderate' => 6.0,
          'mild' => 6.8,
          _ => 6.4,
        };
      }
      return switch (f.severity.toLowerCase()) {
        'severe' => 4.2,
        'moderate' => 5.6,
        'mild' => 6.4,
        _ => 6.0,
      };
    }

    final zones = <ZoneScore>[
      ZoneScore('FOREHEAD', zoneScore('wrinkles')),
      ZoneScore('EYES', zoneScore('eyes')),
      ZoneScore('SKIN', zoneScore('skin')),
      ZoneScore('CHEEKS', zoneScore('cheeks')),
      ZoneScore('LIPS', zoneScore('lips')),
      ZoneScore('JAW', zoneScore('jaw', defaultScore: 7.4)),
    ];
    final marked = _markNeedsWork(zones);
    final glow = report.overallScore.clamp(0, 100);
    return GlowScores(
      glowScore: glow,
      potentialScore: _potentialFromGlow(glow),
      zones: marked,
      skinMetrics: [
        SkinMetric('Clarity', zoneScore('skin')),
        SkinMetric('Tone', zoneScore('skin').clamp(3.0, 9.5)),
        SkinMetric('Texture', zoneScore('wrinkles')),
        SkinMetric('Under-eyes', zoneScore('eyes')),
      ],
    );
  }

  List<DissolveZone> _dissolveZonesFromFaceReport(FaceAnalysisReport report) {
    final out = <DissolveZone>[];
    final seen = <String>{};

    void addZone(String label, String note, DissolveConfidence confidence) {
      if (seen.contains(label)) return;
      seen.add(label);
      out.add(DissolveZone(zone: label, confidence: confidence, note: note));
    }

    for (final z in report.filler.overfillZones) {
      addZone(
        z.areaLabel,
        z.note.isNotEmpty ? z.note : z.verdictLabel,
        z.verdict.toLowerCase().contains('overfilled')
            ? DissolveConfidence.high
            : DissolveConfidence.medium,
      );
    }

    for (final f in report.findings) {
      final area = f.area.toLowerCase();
      if (area != 'lips' &&
          area != 'cheeks' &&
          area != 'filler' &&
          area != 'jaw') {
        continue;
      }
      if (!f.isConfirmedFillerOverfill) continue;
      final label = switch (area) {
        'filler' => 'Filler balance',
        'lips' => 'Lips',
        'jaw' => 'Jawline',
        _ => 'Cheeks',
      };
      addZone(
        label,
        f.note.isNotEmpty ? f.note : 'Volume may need rebalancing',
        f.severity == 'severe'
            ? DissolveConfidence.high
            : DissolveConfidence.medium,
      );
    }
    if (out.isNotEmpty) return out;
    return _dissolveZonesFromScores(_scoresFromFaceReport(report).zones);
  }

  // Optional when REPLICATE_FACE_MESH_MODEL is configured (landmark symmetry).
  // ignore: unused_element
  Future<GlowScores> _scoreFromMesh(String image) async {
    final slug = _faceMeshSlug;
    if (slug.isEmpty) {
      // No mesh model configured — use deterministic synthetic scores
      // (no Replicate call, no error).
      return GlowScores.synthetic(image.hashCode);
    }
    final raw = await _replicate.run(slug, input: {'image': image});
    final landmarks = _extractLandmarks(raw);
    if (landmarks.length < 50) {
      return GlowScores.synthetic(image.hashCode);
    }
    return _scoreFromLandmarks(landmarks);
  }
}

List<_Pt> _extractLandmarks(Object? raw) {
  final candidates = <Object?>[
    raw,
    if (raw is Map) raw['landmarks'],
    if (raw is Map) raw['face_landmarks'],
    if (raw is Map && raw['faces'] is List && (raw['faces'] as List).isNotEmpty)
      (raw['faces'] as List).first is Map
          ? ((raw['faces'] as List).first as Map)['landmarks']
          : null,
    if (raw is List && raw.isNotEmpty && raw.first is Map)
      (raw.first as Map)['landmarks'],
  ];
  for (final candidate in candidates) {
    final pts = _coercePointList(candidate);
    if (pts.length >= 50) return pts;
  }
  return const [];
}

List<_Pt> _coercePointList(Object? value) {
  if (value is! List) return const [];
  final out = <_Pt>[];
  for (final item in value) {
    if (item is List && item.length >= 2) {
      final x = _asDouble(item[0]);
      final y = _asDouble(item[1]);
      if (x != null && y != null) out.add(_Pt(x, y));
    } else if (item is Map) {
      final x = _asDouble(item['x']);
      final y = _asDouble(item['y']);
      if (x != null && y != null) out.add(_Pt(x, y));
    }
  }
  return out;
}

double? _asDouble(Object? v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v);
  return null;
}

@immutable
class _Pt {
  const _Pt(this.x, this.y);
  final double x;
  final double y;
}

const _zoneIndices = <String, List<int>>{
  'FOREHEAD': [10, 67, 69, 109, 151, 297, 299, 332, 338],
  'EYES': [33, 133, 159, 145, 362, 263, 386, 374, 468, 473],
  'CHEEKS': [50, 117, 118, 119, 205, 280, 346, 347, 348, 425],
  'JAW': [152, 175, 199, 200, 377, 396, 365, 379, 378, 148, 176, 149, 150, 136],
  'LIPS': [13, 14, 17, 0, 61, 291, 78, 308, 81, 311, 87, 178, 318],
  'SKIN': [206, 426, 36, 266, 50, 280, 234, 454],
};

GlowScores _scoreFromLandmarks(List<_Pt> pts) {
  double axis = 0;
  var axisCount = 0;
  for (final idx in [1, 4, 5, 6, 168, 197]) {
    if (idx < pts.length) {
      axis += pts[idx].x;
      axisCount++;
    }
  }
  if (axisCount == 0) {
    return GlowScores.synthetic(pts.length);
  }
  axis /= axisCount;

  final faceMaxX = pts.map((p) => p.x).reduce(math.max);
  final faceMinX = pts.map((p) => p.x).reduce(math.min);
  final faceWidth = (faceMaxX - faceMinX).abs().clamp(1e-6, double.infinity);

  final zoneScores = <ZoneScore>[];
  _zoneIndices.forEach((name, indices) {
    final valid = [
      for (final i in indices)
        if (i < pts.length) pts[i],
    ];
    if (valid.isEmpty) {
      zoneScores.add(ZoneScore(name, 6.0));
      return;
    }
    var residual = 0.0;
    for (final p in valid) {
      final mirrorX = 2 * axis - p.x;
      double best = double.infinity;
      for (final q in valid) {
        final dx = q.x - mirrorX;
        final dy = q.y - p.y;
        final d = math.sqrt(dx * dx + dy * dy);
        if (d < best) best = d;
      }
      residual += best;
    }
    residual /= valid.length;
    final asymmetry = (residual / faceWidth).clamp(0.0, 1.0);
    final symmetry = 1.0 - asymmetry;
    final coverage = (valid.length / indices.length).clamp(0.0, 1.0);
    final raw = (symmetry * 0.75 + coverage * 0.25) * 10;
    zoneScores.add(ZoneScore(name, raw.clamp(3.5, 9.5), asymmetry: asymmetry));
  });

  double scoreOf(String z) => zoneScores
      .firstWhere((s) => s.name == z, orElse: () => const ZoneScore('', 6))
      .score;
  final skinScore = scoreOf('SKIN');
  final cheeksScore = scoreOf('CHEEKS');
  final eyesScore = scoreOf('EYES');
  final metrics = <SkinMetric>[
    SkinMetric('Pore size', (skinScore * 0.7 + 2.0).clamp(3.0, 9.5)),
    SkinMetric('Brightness', (cheeksScore * 0.85 + 0.5).clamp(3.0, 9.5)),
    SkinMetric('Evenness', ((skinScore + cheeksScore) / 2).clamp(3.0, 9.5)),
    SkinMetric(
      'Hydration',
      (eyesScore * 0.6 + skinScore * 0.4).clamp(3.0, 9.5),
    ),
  ];
  final marked = _markNeedsWork(zoneScores);
  final glow = _glowFromZones(marked);
  return GlowScores(
    glowScore: glow,
    potentialScore: _potentialFromGlow(glow),
    zones: marked,
    skinMetrics: metrics,
  );
}