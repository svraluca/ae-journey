import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// Pixel-space facial landmarks (eyes, nose, mouth) in image coordinates.
class FaceGlowMap {
  const FaceGlowMap({
    required this.imageWidth,
    required this.imageHeight,
    required this.leftEye,
    required this.rightEye,
    required this.nose,
    required this.mouthBottom,
    this.leftMouth,
    this.rightMouth,
    this.leftCheek,
    this.rightCheek,
  });

  final int imageWidth;
  final int imageHeight;
  final Offset leftEye;
  final Offset rightEye;
  final Offset nose;
  final Offset mouthBottom;
  final Offset? leftMouth;
  final Offset? rightMouth;
  final Offset? leftCheek;
  final Offset? rightCheek;

  double get interEye => (rightEye - leftEye).distance;

  double get faceScale => interEye.clamp(24.0, imageWidth * 0.45);

  double get eyeRx => faceScale * 0.20;

  double get eyeRy => faceScale * 0.14;

  Offset get faceCenter =>
      Offset((leftEye.dx + rightEye.dx) / 2, (leftEye.dy + rightEye.dy) / 2);

  double nx(double x) => x / imageWidth;

  double ny(double y) => y / imageHeight;
}

class _SubjectBox {
  const _SubjectBox(this.left, this.top, this.right, this.bottom);
  final int left;
  final int top;
  final int right;
  final int bottom;

  double get width => (right - left).toDouble();
  double get height => (bottom - top).toDouble();
  double get cx => (left + right) / 2;
}

/// Portrait landmark detection from the subject silhouette (black-studio cutout).
/// Pure Dart — works on iOS simulator (no ML Kit native dependency).
class FaceLandmarkService {
  static Future<FaceGlowMap?> detectFromFile(String imagePath) async {
    try {
      final file = File(imagePath);
      if (!await file.exists()) return null;

      final decoded = img.decodeImage(await file.readAsBytes());
      if (decoded == null) return null;

      return detectFromImage(decoded);
    } catch (e, st) {
      debugPrint('[FaceLandmarks] detect failed: $e\n$st');
      return null;
    }
  }

  /// Face scan on the original capture — finds real eye positions from luminance.
  static FaceGlowMap? detectFromOriginalCapture(img.Image decoded) {
    final box = _subjectBoundsFromCapture(decoded);
    if (box == null) {
      debugPrint('[FaceScan] no subject in original capture');
      return null;
    }

    var eyes = _detectEyeCentersFromCapture(decoded, box);
    eyes ??= _detectEyeCentersFromLuminanceRow(decoded, box);
    if (eyes == null) {
      debugPrint('[FaceScan] eye row fallback');
      final eyeY = _estimateEyeRowFromCapture(decoded, box);
      return _mapFromSubjectBox(
        decoded,
        box,
        eyeYFrac: (eyeY - box.top) / box.height,
      );
    }

    final leftEye = eyes.$1;
    final rightEye = eyes.$2;
    final w = box.width;
    final h = box.height;
    final l = box.left.toDouble();
    final t = box.top.toDouble();
    final eyeY = (leftEye.dy + rightEye.dy) * 0.5;

    final map = FaceGlowMap(
      imageWidth: decoded.width,
      imageHeight: decoded.height,
      leftEye: leftEye,
      rightEye: rightEye,
      nose: Offset(box.cx, eyeY + h * 0.14),
      mouthBottom: Offset(box.cx, t + h * 0.78),
      leftMouth: Offset(l + w * 0.38, t + h * 0.74),
      rightMouth: Offset(l + w * 0.62, t + h * 0.74),
      leftCheek: Offset(l + w * 0.22, t + h * 0.52),
      rightCheek: Offset(l + w * 0.78, t + h * 0.52),
    );

    debugPrint(
      '[FaceScan] eyes L=(${leftEye.dx.round()},${leftEye.dy.round()}) '
      'R=(${rightEye.dx.round()},${rightEye.dy.round()}) '
      'interEye=${map.interEye.round()}',
    );
    return map;
  }

