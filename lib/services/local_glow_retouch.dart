import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'face_landmark_service.dart';
import 'glow_up/clinic_prompt_builder.dart';
import 'glow_up_face_analysis_service.dart';

/// Landmark-guided pixel retouch (ML Kit) — targets tear troughs, lines, lips
/// without blurring the eyes.
/// Minimal landmark polish after OpenAI — no lip/cheek/jaw geometry warps.
Future<String> applyClinicLocalPolish(
  String imagePath, {
  FaceAnalysisReport? report,
  bool softCapture = false,
}) async {
  // Only apply local retouch if explicitly enabled
  final localEnabled = (dotenv.env['GLOW_UP_LOCAL_PASS'] ?? 'false')
      .trim()
      .toLowerCase() == 'true';
  if (!localEnabled) {
    debugPrint('[LocalRetouch] skipped — '
        'GLOW_UP_LOCAL_PASS=false');
    return imagePath;
  }
  debugPrint(
    '[LocalRetouch] clinic polish (minimal)'
    '${softCapture ? ' (soft capture)' : ''}',
  );
  return applyLocalGlowRetouch(
    imagePath,
    report: report,
    clinicMinimal: true,
    softCapture: softCapture,
  );
}

/// Stronger pixel-only preview when OpenAI/Replicate are unavailable.
Future<String> applyClinicVisibleFallback(
  String imagePath, {
  FaceAnalysisReport? report,
  bool softCapture = false,
}) async {
  final localEnabled = (dotenv.env['GLOW_UP_LOCAL_PASS'] ?? 'false')
      .trim()
      .toLowerCase() == 'true';
  if (!localEnabled) {
    debugPrint('[LocalRetouch] visible fallback skipped — '
        'GLOW_UP_LOCAL_PASS=false');
    return imagePath;
  }
  debugPrint(
    '[LocalRetouch] clinic visible fallback (no AI)'
    '${softCapture ? ' (soft capture)' : ''}',
  );
  return applyLocalGlowRetouch(
    imagePath,
    report: report,
    clinicMinimal: true,
    clinicVisibleFallback: true,
    softCapture: softCapture,
  );
}

/// Subtle lip/mouth symmetry from landmarks (corners + cupid's bow).
Future<String> balanceLipSymmetryFile(
  String imagePath, {
  bool force = false,
}) async {
  final bytes = await File(imagePath).readAsBytes();
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return imagePath;

  final map = FaceLandmarkService.detectFromImage(decoded);
  if (map == null) return imagePath;
  if (!force && !FaceLandmarkService.lipsNeedAnySymmetryWork(map)) {
    return imagePath;
  }

  _applyLipSymmetryPasses(decoded, map, force: force || _skipLocalCheekTouchups());
  final docs = await getApplicationDocumentsDirectory();
  final dir = Directory('${docs.path}/photos');
  if (!await dir.exists()) await dir.create(recursive: true);
  final out = File('${dir.path}/glow_lip_sym_${const Uuid().v4()}.jpg');
  await out.writeAsBytes(img.encodeJpg(decoded, quality: 94), flush: true);
  debugPrint('[LocalRetouch] lip symmetry → ${out.path}');
  return out.path;
}

/// Tear-trough only — lightens dark under-eye circles (runs even when full local polish is skipped).
Future<String> lightenUnderEyeDarkCirclesFile(
  String imagePath, {
  double strength = 0.34,
}) async {
  final bytes = await File(imagePath).readAsBytes();
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return imagePath;

  final map = FaceLandmarkService.detectFromImage(decoded);
  if (map == null) return imagePath;

  final n = lightenUnderEyeDarkCirclesOnImage(decoded, map, strength: strength);
  if (n == 0) return imagePath;

  final docs = await getApplicationDocumentsDirectory();
  final dir = Directory('${docs.path}/photos');
  if (!await dir.exists()) await dir.create(recursive: true);
  final out = File('${dir.path}/glow_undereye_${const Uuid().v4()}.jpg');
  await out.writeAsBytes(img.encodeJpg(decoded, quality: 94), flush: true);
  debugPrint('[LocalRetouch] lightened $n under-eye dark-circle px → ${out.path}');
  return out.path;
}

bool _shouldSoftenSmileLines(FaceAnalysisReport? report) {
  if (report == null) return true;
  return report.plansSmileLineTreatment;
}

/// Opt-out only — fold-only soften is safe on ChatGPT-style AI edits (no cheek ovals).
bool _localSmileLinesEnabled() {
  final v = (dotenv.env['GLOW_UP_LOCAL_SMILE_LINES'] ?? '').trim().toLowerCase();
  if (v == 'false' || v == '0' || v == 'off') return false;
  return true;
}

/// Nasolabial fold only — no under-eye brighten (safe with ChatGPT-style edits).
void softenSmileLinesOnImage(
  img.Image im,
  FaceGlowMap map, {
  bool strong = false,
}) {
  final strength = strong ? 0.56 : 0.46;
  for (final left in [true, false]) {
    _softenNasolabialAlongFold(
      im,
      map,
      leftSide: left,
      strength: strength,
      blurRadius: strong ? 6 : 5,
    );
    if (strong) {
      _softenNasolabialAlongFold(
        im,
        map,
        leftSide: left,
        strength: 0.38,
        blurRadius: 4,
      );
    }
  }
  debugPrint(
    '[LocalRetouch] smile-line soften only'
    '${strong ? ' (strong)' : ''}',
  );
}

bool _skipLocalCheekTouchups() {
  final v = (dotenv.env['GLOW_UP_SKIP_LOCAL_CHEEK_TOUCHUPS'] ?? '')
      .trim()
      .toLowerCase();
  if (v == 'true' || v == '1' || v == 'on') return true;
  if (v == 'false' || v == '0' || v == 'off') return false;
  return ClinicPromptBuilder.chatGptStyleFromEnv();
}

/// After OpenAI — lip/nose symmetry only when chatgpt-style (cheek pixels cause spots).
Future<String> applyPostAiTargetedFinish(
  String imagePath, {
  FaceAnalysisReport? report,
  bool strong = false,
}) async {
  final bytes = await File(imagePath).readAsBytes();
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return imagePath;

  final map = FaceLandmarkService.detectFromImage(decoded);
  if (map == null) return imagePath;

  final skipCheek = _skipLocalCheekTouchups();
  if (!skipCheek) {
    final tearStrength = strong ? 0.36 : 0.28;
    lightenUnderEyeDarkCirclesOnImage(decoded, map, strength: tearStrength);
  } else {
    debugPrint(
      '[LocalRetouch] post-AI under-eye skipped (AI edit — planned fold/lip passes still run)',
    );
  }

  if (report != null) {
    applyPlannedTreatmentFinishOnImage(
      decoded,
      map,
      report,
      strongSmileLines: strong || report.plansSmileLineTreatment,
    );
  }

  final docs = await getApplicationDocumentsDirectory();
  final dir = Directory('${docs.path}/photos');
  if (!await dir.exists()) await dir.create(recursive: true);
  final out = File('${dir.path}/glow_targeted_${const Uuid().v4()}.jpg');
  await out.writeAsBytes(img.encodeJpg(decoded, quality: 94), flush: true);
  debugPrint(
    '[LocalRetouch] post-AI targeted finish'
    '${strong ? ' (strong)' : ''} → ${out.path}',
  );
  return out.path;
}

/// In-place tear-trough brighten; returns pixels touched.
int lightenUnderEyeDarkCirclesOnImage(
  img.Image decoded,
  FaceGlowMap map, {
  double strength = 0.34,
}) {
  final s = map.faceScale;
  var before = 0;
  var after = 0;
  before += _countTearTroughDarkPixels(decoded, map, map.leftEye, s);
  after += _lightenUnderEyeHarmonizeZone(decoded, map, strength: strength);
  return math.max(0, before - after);
}

