import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../ui/photo_storage.dart';
import 'face_landmark_service.dart';
import 'glow_up/clinic_prompt_builder.dart';
import 'local_glow_retouch.dart';
import 'openai_image_edit_service.dart';
import 'photo_processor.dart'
    show
        blackStudioEdgeScore,
        polishStudioBeforeFile,
        sanitizeStudioPortrait,
        studioBackdrop;

/// Merges aligned AI edit onto studio photo — black bg stays from studio,
/// subject pixels from AI (no oval mask → no vertical seam).
Uint8List compositeGlowUpOnOriginal(
  List<int> inputBytes,
  List<int> outputBytes, {
  double editStrength = 1.0,
}) {
  final strength = editStrength.clamp(0.0, 1.0);
  final inp = img.decodeImage(Uint8List.fromList(inputBytes));
  final rawOut = img.decodeImage(Uint8List.fromList(outputBytes));
  if (inp == null || rawOut == null) {
    return Uint8List.fromList(outputBytes);
  }

  final out = rawOut.width == inp.width && rawOut.height == inp.height
      ? rawOut
      : img.copyResize(
          rawOut,
          width: inp.width,
          height: inp.height,
          interpolation: img.Interpolation.cubic,
        );

  final aligned = out.width == inp.width && out.height == inp.height
      ? out
      : _alignSubjectToReference(inp, out);
  final refB = _subjectBounds(inp);
  debugPrint('[GlowUpComposite] silhouette merge ${inp.width}x${inp.height}');

  var result = img.Image.from(inp);
  if (refB == null) return Uint8List.fromList(img.encodeJpg(result, quality: 96));

  final blurredOrig = img.gaussianBlur(img.Image.from(inp), radius: 1);
  // Lower detail pull-back when blend < 1 — avoids ghosting if AI face shifts slightly.
  final detailPreserve = (0.12 + strength * 0.28).clamp(0.12, 0.45);

  for (var y = 0; y < inp.height; y++) {
    for (var x = 0; x < inp.width; x++) {
      if (_luminance(inp.getPixel(x, y)) <= 28) continue;

      final pa = aligned.getPixel(x, y);
      if (_luminance(pa) <= 28) continue;

      final w = _subjectFeather(x, y, refB) * strength;
      if (w <= 0) continue;

      final ps = inp.getPixel(x, y);
      final bl = blurredOrig.getPixel(x, y);
      var r = _blendChannel(ps.r, pa.r, w);
      var g = _blendChannel(ps.g, pa.g, w);
      var b = _blendChannel(ps.b, pa.b, w);
      r = (r + (ps.r - bl.r) * detailPreserve).round().clamp(0, 255);
      g = (g + (ps.g - bl.g) * detailPreserve).round().clamp(0, 255);
      b = (b + (ps.b - bl.b) * detailPreserve).round().clamp(0, 255);
      result.setPixelRgba(x, y, r, g, b, 255);
    }
  }

  result = _sharpenSubjectImage(result, amount: 0.14);
  return Uint8List.fromList(img.encodeJpg(result, quality: 96));
}

/// Tight face crop so editors keep framing (avoids FLUX zooming out).
class FaceEditCropSpec {
  const FaceEditCropSpec({
    required this.cropPath,
    required this.offsetX,
    required this.offsetY,
    required this.cropWidth,
    required this.cropHeight,
  });

  final String cropPath;
  final int offsetX;
  final int offsetY;
  final int cropWidth;
  final int cropHeight;
}

Future<FaceEditCropSpec?> prepareFaceEditCrop(String studioPath) async {
  final bytes = await File(studioPath).readAsBytes();
  final im = img.decodeImage(bytes);
  if (im == null) return null;

  final b = _subjectBounds(im);
  if (b == null) return null;

  final subW = b.right - b.left;
  final subH = b.bottom - b.top;
  if (subW < 48 || subH < 48) return null;

  final padX = (subW * 0.06).round().clamp(8, 56);
  final padY = (subH * 0.08).round().clamp(12, 72);

  final left = (b.left - padX).clamp(0, im.width - 1);
  final top = (b.top - padY).clamp(0, im.height - 1);
  final right = (b.right + padX).clamp(left + 1, im.width);
  final bottom = (b.bottom + padY).clamp(top + 1, im.height);
  final w = right - left;
  final h = bottom - top;
  if (w < 96 || h < 96) return null;

  final cropped = img.copyCrop(im, x: left, y: top, width: w, height: h);
  final docs = await getApplicationDocumentsDirectory();
  final dir = Directory('${docs.path}/photos');
  if (!await dir.exists()) await dir.create(recursive: true);
  final out = File('${dir.path}/glow_face_crop_${const Uuid().v4()}.jpg');
  await out.writeAsBytes(img.encodeJpg(cropped, quality: 94), flush: true);
  debugPrint('[GlowUpComposite] face crop ${w}x$h at ($left,$top)');
  return FaceEditCropSpec(
    cropPath: out.path,
    offsetX: left,
    offsetY: top,
    cropWidth: w,
    cropHeight: h,
  );
}

Future<String> mergeFaceEditIntoStudio({
  required String studioPath,
  required FaceEditCropSpec crop,
  required String editedPath,
}) async {
  final studio = img.decodeImage(await File(studioPath).readAsBytes());
  final edit = img.decodeImage(await File(editedPath).readAsBytes());
  if (studio == null || edit == null) return editedPath;

  final patch = img.copyResize(
    edit,
    width: crop.cropWidth,
    height: crop.cropHeight,
    interpolation: img.Interpolation.linear,
  );

  final result = img.Image.from(studio);
  for (var y = 0; y < crop.cropHeight; y++) {
    for (var x = 0; x < crop.cropWidth; x++) {
      final tx = crop.offsetX + x;
      final ty = crop.offsetY + y;
      if (tx >= studio.width || ty >= studio.height) continue;
      final pe = patch.getPixel(x, y);
      if (_luminance(pe) <= 28) continue;
      result.setPixel(tx, ty, pe);
    }
  }

  final docs = await getApplicationDocumentsDirectory();
  final dir = Directory('${docs.path}/photos');
  if (!await dir.exists()) await dir.create(recursive: true);
  final out = File('${dir.path}/glow_merged_${const Uuid().v4()}.jpg');
  await out.writeAsBytes(img.encodeJpg(result, quality: 94), flush: true);
  debugPrint('[GlowUpComposite] pasted face edit → ${out.path}');
  return out.path;
}

/// Fits [src] into [targetW]×[targetH] on black without stretching aspect ratio.
img.Image letterboxToSize(img.Image src, int targetW, int targetH) {
  if (src.width == targetW && src.height == targetH) return src;

  final scale = math.min(targetW / src.width, targetH / src.height);
  final w = (src.width * scale).round().clamp(1, targetW);
  final h = (src.height * scale).round().clamp(1, targetH);
  final scaled = img.copyResize(
    src,
    width: w,
    height: h,
    interpolation: img.Interpolation.cubic,
  );

  final out = img.Image(width: targetW, height: targetH);
  out.clear(img.ColorRgb8(0, 0, 0));
  img.compositeImage(
    out,
    scaled,
    dstX: (targetW - w) ~/ 2,
    dstY: (targetH - h) ~/ 2,
  );
  return out;
}

/// Resizes the edit to match studio dimensions (letterbox — no squash/stretch).
Future<String> resizeGlowUpToStudio(String studioPath, String editedPath) async {
  final studio = img.decodeImage(await File(studioPath).readAsBytes());
  final rawEdit = img.decodeImage(await File(editedPath).readAsBytes());
  if (studio == null || rawEdit == null) return editedPath;
  if (studio.width == rawEdit.width && studio.height == rawEdit.height) {
    return editedPath;
  }
  final fitted = letterboxToSize(rawEdit, studio.width, studio.height);
  final docs = await getApplicationDocumentsDirectory();
  final dir = Directory('${docs.path}/photos');
  if (!await dir.exists()) await dir.create(recursive: true);
  final out = File('${dir.path}/glow_letterbox_${const Uuid().v4()}.jpg');
  await out.writeAsBytes(img.encodeJpg(fitted, quality: 94), flush: true);
  return out.path;
}

/// Slider output size — 3:4, matches the glow report compare frame.
/// Square slider frames — before/after share the same face-centered crop.
const kSliderCanvasW = 1024;
const kSliderCanvasH = 1024;
const kGlowJpegQuality = 98;

/// Pure black studio — strips rembg halos / white fringe (pipeline stage 1).
Future<String> finalizeBlackStudio(String imagePath) async =>
    polishStudioBeforeFile(imagePath);