  /// 0 outside head, 1 inside — studio backdrop must not replace these pixels.
  static double faceShieldWeight(FaceGlowMap map, int x, int y) {
    final s = map.faceScale;
    final eyeY = (map.leftEye.dy + map.rightEye.dy) * 0.5;
    final face = _ellipseWeight(
      x,
      y,
      map.faceCenter.dx,
      eyeY + s * 0.18,
      s * 0.78,
      s * 0.95,
    );
    final eyes = math.max(
      _ellipseWeight(x, y, map.leftEye.dx, map.leftEye.dy, s * 0.50, s * 0.38),
      _ellipseWeight(x, y, map.rightEye.dx, map.rightEye.dy, s * 0.50, s * 0.38),
    );
    return math.max(face, eyes).clamp(0.0, 1.0);
  }

  static FaceGlowMap? detectFromImage(img.Image decoded) {
    final box = _subjectBounds(decoded);
    if (box == null) {
      debugPrint('[FaceLandmarks] no subject silhouette');
      return null;
    }

    return _mapFromSubjectBox(decoded, box, eyeYFrac: 0.43);
  }

  static FaceGlowMap _mapFromSubjectBox(
    img.Image decoded,
    _SubjectBox box, {
    required double eyeYFrac,
  }) {
  // Anthropometric layout inside the head silhouette (frontal portrait).
    final w = box.width;
    final h = box.height;
    final l = box.left.toDouble();
    final t = box.top.toDouble();

    // Fixed iris row — do not use brightest-row search (often lands on brows).
    final eyeY = t + h * eyeYFrac;

    final leftEye = Offset(l + w * 0.34, eyeY);
    final rightEye = Offset(l + w * 0.66, eyeY);
    final nose = Offset(box.cx, t + h * 0.56);
    final mouthBottom = Offset(box.cx, t + h * 0.78);
    final leftMouth = Offset(l + w * 0.38, t + h * 0.74);
    final rightMouth = Offset(l + w * 0.62, t + h * 0.74);
    final leftCheek = Offset(l + w * 0.22, t + h * 0.52);
    final rightCheek = Offset(l + w * 0.78, t + h * 0.52);

    final map = FaceGlowMap(
      imageWidth: decoded.width,
      imageHeight: decoded.height,
      leftEye: leftEye,
      rightEye: rightEye,
      nose: nose,
      mouthBottom: mouthBottom,
      leftMouth: leftMouth,
      rightMouth: rightMouth,
      leftCheek: leftCheek,
      rightCheek: rightCheek,
    );

    debugPrint(
      '[FaceLandmarks] silhouette eyes L=(${leftEye.dx.round()},${leftEye.dy.round()}) '
      'R=(${rightEye.dx.round()},${rightEye.dy.round()}) '
      'interEye=${map.interEye.round()}',
    );
    return map;
  }

  static _SubjectBox? _subjectBoundsFromCapture(img.Image im) {
    var minX = im.width;
    var minY = im.height;
    var maxX = 0;
    var maxY = 0;
    var n = 0;
    for (var y = 0; y < im.height; y++) {
      for (var x = 0; x < im.width; x++) {
        final p = im.getPixel(x, y);
        if (_isCaptureWallPixel(p)) continue;
        if (_luminance(p) < 40) continue;
        minX = math.min(minX, x);
        minY = math.min(minY, y);
        maxX = math.max(maxX, x);
        maxY = math.max(maxY, y);
        n++;
      }
    }
    if (n < 200) return null;
    return _SubjectBox(minX, minY, maxX, maxY);
  }

  static bool _isCaptureWallPixel(img.Pixel p) {
    final lum = _luminance(p);
    if (lum < 120) return false;
    final r = p.r.toInt();
    final g = p.g.toInt();
    final b = p.b.toInt();
    final chroma = math.max(r, math.max(g, b)) - math.min(r, math.min(g, b));
    if (lum > 195 && chroma < 32) return true;
    if (lum > 155 && chroma < 14) return true;
    if (g > r + 12 && g > b + 12 && lum > 100) return true;
    return false;
  }

