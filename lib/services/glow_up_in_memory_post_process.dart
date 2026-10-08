import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'face_landmark_service.dart';
import 'glow_up_edit_composite.dart';
import 'glow_up_face_analysis_service.dart';
import 'local_glow_retouch.dart';
import 'photo_processor.dart';

/// Single encode after all pixel passes — avoids stacked JPEG artefacts.
const int kGlowProcessJpegQuality = 96;

/// Options mirrored from [GlowUpPipeline] env flags.
class GlowUpPostProcessOptions {
  const GlowUpPostProcessOptions({
    required this.chatGptStyle,
    required this.harmonizeFaceColor,
    required this.neutralizeWarmAfterSkin,
    required this.preserveBrows,
    required this.preserveEyesLips,
    required this.applyLocalPass,
    required this.healInpaintSpecks,
  });

  final bool chatGptStyle;
  final bool harmonizeFaceColor;
  final bool neutralizeWarmAfterSkin;
  final bool preserveBrows;
  final bool preserveEyesLips;
  final bool applyLocalPass;
  final bool healInpaintSpecks;
}

Future<String> saveGlowProcessedImage(
  img.Image image, {
  String tag = 'glow_out',
}) async {
  final docs = await getApplicationDocumentsDirectory();
  final dir = Directory('${docs.path}/photos');
  if (!await dir.exists()) await dir.create(recursive: true);
  final out = File('${dir.path}/${tag}_${const Uuid().v4()}.jpg');
  await out.writeAsBytes(
    img.encodeJpg(image, quality: kGlowProcessJpegQuality),
    flush: true,
  );
  debugPrint('[GlowUp] post-AI pipeline → single JPEG ${out.path}');
  return out.path;
}

/// Mean RGB delta in face hull (0 = identical).
double faceEditDeltaMeanImages(img.Image studio, img.Image edit) {
  final after = edit.width == studio.width && edit.height == studio.height
      ? edit
      : letterboxToSize(edit, studio.width, studio.height);

  final map = FaceLandmarkService.detectFromImage(studio);
  var sum = 0.0;
  var n = 0;
  for (var y = 0; y < studio.height; y++) {
    for (var x = 0; x < studio.width; x++) {
      final w = map != null
          ? FaceLandmarkService.faceStudioSensorWeight(map, x, y)
          : _fallbackFaceWeight(studio, x, y);
      if (w < 0.12) continue;
      final p0 = studio.getPixel(x, y);
      final p1 = after.getPixel(x, y);
      sum += (p0.r - p1.r).abs() +
          (p0.g - p1.g).abs() +
          (p0.b - p1.b).abs();
      n++;
    }
  }
  if (n == 0) return 0;
  return sum / (n * 3);
}

double _fallbackFaceWeight(img.Image im, int x, int y) {
  final cx = im.width * 0.5;
  final cy = im.height * 0.42;
  final rx = im.width * 0.28;
  final ry = im.height * 0.36;
  final dx = (x - cx) / rx;
  final dy = (y - cy) / ry;
  final d2 = dx * dx + dy * dy;
  if (d2 >= 1) return 0;
  final t = 1 - d2;
  return t * t * (3 - 2 * t);
}