/// Optional OpenAI pass for before lighting (high fidelity). Falls back to [studioPath].
Future<String> polishBeforeStudioPreview(
  String studioPath, {
  OpenAIImageEditService? editor,
}) async {
  final ed = editor;
  if (ed == null || !ed.canEdit) return studioPath;
  try {
    final path = await ed.polishBeforeStudioLighting(studioPath);
    return await finalizeBlackStudio(path);
  } catch (e) {
    debugPrint('[GlowUpComposite] before studio light polish skipped: $e');
    return studioPath;
  }
}

/// Builds matched before/after JPEGs on one canonical canvas (same scale + center).
Future<({String before, String after, String sideBySide})> prepareGlowUpSliderPair(
  String studioPath,
  String editedPath, {
  OpenAIImageEditService? beforeLightEditor,
  bool useOpenAiBeforeLighting = false,
  bool minimalPrep = false,
}) async {
  var studioDecoded = img.decodeImage(await File(studioPath).readAsBytes());
  final editRaw = img.decodeImage(await File(editedPath).readAsBytes());
  if (studioDecoded == null || editRaw == null) {
    return (
      before: studioPath,
      after: editedPath,
      sideBySide: editedPath,
    );
  }

  if (useOpenAiBeforeLighting) {
    final polishedPath = await polishBeforeStudioPreview(
      studioPath,
      editor: beforeLightEditor,
    );
    studioDecoded =
        img.decodeImage(await File(polishedPath).readAsBytes()) ?? studioDecoded;
  }

  // Letterbox only on the edit — scrub/sanitize can punch holes that heal into green specks.
  var edit = letterboxToSize(editRaw, studioDecoded.width, studioDecoded.height);

  final studioMap = FaceLandmarkService.detectFromImage(studioDecoded);
  final studio = minimalPrep
      ? studioDecoded
      : sanitizeStudioPortrait(
          _scrubStudioFringe(studioDecoded, protectMap: studioMap),
          protectMap: studioMap,
        );

  final refB = _subjectBounds(studio);
  if (refB == null) {
    return (
      before: studioPath,
      after: editedPath,
      sideBySide: editedPath,
    );
  }

  if (blackStudioEdgeScore(studio) < 0.52) {
    debugPrint(
      '[GlowUpComposite] warn: before source is not black-studio — '
      're-run glow scan after stage-1 rembg',
    );
  }

  // Always align for slider mirror — ChatGPT edits often shift the face in-frame.
  edit = _translateEditToMatchStudio(studio, edit, forSliderMirror: true);

  edit = healFaceInpaintSpecksOnImage(studio, edit);
  final editMap = FaceLandmarkService.detectFromImage(edit);
  if (editMap != null) {
    edit = healOuterEyeDarkMarksOnImage(edit, editMap);
    final (canthusHealed, _) =
        healOuterCanthusResidualsOnImage(studio, edit, editMap);
    edit = canthusHealed;
  }

  final pair = _renderMatchedPreviewPair(studio, edit, refB);
  final (sliderBefore, sliderAfter) = _alignSliderPairByEyes(pair.$1, pair.$2);
  final strip = _renderSideBySideStrip(studio, edit, refB);

  final before = await _writeSliderJpg(sliderBefore, tag: 'before');
  final after = await _writeSliderJpg(sliderAfter, tag: 'after');
  final sideBySide = await _writeSliderJpg(strip, tag: 'side_by_side');
  debugPrint(
    '[GlowUpComposite] preview ${kSliderCanvasW}x$kSliderCanvasH '
    '+ side-by-side ${strip.width}x${strip.height}',
  );
  return (before: before, after: after, sideBySide: sideBySide);
}

Future<String> alignGlowUpForSlider(String studioPath, String editedPath) async {
  final pair = await prepareGlowUpSliderPair(studioPath, editedPath);
  return pair.after;
}

/// Looser 4:5 framing for the studio-before confirm screen (display only).
Future<String> prepareStudioBeforeDisplayPreview(String studioPath) async {
  final studioRaw = img.decodeImage(await File(studioPath).readAsBytes());
  if (studioRaw == null) return studioPath;

  final studio = studioRaw;
  final refB = _subjectBounds(studio);
  if (refB == null) return studioPath;

  final preview = _renderStudioPreviewFrame(
    studio,
    refB,
    marginScale: _kStudioConfirmMarginScale,
    subjectPad: _kStudioConfirmSubjectPad,
    faceCenterYFrac: _kStudioConfirmFaceCenterYFrac,
  );
  final out = await _writeSliderJpg(preview, tag: 'studio_confirm');
  debugPrint('[GlowUpComposite] studio confirm preview → $out');
  return out;
}

const _kStudioConfirmMarginScale = 0.72;
const _kStudioConfirmSubjectPad = 0.24;
/// Face vertical anchor on confirm canvas (lower = face higher, less empty space above).
const _kStudioConfirmFaceCenterYFrac = 0.40;

const _kPreviewSubjectPad = 0.14;
/// Higher = tighter face crop on compare canvas (closer in slider / side-by-side).
const _kSliderPairMarginScale = 0.95;
const _kPreviewFaceCenterYFrac = 0.43;

_Bounds _paddedSubjectBounds(_Bounds b, int imgW, int imgH, {double pad = _kPreviewSubjectPad}) {
  final padX = (b.right - b.left) * pad;
  final padY = (b.bottom - b.top) * pad;
  return _Bounds(
    math.max(0, (b.left - padX).round()),
    math.max(0, (b.top - padY).round()),
    math.min(imgW - 1, (b.right + padX).round()),
    math.min(imgH - 1, (b.bottom + padY).round()),
  );
}

double _previewSampleScale(
  _Bounds refB,
  int imgW,
  int imgH, {
  required double marginScale,
  required double subjectPad,
}) {
  final crop = _paddedSubjectBounds(refB, imgW, imgH, pad: subjectPad);
  final cropW = (crop.right - crop.left).toDouble();
  final cropH = (crop.bottom - crop.top).toDouble();
  return math.min(kSliderCanvasW / cropW, kSliderCanvasH / cropH) * marginScale;
}

_Bounds _previewCropBounds(
  _Bounds refB,
  int imgW,
  int imgH, {
  required double subjectPad,
}) =>
    _paddedSubjectBounds(refB, imgW, imgH, pad: subjectPad);

img.Image _renderStudioPreviewFrame(
  img.Image studio,
  _Bounds refB, {
  required double marginScale,
  required double subjectPad,
  double faceCenterYFrac = _kPreviewFaceCenterYFrac,
}) {
  final crop = _previewCropBounds(
    refB,
    studio.width,
    studio.height,
    subjectPad: subjectPad,
  );
  final scale = _previewSampleScale(
    refB,
    studio.width,
    studio.height,
    marginScale: marginScale,
    subjectPad: subjectPad,
  );
  final targetCx = kSliderCanvasW / 2;
  final targetCy = kSliderCanvasH * faceCenterYFrac;

  final out = img.Image(width: kSliderCanvasW, height: kSliderCanvasH);
  for (var y = 0; y < kSliderCanvasH; y++) {
    for (var x = 0; x < kSliderCanvasW; x++) {
      final sx = crop.centerX + (x - targetCx) / scale;
      final sy = crop.centerY + (y - targetCy) / scale;
      final p = _sampleRgb(studio, sx, sy);
      out.setPixelRgb(x, y, p[0], p[1], p[2]);
    }
  }
  return out;
}