/// Tear-trough only — uses landmark mask (avoids curved cheek arcs from wide ellipses).
int _lightenUnderEyeHarmonizeZone(
  img.Image im,
  FaceGlowMap map, {
  required double strength,
}) {
  var touched = 0;
  for (var y = 0; y < im.height; y++) {
    for (var x = 0; x < im.width; x++) {
      var w = FaceLandmarkService.underEyeHarmonizeWeight(map, x, y);
      if (w < 0.06) continue;
      final exclude = FaceLandmarkService.eyeExclusion(map, x, y);
      w *= (1 - exclude);
      // Smoothstep — no hard ring on mid-cheek at mask edge.
      w = w * w * (3 - 2 * w);
      if (w < 0.04) continue;

      final p = im.getPixel(x, y);
      final l =
          0.299 * p.r.toDouble() + 0.587 * p.g.toDouble() + 0.114 * p.b.toDouble();
      if (l > 215) continue;
      final darkBoost = l < 100 ? 1.35 : (l < 130 ? 1.15 : 1.0);
      final lift = (195 - l) * strength * w * 0.48 * darkBoost;
      if (lift < 1.5) continue;
      im.setPixelRgba(
        x,
        y,
        (p.r + lift).round().clamp(0, 255),
        (p.g + lift * 0.96).round().clamp(0, 255),
        (p.b + lift * 0.88).round().clamp(0, 255),
        255,
      );
      touched++;
    }
  }
  return touched;
}

int _countTearTroughDarkPixels(
  img.Image im,
  FaceGlowMap map,
  Offset eye,
  double s,
) {
  var n = 0;
  for (var y = 0; y < im.height; y++) {
    for (var x = 0; x < im.width; x++) {
      final w = FaceLandmarkService.underEyeHarmonizeWeight(map, x, y);
      if (w < 0.2) continue;
      final l = 0.299 * im.getPixel(x, y).r +
          0.587 * im.getPixel(x, y).g +
          0.114 * im.getPixel(x, y).b;
      if (l < 155) n++;
    }
  }
  return n;
}

/// In-memory clinic polish (no extra JPEG round-trip).
img.Image applyClinicLocalPolishOnImage(
  img.Image decoded, {
  FaceAnalysisReport? report,
  bool softCapture = false,
  bool force = false,
  bool gentle = false,
}) {
  final localEnabled = (dotenv.env['GLOW_UP_LOCAL_PASS'] ?? 'false')
          .trim()
          .toLowerCase() ==
      'true';
  if (!localEnabled && !force) return decoded;

  final landmarks = FaceLandmarkService.detectFromImage(decoded);
  if (landmarks != null) {
    _applyClinicMinimalPolish(
      decoded,
      landmarks,
      report,
      softCapture: softCapture,
      visibleFallback: gentle,
    );
    if (gentle) {
      _blendRetouchSeams(decoded, landmarks);
    } else if (softCapture) {
      _softenSmileLinesForSoftCapture(decoded, landmarks, report);
    }
  } else {
    _applyClinicMinimalFallback(
      decoded,
      report,
      softCapture: softCapture,
      visibleFallback: gentle,
    );
  }
  return decoded;
}

/// Strong pixel-only preview when AI delta is still too low.
img.Image applyClinicVisibleFallbackOnImage(
  img.Image studio, {
  FaceAnalysisReport? report,
  bool softCapture = false,
}) {
  final localEnabled = (dotenv.env['GLOW_UP_LOCAL_PASS'] ?? 'false')
          .trim()
          .toLowerCase() ==
      'true';
  if (!localEnabled) return img.Image.from(studio);

  final result = img.Image.from(studio);
  final landmarks = FaceLandmarkService.detectFromImage(result);
  if (landmarks != null) {
    _applyClinicMinimalPolish(
      result,
      landmarks,
      report,
      softCapture: softCapture,
      visibleFallback: true,
    );
    _blendRetouchSeams(result, landmarks);
  } else {
    _applyClinicMinimalFallback(
      result,
      report,
      softCapture: softCapture,
      visibleFallback: true,
    );
  }
  return result;
}

/// Landmark treatments from the analysis plan — always safe to run after AI.
void applyPlannedTreatmentFinishOnImage(
  img.Image decoded,
  FaceGlowMap map,
  FaceAnalysisReport report, {
  bool strongSmileLines = false,
}) {
  if (_localSmileLinesEnabled() && _shouldSoftenSmileLines(report)) {
    softenSmileLinesOnImage(decoded, map, strong: strongSmileLines);
  }

  if (report.plansNoseRhinoplasty ||
      FaceLandmarkService.noseNeedsCorrection(map)) {
    _correctNoseTipAsymmetry(decoded, map);
  }

  final lipWork = report.plansLipSymmetry ||
      report.plansLipEnhancement ||
      FaceLandmarkService.lipsNeedAnySymmetryWork(map);
  if (lipWork) {
    _applyLipSymmetryPasses(decoded, map, force: true);
  }
}

/// In-memory post-AI targeted finish.
void applyPostAiTargetedFinishOnImage(
  img.Image decoded, {
  FaceAnalysisReport? report,
  bool strong = false,
}) {
  final map = FaceLandmarkService.detectFromImage(decoded);
  if (map == null || report == null) return;

  final skipCheek = _skipLocalCheekTouchups();
  if (!skipCheek) {
    final tearStrength = strong ? 0.36 : 0.28;
    lightenUnderEyeDarkCirclesOnImage(decoded, map, strength: tearStrength);
  }

  applyPlannedTreatmentFinishOnImage(
    decoded,
    map,
    report,
    strongSmileLines: strong || report.plansSmileLineTreatment,
  );
}

/// In-memory lip symmetry.
void balanceLipSymmetryOnImage(
  img.Image decoded,
  FaceGlowMap map, {
  bool force = false,
}) {
  if (!force && !FaceLandmarkService.lipsNeedAnySymmetryWork(map)) return;
  _applyLipSymmetryPasses(decoded, map, force: force || _skipLocalCheekTouchups());
}

/// Soft-capture line soften without file I/O.
void applySoftCaptureLineSofteningOnImage(
  img.Image decoded, {
  FaceAnalysisReport? report,
}) {
  final localEnabled = (dotenv.env['GLOW_UP_LOCAL_PASS'] ?? 'false')
          .trim()
          .toLowerCase() ==
      'true';
  if (!localEnabled) return;

  final landmarks = FaceLandmarkService.detectFromImage(decoded);
  if (landmarks != null) {
    _softenSmileLinesForSoftCapture(decoded, landmarks, report);
  } else {
    _softenZone(decoded, 0.40, 0.53, 0.05, 0.15, amount: 0.72, blurRadius: 6);
    _softenZone(decoded, 0.60, 0.53, 0.05, 0.15, amount: 0.72, blurRadius: 6);
    _softenZone(decoded, 0.50, 0.16, 0.28, 0.12, amount: 0.55, blurRadius: 5);
  }
}

/// Post-AI polish — delegates to [applyClinicLocalPolish] (no geometric volume warps).
Future<String> applyClinicalLocalFinish(
  String imagePath, {
  FaceAnalysisReport? report,
  bool softCapture = false,
}) =>
    applyClinicLocalPolish(
      imagePath,
      report: report,
      softCapture: softCapture,
    );

/// Extra pass for soft/blurry captures — softens smile lines without sharpening.
Future<String> applySoftCaptureLineSoftening(
  String imagePath, {
  FaceAnalysisReport? report,
}) async {
  final localEnabled = (dotenv.env['GLOW_UP_LOCAL_PASS'] ?? 'false')
      .trim()
      .toLowerCase() == 'true';
  if (!localEnabled) {
    debugPrint('[LocalRetouch] soft-capture soften skipped — '
        'GLOW_UP_LOCAL_PASS=false');
    return imagePath;
  }
  final bytes = await File(imagePath).readAsBytes();
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return imagePath;

  final landmarks = await FaceLandmarkService.detectFromFile(imagePath);
  if (landmarks != null) {
    _softenSmileLinesForSoftCapture(decoded, landmarks, report);
  } else {
    _softenZone(decoded, 0.40, 0.53, 0.05, 0.15, amount: 0.72, blurRadius: 6);
    _softenZone(decoded, 0.60, 0.53, 0.05, 0.15, amount: 0.72, blurRadius: 6);
    _softenZone(decoded, 0.50, 0.16, 0.28, 0.12, amount: 0.55, blurRadius: 5);
  }

  final docs = await getApplicationDocumentsDirectory();
  final dir = Directory('${docs.path}/photos');
  if (!await dir.exists()) await dir.create(recursive: true);
  final out = File('${dir.path}/glow_soft_${const Uuid().v4()}.jpg');
  await out.writeAsBytes(img.encodeJpg(decoded, quality: 96), flush: true);
  debugPrint('[LocalRetouch] soft-capture line soften → ${out.path}');
  return out.path;
}