  /// Brightest points in left/right eye bands (sclera / iris highlights).
  static (Offset, Offset)? _detectEyeCentersFromCapture(
    img.Image im,
    _SubjectBox box,
  ) {
    final y0 = (box.top + box.height * 0.34).round();
    final y1 = (box.top + box.height * 0.50).round();
    final midX = box.cx.round();

    var bestLLum = 0.0;
    var bestL = Offset(box.left + box.width * 0.34, (y0 + y1) * 0.5);
    var bestRLum = 0.0;
    var bestR = Offset(box.left + box.width * 0.66, (y0 + y1) * 0.5);

    for (var y = y0; y <= y1; y++) {
      for (var x = box.left; x <= box.right; x++) {
        final p = im.getPixel(x, y);
        if (_isCaptureWallPixel(p)) continue;
        final lum = _luminance(p);
        if (lum < 45) continue;
        if (x < midX) {
          if (lum > bestLLum) {
            bestLLum = lum;
            bestL = Offset(x.toDouble(), y.toDouble());
          }
        } else {
          if (lum > bestRLum) {
            bestRLum = lum;
            bestR = Offset(x.toDouble(), y.toDouble());
          }
        }
      }
    }

    if (bestLLum < 32 || bestRLum < 32) return null;
    final inter = (bestR.dx - bestL.dx).abs();
    if (inter < box.width * 0.15) return null;
    return (bestL, bestR);
  }

  /// Eye row = band with highest average luminance in mid-face.
  static double _estimateEyeRowFromCapture(img.Image im, _SubjectBox box) {
    final y0 = (box.top + box.height * 0.30).round();
    final y1 = (box.top + box.height * 0.52).round();
    final xL = (box.left + box.width * 0.20).round();
    final xR = (box.right - box.width * 0.20).round();
    var bestY = (y0 + y1) * 0.5;
    var bestScore = 0.0;
    for (var y = y0; y <= y1; y++) {
      var sum = 0.0;
      var c = 0;
      for (var x = xL; x <= xR; x++) {
        final p = im.getPixel(x, y);
        if (_isCaptureWallPixel(p)) continue;
        sum += _luminance(p);
        c++;
      }
      if (c > 0 && sum > bestScore) {
        bestScore = sum;
        bestY = y.toDouble();
      }
    }
    return bestY;
  }

  /// Left/right peak luminance on the estimated eye row.
  static (Offset, Offset)? _detectEyeCentersFromLuminanceRow(
    img.Image im,
    _SubjectBox box,
  ) {
    final eyeY = _estimateEyeRowFromCapture(im, box).round();
    final y0 = (eyeY - box.height * 0.04).round();
    final y1 = (eyeY + box.height * 0.04).round();
    final midX = box.cx.round();
    var bestLLum = 0.0;
    var bestL = Offset(box.left + box.width * 0.34, eyeY.toDouble());
    var bestRLum = 0.0;
    var bestR = Offset(box.left + box.width * 0.66, eyeY.toDouble());

    for (var y = y0; y <= y1; y++) {
      for (var x = box.left; x <= box.right; x++) {
        final p = im.getPixel(x, y);
        if (_isCaptureWallPixel(p)) continue;
        final lum = _luminance(p);
        if (lum < 30) continue;
        if (x < midX) {
          if (lum > bestLLum) {
            bestLLum = lum;
            bestL = Offset(x.toDouble(), y.toDouble());
          }
        } else if (lum > bestRLum) {
          bestRLum = lum;
          bestR = Offset(x.toDouble(), y.toDouble());
        }
      }
    }
    if (bestLLum < 28 || bestRLum < 28) return null;
    return (bestL, bestR);
  }

  static _SubjectBox? _subjectBounds(img.Image im) {
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
    return _SubjectBox(minX, minY, maxX, maxY);
  }

  static double _luminance(img.Pixel p) =>
      0.299 * p.r + 0.587 * p.g + 0.114 * p.b;

  /// 1 = too high on face (brow/forehead) — never lighten or blur here.
  static double upperFaceGuard(FaceGlowMap map, int y) {
    final limit = map.leftEye.dy - map.faceScale * 0.12;
    if (y >= limit) return 0;
    final t = ((limit - y) / (map.faceScale * 0.15)).clamp(0.0, 1.0);
    return t;
  }