/// Shifts [edit] so eye row + midline match [studio] (translation only).
img.Image _translateEditToMatchStudio(
  img.Image studio,
  img.Image edit, {
  required bool forSliderMirror,
}) {
  final sm = FaceLandmarkService.detectFromImage(studio);
  final em = FaceLandmarkService.detectFromImage(edit);
  if (sm == null || em == null) return edit;

  final eyeXs = (sm.leftEye.dx + sm.rightEye.dx) * 0.5;
  final eyeXe = (em.leftEye.dx + em.rightEye.dx) * 0.5;
  final eyeYs = (sm.leftEye.dy + sm.rightEye.dy) * 0.5;
  final eyeYe = (em.leftEye.dy + em.rightEye.dy) * 0.5;
  final dx = eyeXs - eyeXe;
  final dy = eyeYs - eyeYe;

  final s = sm.faceScale;
  if (!forSliderMirror &&
      (dx.abs() > s * 0.08 || dy.abs() > s * 0.08)) {
    debugPrint(
      '[GlowUpComposite] align skipped (Δx=${dx.toStringAsFixed(1)} '
      'Δy=${dy.toStringAsFixed(1)} — avoids eye ghosting)',
    );
    return edit;
  }

  final maxDx = forSliderMirror ? s * 0.28 : s * 0.12;
  final maxDy = forSliderMirror ? s * 0.28 : s * 0.10;
  final tdx = dx.clamp(-maxDx, maxDx);
  final tdy = dy.clamp(-maxDy, maxDy);
  if (!forSliderMirror && tdx.abs() < 0.15 && tdy.abs() < 0.15) return edit;

  final bg = studioBackdrop();
  final out = img.Image(width: edit.width, height: edit.height);
  out.clear(bg.color);

  for (var y = 0; y < edit.height; y++) {
    for (var x = 0; x < edit.width; x++) {
      final sx = x - tdx;
      final sy = y - tdy;
      if (sx >= 0 &&
          sx < edit.width - 1 &&
          sy >= 0 &&
          sy < edit.height - 1) {
        final c = _sampleBilinear(edit, sx, sy);
        out.setPixelRgb(x, y, c[0], c[1], c[2]);
      }
    }
  }

  debugPrint(
    '[GlowUpComposite] ${forSliderMirror ? 'slider mirror' : 'landmark'} align '
    'Δx=${tdx.toStringAsFixed(1)} Δy=${tdy.toStringAsFixed(1)}',
  );
  return out;
}

/// Before + after on [kSliderCanvasW]² — matched scale/anchors for mirror slider.
(img.Image, img.Image) _renderMatchedPreviewPair(
  img.Image studio,
  img.Image edit,
  _Bounds refB,
) {
  final crop = _previewCropBounds(
    refB,
    studio.width,
    studio.height,
    subjectPad: _kPreviewSubjectPad,
  );
  final beforeScale = math.min(
        kSliderCanvasW / crop.width,
        kSliderCanvasH / crop.height,
      ) *
      _kSliderPairMarginScale;
  final targetCx = kSliderCanvasW / 2.0;
  final targetCy = kSliderCanvasH * _kPreviewFaceCenterYFrac;

  final sm = FaceLandmarkService.detectFromImage(studio);
  final em = FaceLandmarkService.detectFromImage(edit);

  // Eye midpoint anchor — identical source coords for before & after on the canvas.
  final anchorBx = sm != null
      ? (sm.leftEye.dx + sm.rightEye.dx) * 0.5
      : crop.centerX;
  final anchorBy = sm != null
      ? (sm.leftEye.dy + sm.rightEye.dy) * 0.5
      : crop.centerY;

  final scale = beforeScale;

  final before = img.Image(width: kSliderCanvasW, height: kSliderCanvasH);
  final after = img.Image(width: kSliderCanvasW, height: kSliderCanvasH);

  for (var y = 0; y < kSliderCanvasH; y++) {
    for (var x = 0; x < kSliderCanvasW; x++) {
      final sx = anchorBx + (x - targetCx) / scale;
      final sy = anchorBy + (y - targetCy) / scale;
      final pb = _sampleRgb(studio, sx, sy);
      before.setPixelRgb(x, y, pb[0], pb[1], pb[2]);
      final pa = _sampleRgb(edit, sx, sy);
      after.setPixelRgb(x, y, pa[0], pa[1], pa[2]);
    }
  }

  if (sm != null && em != null) {
    debugPrint(
      '[GlowUpComposite] mirror grid scale=${scale.toStringAsFixed(3)} '
      'Δeye=${(sm.interEye - em.interEye).toStringAsFixed(1)}px '
      'Δcenter=${(sm.faceCenter.dx - em.faceCenter.dx).toStringAsFixed(1)},'
      '${(sm.faceCenter.dy - em.faceCenter.dy).toStringAsFixed(1)}',
    );
  } else {
    debugPrint(
      '[GlowUpComposite] matched grid scale=${scale.toStringAsFixed(3)} '
      '→ ${kSliderCanvasW}x$kSliderCanvasH',
    );
  }
  return _alignSliderPairByEyes(before, after);
}

/// Wide compare strip — faces biased toward the center seam (no dead black gap).
img.Image _renderSideBySideStrip(
  img.Image studio,
  img.Image edit,
  _Bounds refB,
) {
  final crop = _previewCropBounds(
    refB,
    studio.width,
    studio.height,
    subjectPad: _kPreviewSubjectPad,
  );
  final scale = math.min(
        kSliderCanvasW / crop.width,
        kSliderCanvasH / crop.height,
      ) *
      _kSliderPairMarginScale;
  final targetCy = kSliderCanvasH * _kPreviewFaceCenterYFrac;
  final sm = FaceLandmarkService.detectFromImage(studio);
  final anchorBx = sm != null
      ? (sm.leftEye.dx + sm.rightEye.dx) * 0.5
      : crop.centerX;
  final anchorBy = sm != null
      ? (sm.leftEye.dy + sm.rightEye.dy) * 0.5
      : crop.centerY;

  const beforeEyeX = kSliderCanvasW * 0.58;
  const afterEyeX = kSliderCanvasW * 1.42;
  final out = img.Image(width: kSliderCanvasW * 2, height: kSliderCanvasH);

  for (var y = 0; y < kSliderCanvasH; y++) {
    for (var x = 0; x < out.width; x++) {
      final targetCx = x < kSliderCanvasW ? beforeEyeX : afterEyeX;
      final sx = anchorBx + (x - targetCx) / scale;
      final sy = anchorBy + (y - targetCy) / scale;
      final src = x < kSliderCanvasW ? studio : edit;
      final rgb = _sampleRgb(src, sx, sy);
      out.setPixelRgb(x, y, rgb[0], rgb[1], rgb[2]);
    }
  }

  debugPrint(
    '[GlowUpComposite] side-by-side strip ${out.width}x${out.height} '
    'scale=${scale.toStringAsFixed(3)}',
  );
  return out;
}

/// Shifts [before] only — [after] stays fixed (slider reveals before over after).
(img.Image, img.Image) _alignSliderPairByEyes(
  img.Image before,
  img.Image after,
) {
  final bm = FaceLandmarkService.detectFromImage(before);
  final am = FaceLandmarkService.detectFromImage(after);
  if (bm == null || am == null) return (before, after);

  final bEyeX = (bm.leftEye.dx + bm.rightEye.dx) * 0.5;
  final bEyeY = (bm.leftEye.dy + bm.rightEye.dy) * 0.5;
  final aEyeX = (am.leftEye.dx + am.rightEye.dx) * 0.5;
  final aEyeY = (am.leftEye.dy + am.rightEye.dy) * 0.5;

  // Move before to match after eyes — never shift the after preview.
  final dx = (aEyeX - bEyeX).round().clamp(-72, 72);
  final dy = (aEyeY - bEyeY).round().clamp(-72, 72);
  if (dx.abs() < 1 && dy.abs() < 1) return (before, after);

  final shiftedBefore =
      _shiftImageRgb(before, dx: dx, dy: dy, fill: studioBackdrop().color);
  debugPrint(
    '[GlowUpComposite] slider before-only eye align Δx=$dx Δy=$dy '
    'before=(${bEyeX.toStringAsFixed(0)},${bEyeY.toStringAsFixed(0)}) '
    'after=(${aEyeX.toStringAsFixed(0)},${aEyeY.toStringAsFixed(0)})',
  );
  return (shiftedBefore, after);
}

img.Image _shiftImageRgb(
  img.Image src, {
  required int dx,
  required int dy,
  required img.Color fill,
}) {
  final out = img.Image(width: src.width, height: src.height);
  out.clear(fill);
  for (var y = 0; y < src.height; y++) {
    for (var x = 0; x < src.width; x++) {
      final sx = x - dx;
      final sy = y - dy;
      if (sx >= 0 && sx < src.width && sy >= 0 && sy < src.height) {
        final p = src.getPixel(sx, sy);
        out.setPixelRgb(x, y, p.r, p.g, p.b);
      }
    }
  }
  return out;
}

List<int> _sampleRgb(img.Image sample, double sx, double sy) {
  if (sx < 0 || sy < 0 || sx >= sample.width - 1 || sy >= sample.height - 1) {
    return const [0, 0, 0];
  }
  // 2×2 supersample — reduces blocky tiles when scaling to the slider canvas.
  const o = 0.28;
  var r = 0, g = 0, b = 0;
  for (final t in const [(-o, -o), (o, -o), (-o, o), (o, o)]) {
    final c = _sampleBilinear(sample, sx + t.$1, sy + t.$2);
    r += c[0];
    g += c[1];
    b += c[2];
  }
  return [r ~/ 4, g ~/ 4, b ~/ 4];
}