Future<String> applyLocalGlowRetouch(
  String imagePath, {
  FaceAnalysisReport? report,
  bool aggressiveVolume = true,
  bool allowLipVolume = false,
  bool visibleBoost = false,
  bool maximumBoost = false,
  bool softCapture = false,
  bool clinicMinimal = false,
  bool clinicVisibleFallback = false,
}) async {
  final localEnabled = (dotenv.env['GLOW_UP_LOCAL_PASS'] ?? 'false')
      .trim()
      .toLowerCase() == 'true';
  if (!localEnabled) {
    debugPrint('[LocalRetouch] applyLocalGlowRetouch skipped — '
        'GLOW_UP_LOCAL_PASS=false');
    return imagePath;
  }
  final bytes = await File(imagePath).readAsBytes();
  final decoded = img.decodeImage(bytes);
  if (decoded == null) {
    throw const FormatException('Could not decode image for local retouch');
  }

  final landmarks = await FaceLandmarkService.detectFromFile(imagePath);
  if (clinicMinimal) {
    if (landmarks != null) {
      _applyClinicMinimalPolish(
        decoded,
        landmarks,
        report,
        softCapture: softCapture,
        visibleFallback: clinicVisibleFallback,
      );
    } else {
      _applyClinicMinimalFallback(
        decoded,
        report,
        softCapture: softCapture,
        visibleFallback: clinicVisibleFallback,
      );
    }
  } else if (landmarks != null) {
    _applyLandmarkRetouch(
      decoded,
      landmarks,
      report,
      aggressiveVolume: aggressiveVolume,
      allowLipVolume: allowLipVolume,
      visibleBoost: visibleBoost,
      maximumBoost: maximumBoost,
      softCapture: softCapture,
    );
  } else {
    _applyFallbackRetouch(
      decoded,
      report,
      aggressiveVolume: aggressiveVolume,
      allowLipVolume: allowLipVolume,
      visibleBoost: visibleBoost,
      maximumBoost: maximumBoost,
      softCapture: softCapture,
    );
  }

  if (clinicMinimal) {
    if (clinicVisibleFallback && landmarks != null) {
      _blendRetouchSeams(decoded, landmarks);
    } else if (softCapture && landmarks != null) {
      _softenSmileLinesForSoftCapture(decoded, landmarks, report);
    }
  } else if (softCapture) {
    if (landmarks != null) {
      _softenSmileLinesForSoftCapture(decoded, landmarks, report);
    }
  } else {
    _evenSkinTone(
      decoded,
      strength: maximumBoost
          ? 0.18
          : (visibleBoost ? 0.11 : 0.10),
    );
    if (!visibleBoost || maximumBoost) {
      _unsharpFace(
        decoded,
        amount: maximumBoost ? 0.09 : (visibleBoost ? 0.05 : 0.04),
      );
    }
  }

  if (!clinicMinimal && visibleBoost && landmarks != null) {
    final lips = _finding(report, 'lips');
    if (allowLipVolume ||
        report?.plansLipEnhancement == true ||
        _wantsLipVolume(report, lips)) {
      _applyRussianLipVolume(
        decoded,
        landmarks,
        strength: maximumBoost ? 1.25 : (softCapture ? 0.92 : 1.05),
      );
      _featherLipWarpSeams(decoded, landmarks);
    }
    if (report?.plansSmileLineTreatment != false) {
      for (final left in [true, false]) {
        _softenNasolabialAlongFold(
          decoded,
          landmarks,
          leftSide: left,
          strength: 0.48,
          blurRadius: 5,
        );
      }
    }
    _blendRetouchSeams(decoded, landmarks);
    if (report?.plansNoseRhinoplasty == true ||
        FaceLandmarkService.noseNeedsCorrection(landmarks)) {
      _correctNoseTipAsymmetry(decoded, landmarks);
    }
    _cleanChinArtifact(decoded, landmarks);
  }

  final outBytes = img.encodeJpg(decoded, quality: 96);
  final docs = await getApplicationDocumentsDirectory();
  final dir = Directory('${docs.path}/photos');
  if (!await dir.exists()) await dir.create(recursive: true);
  final out = File('${dir.path}/glow_local_${const Uuid().v4()}.jpg');
  await out.writeAsBytes(outBytes, flush: true);
  debugPrint('[LocalRetouch] saved → ${out.path}');
  return out.path;
}

void _softenSmileLinesForSoftCapture(
  img.Image decoded,
  FaceGlowMap map,
  FaceAnalysisReport? report,
) {
  final s = map.faceScale;
  final lineK = report?.plansSmileLineTreatment == false ? 0.85 : 1.15;
  for (final left in [true, false]) {
    _softenNasolabialStrip(
      decoded,
      map,
      leftSide: left,
      strength: 0.52 * lineK,
      blurRadius: 5,
    );
  }
  for (final eye in [map.leftEye, map.rightEye]) {
    final side = eye.dx < map.faceCenter.dx ? -1.0 : 1.0;
    _softenAt(
      decoded,
      map,
      cx: eye.dx + side * s * 0.22,
      cy: eye.dy + s * 0.06,
      rx: s * 0.11,
      ry: s * 0.08,
      amount: 0.52,
      blurRadius: 4,
    );
  }
  _softenAt(
    decoded,
    map,
    cx: map.faceCenter.dx,
    cy: (map.leftEye.dy + map.rightEye.dy) / 2 - s * 0.62,
    rx: s * 0.52,
    ry: s * 0.20,
    amount: 0.48,
    blurRadius: 6,
  );
  debugPrint('[LocalRetouch] soft-capture smile/wrinkle soften');
}

/// Light under-eye, smile lines, skin evenness, minor nose symmetry — no volume warps.
void _applyClinicMinimalPolish(
  img.Image decoded,
  FaceGlowMap map,
  FaceAnalysisReport? report, {
  bool softCapture = false,
  bool visibleFallback = false,
}) {
  final s = map.faceScale;
  final eyeLine = (map.leftEye.dy + map.rightEye.dy) / 2;
  final gentleSoft = softCapture && !visibleFallback;

  final tearStrength = visibleFallback ? 0.38 : (gentleSoft ? 0.22 : 0.16);
  final smileStrength = visibleFallback ? 0.58 : (gentleSoft ? 0.42 : 0.46);
  final skinStrength = visibleFallback ? 0.18 : (gentleSoft ? 0.10 : 0.12);
  final foreheadAmount = visibleFallback ? 0.52 : (gentleSoft ? 0.38 : 0.44);

  for (final eye in [map.leftEye, map.rightEye]) {
    _lightenTearTrough(
      decoded,
      map,
      cx: eye.dx,
      cy: eye.dy + s * 0.30,
      rx: s * 0.10,
      ry: s * 0.04,
      strength: tearStrength,
    );
  }

  if (report?.plansSmileLineTreatment != false) {
    for (final left in [true, false]) {
      _softenNasolabialAlongFold(
        decoded,
        map,
        leftSide: left,
        strength: smileStrength,
        blurRadius: visibleFallback ? 6 : 5,
      );
    }
    if (visibleFallback) {
      for (final left in [true, false]) {
        _softenNasolabialAlongFold(
          decoded,
          map,
          leftSide: left,
          strength: 0.44,
          blurRadius: 4,
        );
      }
    }
  }

  _evenSkinTone(decoded, strength: skinStrength);

  if (report?.plansNoseRhinoplasty == true ||
      FaceLandmarkService.noseNeedsCorrection(map)) {
    _correctNoseTipAsymmetry(decoded, map);
  }

  final lipForce = report?.plansLipSymmetry == true ||
      report?.plansLipEnhancement == true;
  if (lipForce ||
      FaceLandmarkService.lipsNeedSymmetryBalance(map) ||
      FaceLandmarkService.lipsNeedVolumeSymmetry(map)) {
    _applyLipSymmetryPasses(decoded, map, force: lipForce);
  }

  _softenAt(
    decoded,
    map,
    cx: map.faceCenter.dx,
    cy: eyeLine - s * 0.62,
    rx: s * 0.50,
    ry: s * 0.18,
    amount: foreheadAmount,
    blurRadius: visibleFallback ? 6 : 5,
  );

  if (visibleFallback) {
    for (final eye in [map.leftEye, map.rightEye]) {
      final side = eye.dx < map.faceCenter.dx ? -1.0 : 1.0;
      _softenAt(
        decoded,
        map,
        cx: eye.dx + side * s * 0.22,
        cy: eye.dy + s * 0.06,
        rx: s * 0.10,
        ry: s * 0.07,
        amount: 0.40,
        blurRadius: 3,
      );
    }
    _softenAt(
      decoded,
      map,
      cx: map.mouthBottom.dx,
      cy: map.mouthBottom.dy + s * 0.14,
      rx: s * 0.10,
      ry: s * 0.08,
      amount: 0.36,
      blurRadius: 4,
    );
    if (report?.plansLipEnhancement == true) {
      final lipW = map.leftMouth != null && map.rightMouth != null
          ? (map.rightMouth!.dx - map.leftMouth!.dx).abs() * 0.58
          : s * 0.24;
      _enhanceLipColorAt(
        decoded,
        map.mouthBottom.dx,
        map.mouthBottom.dy - s * 0.02,
        lipW,
        s * 0.12,
        strength: 0.14,
      );
    }
  }

  debugPrint(
    '[LocalRetouch] clinic minimal polish (landmarks'
    '${visibleFallback ? ', visible fallback' : ''})',
  );
}