  /// 0 = ok to edit, 1 = keep original brow pixels (above eyes, not on lids).
  static double browPreserveWeight(FaceGlowMap map, int x, int y) {
    final s = map.faceScale;
    final eyeY = (map.leftEye.dy + map.rightEye.dy) / 2;
    // Below lash line — allow under-eye / lid edits.
    if (y > eyeY - s * 0.04) return 0;

    final browCy = eyeY - s * 0.20;
    final wL = _ellipseWeight(
      x,
      y,
      map.leftEye.dx,
      browCy,
      s * 0.30,
      s * 0.12,
    );
    final wR = _ellipseWeight(
      x,
      y,
      map.rightEye.dx,
      browCy,
      s * 0.30,
      s * 0.12,
    );
    final wBridge = _ellipseWeight(
      x,
      y,
      map.faceCenter.dx,
      browCy - s * 0.02,
      s * 0.22,
      s * 0.09,
    );
    final wFore = _ellipseWeight(
          x,
          y,
          map.faceCenter.dx,
          browCy - s * 0.14,
          s * 0.18,
          s * 0.08,
        ) *
        0.55;
    return math.max(
      math.max(math.max(wL, wR), wBridge),
      wFore,
    ).clamp(0.0, 1.0);
  }

  static Offset mouthCorner(FaceGlowMap map, {required bool left}) {
    final s = map.faceScale;
    if (left) {
      return map.leftMouth ?? Offset(map.nose.dx - s * 0.25, map.mouthBottom.dy);
    }
    return map.rightMouth ?? Offset(map.nose.dx + s * 0.25, map.mouthBottom.dy);
  }

  /// Distance from (x,y) to the nasolabial segment on one side.
  static double distanceToNasolabial(FaceGlowMap map, double x, double y, {required bool left}) {
    return _distPointToSegment(Offset(x, y), map.nose, mouthCorner(map, left: left));
  }

  /// 0 at nose base, 1 at mouth corner along one nasolabial fold.
  static double alongNasolabialT(
    FaceGlowMap map,
    double x,
    double y, {
    required bool left,
  }) {
    final a = map.nose;
    final b = mouthCorner(map, left: left);
    final abx = b.dx - a.dx;
    final aby = b.dy - a.dy;
    final len2 = abx * abx + aby * aby;
    if (len2 < 1) return 0;
    final t = ((x - a.dx) * abx + (y - a.dy) * aby) / len2;
    return t.clamp(0.0, 1.0);
  }

  /// Soft block near nasolabial — avoids hard cheek arcs from tear-trough brighten.
  static double smileLineLightenBlock(FaceGlowMap map, int x, int y) {
    final s = map.faceScale;
    final d = math.min(
      distanceToNasolabial(map, x.toDouble(), y.toDouble(), left: true),
      distanceToNasolabial(map, x.toDouble(), y.toDouble(), left: false),
    );
    final eyeY = (map.leftEye.dy + map.rightEye.dy) / 2;
    if (y < eyeY + s * 0.10 || y > eyeY + s * 0.30) return 0;
    if (d >= s * 0.16) return 0;
    return (1 - d / (s * 0.16)).clamp(0.0, 1.0);
  }

  /// Mouth-corner height mismatch (+ = patient's left corner lower on image).
  static double lipCornerHeightDelta(FaceGlowMap map) {
    final left = mouthCorner(map, left: true);
    final right = mouthCorner(map, left: false);
    return left.dy - right.dy;
  }

  static bool lipsNeedSymmetryBalance(FaceGlowMap map) =>
      lipCornerHeightDelta(map).abs() > map.faceScale * 0.0025;

  static bool lipsNeedAnySymmetryWork(FaceGlowMap map) =>
      lipsNeedSymmetryBalance(map) || lipsNeedVolumeSymmetry(map);

  /// Width mismatch between left/right lip halves (+ = left half wider on image).
  static double lipHalfWidthDelta(FaceGlowMap map) {
    final left = mouthCorner(map, left: true);
    final right = mouthCorner(map, left: false);
    final mid = (left.dx + right.dx) * 0.5;
    return (mid - left.dx).abs() - (right.dx - mid).abs();
  }

  static bool lipsNeedVolumeSymmetry(FaceGlowMap map) =>
      lipHalfWidthDelta(map).abs() > map.faceScale * 0.012;

  /// Nose tip offset from facial midline (+ = toward image right).
  static double noseTipDeviation(FaceGlowMap map) =>
      map.nose.dx - map.faceCenter.dx;

  /// True when the tip is visibly off-center (landmark-based).
  static bool noseNeedsCorrection(FaceGlowMap map) =>
      noseTipDeviation(map).abs() > map.faceScale * 0.02;