class _RgbMean {
  const _RgbMean(this.r, this.g, this.b);
  final double r;
  final double g;
  final double b;
}

_RgbMean _subjectRgbMean(img.Image im, _Bounds b) {
  var sr = 0.0;
  var sg = 0.0;
  var sb = 0.0;
  var n = 0;
  for (var y = b.top; y <= b.bottom; y++) {
    for (var x = b.left; x <= b.right; x++) {
      final p = im.getPixel(x, y);
      if (_luminance(p) <= 28) continue;
      sr += p.r;
      sg += p.g;
      sb += p.b;
      n++;
    }
  }
  if (n == 0) return const _RgbMean(128, 128, 128);
  return _RgbMean(sr / n, sg / n, sb / n);
}

/// Slight studio lighting toward [after] — no reshape, no skin smoothing.
img.Image _harmonizeBeforeToAfter(img.Image before, img.Image after) {
  final refB = _subjectBounds(before);
  if (refB == null) return before;

  final from = _subjectRgbMean(before, refB);
  final to = _subjectRgbMean(after, refB);
  final rGain = (to.r / from.r).clamp(0.97, 1.03);
  final gGain = (to.g / from.g).clamp(0.97, 1.03);
  final bGain = (to.b / from.b).clamp(0.97, 1.03);
  const strength = 0.10;

  final out = img.Image.from(before);
  for (var y = 0; y < before.height; y++) {
    for (var x = 0; x < before.width; x++) {
      if (_luminance(before.getPixel(x, y)) <= 28) {
        out.setPixelRgb(x, y, 0, 0, 0);
        continue;
      }
      final p = before.getPixel(x, y);
      final r = p.r * (1 - strength) + p.r * rGain * strength;
      final g = p.g * (1 - strength) + p.g * gGain * strength;
      final b = p.b * (1 - strength) + p.b * bGain * strength;
      out.setPixelRgb(
        x,
        y,
        r.round().clamp(0, 255),
        g.round().clamp(0, 255),
        b.round().clamp(0, 255),
      );
    }
  }
  return out;
}

/// Light rembg fringe / wall residue on the silhouette rim.
bool _isWhiteHaloOnly(img.Pixel p) {
  final r = p.r.toInt();
  final g = p.g.toInt();
  final b = p.b.toInt();
  final lum = _luminance(p);
  final chroma = math.max(r, math.max(g, b)) - math.min(r, math.min(g, b));
  if (lum > 228 && chroma < 38) return true;
  if (lum > 195 && chroma < 18) return true;
  if (lum > 155 && chroma < 12) return true;
  return false;
}

/// Black studio: black out background; strip obvious halos on the outer rim.
img.Image _scrubStudioFringe(img.Image im, {FaceGlowMap? protectMap}) {
  final map = protectMap ?? FaceLandmarkService.detectFromImage(im);
  final b = _subjectBounds(im);
  final out = img.Image(width: im.width, height: im.height);

  for (var y = 0; y < im.height; y++) {
    for (var x = 0; x < im.width; x++) {
      final p = im.getPixel(x, y);
      final lum = _luminance(p);

      final insideBox = b != null &&
          x >= b.left &&
          x <= b.right &&
          y >= b.top &&
          y <= b.bottom;

      if (insideBox) {
        if (map != null &&
            FaceLandmarkService.faceStudioSensorWeight(map, x, y) > 0.05) {
          out.setPixelRgb(x, y, p.r.toInt(), p.g.toInt(), p.b.toInt());
          continue;
        }
        // Rim + hair streaks: light pixels touching black backdrop (not on face).
        if (_isWhiteHaloOnly(p) && _pixelTouchesBlack(im, x, y)) {
          out.setPixelRgb(x, y, 0, 0, 0);
          continue;
        }
        out.setPixelRgb(x, y, p.r.toInt(), p.g.toInt(), p.b.toInt());
        continue;
      }

      if (lum <= 22 || _isWhiteHaloOnly(p)) {
        out.setPixelRgb(x, y, 0, 0, 0);
      } else {
        out.setPixelRgb(x, y, 0, 0, 0);
      }
    }
  }
  return out;
}

bool _pixelTouchesOutsideBox(img.Image im, int x, int y, _Bounds b) {
  for (var dy = -1; dy <= 1; dy++) {
    for (var dx = -1; dx <= 1; dx++) {
      if (dx == 0 && dy == 0) continue;
      final nx = x + dx;
      final ny = y + dy;
      if (nx < 0 || ny < 0 || nx >= im.width || ny >= im.height) return true;
      if (nx < b.left || nx > b.right || ny < b.top || ny > b.bottom) {
        return true;
      }
      if (_luminance(im.getPixel(nx, ny)) <= 26) return true;
    }
  }
  return false;
}

bool _pixelTouchesBlack(img.Image im, int x, int y) {
  for (var dy = -2; dy <= 2; dy++) {
    for (var dx = -2; dx <= 2; dx++) {
      if (dx == 0 && dy == 0) continue;
      final nx = x + dx;
      final ny = y + dy;
      if (nx < 0 || ny < 0 || nx >= im.width || ny >= im.height) continue;
      if (_luminance(im.getPixel(nx, ny)) <= 26) return true;
    }
  }
  return false;
}

/// Unsharp mask on the portrait subject — restores clarity after AI soften/blend.
img.Image _sharpenSubjectImage(img.Image im, {double amount = 0.35}) {
  if (amount <= 0) return im;
  final b = _subjectBounds(im);
  if (b == null) return im;

  final blurred = img.gaussianBlur(img.Image.from(im), radius: 1);
  final out = img.Image.from(im);
  for (var y = 0; y < im.height; y++) {
    for (var x = 0; x < im.width; x++) {
      if (_luminance(im.getPixel(x, y)) <= 28) continue;
      final p = im.getPixel(x, y);
      final bl = blurred.getPixel(x, y);
      final edgeW = _subjectFeather(x, y, b);
      final a = amount * edgeW;
      out.setPixelRgb(
        x,
        y,
        (p.r + (p.r - bl.r) * a).round().clamp(0, 255),
        (p.g + (p.g - bl.g) * a).round().clamp(0, 255),
        (p.b + (p.b - bl.b) * a).round().clamp(0, 255),
      );
    }
  }
  return out;
}

Future<String> _writeSliderJpg(img.Image image, {required String tag}) async {
  final docs = await getApplicationDocumentsDirectory();
  final dir = Directory('${docs.path}/photos');
  if (!await dir.exists()) await dir.create(recursive: true);
  final out = File('${dir.path}/glow_slider_${tag}_${const Uuid().v4()}.jpg');
  await out.writeAsBytes(img.encodeJpg(image, quality: kGlowJpegQuality), flush: true);
  return out.path;
}

/// Pastes pre-FLUX brow band from [originalPath] (black studio) onto [editedPath].
/// Optional [rawPhotoPath] adds hair detail when landmarks align.
/// In-memory brow restore (optional raw photo for texture).
Future<img.Image> preserveEyebrowsOnImage({
  required img.Image studio,
  required img.Image edit,
  String? rawPhotoPath,
}) async {
  img.Image? raw;
  var rawDx = 0;
  var rawDy = 0;

  final map =
      FaceLandmarkService.detectFromImage(studio) ??
      FaceLandmarkService.detectFromImage(edit);
  if (map == null) return edit;

  final rawTrim = (rawPhotoPath ?? '').trim();
  if (rawTrim.isNotEmpty) {
    try {
      final localRaw = await resolveLocalPhotoPath(rawTrim);
      var decoded = img.decodeImage(await File(localRaw).readAsBytes());
      if (decoded != null) {
        if (decoded.width != edit.width || decoded.height != edit.height) {
          decoded = letterboxToSize(decoded, edit.width, edit.height);
        }
        raw = decoded;
        final rawMap = FaceLandmarkService.detectFromImage(raw);
        if (rawMap != null) {
          rawDx = (map.leftEye.dx - rawMap.leftEye.dx).round();
          rawDy = (((map.leftEye.dy + map.rightEye.dy) / 2) -
                  ((rawMap.leftEye.dy + rawMap.rightEye.dy) / 2))
              .round();
        }
      }
    } catch (_) {}
  }

  final result = img.Image.from(edit);
  var n = 0;
  for (var y = 0; y < edit.height; y++) {
    for (var x = 0; x < edit.width; x++) {
      final w = FaceLandmarkService.browPreserveWeight(map, x, y);
      if (w <= 0.08) continue;

      final ps = studio.getPixel(x, y);
      if (_luminance(ps) <= 22) continue;

      img.Pixel po = ps;
      if (raw != null) {
        final rx = x + rawDx;
        final ry = y + rawDy;
        if (rx >= 0 && ry >= 0 && rx < edit.width && ry < edit.height) {
          final pr = raw.getPixel(rx, ry);
          if (_luminance(pr) > 28) po = pr;
        }
      }

      final blend = w >= 0.2 ? 1.0 : (w * 5).clamp(0.0, 1.0);
      final pe = edit.getPixel(x, y);
      result.setPixelRgba(
        x,
        y,
        _blendChannel(po.r, pe.r, blend),
        _blendChannel(po.g, pe.g, blend),
        _blendChannel(po.b, pe.b, blend),
        255,
      );
      n++;
    }
  }

  if (n >= 12) {
    debugPrint('[GlowUpComposite] restored brows in-memory ($n px)');
  }
  return result;
}