void _applyClinicMinimalFallback(
  img.Image decoded,
  FaceAnalysisReport? report, {
  bool softCapture = false,
  bool visibleFallback = false,
}) {
  final gentleSoft = softCapture && !visibleFallback;
  _lightenZone(
    decoded,
    0.50,
    0.16,
    0.28,
    0.12,
    visibleFallback ? 0.72 : (gentleSoft ? 0.55 : 0.60),
  );
  final zoneAmt = visibleFallback ? 0.72 : 0.58;
  _softenZone(decoded, 0.40, 0.53, 0.05, 0.15, amount: zoneAmt, blurRadius: 6);
  _softenZone(decoded, 0.60, 0.53, 0.05, 0.15, amount: zoneAmt, blurRadius: 6);
  _evenSkinTone(decoded, strength: visibleFallback ? 0.16 : 0.10);
  debugPrint(
    '[LocalRetouch] clinic minimal polish (zones'
    '${visibleFallback ? ', visible fallback' : ''})',
  );
}

void _applyLandmarkRetouch(
  img.Image decoded,
  FaceGlowMap map,
  FaceAnalysisReport? report, {
  bool aggressiveVolume = true,
  bool allowLipVolume = false,
  bool visibleBoost = false,
  bool maximumBoost = false,
  bool softCapture = false,
}) {
  final k = softCapture
      ? (visibleBoost ? 2.65 : 1.55)
      : (maximumBoost ? 4.2 : (visibleBoost ? 2.35 : 1.0));
  final doLips =
      aggressiveVolume || allowLipVolume || visibleBoost || maximumBoost;
  final lips = _finding(report, 'lips');
  final jaw = _finding(report, 'jaw');
  final cheeks = _finding(report, 'cheeks');
  final s = map.faceScale;

  final eyeLine = (map.leftEye.dy + map.rightEye.dy) / 2;

  // Under-eye tear trough only — keep off upper cheek beside nose.
  for (final eye in [map.leftEye, map.rightEye]) {
    _lightenTearTrough(
      decoded,
      map,
      cx: eye.dx,
      cy: eye.dy + s * 0.30,
      rx: s * 0.10,
      ry: s * 0.04,
      strength: (maximumBoost
              ? 0.42
              : (visibleBoost ? 0.11 : (softCapture ? 0.22 : 0.16))) *
          (maximumBoost ? 1.0 : (visibleBoost ? 1.0 : k.clamp(1.0, 1.8))),
    );
  }

  if (maximumBoost) {
    _boostLowerFace(
      decoded,
      map,
      strength: 0.14,
    );
  }

  // Forehead wrinkles — upper forehead only.
  _softenAt(
    decoded,
    map,
    cx: map.faceCenter.dx,
    cy: eyeLine - s * 0.62,
    rx: s * 0.50,
    ry: s * 0.18,
    amount: 0.62 * k,
    blurRadius: visibleBoost ? 6 : 5,
  );

  // Do not soften glabella — bleeds into brows and darkens brow hair.

  // Crow's feet — thin zones at outer eye corners only (not above brow).
  for (final eye in [map.leftEye, map.rightEye]) {
    final side = eye.dx < map.faceCenter.dx ? -1.0 : 1.0;
    _softenAt(
      decoded,
      map,
      cx: eye.dx + side * s * 0.22,
      cy: eye.dy + s * 0.06,
      rx: s * 0.10,
      ry: s * 0.07,
      amount: 0.35 * k,
      blurRadius: 2,
    );
  }

  // Smile lines — one smooth pass later (avoids patch spots near nose).

  // Marionette — only when not clinical visible (avoids blobs under smile lines).
  if (!visibleBoost || maximumBoost) {
    _softenAt(
      decoded,
      map,
      cx: map.mouthBottom.dx,
      cy: map.mouthBottom.dy + s * 0.16,
      rx: s * 0.08,
      ry: s * 0.07,
      amount: 0.32 * k,
      blurRadius: 3,
    );
  }

  // Lips — Russian-style volume (warp), not just tint.
  if (lips?.isConfirmedFillerOverfill == true) {
    _deflateAt(decoded, map.mouthBottom.dx, map.mouthBottom.dy, s * 0.20, s * 0.10, 0.12);
  } else if (doLips &&
      (maximumBoost ||
          visibleBoost ||
          report?.plansLipEnhancement == true ||
          _wantsLipVolume(report, lips))) {
    final lipW = map.leftMouth != null && map.rightMouth != null
        ? (map.rightMouth!.dx - map.leftMouth!.dx).abs() * 0.58
        : s * 0.24;
    if (visibleBoost || maximumBoost || report?.plansLipEnhancement == true) {
      _applyRussianLipVolume(
        decoded,
        map,
        strength: maximumBoost ? 1.15 : (softCapture ? 0.88 : 0.95),
      );
    } else {
      _inflateAt(
        decoded,
        map.mouthBottom.dx,
        map.mouthBottom.dy - s * 0.03,
        lipW,
        s * 0.14,
        strength: allowLipVolume ? 0.22 : 0.14,
      );
    }
    // Volume only — no red/pink lipstick tint on clinical preview.
    if (!visibleBoost && !softCapture) {
      _enhanceLipColorAt(
        decoded,
        map.mouthBottom.dx,
        map.mouthBottom.dy,
        lipW,
        s * 0.11,
        strength: maximumBoost ? 0.35 : 0.18,
      );
    }
    debugPrint(
      '[LocalRetouch] lip volume (landmarks'
      '${maximumBoost ? ', max' : visibleBoost ? ', visible' : ''})',
    );
  }

  // Cheeks / jowls.
  if (cheeks?.isConfirmedFillerOverfill == true) {
    for (final c in [map.leftCheek, map.rightCheek]) {
      if (c == null) continue;
      _deflateAt(decoded, c.dx, c.dy, s * 0.16, s * 0.14, 0.07);
    }
  } else if (maximumBoost && _wantsCheekVolume(report, cheeks)) {
    final cheekK = 1.35;
    for (final left in [true, false]) {
      final cheek = left ? map.leftCheek : map.rightCheek;
      final eye = left ? map.leftEye : map.rightEye;
      final pt = cheek ?? Offset(eye.dx, (eye.dy + map.nose.dy) / 2);
      _inflateAt(
        decoded,
        pt.dx,
        pt.dy,
        s * 0.14,
        s * 0.12,
        strength: 0.06 * cheekK,
      );
    }
    debugPrint('[LocalRetouch] cheek volume (landmarks, max)');
  }

  if (jaw?.isConfirmedFillerOverfill == true) {
    _slimLowerFace(decoded, strength: 0.28);
  } else if (_wantsJowlSoftening(report, jaw) && !visibleBoost) {
    _softenAt(
      decoded,
      map,
      cx: map.mouthBottom.dx - s * 0.38,
      cy: map.mouthBottom.dy + s * 0.22,
      rx: s * 0.12,
      ry: s * 0.10,
      amount: 0.32,
      blurRadius: 3,
    );
    _softenAt(
      decoded,
      map,
      cx: map.mouthBottom.dx + s * 0.38,
      cy: map.mouthBottom.dy + s * 0.22,
      rx: s * 0.12,
      ry: s * 0.10,
      amount: 0.32,
      blurRadius: 3,
    );
  }

  debugPrint('[LocalRetouch] landmark zones applied');
}