  /// FLUX prompt clause for visible nasal-tip asymmetry.
  static String replicateNoseAsymmetryPrompt(FaceGlowMap map) {
    final dev = noseTipDeviation(map);
    final s = map.faceScale;
    if (dev.abs() < s * 0.018) return '';
    final patientSide = dev > 0 ? 'right' : 'left';
    return 'NOSE (required): nasal tip visibly off-center toward patient\'s $patientSide — '
        'rhinoplasty preview: straighten bridge, center tip on midline (~8%), '
        'balanced nostrils, natural skin tone — do not widen or shorten the nose.';
  }

  /// 1 = below vermillion — exclude from lip volume warp (chin).
  static double chinExclusion(FaceGlowMap map, int y) {
    final limit = map.mouthBottom.dy + map.faceScale * 0.08;
    if (y <= limit) return 0;
    final t = ((y - limit) / (map.faceScale * 0.10)).clamp(0.0, 1.0);
    return t;
  }

  static double _distPointToSegment(Offset p, Offset a, Offset b) {
    final ab = b - a;
    final len2 = ab.dx * ab.dx + ab.dy * ab.dy;
    if (len2 < 1) return (p - a).distance;
    final t = ((p.dx - a.dx) * ab.dx + (p.dy - a.dy) * ab.dy) / len2;
    final tc = t.clamp(0.0, 1.0);
    final proj = Offset(a.dx + ab.dx * tc, a.dy + ab.dy * tc);
    return (p - proj).distance;
  }

  /// 0 = outside face, 1 = inside — blocks studio defringe / black flood on skin.
  static double faceStudioSensorWeight(FaceGlowMap map, int x, int y) {
    final s = map.faceScale;
    final eyeY = (map.leftEye.dy + map.rightEye.dy) / 2;

    final faceOval = _ellipseWeight(
      x,
      y,
      map.faceCenter.dx,
      map.nose.dy - s * 0.04,
      s * 0.60,
      s * 0.74,
    );
    final forehead = _ellipseWeight(
      x,
      y,
      map.faceCenter.dx,
      eyeY - s * 0.30,
      s * 0.50,
      s * 0.24,
    );
    final eyes = eyeNaturalPreserveWeight(map, x, y);
    final brows = browPreserveWeight(map, x, y);
    final nose = _ellipseWeight(
      x,
      y,
      map.nose.dx,
      map.nose.dy,
      s * 0.16,
      s * 0.24,
    );
    final mouth = lipColorPreserveWeight(map, x, y);
    final cheekL = map.leftCheek != null
        ? _ellipseWeight(
            x,
            y,
            map.leftCheek!.dx,
            map.leftCheek!.dy,
            s * 0.24,
            s * 0.20,
          )
        : 0.0;
    final cheekR = map.rightCheek != null
        ? _ellipseWeight(
            x,
            y,
            map.rightCheek!.dx,
            map.rightCheek!.dy,
            s * 0.24,
            s * 0.20,
          )
        : 0.0;

    return math
        .max(
          math.max(
            math.max(math.max(faceOval, forehead), math.max(eyes, brows)),
            math.max(nose, mouth),
          ),
          math.max(cheekL, cheekR),
        )
        .clamp(0.0, 1.0);
  }

  /// 0 = outside, 1 = tear-trough only (below lash line — never over iris).
  static double underEyeHarmonizeWeight(FaceGlowMap map, int x, int y) {
    final s = map.faceScale;
    final eyeY = (map.leftEye.dy + map.rightEye.dy) / 2;
    if (y < eyeY + s * 0.09 || y > eyeY + s * 0.24) return 0;
    if (eyeNaturalPreserveWeight(map, x, y) > 0.05) return 0;

    final wL = _ellipseWeight(
      x,
      y,
      map.leftEye.dx,
      eyeY + s * 0.16,
      s * 0.24,
      s * 0.09,
    );
    final wR = _ellipseWeight(
      x,
      y,
      map.rightEye.dx,
      eyeY + s * 0.16,
      s * 0.24,
      s * 0.09,
    );
    return math.max(wL, wR).clamp(0.0, 1.0);
  }