Future<String> preserveEyebrowsFromOriginal({
  required String originalPath,
  required String editedPath,
  String? rawPhotoPath,
}) async {
  final editBytes = await File(editedPath).readAsBytes();
  var edit = img.decodeImage(editBytes);
  if (edit == null) return editedPath;

  final studioPath = await resolveLocalPhotoPath(originalPath);
  var studio = img.decodeImage(await File(studioPath).readAsBytes());
  if (studio == null) return editedPath;
  if (studio.width != edit.width || studio.height != edit.height) {
    studio = letterboxToSize(studio, edit.width, edit.height);
  }

  img.Image? raw;
  var rawDx = 0;
  var rawDy = 0;
  final rawTrim = (rawPhotoPath ?? '').trim();
  if (rawTrim.isNotEmpty) {
    try {
      final localRaw = await resolveLocalPhotoPath(rawTrim);
      var decoded = img.decodeImage(await File(localRaw).readAsBytes());
      if (decoded != null) {
        if (decoded.width != edit.width || decoded.height != edit.height) {
          decoded = letterboxToSize(decoded, edit.width, edit.height);
        }
        raw = decoded;
      }
    } catch (_) {}
  }

  final map =
      FaceLandmarkService.detectFromImage(studio) ??
      FaceLandmarkService.detectFromImage(edit);
  if (map == null) {
    debugPrint('[GlowUpComposite] brow preserve skipped — no landmarks');
    return editedPath;
  }

  if (raw != null) {
    final rawMap = FaceLandmarkService.detectFromImage(raw);
    if (rawMap != null) {
      rawDx = (map.leftEye.dx - rawMap.leftEye.dx).round();
      rawDy = (((map.leftEye.dy + map.rightEye.dy) / 2) -
              ((rawMap.leftEye.dy + rawMap.rightEye.dy) / 2))
          .round();
    }
  }

  final result = img.Image.from(edit);
  var n = 0;
  for (var y = 0; y < edit.height; y++) {
    for (var x = 0; x < edit.width; x++) {
      final w = FaceLandmarkService.browPreserveWeight(map, x, y);
      if (w <= 0.08) continue;

      final ps = studio.getPixel(x, y);
      if (_luminance(ps) <= 22) continue;

      img.Pixel po = ps;
      if (raw != null) {
        final rx = x + rawDx;
        final ry = y + rawDy;
        if (rx >= 0 && ry >= 0 && rx < edit.width && ry < edit.height) {
          final pr = raw.getPixel(rx, ry);
          if (_luminance(pr) > 28) po = pr;
        }
      }

      // Hard restore in the brow band — FLUX often thins even at 50% blend.
      final blend = w >= 0.2 ? 1.0 : (w * 5).clamp(0.0, 1.0);
      final pe = edit.getPixel(x, y);
      result.setPixelRgba(
        x,
        y,
        _blendChannel(po.r, pe.r, blend),
        _blendChannel(po.g, pe.g, blend),
        _blendChannel(po.b, pe.b, blend),
        255,
      );
      n++;
    }
  }

  if (n < 12) {
    debugPrint('[GlowUpComposite] brow preserve skipped — no brow zone pixels');
    return editedPath;
  }

  final outPath = await _writeSliderJpg(result, tag: 'brows_preserved');
  debugPrint(
    '[GlowUpComposite] restored brows from studio'
    '${raw != null ? '+raw' : ''} ($n px) → $outPath',
  );
  return outPath;
}

bool _needsLipColorRestore(img.Pixel pe, img.Pixel ps) {
  final re = pe.r.toInt() - pe.g.toInt();
  final rs = ps.r.toInt() - ps.g.toInt();
  if (pe.r.toInt() > ps.r.toInt() + 16 && re > rs + 10) return true;
  if (pe.r.toInt() + pe.g.toInt() > ps.r.toInt() + ps.g.toInt() + 30 &&
      pe.r.toInt() > ps.r.toInt() + 10) {
    return true;
  }
  return false;
}

(int, int) _studioAlignShift(FaceGlowMap studioMap, FaceGlowMap editMap) {
  final shiftX = (((editMap.leftEye.dx + editMap.rightEye.dx) / 2) -
          ((studioMap.leftEye.dx + studioMap.rightEye.dx) / 2))
      .round();
  final shiftY = (((editMap.leftEye.dy + editMap.rightEye.dy) / 2) -
          ((studioMap.leftEye.dy + studioMap.rightEye.dy) / 2))
      .round();
  return (shiftX, shiftY);
}

img.Pixel? _studioPixelAt(
  img.Image studio,
  int x,
  int y,
  int shiftX,
  int shiftY,
) {
  final sx = x - shiftX;
  final sy = y - shiftY;
  if (sx < 0 || sy < 0 || sx >= studio.width || sy >= studio.height) {
    return null;
  }
  return studio.getPixel(sx, sy);
}

/// In-memory eye restore with landmark alignment (reduces low-delta ghosting).
img.Image preserveEyesNaturalOnImage(
  img.Image studio,
  img.Image edit,
  FaceGlowMap studioMap,
  FaceGlowMap editMap,
) {
  final result = img.Image.from(edit);
  final (shiftX, shiftY) = _studioAlignShift(studioMap, editMap);
  var eyeN = 0;

  for (var y = 0; y < edit.height; y++) {
    for (var x = 0; x < edit.width; x++) {
      final ps = _studioPixelAt(studio, x, y, shiftX, shiftY);
      if (ps == null || _luminance(ps) <= 22) continue;

      final eyeW = FaceLandmarkService.eyeNaturalPreserveWeight(editMap, x, y);
      if (eyeW <= 0.1) continue;

      final pe = edit.getPixel(x, y);
      var blend = eyeW >= 0.28 ? 1.0 : (eyeW * 3.2).clamp(0.0, 1.0);
      blend = blend * blend * (3 - 2 * blend);
      result.setPixelRgba(
        x,
        y,
        _blendChannel(ps.r, pe.r, blend),
        _blendChannel(ps.g, pe.g, blend),
        _blendChannel(ps.b, pe.b, blend),
        255,
      );
      eyeN++;
    }
  }

  if (eyeN >= 8) {
    debugPrint('[GlowUpComposite] restored natural eyes in-memory ($eyeN px)');
  }
  return result;
}

/// In-memory lip color restore with landmark alignment.
img.Image preserveLipsNaturalOnImage(
  img.Image studio,
  img.Image edit,
  FaceGlowMap studioMap,
  FaceGlowMap editMap,
) {
  final result = img.Image.from(edit);
  final (shiftX, shiftY) = _studioAlignShift(studioMap, editMap);
  var lipN = 0;

  for (var y = 0; y < edit.height; y++) {
    for (var x = 0; x < edit.width; x++) {
      final ps = _studioPixelAt(studio, x, y, shiftX, shiftY);
      if (ps == null || _luminance(ps) <= 22) continue;

      final lipW = FaceLandmarkService.lipColorPreserveWeight(editMap, x, y);
      if (lipW <= 0.08) continue;

      final pe = edit.getPixel(x, y);
      var blend = lipW >= 0.22 ? 0.82 : (lipW * 3.6).clamp(0.0, 1.0);
      if (_needsLipColorRestore(pe, ps)) blend = math.max(blend, 0.94);
      blend = blend * blend * (3 - 2 * blend);
      result.setPixelRgba(
        x,
        y,
        _blendChannel(ps.r, pe.r, blend),
        _blendChannel(ps.g, pe.g, blend),
        _blendChannel(ps.b, pe.b, blend),
        255,
      );
      lipN++;
    }
  }

  if (lipN >= 8) {
    debugPrint('[GlowUpComposite] restored natural lips in-memory ($lipN px)');
  }
  return result;
}