void _applyFallbackRetouch(
  img.Image decoded,
  FaceAnalysisReport? report, {
  bool aggressiveVolume = true,
  bool allowLipVolume = false,
  bool visibleBoost = false,
  bool maximumBoost = false,
  bool softCapture = false,
}) {
  final k = softCapture
      ? (visibleBoost ? 1.85 : 1.35)
      : (maximumBoost ? 4.2 : (visibleBoost ? 1.75 : 1.0));
  final lips = _finding(report, 'lips');
  if ((aggressiveVolume || allowLipVolume || visibleBoost) &&
      (visibleBoost || _wantsLipVolume(report, lips))) {
    _inflateZone(
      decoded,
      0.50,
      0.64,
      0.13,
      0.075,
      strength: 0.10 * k,
    );
  }
  // Under-eye lower on face — avoids covering irises.
  _lightenUnderEyes(decoded, strength: 0.55 * k);
  _softenZone(
    decoded,
    0.50,
    0.16,
    0.24,
    0.10,
    amount: 0.50 * k,
    blurRadius: 5,
  );
  _softenZone(decoded, 0.50, 0.28, 0.07, 0.05, amount: 0.45 * k, blurRadius: 4);
  // Narrow vertical strips on the fold — not wide cheek circles.
  _softenZone(decoded, 0.40, 0.53, 0.045, 0.14, amount: 0.52 * k, blurRadius: 5);
  _softenZone(decoded, 0.60, 0.53, 0.045, 0.14, amount: 0.52 * k, blurRadius: 5);
  debugPrint('[LocalRetouch] gentle fallback (no landmarks)');
}

/// Direct RGB lift on mid/lower face — visible on slider when AI is unavailable.
void _boostLowerFace(img.Image im, FaceGlowMap map, {required double strength}) {
  final cx = map.faceCenter.dx;
  final cy = map.faceCenter.dy + map.faceScale * 0.08;
  final rx = map.faceScale * 0.42;
  final ry = map.faceScale * 0.38;
  for (var y = 0; y < im.height; y++) {
    for (var x = 0; x < im.width; x++) {
      final guard = FaceLandmarkService.upperFaceGuard(map, y);
      if (guard > 0.35) continue;
      final exclude = FaceLandmarkService.eyeExclusion(map, x, y);
      if (exclude > 0.25) continue;
      final w = _ellipseWeight(x, y, cx, cy, rx, ry);
      if (w <= 0) continue;
      final p = im.getPixel(x, y);
      final lift = 28 * strength * w;
      im.setPixelRgba(
        x,
        y,
        (p.r + lift).round().clamp(0, 255),
        (p.g + lift * 0.95).round().clamp(0, 255),
        (p.b + lift * 0.88).round().clamp(0, 255),
        255,
      );
    }
  }
}

void _lightenTearTrough(
  img.Image im,
  FaceGlowMap map, {
  required double cx,
  required double cy,
  required double rx,
  required double ry,
  required double strength,
}) {
  for (var y = 0; y < im.height; y++) {
    for (var x = 0; x < im.width; x++) {
      final guard = FaceLandmarkService.upperFaceGuard(map, y);
      if (guard > 0.5) continue;
      final lidFloor = math.min(map.leftEye.dy, map.rightEye.dy) + map.faceScale * 0.14;
      if (y < lidFloor) continue;
      final exclude = FaceLandmarkService.eyeExclusion(map, x, y);
      if (exclude > 0.35) continue;
      var w = _ellipseWeight(x, y, cx, cy, rx, ry) * (1 - exclude) * (1 - guard);
      final block = FaceLandmarkService.smileLineLightenBlock(map, x, y);
      w *= (1 - block * 0.85);
      w = w * w * (3 - 2 * w);
      if (w <= 0.04) continue;
      final p = im.getPixel(x, y);
      final l =
          0.299 * p.r.toDouble() + 0.587 * p.g.toDouble() + 0.114 * p.b.toDouble();
      if (l > 210) continue;
      final darkBoost = l < 105 ? 1.35 : (l < 135 ? 1.15 : 1.0);
      final lift = (195 - l) * strength * w * 0.45 * darkBoost;
      im.setPixelRgba(
        x,
        y,
        (p.r + lift).round().clamp(0, 255),
        (p.g + lift * 0.96).round().clamp(0, 255),
        (p.b + lift * 0.88).round().clamp(0, 255),
        255,
      );
    }
  }
}

/// Visible Russian-style filler — vertical plump on upper/lower lip + center pout.
void _applyRussianLipVolume(
  img.Image im,
  FaceGlowMap map, {
  required double strength,
}) {
  final s = map.faceScale;
  final mb = map.mouthBottom;
  final lipW = map.leftMouth != null && map.rightMouth != null
      ? (map.rightMouth!.dx - map.leftMouth!.dx).abs() * 0.62
      : s * 0.26;
  final cx = map.leftMouth != null && map.rightMouth != null
      ? (map.leftMouth!.dx + map.rightMouth!.dx) / 2
      : mb.dx;
  final cy = mb.dy - s * 0.02;

  _inflateAtAniso(
    im,
    map,
    cx,
    cy - s * 0.06,
    lipW * 0.50,
    s * 0.08,
    strengthX: 0.14 * strength,
    strengthY: 0.52 * strength,
  );
  _inflateAtAniso(
    im,
    map,
    cx,
    cy + s * 0.02,
    lipW * 0.52,
    s * 0.08,
    strengthX: 0.16 * strength,
    strengthY: 0.55 * strength,
  );
  _inflateAtAniso(
    im,
    map,
    cx,
    cy,
    lipW * 0.38,
    s * 0.09,
    strengthX: 0.12 * strength,
    strengthY: 0.44 * strength,
  );
  _inflateLipZone(
    im,
    map,
    cx,
    cy,
    lipW * 0.68,
    s * 0.15,
    strength: 0.32 * strength,
  );
}

void _inflateLipZone(
  img.Image im,
  FaceGlowMap map,
  double cx,
  double cy,
  double rx,
  double ry, {
  required double strength,
}) {
  final src = img.Image.from(im);
  for (var y = 0; y < im.height; y++) {
    for (var x = 0; x < im.width; x++) {
      if (FaceLandmarkService.chinExclusion(map, y) >= 0.85) continue;
      final w = _ellipseWeight(x, y, cx, cy, rx, ry);
      if (w <= 0) continue;
      final expand = 1 + strength * w;
      final sx = (cx + (x - cx) * expand).clamp(0, im.width - 1).toDouble();
      final sy = (cy + (y - cy) * expand).clamp(0, im.height - 1).toDouble();
      final c = _sampleBilinear(src, sx, sy);
      im.setPixelRgba(x, y, c[0], c[1], c[2], 255);
    }
  }
}

/// One continuous soften along the fold — no stacked circles near the nose.
void _softenNasolabialAlongFold(
  img.Image im,
  FaceGlowMap map, {
  required bool leftSide,
  required double strength,
  int blurRadius = 4,
}) {
  final s = map.faceScale;
  final nose = map.nose;
  final corner = FaceLandmarkService.mouthCorner(map, left: leftSide);
  final pad = s * 0.14;
  final x0 = math.min(nose.dx, corner.dx) - pad;
  final x1 = math.max(nose.dx, corner.dx) + pad;
  final y0 = math.min(nose.dy, corner.dy) - pad;
  final y1 = math.max(nose.dy, corner.dy) + pad;
  final ix0 = x0.round().clamp(0, im.width - 1);
  final iy0 = y0.round().clamp(0, im.height - 1);
  final ix1 = x1.round().clamp(ix0 + 1, im.width);
  final iy1 = y1.round().clamp(iy0 + 1, im.height);
  final patch = img.copyCrop(
    im,
    x: ix0,
    y: iy0,
    width: ix1 - ix0,
    height: iy1 - iy0,
  );
  final blurred = img.gaussianBlur(patch, radius: blurRadius);
  final maxD = s * 0.042;
  final featherD = s * 0.055;

  for (var y = iy0; y < iy1; y++) {
    for (var x = ix0; x < ix1; x++) {
      final along = FaceLandmarkService.alongNasolabialT(
        map,
        x.toDouble(),
        y.toDouble(),
        left: leftSide,
      );
      if (along < 0.48) continue;
      final d = FaceLandmarkService.distanceToNasolabial(
        map,
        x.toDouble(),
        y.toDouble(),
        left: leftSide,
      );
      if (d > featherD) continue;
      final edge = FaceLandmarkService.eyeExclusion(map, x, y);
      if (edge > 0.2) continue;
      final distFade = d <= maxD
          ? 1.0
          : (1 - (d - maxD) / (featherD - maxD)).clamp(0.0, 1.0);
      final lineW = (1 - d / featherD) * strength * distFade;
      final alongW = ((along - 0.48) / 0.52).clamp(0.0, 1.0);
      final w = (lineW * lineW * (3 - 2 * lineW) * alongW).clamp(0.0, 0.42);
      if (w <= 0.01) continue;
      final orig = im.getPixel(x, y);
      final b = blurred.getPixel(x - ix0, y - iy0);
      im.setPixelRgba(
        x,
        y,
        _blend(orig.r.toDouble(), b.r.toDouble(), w),
        _blend(orig.g.toDouble(), b.g.toDouble(), w),
        _blend(orig.b.toDouble(), b.b.toDouble(), w),
        255,
      );
    }
  }
}