/// All post-AI pixel work in RAM → one JPEG write.
Future<String> runPostAiEditPipeline({
  required String studioPath,
  required String editedPath,
  required FaceAnalysisReport report,
  required GlowUpPostProcessOptions opts,
  bool softCapture = false,
  String? rawPhotoPath,
  double minEditDelta = 2.0,
  bool needsVisiblePreview = true,
}) async {
  final studioBytes = await File(studioPath).readAsBytes();
  final editBytes = await File(editedPath).readAsBytes();
  final studio = img.decodeImage(studioBytes);
  final rawEdit = img.decodeImage(editBytes);
  if (studio == null || rawEdit == null) return editedPath;

  var edit = letterboxToSize(rawEdit, studio.width, studio.height);
  final studioMap = FaceLandmarkService.detectFromImage(studio);
  final editMap =
      FaceLandmarkService.detectFromImage(edit) ?? studioMap;

  if (opts.healInpaintSpecks) {
    edit = healFaceInpaintSpecksOnImage(studio, edit, faceMap: studioMap);
  }
  if (editMap != null) {
    edit = healOuterEyeDarkMarksOnImage(edit, editMap);
  }

  if (!opts.chatGptStyle && editMap != null) {
    lightenUnderEyeDarkCirclesOnImage(
      edit,
      editMap,
      strength: 0.34,
    );
  }

  if (opts.harmonizeFaceColor &&
      !opts.chatGptStyle &&
      studioMap != null &&
      editMap != null) {
    edit = harmonizeAfterFaceColorOnImage(studio, edit, editMap);
  }

  if (opts.neutralizeWarmAfterSkin && studioMap != null) {
    edit = neutralizeWarmSkinCast(studio, edit, map: studioMap);
  }

  if (blackStudioEdgeScore(edit) < 0.52 && studioMap != null) {
    edit = sanitizeStudioPortraitMild(edit, protectMap: studioMap);
  }

  var prePolish = faceEditDeltaMeanImages(studio, edit);

  if (prePolish < minEditDelta * 1.5) {
    edit = applyClinicLocalPolishOnImage(
      edit,
      report: report,
      softCapture: softCapture,
    );
    prePolish = faceEditDeltaMeanImages(studio, edit);
  } else {
    debugPrint(
      '[GlowUp] skipping local polish — AI delta=$prePolish (strong edit)',
    );
  }

  if (softCapture && prePolish < minEditDelta * 1.5) {
    applySoftCaptureLineSofteningOnImage(edit, report: report);
  } else if (opts.applyLocalPass && prePolish < minEditDelta * 1.5) {
    edit = applyClinicLocalPolishOnImage(
      edit,
      report: report,
      softCapture: softCapture,
      force: true,
      gentle: true,
    );
  }

  final skipFeatureRestore = prePolish >= minEditDelta * 1.5;
  if (skipFeatureRestore) {
    debugPrint(
      '[GlowUp] skipping brow/eye/lip preserve — AI delta=$prePolish',
    );
  }

  if (opts.preserveBrows && !skipFeatureRestore) {
    try {
      edit = await preserveEyebrowsOnImage(
        studio: studio,
        edit: edit,
        rawPhotoPath: rawPhotoPath,
      );
    } catch (e) {
      debugPrint('[GlowUp] brow preserve failed: $e');
    }
  }

  final skipLipPreserve = report.plansUnderEyeTreatment ||
      report.plansSmileLineTreatment ||
      report.plansLipSymmetry ||
      report.plansLipEnhancement;

  if (opts.preserveEyesLips && studioMap != null && editMap != null) {
    edit = preserveEyesNaturalOnImage(studio, edit, studioMap, editMap);
    if (!skipFeatureRestore && !skipLipPreserve) {
      edit = preserveLipsNaturalOnImage(studio, edit, studioMap, editMap);
    }
  }

  final stillSubtle = _linesStillTooSubtleImages(studio, edit);
  final strongLines = stillSubtle || report.plansSmileLineTreatment;
  if (editMap != null) {
    applyPlannedTreatmentFinishOnImage(
      edit,
      editMap,
      report,
      strongSmileLines: strongLines,
    );
  } else {
    applyPostAiTargetedFinishOnImage(
      edit,
      report: report,
      strong: strongLines,
    );
  }

  if (studioMap != null && editMap != null) {
    final (healed, fixed) =
        healOuterCanthusResidualsOnImage(studio, edit, editMap);
    if (fixed >= 4) edit = healed;
  }

  final delta = faceEditDeltaMeanImages(studio, edit);
  if (delta < minEditDelta && needsVisiblePreview) {
    debugPrint(
      '[GlowUp] AI delta=$delta still too low — clinic visible fallback',
    );
    edit = applyClinicVisibleFallbackOnImage(
      studio,
      report: report,
      softCapture: softCapture,
    );
    if (opts.preserveBrows && rawPhotoPath != null) {
      try {
        edit = await preserveEyebrowsOnImage(
          studio: studio,
          edit: edit,
          rawPhotoPath: rawPhotoPath,
        );
      } catch (_) {}
    }
  }

  return saveGlowProcessedImage(edit, tag: 'glow_processed');
}

bool _linesStillTooSubtleImages(img.Image studio, img.Image edit) {
  final zones = <(double, double, double, double)>[
    (0.38, 0.54, 0.24, 0.14),
    (0.62, 0.54, 0.24, 0.14),
    (0.36, 0.40, 0.28, 0.10),
    (0.64, 0.40, 0.28, 0.10),
  ];
  for (final z in zones) {
    final d = _zoneDeltaMean(studio, edit, z.$1, z.$2, z.$3, z.$4);
    if (d < 6) return true;
  }
  return false;
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