/// Restores natural lids/iris/sclera from studio before (blocks AI catchlight specks).
Future<String> preserveEyesNaturalFromStudio({
  required String studioPath,
  required String editedPath,
}) async {
  final pair = await _loadStudioEditPair(studioPath, editedPath);
  if (pair == null) return editedPath;
  final (studio, edit, map) = pair;

  final result = img.Image.from(edit);
  var eyeN = 0;

  for (var y = 0; y < edit.height; y++) {
    for (var x = 0; x < edit.width; x++) {
      if (_luminance(studio.getPixel(x, y)) <= 22) continue;
      final ps = studio.getPixel(x, y);
      final pe = edit.getPixel(x, y);

      final eyeW = FaceLandmarkService.eyeNaturalPreserveWeight(map, x, y);
      if (eyeW <= 0.1) continue;

      final blend = eyeW >= 0.28 ? 1.0 : (eyeW * 3.2).clamp(0.0, 1.0);
      result.setPixelRgba(
        x,
        y,
        _blendChannel(ps.r, pe.r, blend),
        _blendChannel(ps.g, pe.g, blend),
        _blendChannel(ps.b, pe.b, blend),
        255,
      );
      eyeN++;
    }
  }

  if (eyeN < 8) {
    debugPrint('[GlowUpComposite] eye preserve skipped — tiny zones');
    return editedPath;
  }

  final outPath = await _writeSliderJpg(result, tag: 'natural_eyes');
  debugPrint('[GlowUpComposite] restored natural eyes ($eyeN px) → $outPath');
  return outPath;
}

/// Restores natural lip color from studio before (volume edits may stay elsewhere).
Future<String> preserveLipsNaturalFromStudio({
  required String studioPath,
  required String editedPath,
}) async {
  final pair = await _loadStudioEditPair(studioPath, editedPath);
  if (pair == null) return editedPath;
  final (studio, edit, map) = pair;

  final result = img.Image.from(edit);
  var lipN = 0;

  for (var y = 0; y < edit.height; y++) {
    for (var x = 0; x < edit.width; x++) {
      if (_luminance(studio.getPixel(x, y)) <= 22) continue;
      final ps = studio.getPixel(x, y);
      final pe = edit.getPixel(x, y);

      final lipW = FaceLandmarkService.lipColorPreserveWeight(map, x, y);
      if (lipW <= 0.08) continue;
      var blend = lipW >= 0.22 ? 0.82 : (lipW * 3.6).clamp(0.0, 1.0);
      if (_needsLipColorRestore(pe, ps)) blend = math.max(blend, 0.94);
      result.setPixelRgba(
        x,
        y,
        _blendChannel(ps.r, pe.r, blend),
        _blendChannel(ps.g, pe.g, blend),
        _blendChannel(ps.b, pe.b, blend),
        255,
      );
      lipN++;
    }
  }

  if (lipN < 8) {
    debugPrint('[GlowUpComposite] lip preserve skipped — tiny zones');
    return editedPath;
  }

  final outPath = await _writeSliderJpg(result, tag: 'natural_lips');
  debugPrint('[GlowUpComposite] restored natural lips ($lipN px) → $outPath');
  return outPath;
}

/// Restores pre-FLUX eyes and lip color from black-studio before (blocks AI makeup/tint).
Future<String> preserveEyesAndLipsNaturalFromStudio({
  required String studioPath,
  required String editedPath,
}) async {
  var out = await preserveEyesNaturalFromStudio(
    studioPath: studioPath,
    editedPath: editedPath,
  );
  out = await preserveLipsNaturalFromStudio(
    studioPath: studioPath,
    editedPath: out,
  );
  return out;
}

Future<(img.Image studio, img.Image edit, FaceGlowMap map)?> _loadStudioEditPair(
  String studioPath,
  String editedPath,
) async {
  final edit = img.decodeImage(await File(editedPath).readAsBytes());
  if (edit == null) return null;

  final localStudio = await resolveLocalPhotoPath(studioPath);
  var studio = img.decodeImage(await File(localStudio).readAsBytes());
  if (studio == null) return null;
  if (studio.width != edit.width || studio.height != edit.height) {
    studio = letterboxToSize(studio, edit.width, edit.height);
  }

  final map =
      FaceLandmarkService.detectFromImage(studio) ??
      FaceLandmarkService.detectFromImage(edit);
  if (map == null) {
    debugPrint('[GlowUpComposite] studio/edit pair skipped — no landmarks');
    return null;
  }
  return (studio, edit, map);
}

Future<String> compositeGlowUpFile(String studioPath, String editedPath) async {
  final studio = await File(studioPath).readAsBytes();
  final edited = await File(editedPath).readAsBytes();
  final bytes = compositeGlowUpOnOriginal(studio, edited);
  final docs = await getApplicationDocumentsDirectory();
  final dir = Directory('${docs.path}/photos');
  if (!await dir.exists()) await dir.create(recursive: true);
  final out = File('${dir.path}/glow_composite_${const Uuid().v4()}.jpg');
  await out.writeAsBytes(bytes, flush: true);
  debugPrint('[GlowUpComposite] saved → ${out.path}');
  return out.path;
}

class _Bounds {
  const _Bounds(this.left, this.top, this.right, this.bottom);
  final int left;
  final int top;
  final int right;
  final int bottom;

  double get centerX => (left + right) / 2;
  double get centerY => (top + bottom) / 2;
  double get width => (right - left).toDouble();
  double get height => (bottom - top).toDouble();
}

img.Image _alignSubjectToReference(img.Image ref, img.Image src) {
  final refB = _subjectBounds(ref);
  final srcB = _subjectBounds(src);
  if (refB == null || srcB == null) return src;

  final scale = (refB.height / srcB.height).clamp(0.92, 1.08);

  final dst = img.Image(width: ref.width, height: ref.height);
  for (var y = 0; y < ref.height; y++) {
    for (var x = 0; x < ref.width; x++) {
      if (_luminance(ref.getPixel(x, y)) <= 28) {
        dst.setPixelRgb(x, y, 0, 0, 0);
        continue;
      }
      final sx = srcB.centerX + (x - refB.centerX) / scale;
      final sy = srcB.centerY + (y - refB.centerY) / scale;
      if (sx >= 0 &&
          sx < src.width - 1 &&
          sy >= 0 &&
          sy < src.height - 1) {
        final c = _sampleBilinear(src, sx, sy);
        dst.setPixelRgb(x, y, c[0], c[1], c[2]);
      } else {
        dst.setPixelRgb(x, y, 0, 0, 0);
      }
    }
  }
  return dst;
}

_Bounds? _subjectBounds(img.Image im) {
  var minX = im.width;
  var minY = im.height;
  var maxX = 0;
  var maxY = 0;
  var n = 0;
  for (var y = 0; y < im.height; y++) {
    for (var x = 0; x < im.width; x++) {
      if (_luminance(im.getPixel(x, y)) <= 28) continue;
      minX = math.min(minX, x);
      minY = math.min(minY, y);
      maxX = math.max(maxX, x);
      maxY = math.max(maxY, y);
      n++;
    }
  }
  if (n < 100) return null;
  return _Bounds(minX, minY, maxX, maxY);
}

double _subjectFeather(int x, int y, _Bounds b) {
  final distEdge = math.min(
    math.min(x - b.left, b.right - x),
    math.min(y - b.top, b.bottom - y),
  ).toDouble();
  const feather = 28.0;
  if (distEdge >= feather) return 1;
  if (distEdge <= 0) return 0;
  final t = distEdge / feather;
  return t * t * (3 - 2 * t);
}

double _luminance(img.Pixel p) =>
    0.299 * p.r + 0.587 * p.g + 0.114 * p.b;

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

int _blendChannel(num a, num b, double w) =>
    (a * (1 - w) + b * w).round().clamp(0, 255);

bool _isFaceSkinPixel(img.Image ref, int x, int y) {
  final lum = _luminance(ref.getPixel(x, y));
  return lum > 32;
}

bool _isInpaintHole(img.Pixel p) => p.r < 12 && p.g < 12 && p.b < 12;