/// Blends lip warp back to original at the outer lip edge (removes mouth-side line).
void _featherLipWarpSeams(img.Image im, FaceGlowMap map) {
  final src = img.Image.from(im);
  final s = map.faceScale;
  final mb = map.mouthBottom;
  final lipW = map.leftMouth != null && map.rightMouth != null
      ? (map.rightMouth!.dx - map.leftMouth!.dx).abs() * 0.72
      : s * 0.30;
  final cx = map.leftMouth != null && map.rightMouth != null
      ? (map.leftMouth!.dx + map.rightMouth!.dx) / 2
      : mb.dx;
  final cy = mb.dy - s * 0.02;
  final outerRx = lipW * 0.52;
  final outerRy = s * 0.20;

  for (var y = 0; y < im.height; y++) {
    for (var x = 0; x < im.width; x++) {
      final inner = _ellipseWeight(x, y, cx, cy, lipW * 0.38, s * 0.11);
      final outer = _ellipseWeight(x, y, cx, cy, outerRx, outerRy);
      if (outer <= inner || outer <= 0.12) continue;
      final ring = (outer - inner).clamp(0.0, 1.0);
      if (ring > 0.55) continue;
      final blend = (1 - ring / 0.55) * 0.72;
      final warped = im.getPixel(x, y);
      final orig = src.getPixel(x, y);
      im.setPixelRgba(
        x,
        y,
        _blend(warped.r, orig.r, blend),
        _blend(warped.g, orig.g, blend),
        _blend(warped.b, orig.b, blend),
        255,
      );
    }
  }
}

/// Soft micro-blur on mid-cheek to hide retouch patch boundaries.
void _blendRetouchSeams(img.Image im, FaceGlowMap map) {
  final s = map.faceScale;
  final eyeY = (map.leftEye.dy + map.rightEye.dy) / 2;
  final yMin = eyeY + s * 0.12;
  final yMax = map.mouthBottom.dy + s * 0.08;
  final xPad = s * 0.55;
  final cx = map.faceCenter.dx;
  final x0 = (cx - xPad).round().clamp(0, im.width - 1);
  final x1 = (cx + xPad).round().clamp(x0 + 1, im.width);
  final y0 = yMin.round().clamp(0, im.height - 1);
  final y1 = yMax.round().clamp(y0 + 1, im.height);
  final patch = img.copyCrop(im, x: x0, y: y0, width: x1 - x0, height: y1 - y0);
  final blurred = img.gaussianBlur(patch, radius: 2);

  for (var y = y0; y < y1; y++) {
    for (var x = x0; x < x1; x++) {
      if (FaceLandmarkService.eyeNaturalPreserveWeight(map, x, y) > 0.25) {
        continue;
      }
      if (FaceLandmarkService.lipColorPreserveWeight(map, x, y) > 0.35) {
        continue;
      }
      final orig = im.getPixel(x, y);
      final b = blurred.getPixel(x - x0, y - y0);
      const w = 0.22;
      im.setPixelRgba(
        x,
        y,
        _blend(orig.r.toDouble(), b.r.toDouble(), w),
        _blend(orig.g.toDouble(), b.g.toDouble(), w),
        _blend(orig.b.toDouble(), b.b.toDouble(), w),
        255,
      );
    }
  }
}

void _inflateAtAniso(
  img.Image im,
  FaceGlowMap map,
  double cx,
  double cy,
  double rx,
  double ry, {
  required double strengthX,
  required double strengthY,
}) {
  if (strengthX <= 0 && strengthY <= 0) return;
  final src = img.Image.from(im);

  for (var y = 0; y < im.height; y++) {
    for (var x = 0; x < im.width; x++) {
      final chin = FaceLandmarkService.chinExclusion(map, y);
      if (chin >= 0.85) continue;
      final w = _ellipseWeight(x, y, cx, cy, rx, ry) * (1 - chin);
      if (w <= 0) continue;
      final expandX = 1 + strengthX * w;
      final expandY = 1 + strengthY * w;
      final sx = (cx + (x - cx) * expandX).clamp(0, im.width - 1).toDouble();
      final sy = (cy + (y - cy) * expandY).clamp(0, im.height - 1).toDouble();
      final c = _sampleBilinear(src, sx, sy);
      im.setPixelRgba(x, y, c[0], c[1], c[2], 255);
    }
  }
}

void _applyLipSymmetryPasses(
  img.Image im,
  FaceGlowMap map, {
  required bool force,
}) {
  _correctLipSymmetry(im, map, force: force);
  if (force || FaceLandmarkService.lipsNeedVolumeSymmetry(map)) {
    _balanceLipVolumeSymmetry(im, map, force: force);
  }
}

/// Vertical warp so mouth corners sit level.
void _correctLipSymmetry(
  img.Image im,
  FaceGlowMap map, {
  bool force = false,
}) {
  final left = FaceLandmarkService.mouthCorner(map, left: true);
  final right = FaceLandmarkService.mouthCorner(map, left: false);
  final devY = left.dy - right.dy;
  final s = map.faceScale;
  final minDev = force ? s * 0.002 : s * 0.008;
  if (devY.abs() < minDev) return;

  final cx = (left.dx + right.dx) * 0.5;
  final cy = map.mouthBottom.dy - s * 0.05;
  final rx = ((right.dx - left.dx).abs() * 0.54).clamp(s * 0.20, s * 0.44);
  final ry = s * 0.17;
  final src = img.Image.from(im);
  final shift = devY * (force ? 0.72 : 0.48);

  for (var y = 0; y < im.height; y++) {
    for (var x = 0; x < im.width; x++) {
      final lipW = FaceLandmarkService.lipColorPreserveWeight(map, x, y);
      if (lipW < 0.14) continue;
      var w = _ellipseWeight(x, y, cx, cy, rx, ry) * lipW;
      w = w * w * (3 - 2 * w);
      if (w <= 0.04) continue;
      final side = x < cx ? -1.0 : 1.0;
      final sy = (y - shift * side * w).clamp(0, im.height - 1).toDouble();
      final c = _sampleBilinear(src, x.toDouble(), sy);
      im.setPixelRgba(x, y, c[0], c[1], c[2], 255);
    }
  }
  debugPrint(
    '[LocalRetouch] lip symmetry (corner Δy=${devY.toStringAsFixed(1)}px)',
  );
}

/// Subtle horizontal plump on the thinner lip half (cupid's bow / vermillion balance).
void _balanceLipVolumeSymmetry(
  img.Image im,
  FaceGlowMap map, {
  bool force = false,
}) {
  final delta = FaceLandmarkService.lipHalfWidthDelta(map);
  final s = map.faceScale;
  final minDelta = force ? s * 0.010 : s * 0.018;
  if (delta.abs() < minDelta) return;

  final left = FaceLandmarkService.mouthCorner(map, left: true);
  final right = FaceLandmarkService.mouthCorner(map, left: false);
  final cx = (left.dx + right.dx) * 0.5;
  final cy = map.mouthBottom.dy - s * 0.07;
  final lipW = (right.dx - left.dx).abs() * 0.48;
  final thinnerOnLeft = delta < 0;
  final targetCx = thinnerOnLeft ? cx - lipW * 0.22 : cx + lipW * 0.22;
  final strength = (force ? 0.14 : 0.08) * (delta.abs() / (s * 0.06)).clamp(0.55, 1.25);

  _inflateAtAniso(
    im,
    map,
    targetCx,
    cy,
    lipW * 0.38,
    s * 0.08,
    strengthX: strength,
    strengthY: strength * 0.7,
  );
  debugPrint(
    '[LocalRetouch] lip volume symmetry (Δwidth=${delta.toStringAsFixed(1)}px)',
  );
}