  /// Crow's-feet / temple beside outer eye corners (small dark AI dots land here).
  static double outerCanthusMarkHealWeight(FaceGlowMap map, int x, int y) {
    final s = map.faceScale;
    final eyeY = (map.leftEye.dy + map.rightEye.dy) / 2;
    // Include upper lid crease — AI often leaves curved ghost lines there.
    if (y < eyeY - s * 0.12 || y > eyeY + s * 0.32) return 0;
    if (eyeNaturalPreserveWeight(map, x, y) > 0.18) return 0;

    final wOuterL = _ellipseWeight(
      x,
      y,
      map.leftEye.dx - s * 0.24,
      eyeY + s * 0.14,
      s * 0.16,
      s * 0.13,
    );
    final wOuterR = _ellipseWeight(
      x,
      y,
      map.rightEye.dx + s * 0.24,
      eyeY + s * 0.14,
      s * 0.16,
      s * 0.13,
    );
    return math.max(wOuterL, wOuterR).clamp(0.0, 1.0);
  }

  /// Inner eye corners + nose bridge (neon AI specks often land here).
  static double innerCanthusNeonFixWeight(FaceGlowMap map, int x, int y) {
    final s = map.faceScale;
    final eyeY = (map.leftEye.dy + map.rightEye.dy) / 2;
    if (y < eyeY - s * 0.06 || y > eyeY + s * 0.20) return 0;

    final mid = (map.leftEye.dx + map.rightEye.dx) / 2;
    final innerLx = map.leftEye.dx + (mid - map.leftEye.dx) * 0.42;
    final innerRx = map.rightEye.dx + (mid - map.rightEye.dx) * 0.42;
    final cy = eyeY + s * 0.09;

    final wL = _ellipseWeight(x, y, innerLx, cy, s * 0.16, s * 0.13);
    final wR = _ellipseWeight(x, y, innerRx, cy, s * 0.16, s * 0.13);
    final wBridge = _ellipseWeight(
      x,
      y,
      map.nose.dx,
      cy,
      s * 0.11,
      s * 0.14,
    );
    return math.max(math.max(wL, wR), wBridge).clamp(0.0, 1.0);
  }

  /// 0 = ok to edit, 1 = restore natural lids/iris (blocks AI eyeshadow/liner).
  static double eyeNaturalPreserveWeight(FaceGlowMap map, int x, int y) {
    final s = map.faceScale;
    final eyeY = (map.leftEye.dy + map.rightEye.dy) / 2;
    // Keep tear-trough edits below the lash line.
    if (y > eyeY + s * 0.12) return 0;

    final wL = _ellipseWeight(
      x,
      y,
      map.leftEye.dx,
      map.leftEye.dy,
      s * 0.34,
      s * 0.24,
    );
    final wR = _ellipseWeight(
      x,
      y,
      map.rightEye.dx,
      map.rightEye.dy,
      s * 0.34,
      s * 0.24,
    );
    return math.max(wL, wR).clamp(0.0, 1.0);
  }

  /// 0 = ok to edit, 1 = restore natural lip color (volume edits may stay).
  static double lipColorPreserveWeight(FaceGlowMap map, int x, int y) {
    final s = map.faceScale;
    final mb = map.mouthBottom;
    final lipW = map.leftMouth != null && map.rightMouth != null
        ? (map.rightMouth!.dx - map.leftMouth!.dx).abs() * 0.55
        : s * 0.28;
    final cx = map.leftMouth != null && map.rightMouth != null
        ? (map.leftMouth!.dx + map.rightMouth!.dx) / 2
        : mb.dx;
    return _ellipseWeight(
      x,
      y,
      cx,
      mb.dy - s * 0.03,
      lipW,
      s * 0.13,
    ).clamp(0.0, 1.0);
  }

  /// 0 = ok to edit, 1 = protect (inside eye).
  static double eyeExclusion(FaceGlowMap map, int x, int y) {
    final wL = _ellipseWeight(
      x,
      y,
      map.leftEye.dx,
      map.leftEye.dy,
      map.eyeRx,
      map.eyeRy,
    );
    final wR = _ellipseWeight(
      x,
      y,
      map.rightEye.dx,
      map.rightEye.dy,
      map.eyeRx,
      map.eyeRy,
    );
    return math.max(wL, wR).clamp(0.0, 1.0);
  }

  static double _ellipseWeight(
    int x,
    int y,
    double cx,
    double cy,
    double rx,
    double ry,
  ) {
    if (rx <= 0 || ry <= 0) return 0;
    final dx = (x - cx) / rx;
    final dy = (y - cy) / ry;
    final d = dx * dx + dy * dy;
    if (d >= 1) return 0;
    final t = 1 - d;
    return t * t * (3 - 2 * t);
  }
}