bool healInpaintSpecksEnabled() {
  final v = (dotenv.env['GLOW_UP_HEAL_INPAINT_SPECKS'] ?? 'false')
      .trim()
      .toLowerCase();
  return v == 'true' || v == '1' || v == 'on';
}

bool _harmonizeFaceColorEnabled() {
  final v = (dotenv.env['GLOW_UP_HARMONIZE_FACE_COLOR'] ?? 'true')
      .trim()
      .toLowerCase();
  return v != 'false' && v != '0' && v != 'off';
}

/// Pulls AI green/teal skin (especially under eyes) back toward the studio reference.
Future<String> harmonizeAfterFaceColorFile(
  String studioPath,
  String editedPath,
) async {
  if (!_harmonizeFaceColorEnabled()) return editedPath;
  final studio = img.decodeImage(await File(studioPath).readAsBytes());
  var edit = img.decodeImage(await File(editedPath).readAsBytes());
  if (studio == null || edit == null) return editedPath;

  if (edit.width != studio.width || edit.height != studio.height) {
    edit = letterboxToSize(edit, studio.width, studio.height);
  }

  final map = FaceLandmarkService.detectFromImage(studio);
  if (map == null) return editedPath;

  final out = harmonizeAfterFaceColorOnImage(studio, edit, map);
  final docs = await getApplicationDocumentsDirectory();
  final dir = Directory('${docs.path}/photos');
  if (!await dir.exists()) await dir.create(recursive: true);
  final file = File('${dir.path}/glow_color_fix_${const Uuid().v4()}.jpg');
  await file.writeAsBytes(img.encodeJpg(out, quality: 94), flush: true);
  return file.path;
}

/// Only obvious electric lime/yellow AI dots — avoids touching normal skin.
bool _isFaceNeonSpeck(img.Pixel p) {
  final r = p.r.toInt();
  final g = p.g.toInt();
  final b = p.b.toInt();
  final lum = _luminance(p);
  if (lum < 72 || lum > 248) return false;
  if (g > 128 && g > r + 14 && g > b + 20) return true;
  if (r > 145 && g > 140 && b < 92 && lum > 118) return true;
  return false;
}

/// Muted grey-green / teal AI cast in tear trough (not dark circles / neutral shadow).
bool _isUnderEyeGreenCast(img.Pixel p) {
  if (_isFaceNeonSpeck(p)) return true;
  final r = p.r.toInt();
  final g = p.g.toInt();
  final b = p.b.toInt();
  final lum = _luminance(p);
  if (lum < 40 || lum > 238) return false;
  // Neutral black/grey under-eye shadow — lighten pass handles these, not color repair.
  if (lum < 118 && (g - r).abs() < 14 && (g - b).abs() < 14) return false;
  final greenLead = g - math.max(r, b);
  if (greenLead >= 5 && g >= r - 12 && g >= b + 3) return true;
  if (lum < 150 && g > r + 3 && g > b + 6) return true;
  return false;
}

bool _isBadUnderEyeSample(img.Pixel p) =>
    _isFaceNeonSpeck(p) || _isUnderEyeGreenCast(p);

bool _isIsolatedNeonSpeck(img.Image im, int x, int y) {
  if (!_isFaceNeonSpeck(im.getPixel(x, y))) return false;
  var cluster = 0;
  for (var dy = -2; dy <= 2; dy++) {
    for (var dx = -2; dx <= 2; dx++) {
      final nx = x + dx;
      final ny = y + dy;
      if (nx < 0 || ny < 0 || nx >= im.width || ny >= im.height) continue;
      if (_isFaceNeonSpeck(im.getPixel(nx, ny))) cluster++;
    }
  }
  return cluster <= 18;
}

List<int>? _medianSkinNeighborRgb(
  img.Image source,
  int x,
  int y,
  FaceGlowMap map, {
  int radius = 3,
}) {
  var sr = 0.0;
  var sg = 0.0;
  var sb = 0.0;
  var n = 0;
  for (var dy = -radius; dy <= radius; dy++) {
    for (var dx = -radius; dx <= radius; dx++) {
      if (dx == 0 && dy == 0) continue;
      final nx = x + dx;
      final ny = y + dy;
      if (nx < 0 || ny < 0 || nx >= source.width || ny >= source.height) {
        continue;
      }
      if (FaceLandmarkService.eyeNaturalPreserveWeight(map, nx, ny) > 0.22) {
        continue;
      }
      final np = source.getPixel(nx, ny);
      if (_luminance(np) < 48 || _isBadUnderEyeSample(np)) continue;
      sr += np.r;
      sg += np.g;
      sb += np.b;
      n++;
    }
  }
  if (n < 5) return null;
  return [(sr / n).round(), (sg / n).round(), (sb / n).round()];
}

void _repairUnderEyePixel(
  img.Image studio,
  img.Image edit,
  img.Image out,
  FaceGlowMap map,
  int x,
  int y, {
  required double zoneW,
}) {
  final pe = edit.getPixel(x, y);
  if (!_isBadUnderEyeSample(pe)) return;

  var med = _medianSkinNeighborRgb(edit, x, y, map, radius: 5);
  med ??= _medianSkinNeighborRgb(studio, x, y, map, radius: 5);
  if (med == null) {
    final ps = studio.getPixel(x, y);
    if (_luminance(ps) > 42 && !_isBadUnderEyeSample(ps)) {
      med = [ps.r.toInt(), ps.g.toInt(), ps.b.toInt()];
    }
  }
  if (med == null) return;

  final t = (0.72 + 0.20 * zoneW).clamp(0.72, 0.90);
  out.setPixelRgb(
    x,
    y,
    _blendChannel(pe.r, med[0], t),
    _blendChannel(pe.g, med[1], t),
    _blendChannel(pe.b, med[2], t),
  );
}

/// Under-eye green/teal cast + isolated neon dots (tear trough only — no full-face pass).
img.Image harmonizeAfterFaceColorOnImage(
  img.Image studio,
  img.Image edit,
  FaceGlowMap map,
) {
  final out = img.Image.from(edit);
  var fixed = 0;

  for (var y = 2; y < edit.height - 2; y++) {
    for (var x = 2; x < edit.width - 2; x++) {
      if (FaceLandmarkService.eyeNaturalPreserveWeight(map, x, y) > 0.12) {
        continue;
      }

      final uEye = FaceLandmarkService.underEyeHarmonizeWeight(map, x, y);
      final inner = FaceLandmarkService.innerCanthusNeonFixWeight(map, x, y);
      if (uEye < 0.12 && inner < 0.15) continue;

      final pe = edit.getPixel(x, y);
      final inTearTrough = uEye >= 0.18;
      if (inTearTrough) {
        if (!_isUnderEyeGreenCast(pe)) continue;
      } else {
        if (!_isIsolatedNeonSpeck(edit, x, y)) continue;
      }

      final zoneW = math.max(uEye, inner);
      final before = out.getPixel(x, y);
      _repairUnderEyePixel(studio, edit, out, map, x, y, zoneW: zoneW);
      final after = out.getPixel(x, y);
      if (before.r != after.r ||
          before.g != after.g ||
          before.b != after.b) {
        fixed++;
      }
    }
  }

  if (fixed > 0) {
    debugPrint('[GlowUpComposite] fixed $fixed under-eye discoloration px');
  }
  return out;
}

/// Fills small pure-black inpaint specks on the face using nearby skin pixels.
Future<String> healFaceInpaintSpecks(String studioPath, String editedPath) async {
  if (!healInpaintSpecksEnabled()) return editedPath;
  final studio = img.decodeImage(await File(studioPath).readAsBytes());
  var edit = img.decodeImage(await File(editedPath).readAsBytes());
  if (studio == null || edit == null) return editedPath;

  if (edit.width != studio.width || edit.height != studio.height) {
    edit = letterboxToSize(edit, studio.width, studio.height);
  }

  final healed = healFaceInpaintSpecksOnImage(studio, edit);
  final docs = await getApplicationDocumentsDirectory();
  final dir = Directory('${docs.path}/photos');
  if (!await dir.exists()) await dir.create(recursive: true);
  final out = File('${dir.path}/glow_healed_${const Uuid().v4()}.jpg');
  await out.writeAsBytes(img.encodeJpg(healed, quality: 94), flush: true);
  debugPrint('[GlowUpComposite] healed face inpaint specks → ${out.path}');
  return out.path;
}