/// Horizontal warp to center a visibly deviated nasal tip (landmark-guided).
void _correctNoseTipAsymmetry(img.Image im, FaceGlowMap map) {
  final dev = FaceLandmarkService.noseTipDeviation(map);
  final s = map.faceScale;
  if (dev.abs() < s * 0.018) return;

  final shiftPx = -dev * 0.48;
  final cx = map.nose.dx;
  final cy = map.nose.dy - s * 0.06;
  final rx = s * 0.24;
  final ry = s * 0.30;
  final src = img.Image.from(im);

  for (var y = 0; y < im.height; y++) {
    for (var x = 0; x < im.width; x++) {
      final w = _ellipseWeight(x, y, cx, cy, rx, ry);
      if (w <= 0) continue;
      final sx = (x - shiftPx * w).clamp(0, im.width - 1).toDouble();
      final c = _sampleBilinear(src, sx, y.toDouble());
      im.setPixelRgba(x, y, c[0], c[1], c[2], 255);
    }
  }
  debugPrint(
    '[LocalRetouch] nose tip centered (dev=${dev.toStringAsFixed(1)}px shift=${shiftPx.toStringAsFixed(1)})',
  );
}

/// Removes chin bump from lip warp / marionette artifacts.
void _cleanChinArtifact(img.Image im, FaceGlowMap map) {
  final mb = map.mouthBottom;
  final s = map.faceScale;
  _softenAt(
    im,
    map,
    cx: mb.dx,
    cy: mb.dy + s * 0.10,
    rx: s * 0.10,
    ry: s * 0.05,
    amount: 0.38,
    blurRadius: 3,
  );
}

void _softenNasolabialStrip(
  img.Image im,
  FaceGlowMap map, {
  required bool leftSide,
  required double strength,
  int blurRadius = 3,
}) {
  _softenNasolabialAlongFold(
    im,
    map,
    leftSide: leftSide,
    strength: strength,
    blurRadius: blurRadius,
  );
}

void _softenAt(
  img.Image im,
  FaceGlowMap map, {
  required double cx,
  required double cy,
  required double rx,
  required double ry,
  required double amount,
  required int blurRadius,
}) {
  final patch = img.copyCrop(
    im,
    x: (cx - rx).round().clamp(0, im.width - 1),
    y: (cy - ry).round().clamp(0, im.height - 1),
    width: (rx * 2).round().clamp(1, im.width),
    height: (ry * 2).round().clamp(1, im.height),
  );
  final blurred = img.gaussianBlur(patch, radius: blurRadius);
  final ox = (cx - rx).round();
  final oy = (cy - ry).round();

  for (var py = 0; py < patch.height; py++) {
    for (var px = 0; px < patch.width; px++) {
      final x = ox + px;
      final y = oy + py;
      if (x < 0 || x >= im.width || y < 0 || y >= im.height) continue;
      final guard = FaceLandmarkService.upperFaceGuard(map, y);
      if (guard > 0.5) continue;
      final exclude = FaceLandmarkService.eyeExclusion(map, x, y);
      if (exclude > 0.4) continue;
      final w = _ellipseWeight(x, y, cx, cy, rx, ry) *
          (1 - exclude) *
          (1 - guard) *
          amount;
      if (w <= 0) continue;
      final orig = im.getPixel(x, y);
      final b = blurred.getPixel(px, py);
      im.setPixelRgba(
        x,
        y,
        _blend(orig.r.toDouble(), b.r.toDouble(), w),
        _blend(orig.g.toDouble(), b.g.toDouble(), w),
        _blend(orig.b.toDouble(), b.b.toDouble(), w),
        255,
      );
    }
  }
}

void _inflateAt(
  img.Image im,
  double cx,
  double cy,
  double rx,
  double ry, {
  required double strength,
}) {
  _inflateZone(im, cx / im.width, cy / im.height, rx / im.width, ry / im.height, strength: strength);
}

void _deflateAt(
  img.Image im,
  double cx,
  double cy,
  double rx,
  double ry,
  double strength,
) {
  _deflateZone(im, cx / im.width, cy / im.height, rx / im.width, ry / im.height, strength: strength);
}

void _enhanceLipColorAt(
  img.Image im,
  double cx,
  double cy,
  double rx,
  double ry, {
  required double strength,
}) {
  for (var y = 0; y < im.height; y++) {
    for (var x = 0; x < im.width; x++) {
      final w = _ellipseWeight(x, y, cx, cy, rx, ry) * strength;
      if (w <= 0) continue;
      final p = im.getPixel(x, y);
      im.setPixelRgba(
        x,
        y,
        (p.r + 16 * w).round().clamp(0, 255),
        (p.g + 5 * w).round().clamp(0, 255),
        (p.b + 4 * w).round().clamp(0, 255),
        255,
      );
    }
  }
}

FaceFinding? _finding(FaceAnalysisReport? report, String area) {
  if (report == null) return null;
  for (final f in report.findings) {
    if (f.area.toLowerCase() == area.toLowerCase()) return f;
  }
  return null;
}

bool _wantsLipVolume(FaceAnalysisReport? report, FaceFinding? lips) {
  if (report?.plansLipEnhancement == true) return true;
  if (lips == null) return false;
  final s = lips.status.toLowerCase();
  return s.contains('thin') ||
      s.contains('flat') ||
      s.contains('deficient') ||
      s.contains('volume') ||
      lips.showsNaturalAging;
}

bool _wantsCheekVolume(FaceAnalysisReport? report, FaceFinding? cheeks) {
  if (cheeks == null) return true;
  final s = cheeks.status.toLowerCase();
  return s.contains('volume') ||
      s.contains('hollow') ||
      s.contains('flat') ||
      s.contains('thin') ||
      s.contains('sag') ||
      cheeks.showsNaturalAging;
}

bool _wantsJowlSoftening(FaceAnalysisReport? report, FaceFinding? jaw) {
  if (jaw == null) return report != null;
  final s = jaw.status.toLowerCase();
  return s.contains('sag') ||
      s.contains('lax') ||
      s.contains('jowl') ||
      jaw.showsNaturalAging;
}

void _inflateZone(
  img.Image im,
  double cxN,
  double cyN,
  double rxN,
  double ryN, {
  required double strength,
}) {
  final src = img.Image.from(im);
  final cx = cxN * im.width;
  final cy = cyN * im.height;
  final rx = rxN * im.width;
  final ry = ryN * im.height;

  for (var y = 0; y < im.height; y++) {
    for (var x = 0; x < im.width; x++) {
      final w = _ellipseWeight(x, y, cx, cy, rx, ry);
      if (w <= 0) continue;
      final expand = 1 + strength * w;
      final sx = (cx + (x - cx) * expand).clamp(0, im.width - 1).toDouble();
      final sy = (cy + (y - cy) * expand).clamp(0, im.height - 1).toDouble();
      final c = _sampleBilinear(src, sx, sy);
      im.setPixelRgba(x, y, c[0], c[1], c[2], 255);
    }
  }
}

void _enhanceLipColor(img.Image im, {required double strength}) {
  final cx = im.width * 0.5;
  final cy = im.height * 0.64;
  final rx = im.width * 0.14;
  final ry = im.height * 0.075;
  for (var y = 0; y < im.height; y++) {
    for (var x = 0; x < im.width; x++) {
      final w = _ellipseWeight(x, y, cx, cy, rx, ry) * strength;
      if (w <= 0) continue;
      final p = im.getPixel(x, y);
      final r = p.r.toDouble();
      final g = p.g.toDouble();
      final b = p.b.toDouble();
      im.setPixelRgba(
        x,
        y,
        (r + 18 * w).round().clamp(0, 255),
        (g + 6 * w).round().clamp(0, 255),
        (b + 4 * w).round().clamp(0, 255),
        255,
      );
    }
  }
}

void _deflateZone(
  img.Image im,
  double cxN,
  double cyN,
  double rxN,
  double ryN, {
  required double strength,
}) {
  final src = img.Image.from(im);
  final cx = cxN * im.width;
  final cy = cyN * im.height;
  final rx = rxN * im.width;
  final ry = ryN * im.height;

  for (var y = 0; y < im.height; y++) {
    for (var x = 0; x < im.width; x++) {
      final w = _ellipseWeight(x, y, cx, cy, rx, ry);
      if (w <= 0) continue;
      final pinch = 1 + strength * w;
      final sx = (cx + (x - cx) / pinch).clamp(0, im.width - 1).toDouble();
      final sy = (cy + (y - cy) / pinch).clamp(0, im.height - 1).toDouble();
      final c = _sampleBilinear(src, sx, sy);
      im.setPixelRgba(x, y, c[0], c[1], c[2], 255);
    }
  }
}

void _slimLowerFace(img.Image im, {required double strength}) {
  final src = img.Image.from(im);
  final cy = im.height * 0.62;
  for (var y = 0; y < im.height; y++) {
    for (var x = 0; x < im.width; x++) {
      if (y < cy) continue;
      final edge = x < im.width * 0.22 || x > im.width * 0.78;
      if (!edge) continue;
      final pinch = 1 + strength * 0.15;
      final cx = im.width * 0.5;
      final sx = (cx + (x - cx) / pinch).clamp(0, im.width - 1).toDouble();
      final c = _sampleBilinear(src, sx, y.toDouble());
      final blend = strength * 0.85;
      final p = im.getPixel(x, y);
      im.setPixelRgba(
        x,
        y,
        _blend(p.r.toDouble(), c[0].toDouble(), blend),
        _blend(p.g.toDouble(), c[1].toDouble(), blend),
        _blend(p.b.toDouble(), c[2].toDouble(), blend),
        255,
      );
    }
  }
}

List<int> _sampleBilinear(img.Image im, double x, double y) {
  final x0 = x.floor().clamp(0, im.width - 1);
  final y0 = y.floor().clamp(0, im.height - 1);
  final x1 = (x0 + 1).clamp(0, im.width - 1);
  final y1 = (y0 + 1).clamp(0, im.height - 1);
  final tx = x - x0;
  final ty = y - y0;
  final p00 = im.getPixel(x0, y0);
  final p10 = im.getPixel(x1, y0);
  final p01 = im.getPixel(x0, y1);
  final p11 = im.getPixel(x1, y1);
  int ch(num a, num b, num c, num d) =>
      (a * (1 - tx) * (1 - ty) +
              b * tx * (1 - ty) +
              c * (1 - tx) * ty +
              d * tx * ty)
          .round()
          .clamp(0, 255);
  return [
    ch(p00.r, p10.r, p01.r, p11.r),
    ch(p00.g, p10.g, p01.g, p11.g),
    ch(p00.b, p10.b, p01.b, p11.b),
  ];
}

void _lightenUnderEyes(img.Image im, {required double strength}) {
  _lightenZone(im, 0.36, 0.48, 0.12, 0.065, strength);
  _lightenZone(im, 0.64, 0.48, 0.12, 0.065, strength);
}

void _lightenZone(
  img.Image im,
  double cxN,
  double cyN,
  double rxN,
  double ryN,
  double strength,
) {
  final cx = cxN * im.width;
  final cy = cyN * im.height;
  final rx = rxN * im.width;
  final ry = ryN * im.height;

  for (var y = 0; y < im.height; y++) {
    for (var x = 0; x < im.width; x++) {
      final w = _ellipseWeight(x, y, cx, cy, rx, ry);
      if (w <= 0) continue;
      final p = im.getPixel(x, y);
      final l =
          0.299 * p.r.toDouble() + 0.587 * p.g.toDouble() + 0.114 * p.b.toDouble();
      if (l > 200) continue;
      final lift = (200 - l) * strength * w * 0.72;
      im.setPixelRgba(
        x,
        y,
        (p.r + lift).round().clamp(0, 255),
        (p.g + lift * 0.96).round().clamp(0, 255),
        (p.b + lift * 0.88).round().clamp(0, 255),
        255,
      );
    }
  }
}

void _softenZone(
  img.Image im,
  double cxN,
  double cyN,
  double rxN,
  double ryN, {
  required double amount,
  int blurRadius = 3,
}) {
  final x0 = math.max(0, (cxN * im.width - rxN * im.width).floor());
  final y0 = math.max(0, (cyN * im.height - ryN * im.height).floor());
  final patchW = (rxN * im.width * 2).round().clamp(1, im.width - x0);
  final patchH = (ryN * im.height * 2).round().clamp(1, im.height - y0);

  final patch = img.copyCrop(
    im,
    x: x0,
    y: y0,
    width: patchW,
    height: patchH,
  );
  final blurred = img.gaussianBlur(patch, radius: blurRadius);
  final cx = cxN * im.width;
  final cy = cyN * im.height;
  final rx = rxN * im.width;
  final ry = ryN * im.height;

  for (var y = y0; y < im.height && y < cy + ry; y++) {
    for (var x = x0; x < im.width && x < cx + rx; x++) {
      final w = _ellipseWeight(x, y, cx, cy, rx, ry) * amount;
      if (w <= 0) continue;
      final bx = (x - x0).clamp(0, blurred.width - 1);
      final by = (y - y0).clamp(0, blurred.height - 1);
      final o = im.getPixel(x, y);
      final b = blurred.getPixel(bx, by);
      im.setPixelRgba(
        x,
        y,
        _blend(o.r.toDouble(), b.r.toDouble(), w),
        _blend(o.g.toDouble(), b.g.toDouble(), w),
        _blend(o.b.toDouble(), b.b.toDouble(), w),
        255,
      );
    }
  }
}

void _evenSkinTone(img.Image im, {required double strength}) {
  final cx = im.width * 0.5;
  final cy = im.height * 0.45;
  final rx = im.width * 0.28;
  final ry = im.height * 0.35;
  var sumR = 0.0, sumG = 0.0, sumB = 0.0, n = 0;
  for (var y = 0; y < im.height; y++) {
    for (var x = 0; x < im.width; x++) {
      if (_ellipseWeight(x, y, cx, cy, rx, ry) < 0.5) continue;
      final p = im.getPixel(x, y);
      sumR += p.r.toDouble();
      sumG += p.g.toDouble();
      sumB += p.b.toDouble();
      n++;
    }
  }
  if (n == 0) return;
  final avgR = sumR / n;
  final avgG = sumG / n;
  final avgB = sumB / n;

  for (var y = 0; y < im.height; y++) {
    for (var x = 0; x < im.width; x++) {
      final w = _ellipseWeight(x, y, cx, cy, rx, ry) * strength;
      if (w <= 0) continue;
      final p = im.getPixel(x, y);
      im.setPixelRgba(
        x,
        y,
        _blend(p.r.toDouble(), avgR, w * 0.14),
        _blend(p.g.toDouble(), avgG, w * 0.14),
        _blend(p.b.toDouble(), avgB, w * 0.14),
        255,
      );
    }
  }
}

void _unsharpFace(img.Image im, {required double amount}) {
  final blurred = img.gaussianBlur(img.Image.from(im), radius: 1);
  final cx = im.width * 0.5;
  final cy = im.height * 0.42;
  final rx = im.width * 0.30;
  final ry = im.height * 0.38;

  for (var y = 0; y < im.height; y++) {
    for (var x = 0; x < im.width; x++) {
      final w = _ellipseWeight(x, y, cx, cy, rx, ry);
      if (w <= 0) continue;
      final o = im.getPixel(x, y);
      final b = blurred.getPixel(x, y);
      im.setPixelRgba(
        x,
        y,
        (o.r + (o.r - b.r) * amount * w).round().clamp(0, 255),
        (o.g + (o.g - b.g) * amount * w).round().clamp(0, 255),
        (o.b + (o.b - b.b) * amount * w).round().clamp(0, 255),
        255,
      );
    }
  }
}

int _blend(num a, num b, double w) => (a * (1 - w) + b * w).round().clamp(0, 255);

double _ellipseWeight(num x, num y, double cx, double cy, double rx, double ry) {
  final dx = (x.toDouble() - cx) / rx;
  final dy = (y.toDouble() - cy) / ry;
  final d2 = dx * dx + dy * dy;
  if (d2 >= 1) return 0;
  if (d2 <= 0.25) return 1;
  final t = (1 - math.sqrt(d2)) / 0.5;
  return t * t * (3 - 2 * t);
}