/// Landmark face hull when available — avoids fixed-ellipse rings on cheeks.
img.Image healFaceInpaintSpecksOnImage(
  img.Image studio,
  img.Image edit, {
  FaceGlowMap? faceMap,
}) {
  final result = img.Image.from(edit);
  final map = faceMap ??
      FaceLandmarkService.detectFromImage(studio) ??
      FaceLandmarkService.detectFromImage(edit);
  var fixed = 0;

  for (var y = 1; y < edit.height - 1; y++) {
    for (var x = 1; x < edit.width - 1; x++) {
      if (map != null) {
        if (FaceLandmarkService.faceStudioSensorWeight(map, x, y) < 0.08) {
          continue;
        }
      } else {
        final cx = edit.width * 0.5;
        final cy = edit.height * 0.42;
        final rx = edit.width * 0.26;
        final ry = edit.height * 0.32;
        final dx = (x - cx) / rx;
        final dy = (y - cy) / ry;
        if (dx * dx + dy * dy > 1) continue;
      }
      if (!_isFaceSkinPixel(studio, x, y)) continue;

      final p = edit.getPixel(x, y);
      if (!_isInpaintHole(p)) continue;

      var sr = 0.0;
      var sg = 0.0;
      var sb = 0.0;
      var n = 0;
      for (final o in const [
        (-1, 0),
        (1, 0),
        (0, -1),
        (0, 1),
        (-1, -1),
        (1, -1),
        (-1, 1),
        (1, 1),
      ]) {
        final nx = x + o.$1;
        final ny = y + o.$2;
        if (!_isFaceSkinPixel(studio, nx, ny)) continue;
        final np = edit.getPixel(nx, ny);
        if (_isInpaintHole(np) || _isFaceNeonSpeck(np)) continue;
        sr += np.r;
        sg += np.g;
        sb += np.b;
        n++;
      }
      if (n < 3) {
        final ps = studio.getPixel(x, y);
        if (!_isInpaintHole(ps) && _luminance(ps) > 32) {
          result.setPixelRgb(x, y, ps.r, ps.g, ps.b);
          fixed++;
        }
        continue;
      }

      result.setPixelRgba(
        x,
        y,
        (sr / n).round(),
        (sg / n).round(),
        (sb / n).round(),
        255,
      );
      fixed++;
    }
  }
  if (fixed > 0) {
    debugPrint('[GlowUpComposite] filled $fixed face inpaint specks');
  }
  return result;
}

int _localGradientMagnitude(img.Image im, int x, int y) {
  final lum = _luminance(im.getPixel(x, y));
  var grad = 0;
  for (var dy = -1; dy <= 1; dy++) {
    for (var dx = -1; dx <= 1; dx++) {
      if (dx == 0 && dy == 0) continue;
      final nx = x + dx;
      final ny = y + dy;
      if (nx < 0 || ny < 0 || nx >= im.width || ny >= im.height) continue;
      grad += (_luminance(im.getPixel(nx, ny)) - lum).abs().round();
    }
  }
  return grad;
}

/// Thin curved AI lines beside outer eye corners (grey/brown ghost strokes).
bool _isOuterEyeLineArtifact(img.Image im, int x, int y) {
  final lum = _luminance(im.getPixel(x, y));
  if (lum < 38 || lum > 165) return false;
  final grad = _localGradientMagnitude(im, x, y);
  if (grad < 52) return false;
  var contrast = 0;
  for (var dy = -2; dy <= 2; dy++) {
    for (var dx = -2; dx <= 2; dx++) {
      if (dx == 0 && dy == 0) continue;
      final nx = x + dx;
      final ny = y + dy;
      if (nx < 0 || ny < 0 || nx >= im.width || ny >= im.height) continue;
      if ((_luminance(im.getPixel(nx, ny)) - lum).abs() > 18) contrast++;
    }
  }
  return contrast >= 5;
}

bool _isIsolatedDarkSkinMark(img.Image im, int x, int y) {
  final p = im.getPixel(x, y);
  final lum = _luminance(p);
  if (lum < 42 || lum > 128) return false;
  var darker = 0;
  var similar = 0;
  for (var dy = -2; dy <= 2; dy++) {
    for (var dx = -2; dx <= 2; dx++) {
      if (dx == 0 && dy == 0) continue;
      final nx = x + dx;
      final ny = y + dy;
      if (nx < 0 || ny < 0 || nx >= im.width || ny >= im.height) continue;
      final nl = _luminance(im.getPixel(nx, ny));
      if (nl > lum + 12) darker++;
      if ((nl - lum).abs() < 18) similar++;
    }
  }
  return darker >= 4 && similar <= 10;
}

/// Small dark moles / AI dots beside outer eye corners — not iris or lashes.
img.Image healOuterEyeDarkMarksOnImage(img.Image edit, FaceGlowMap map) {
  final out = img.Image.from(edit);
  var fixed = 0;

  for (var y = 2; y < edit.height - 2; y++) {
    for (var x = 2; x < edit.width - 2; x++) {
      final zoneW = FaceLandmarkService.outerCanthusMarkHealWeight(map, x, y);
      if (zoneW < 0.2) continue;
      if (!_isIsolatedDarkSkinMark(edit, x, y) &&
          !_isFaceNeonSpeck(edit.getPixel(x, y)) &&
          !_isOuterEyeLineArtifact(edit, x, y)) {
        continue;
      }

      final med = _medianSkinNeighborRgb(edit, x, y, map, radius: 4);
      if (med == null) continue;

      final pe = edit.getPixel(x, y);
      final t = (0.78 * zoneW).clamp(0.55, 0.88);
      out.setPixelRgb(
        x,
        y,
        _blendChannel(pe.r, med[0], t),
        _blendChannel(pe.g, med[1], t),
        _blendChannel(pe.b, med[2], t),
      );
      fixed++;
    }
  }
  if (fixed > 0) {
    debugPrint('[GlowUpComposite] healed $fixed outer-eye dark marks');
  }
  return out;
}

Future<String> healOuterEyeDarkMarksFile(String editedPath) async {
  final edit = img.decodeImage(await File(editedPath).readAsBytes());
  if (edit == null) return editedPath;

  final map = FaceLandmarkService.detectFromImage(edit);
  if (map == null) return editedPath;

  final healed = healOuterEyeDarkMarksOnImage(edit, map);
  final docs = await getApplicationDocumentsDirectory();
  final dir = Directory('${docs.path}/photos');
  if (!await dir.exists()) await dir.create(recursive: true);
  final file = File('${dir.path}/glow_eye_mark_${const Uuid().v4()}.jpg');
  await file.writeAsBytes(img.encodeJpg(healed, quality: 94), flush: true);
  return file.path;
}

/// Blends ghost lines / specks at outer canthi back toward clean skin.
(img.Image, int) healOuterCanthusResidualsOnImage(
  img.Image studio,
  img.Image edit,
  FaceGlowMap map,
) {
  final result = img.Image.from(edit);
  var fixed = 0;

  for (var y = 2; y < edit.height - 2; y++) {
    for (var x = 2; x < edit.width - 2; x++) {
      if (_luminance(studio.getPixel(x, y)) <= 22) continue;
      final zoneW = FaceLandmarkService.outerCanthusMarkHealWeight(map, x, y);
      if (zoneW < 0.22) continue;

      final pe = edit.getPixel(x, y);
      final isArtifact = _isIsolatedDarkSkinMark(edit, x, y) ||
          _isFaceNeonSpeck(pe) ||
          _isOuterEyeLineArtifact(edit, x, y);
      if (!isArtifact) continue;

      final med = _medianSkinNeighborRgb(edit, x, y, map, radius: 5);
      if (med == null) continue;

      final t = (0.82 * zoneW).clamp(0.62, 0.92);
      result.setPixelRgb(
        x,
        y,
        _blendChannel(pe.r, med[0], t),
        _blendChannel(pe.g, med[1], t),
        _blendChannel(pe.b, med[2], t),
      );
      fixed++;
    }
  }

  if (fixed > 0) {
    debugPrint('[GlowUpComposite] healed $fixed outer-canthus residuals (in-memory)');
  }
  return (result, fixed);
}

Future<String> healOuterCanthusResidualsFromStudio({
  required String studioPath,
  required String editedPath,
}) async {
  final pair = await _loadStudioEditPair(studioPath, editedPath);
  if (pair == null) return editedPath;
  final (studio, edit, map) = pair;

  final (result, fixed) = healOuterCanthusResidualsOnImage(studio, edit, map);
  if (fixed < 4) return editedPath;

  final outPath = await _writeSliderJpg(result, tag: 'outer_canthus_heal');
  debugPrint('[GlowUpComposite] outer-canthus heal file → $outPath');
  return outPath;
}