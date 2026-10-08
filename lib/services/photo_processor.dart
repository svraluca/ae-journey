import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'face_landmark_service.dart';

/// Distinguishes a live camera capture from a library-picked photo.
enum PhotoSource { camera, library }

/// Stage-1 studio fill — soft charcoal by default (not pure #000).
class StudioBackdrop {
  const StudioBackdrop(this.r, this.g, this.b);

  static const soft = StudioBackdrop(14, 14, 18);
  /// Neutral grey studio — reads cleaner than charcoal on eyes.
  static const grey = StudioBackdrop(38, 38, 44);
  static const pureBlack = StudioBackdrop(0, 0, 0);

  final int r;
  final int g;
  final int b;

  img.ColorRgb8 get color => img.ColorRgb8(r, g, b);

  double get luminance => 0.299 * r + 0.587 * g + 0.114 * b;

  bool isBackdropPixel(img.Pixel p, {double lumSlack = 24}) {
    if (_lum(p) > luminance + lumSlack) return false;
    final dr = (p.r.toInt() - r).abs();
    final dg = (p.g.toInt() - g).abs();
    final db = (p.b.toInt() - b).abs();
    return dr + dg + db < 55;
  }
}

/// [GLOW_UP_STUDIO_BACKDROP]: grey (default) | soft | black | #RRGGBB
StudioBackdrop studioBackdrop() {
  final v = (dotenv.env['GLOW_UP_STUDIO_BACKDROP'] ?? 'grey').trim().toLowerCase();
  if (v == 'black' || v == 'pure' || v == '0') {
    return StudioBackdrop.pureBlack;
  }
  if (v == 'soft' || v == 'charcoal') {
    return StudioBackdrop.soft;
  }
  if (v.startsWith('#') && v.length >= 7) {
    final hex = v.substring(1);
    if (hex.length >= 6) {
      final r = int.tryParse(hex.substring(0, 2), radix: 16) ?? 14;
      final g = int.tryParse(hex.substring(2, 4), radix: 16) ?? 14;
      final b = int.tryParse(hex.substring(4, 6), radix: 16) ?? 18;
      return StudioBackdrop(r, g, b);
    }
  }
  return StudioBackdrop.grey;
}

void _paintStudioBackdrop(img.Image im, int x, int y) {
  final b = studioBackdrop();
  im.setPixelRgb(x, y, b.r, b.g, b.b);
}

/// Composites rembg RGBA PNG over studio backdrop (straight-alpha, no blow-up halos).
Future<String> compositeCutoutOverBackdrop({
  required List<int> rgbaPng,
  required PhotoSource source,
  String? originalPhotoPath,
}) async {
  final decoded = img.decodePng(Uint8List.fromList(rgbaPng));
  if (decoded == null) {
    throw const FormatException('rembg output is not a valid PNG');
  }
  final fg = _despillLightBackground(decoded);

  final w = fg.width;
  final h = fg.height;
  var keep = _largestForegroundMask(fg, minAlpha: 0.10);
  keep = _fillInteriorMaskHoles(keep, fg, w, h);

  final originalAligned =
      await _loadRgbAlignedTo(originalPhotoPath, w, h);

  final map =
      (originalAligned != null
          ? FaceLandmarkService.detectFromOriginalCapture(originalAligned)
          : null) ??
      FaceLandmarkService.detectFromImage(fg) ??
      FaceLandmarkService.detectFromImage(
        _roughSilhouettePreview(fg, keep, w, h),
      );
  if (map != null) {
    _expandKeepMaskForEyes(keep, map, w, h);
    _expandFaceShieldMask(keep, map, w, h);
  }

  keep = _dilateMask(keep, w, h, radius: 2);

  final backdrop = studioBackdrop();
  final bg = img.Image(width: w, height: h)..clear(backdrop.color);
  debugPrint(
    '[PhotoProcessor] studio backdrop #'
    '${backdrop.r.toRadixString(16).padLeft(2, '0')}'
    '${backdrop.g.toRadixString(16).padLeft(2, '0')}'
    '${backdrop.b.toRadixString(16).padLeft(2, '0')}',
  );

  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = y * w + x;

      final p = fg.getPixel(x, y);
      final a = (p.a / 255.0).clamp(0.0, 1.0);
      final shield = map != null
          ? FaceLandmarkService.faceShieldWeight(map, x, y)
          : 0.0;

      final inEye = map != null && _eyeRegionWeight(map, x, y) > 0.08;
      final inSclera = map != null && _scleraRegionWeight(map, x, y) > 0.05;

      // Eyes always from original capture — rembg cannot touch them.
      if (originalAligned != null && (inEye || inSclera)) {
        final po = originalAligned.getPixel(x, y);
        if (!_isPickBackgroundPixel(po)) {
          bg.setPixelRgb(
            x,
            y,
            po.r.toInt(),
            po.g.toInt(),
            po.b.toInt(),
          );
          continue;
        }
      }

      // Face scan shield — never leave backdrop in head holes.
      if (shield > 0.08 && originalAligned != null) {
        if (keep[i] == 0 || a < 0.08) {
          final po = originalAligned.getPixel(x, y);
          if (!_isPickBackgroundPixel(po)) {
        bg.setPixelRgb(
          x,
          y,
              po.r.toInt(),
              po.g.toInt(),
              po.b.toInt(),
            );
            continue;
          }
        }
      }
      if (keep[i] == 0 && !inEye && !inSclera && shield < 0.08) continue;
      if (a < 0.03 && !inEye && !inSclera && shield < 0.08) continue;
      // White sclera reads as "wall halo" — must not skip inside eyes.
      if (_isLightWallHalo(p) && !inEye && !inSclera) continue;

      final ab = inEye ? _eyeCompositeAlpha(p, a) : _hairCompositeAlpha(p, a);
      if (ab < 0.04) continue;

      final r = (p.r * ab).round().clamp(0, 255);
      final g = (p.g * ab).round().clamp(0, 255);
      final b = (p.b * ab).round().clamp(0, 255);
      if (!inEye && _isLeakedBackground(r, g, b, ab)) continue;

      bg.setPixelRgb(x, y, r, g, b);
    }
  }

  final faceMap = map;
  final original = originalAligned;
  var cleaned = _restoreHairEdgesFromRembg(bg, fg, faceMap);
  cleaned = sanitizeStudioPortraitMild(cleaned, protectMap: faceMap);
  if (original != null && faceMap != null) {
    cleaned = _pasteProtectedFaceFromOriginal(cleaned, original, faceMap);
  }
  final jpeg = img.encodeJpg(cleaned, quality: 96);
  final docs = await getApplicationDocumentsDirectory();
  final dir = Directory('${docs.path}/photos');
  if (!await dir.exists()) await dir.create(recursive: true);
  final out = File('${dir.path}/glow_${const Uuid().v4()}.jpg');
  await out.writeAsBytes(jpeg, flush: true);
  return out.path;
}

/// Keeps only the largest rembg foreground blob (drops wall/hair stray islands).
Uint8List _largestForegroundMask(img.Image rgba, {required double minAlpha}) {
  final w = rgba.width;
  final h = rgba.height;
  final n = w * h;
  final fg = Uint8List(n);
  for (var i = 0; i < n; i++) {
    final y = i ~/ w;
    final x = i % w;
    if (rgba.getPixel(x, y).a / 255.0 >= minAlpha) fg[i] = 1;
  }

  final labels = List<int>.filled(n, -1);
  var bestLabel = -1;
  var bestSize = 0;
  var nextLabel = 0;

  for (var i = 0; i < n; i++) {
    if (fg[i] == 0 || labels[i] >= 0) continue;
    var size = 0;
    final q = <int>[i];
    labels[i] = nextLabel;
    while (q.isNotEmpty) {
      final cur = q.removeLast();
      size++;
      final cx = cur % w;
      final cy = cur ~/ w;
      for (final d in const [
        (1, 0),
        (-1, 0),
        (0, 1),
        (0, -1),
      ]) {
        final nx = cx + d.$1;
        final ny = cy + d.$2;
        if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
        final ni = ny * w + nx;
        if (fg[ni] == 0 || labels[ni] >= 0) continue;
        labels[ni] = nextLabel;
        q.add(ni);
      }
    }
    if (size > bestSize) {
      bestSize = size;
      bestLabel = nextLabel;
    }
    nextLabel++;
  }

  final keep = Uint8List(n);
  if (bestLabel < 0) return keep;
  for (var i = 0; i < n; i++) {
    if (labels[i] == bestLabel) keep[i] = 1;
  }
  debugPrint('[PhotoProcessor] rembg mask kept $bestSize / $n px');
  return keep;
}

/// Border flood + peel light non-subject pixels attached to the silhouette.
img.Image purgeAggressiveStudioBackground(img.Image im, {FaceGlowMap? protectMap}) {
  var out = purgeBorderBackground(im, aggressive: true, protectMap: protectMap);
  out = _peelAttachedBackdrop(out, protectMap: protectMap);
  return out;
}

/// Stage-1 safe cleanup: mild edge flood, eye-safe defringe, soft portrait light.
img.Image sanitizeStudioPortrait(img.Image im, {FaceGlowMap? protectMap}) {
  var map = protectMap ?? FaceLandmarkService.detectFromImage(im);
  var out = purgeBorderBackground(im, aggressive: false, protectMap: map);
  out = defringeBlackStudio(out, protectMap: map, maxPasses: 6);
  out = applyGentleStudioPortraitLight(out, map: map);
  out = _applyStudioClarity(out, map: map);
  out = _healBlackSpecksOnFace(out, map: map);
  return out;
}

/// Studio before — edge cleanup only (no studio light — preserves eyes/face).
img.Image sanitizeStudioPortraitMild(img.Image im, {FaceGlowMap? protectMap}) {
  final map = protectMap ?? FaceLandmarkService.detectFromImage(im);
  var out = purgeBorderBackground(im, aggressive: false, protectMap: map);
  out = _healBlackSpecksOnFace(out, map: map);
  return out;
}

/// Resize pick for rembg — keep full head/hair, longest side ≤ [maxSide].
Future<String> resizePickForStudioMaxSide(
  String imagePath, {
  int maxSide = 1024,
}) async {
  final raw = await File(imagePath).readAsBytes();
  final im = img.decodeImage(Uint8List.fromList(raw));
  if (im == null) return imagePath;
  if (im.width <= maxSide && im.height <= maxSide) return imagePath;

  int w;
  int h;
  if (im.width >= im.height) {
    w = maxSide;
    h = (maxSide * im.height / im.width).round().clamp(1, maxSide);
  } else {
    h = maxSide;
    w = (maxSide * im.width / im.height).round().clamp(1, maxSide);
  }

  final resized = img.copyResize(
    im,
    width: w,
    height: h,
    interpolation: img.Interpolation.cubic,
  );

  final docs = await getApplicationDocumentsDirectory();
  final dir = Directory('${docs.path}/photos');
  if (!await dir.exists()) await dir.create(recursive: true);
  final out = File('${docs.path}/glow_pick_${const Uuid().v4()}.jpg');
  await out.writeAsBytes(img.encodeJpg(resized, quality: 94), flush: true);
  debugPrint(
    '[PhotoProcessor] pick resize ${im.width}x${im.height} → ${w}x$h',
  );
  return out.path;
}

/// Pull orange/warm AI cast back toward studio before tones (face only).
Future<String> neutralizeAfterSkinToneFile(
  String studioPath,
  String editedPath,
) async {
  final studio = img.decodeImage(await File(studioPath).readAsBytes());
  final edit = img.decodeImage(await File(editedPath).readAsBytes());
  if (studio == null || edit == null) return editedPath;

  final map = FaceLandmarkService.detectFromImage(studio);
  final out = neutralizeWarmSkinCast(studio, edit, map: map);
  final docs = await getApplicationDocumentsDirectory();
  final dir = Directory('${docs.path}/photos');
  if (!await dir.exists()) await dir.create(recursive: true);
  final file = File('${dir.path}/glow_neutral_${const Uuid().v4()}.jpg');
  await file.writeAsBytes(img.encodeJpg(out, quality: 96), flush: true);
  return file.path;
}

img.Image neutralizeWarmSkinCast(
  img.Image studio,
  img.Image edit, {
  FaceGlowMap? map,
}) {
  final faceMap = map ?? FaceLandmarkService.detectFromImage(studio);
  if (faceMap == null) return edit;

  final out = img.Image.from(edit);
  var n = 0;

  for (var y = 0; y < edit.height; y++) {
    for (var x = 0; x < edit.width; x++) {
      if (FaceLandmarkService.faceStudioSensorWeight(faceMap, x, y) < 0.14) {
        continue;
      }
      // Tear-trough — warm neutralize can leave green/cyan cast.
      if (FaceLandmarkService.underEyeHarmonizeWeight(faceMap, x, y) > 0.10) {
        continue;
      }
      final pe = edit.getPixel(x, y);
      final ps = studio.getPixel(x, y);
      if (_lum(pe) <= 32 || _lum(ps) <= 32) continue;

      final editWarm = pe.r.toInt() - pe.b.toInt();
      final refWarm = ps.r.toInt() - ps.b.toInt();
      if (editWarm <= refWarm + 14) continue;

      final cut = ((editWarm - refWarm) * 0.50).round().clamp(0, 55);
      final floor = math.max(pe.g.toInt(), pe.b.toInt()) + 4;
      final r = (pe.r - cut).clamp(floor, 255);
      final g = pe.g.toInt();
      final b = pe.b.toInt();
      if (r == pe.r.toInt() && g == pe.g.toInt() && b == pe.b.toInt()) {
        continue;
      }
      out.setPixelRgb(x, y, r, g, b);
      n++;
    }
  }

  if (n > 0) {
    debugPrint('[PhotoProcessor] neutralized warm cast on $n skin px');
  }
  return out;
}

/// True when the edit has noticeably more orange/warm skin than the studio before.
bool editHasExcessiveWarmCast(
  img.Image studio,
  img.Image edit, {
  FaceGlowMap? map,
}) {
  final faceMap = map ?? FaceLandmarkService.detectFromImage(studio);
  if (faceMap == null) return false;

  var warm = 0;
  var sampled = 0;
  for (var y = 0; y < edit.height; y++) {
    for (var x = 0; x < edit.width; x++) {
      if (FaceLandmarkService.faceStudioSensorWeight(faceMap, x, y) < 0.18) {
        continue;
      }
      if (FaceLandmarkService.underEyeHarmonizeWeight(faceMap, x, y) > 0.12) {
        continue;
      }
      final pe = edit.getPixel(x, y);
      final ps = studio.getPixel(x, y);
      if (_lum(pe) <= 36 || _lum(ps) <= 36) continue;
      sampled++;
      final editWarm = pe.r.toInt() - pe.b.toInt();
      final refWarm = ps.r.toInt() - ps.b.toInt();
      if (editWarm >= refWarm + 16 && pe.r > pe.g + 8) warm++;
    }
  }
  if (sampled < 80) return false;
  return warm / sampled >= 0.14;
}

/// [GLOW_UP_STUDIO_MODE]: openai (default) | rembg | replicate_flux
String studioBackgroundMode() =>
    (dotenv.env['GLOW_UP_STUDIO_MODE'] ?? 'openai').trim().toLowerCase();

/// OpenAI background-only — skip rembg composite and local face paste.
bool useOpenAiStudioOnly() {
  final m = studioBackgroundMode();
  return m == 'openai' || m == 'gpt' || m == 'gpt-image-1';
}

bool useRembgStudioPipeline() {
  final m = studioBackgroundMode();
  return m == 'rembg' ||
      m == 'replicate_flux' ||
      m == 'flux' ||
      m == 'ai' ||
      m == 'replicate';
}

/// True when stage 1 used AI background replace (not rembg composite).
bool isAiGeneratedStudioMode() => useOpenAiStudioOnly() || !useRembgStudioPipeline();

/// AI studio — no border flood (charcoal bg floods into face); minimal eye touch-up.
img.Image polishAiStudioPortrait(img.Image im, {FaceGlowMap? protectMap}) {
  final faceMap = protectMap ?? FaceLandmarkService.detectFromImage(im);
  var out = applyGentleStudioPortraitLight(im, map: faceMap);
  out = _healBlackSpecksOnFace(out, map: faceMap);
  return out;
}

/// Single polish pass for stage-1 studio JPEG (after rembg composite).
Future<String> polishStudioBeforeFile(
  String imagePath, {
  String? originalPhotoPath,
  bool? aiGeneratedStudio,
}) async {
  final raw = img.decodeImage(await File(imagePath).readAsBytes());
  if (raw == null) return imagePath;

  img.Image? original;
  FaceGlowMap? map;
  if (originalPhotoPath != null) {
    original = await _loadRgbAlignedTo(originalPhotoPath, raw.width, raw.height);
    if (original != null) {
      map = FaceLandmarkService.detectFromOriginalCapture(original);
    }
  }
  map ??= FaceLandmarkService.detectFromImage(raw);

  final aiStudio = aiGeneratedStudio ?? isAiGeneratedStudioMode();
  var im = aiStudio
      ? polishAiStudioPortrait(raw, protectMap: map)
      : sanitizeStudioPortraitMild(raw, protectMap: map);
  if (map != null && original != null) {
      im = aiStudio
          ? _touchUpEyesOnly(im, original, map)
          : _pasteProtectedFaceFromOriginal(im, original, map);
  }
  final jpeg = img.encodeJpg(im, quality: 96);
  final docs = await getApplicationDocumentsDirectory();
  final dir = Directory('${docs.path}/photos');
  if (!await dir.exists()) await dir.create(recursive: true);
  final out = File('${dir.path}/glow_studio_${const Uuid().v4()}.jpg');
  await out.writeAsBytes(jpeg, flush: true);
  debugPrint('[PhotoProcessor] studio before polished → ${out.path}');
  return out.path;
}

/// Remove white/grey wall spill from rembg semi-transparent edges.
img.Image _despillLightBackground(img.Image rgba) {
  final out = img.Image.from(rgba);
  var n = 0;
  for (var y = 0; y < rgba.height; y++) {
    for (var x = 0; x < rgba.width; x++) {
      final p = rgba.getPixel(x, y);
      final a = p.a / 255.0;
      if (a < 0.05 || a > 0.98) continue;
      var r = p.r.toDouble();
      var g = p.g.toDouble();
      var b = p.b.toDouble();
      final lum = _lumRgb(r.round(), g.round(), b.round());
      if (lum > 88) {
        final spill = ((lum - 72) / lum).clamp(0.0, 0.92) * (1 - a) * 0.95;
        r *= 1 - spill;
        g *= 1 - spill;
        b *= 1 - spill;
        n++;
      }
      if (g > r + 14 && g > b + 14) {
        final t = 0.45 * (1 - a);
        g = g * (1 - t) + (r + b) / 2 * t;
      }
      out.setPixelRgba(
        x,
        y,
        r.round().clamp(0, 255),
        g.round().clamp(0, 255),
        b.round().clamp(0, 255),
        p.a.toInt(),
      );
    }
  }
  if (n > 0) {
    debugPrint('[PhotoProcessor] despilled $n edge px from light background');
  }
  return out;
}

Uint8List _dilateMask(Uint8List mask, int w, int h, {required int radius}) {
  final out = Uint8List.fromList(mask);
  for (var pass = 0; pass < radius; pass++) {
    final src = Uint8List.fromList(out);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        if (src[y * w + x] != 0) continue;
        for (var dy = -1; dy <= 1; dy++) {
          for (var dx = -1; dx <= 1; dx++) {
            if (dx == 0 && dy == 0) continue;
            final nx = x + dx;
            final ny = y + dy;
            if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
            if (src[ny * w + nx] == 1) {
              out[y * w + x] = 1;
              break;
            }
          }
        }
      }
    }
  }
  return out;
}

/// Strips grey hair halos after composite (studio confirm quality).
img.Image scrubStudioCutoutFringe(img.Image im, {FaceGlowMap? map}) {
  final b = _studioSubjectBounds(im);
  final out = img.Image(width: im.width, height: im.height);

  for (var y = 0; y < im.height; y++) {
    for (var x = 0; x < im.width; x++) {
      final p = im.getPixel(x, y);
      final inside = b != null &&
          x >= b.left &&
          x <= b.right &&
          y >= b.top &&
          y <= b.bottom;

      if (inside) {
        if (_isProtectedFromRimCleanup(map, x, y)) {
          out.setPixelRgb(x, y, p.r.toInt(), p.g.toInt(), p.b.toInt());
          continue;
        }
        if (_isLightWallHalo(p) &&
            _touchesBackground(im, x, y) &&
            _isNearSilhouetteEdge(im, x, y)) {
          _paintStudioBackdrop(out, x, y);
          continue;
        }
        out.setPixelRgb(x, y, p.r.toInt(), p.g.toInt(), p.b.toInt());
        continue;
      }

      _paintStudioBackdrop(out, x, y);
    }
  }
  return out;
}

img.Image _applyStudioClarity(img.Image im, {FaceGlowMap? map}) {
  final b = _studioSubjectBounds(im);
  if (b == null) return im;
  final blurred = img.gaussianBlur(img.Image.from(im), radius: 1);
  final out = img.Image.from(im);
  for (var y = 0; y < im.height; y++) {
    for (var x = 0; x < im.width; x++) {
      if (_lum(im.getPixel(x, y)) <= 28) continue;
      final eyeW = map != null
          ? FaceLandmarkService.eyeNaturalPreserveWeight(map, x, y)
          : 0.0;
      if (eyeW > 0.35) continue;
      final edgeW = _studioFeather(x, y, b);
      final a = 0.08 * edgeW;
      if (a <= 0) continue;
      final p = im.getPixel(x, y);
      final bl = blurred.getPixel(x, y);
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

class _StudioBounds {
  const _StudioBounds(this.left, this.top, this.right, this.bottom);
  final int left;
  final int top;
  final int right;
  final int bottom;
}

_StudioBounds? _studioSubjectBounds(img.Image im) {
  var minX = im.width;
  var minY = im.height;
  var maxX = 0;
  var maxY = 0;
  var n = 0;
  for (var y = 0; y < im.height; y++) {
    for (var x = 0; x < im.width; x++) {
      if (_lum(im.getPixel(x, y)) <= 28) continue;
      minX = math.min(minX, x);
      minY = math.min(minY, y);
      maxX = math.max(maxX, x);
      maxY = math.max(maxY, y);
      n++;
    }
  }
  if (n < 100) return null;
  return _StudioBounds(minX, minY, maxX, maxY);
}

double _studioFeather(int x, int y, _StudioBounds b) {
  final distEdge = math.min(
    math.min(x - b.left, b.right - x),
    math.min(y - b.top, b.bottom - y),
  ).toDouble();
  const feather = 32.0;
  if (distEdge >= feather) return 1;
  if (distEdge <= 0) return 0;
  final t = distEdge / feather;
  return t * t * (3 - 2 * t);
}

bool _isRimGrayHalo(img.Pixel p) {
  final lum = _lum(p);
  final r = p.r.toInt();
  final g = p.g.toInt();
  final b = p.b.toInt();
  final chroma = math.max(r, math.max(g, b)) - math.min(r, math.min(g, b));
  return lum > 78 && lum < 235 && chroma < 32;
}

bool _isNearSilhouetteEdge(img.Image im, int x, int y) {
  var hasBlack = false;
  var hasSubject = false;
  for (var dy = -3; dy <= 3; dy++) {
    for (var dx = -3; dx <= 3; dx++) {
      if (dx == 0 && dy == 0) continue;
      final nx = x + dx;
      final ny = y + dy;
      if (nx < 0 || ny < 0 || nx >= im.width || ny >= im.height) continue;
      final l = _lum(im.getPixel(nx, ny));
      if (l <= 28) hasBlack = true;
      if (l > 45) hasSubject = true;
    }
  }
  return hasBlack && hasSubject;
}

/// Fills rembg holes inside the head (pupils, nostrils) so they are not left black.
Uint8List _fillInteriorMaskHoles(
  Uint8List keep,
  img.Image rgba,
  int w,
  int h,
) {
  final out = Uint8List.fromList(keep);
  var minX = w, minY = h, maxX = 0, maxY = 0;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      if (out[y * w + x] == 0) continue;
      minX = math.min(minX, x);
      minY = math.min(minY, y);
      maxX = math.max(maxX, x);
      maxY = math.max(maxY, y);
    }
  }
  if (maxX <= minX || maxY <= minY) return out;

  for (var pass = 0; pass < 5; pass++) {
    var changed = false;
    for (var y = minY; y <= maxY; y++) {
      for (var x = minX; x <= maxX; x++) {
        final i = y * w + x;
        if (out[i] != 0) continue;
        var fgNeighbors = 0;
        for (var dy = -1; dy <= 1; dy++) {
          for (var dx = -1; dx <= 1; dx++) {
            if (dx == 0 && dy == 0) continue;
            final nx = x + dx;
            final ny = y + dy;
            if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
            if (out[ny * w + nx] == 1) fgNeighbors++;
          }
        }
        if (fgNeighbors < 4) continue;
        final p = rgba.getPixel(x, y);
        final a = p.a / 255.0;
        // Keep dark pupils — don't skip low-alpha
        // dark pixels inside face bounds
        if (a < 0.04 && _lumRgb(p.r.toInt(), p.g.toInt(), p.b.toInt()) < 15) {
          continue;
        }
        out[i] = 1;
        changed = true;
      }
    }
    if (!changed) break;
  }
  return out;
}

double _eyeRegionWeight(FaceGlowMap map, int x, int y) {
  return math
      .max(
        FaceLandmarkService.eyeNaturalPreserveWeight(map, x, y),
        FaceLandmarkService.eyeExclusion(map, x, y),
      )
      .clamp(0.0, 1.0);
}

/// Wider than [_eyeRegionWeight] — catches white sclera rembg drops.
double _scleraRegionWeight(FaceGlowMap map, int x, int y) {
  final s = map.faceScale;
  final eyeY = (map.leftEye.dy + map.rightEye.dy) * 0.5;
  if (y > eyeY + s * 0.10) return 0.0;
  final rx = s * 0.52;
  final ry = s * 0.38;
  return math
      .max(
        _ellipseFalloff(x, y, map.leftEye.dx, map.leftEye.dy, rx, ry),
        _ellipseFalloff(x, y, map.rightEye.dx, map.rightEye.dy, rx, ry),
      )
      .clamp(0.0, 1.0);
}

double _ellipseFalloff(
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

Future<img.Image?> _loadRgbAlignedTo(String? path, int w, int h) async {
  if (path == null || path.trim().isEmpty) return null;
  final file = File(path);
  if (!await file.exists()) return null;
  final im = img.decodeImage(await file.readAsBytes());
  if (im == null) return null;
  if (im.width == w && im.height == h) return im;
  return img.copyResize(
    im,
    width: w,
    height: h,
    interpolation: img.Interpolation.cubic,
  );
}

/// Light wall/sky pixels in the library pick — not part of the face.
bool _isPickBackgroundPixel(img.Pixel p) {
  final lum = _lum(p);
  if (lum < 28) return false;
  final r = p.r.toInt();
  final g = p.g.toInt();
  final b = p.b.toInt();
  final chroma = math.max(r, math.max(g, b)) - math.min(r, math.min(g, b));
  if (lum > 200 && chroma < 35) return true;
  if (lum > 170 && chroma < 16) return true;
  if (g > r + 14 && g > b + 14 && lum > 110) return true;
  return false;
}

void _expandFaceShieldMask(Uint8List keep, FaceGlowMap map, int w, int h) {
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      if (FaceLandmarkService.faceShieldWeight(map, x, y) < 0.08) continue;
      keep[y * w + x] = 1;
    }
  }
}

/// Paste eyes + any backdrop leaks inside face scan shield from original.
img.Image _pasteProtectedFaceFromOriginal(
  img.Image studio,
  img.Image original,
  FaceGlowMap map,
) {
  final out = img.Image.from(studio);
  final backdrop = studioBackdrop();
  var eyes = 0;
  var face = 0;

  for (var y = 0; y < studio.height; y++) {
    for (var x = 0; x < studio.width; x++) {
      final eyeW = _eyeRegionWeight(map, x, y);
      final scleraW = _scleraRegionWeight(map, x, y);
      final regionW = math.max(eyeW, scleraW);
      final shield = FaceLandmarkService.faceShieldWeight(map, x, y);

      final po = original.getPixel(x, y);
      if (_isPickBackgroundPixel(po)) continue;

      final ps = studio.getPixel(x, y);
      final psLum = _lum(ps);
      final poLum = _lum(po);

      // Full eye ovals — always from capture.
      if (regionW > 0.06) {
        var r = po.r.toInt();
        var g = po.g.toInt();
        var b = po.b.toInt();
        if (poLum < 50) {
          final boost = ((38 - poLum * 0.25) * regionW).clamp(0.0, 40.0);
          r = (r + boost * 0.85).round().clamp(0, 255);
          g = (g + boost * 0.80).round().clamp(0, 255);
          b = (b + boost * 0.70).round().clamp(0, 255);
        }
        out.setPixelRgb(x, y, r, g, b);
        eyes++;
        continue;
      }

      if (shield < 0.12) continue;
      final leaked = backdrop.isBackdropPixel(ps) || psLum < backdrop.luminance + 28;
      if (!leaked && psLum >= poLum - 12) continue;

      out.setPixelRgb(
        x,
        y,
        po.r.toInt(),
        po.g.toInt(),
        po.b.toInt(),
      );
      face++;
    }
  }

  debugPrint(
    '[PhotoProcessor] face scan pasted $eyes eye + $face face px from capture',
  );
  return out;
}

/// Small fix for AI studio — only true black holes in iris (no full-eye paste).
img.Image _touchUpEyesOnly(
  img.Image studio,
  img.Image original,
  FaceGlowMap map,
) {
  final out = img.Image.from(studio);
  var n = 0;
  const maxPx = 800;

  for (var y = 0; y < studio.height; y++) {
    if (n >= maxPx) break;
    for (var x = 0; x < studio.width; x++) {
      if (n >= maxPx) break;
      if (_eyeRegionWeight(map, x, y) < 0.42) continue;

      final cur = studio.getPixel(x, y);
      final curLum = _lum(cur);
      if (curLum > 22) continue;

      final po = original.getPixel(x, y);
      final poLum = _lum(po);
      if (poLum < 50) continue;

      out.setPixelRgb(
        x,
        y,
        po.r.toInt(),
        po.g.toInt(),
        po.b.toInt(),
      );
      n++;
    }
  }

  if (n > 0) {
    debugPrint('[PhotoProcessor] AI studio eye touch-up: $n px');
  }
  return out;
}

int _blendInt(int from, int to, double t) =>
    (from + (to - from) * t).round().clamp(0, 255);

/// Soft beauty light on the face — not on eyes or background.
img.Image applyGentleStudioPortraitLight(img.Image im, {FaceGlowMap? map}) {
  final faceMap = map ?? FaceLandmarkService.detectFromImage(im);
  final out = img.Image.from(im);
  var n = 0;

  for (var y = 0; y < im.height; y++) {
    for (var x = 0; x < im.width; x++) {
      if (_lum(im.getPixel(x, y)) <= 28) continue;
      final eyeW = faceMap != null ? _eyeRegionWeight(faceMap, x, y) : 0.0;
      final scleraW =
          faceMap != null ? _scleraRegionWeight(faceMap, x, y) : 0.0;
      if (eyeW > 0.12 || scleraW > 0.08) continue;

      final p = im.getPixel(x, y);
      final l = _lum(p);
      final shadow = ((118 - l) / 118).clamp(0.0, 1.0);
      final lift = 0.05 * shadow * (1 - eyeW * 0.85);
      if (lift <= 0.004) continue;

      out.setPixelRgb(
        x,
        y,
        (p.r + 255 * lift).round().clamp(0, 255),
        (p.g + 255 * lift).round().clamp(0, 255),
        (p.b + 255 * lift).round().clamp(0, 255),
      );
      n++;
    }
  }
  if (n > 0) {
    debugPrint('[PhotoProcessor] gentle studio light on $n face px');
  }
  return out;
}

/// Face + hair sensor — never paint black over subject pixels.
bool _isProtectedFromRimCleanup(FaceGlowMap? map, int x, int y) {
  if (map == null) return false;
  if (FaceLandmarkService.faceShieldWeight(map, x, y) > 0.06) return true;
  if (_eyeRegionWeight(map, x, y) > 0.08) return true;
  if (_scleraRegionWeight(map, x, y) > 0.06) return true;
  return FaceLandmarkService.faceStudioSensorWeight(map, x, y) > 0.05;
}

void _expandKeepMaskForEyes(Uint8List keep, FaceGlowMap map, int w, int h) {
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      if (_eyeRegionWeight(map, x, y) < 0.08 &&
          _scleraRegionWeight(map, x, y) < 0.06) {
        continue;
      }
      keep[y * w + x] = 1;
    }
  }
}

/// Quick RGB preview for landmarks before composite (from rembg mask).
img.Image _roughSilhouettePreview(img.Image rgba, Uint8List keep, int w, int h) {
  final out = img.Image(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      if (keep[y * w + x] == 0) continue;
      final p = rgba.getPixel(x, y);
      final a = p.a / 255.0;
      out.setPixelRgb(
        x,
        y,
        (p.r * a).round().clamp(0, 255),
        (p.g * a).round().clamp(0, 255),
        (p.b * a).round().clamp(0, 255),
      );
    }
  }
  return out;
}

/// Sclera/iris need high alpha on black — rembg often leaves them faint.
double _eyeCompositeAlpha(img.Pixel p, double a) {
  final lum = _lum(p);
  if (a >= 0.92) return a;
  if (lum >= 140) return math.max(a, 0.95); // sclera
  if (lum >= 90) return math.max(a, 0.90);
  if (lum >= 50) return math.max(a, 0.85);
  if (lum >= 20) return math.max(a, 0.80); // dark iris
  return math.max(a, 0.75); // pupil
}

/// Boost wispy hair alpha so blonde strands are not mud on black.
double _hairCompositeAlpha(img.Pixel p, double a) {
  if (a >= 0.92) return a;
  if (_isLightWallHalo(p)) return 0;
  if (!_looksLikeHairColor(p)) return a;
  return (a + (1 - a) * 0.62).clamp(0.0, 1.0);
}

bool _looksLikeHairColor(img.Pixel p) {
  final lum = _lum(p);
  if (lum < 28 || lum > 220) return false;
  final r = p.r.toInt();
  final g = p.g.toInt();
  final b = p.b.toInt();
  final chroma = math.max(r, math.max(g, b)) - math.min(r, math.min(g, b));
  return chroma >= 12;
}

/// Rebuild temple/hair from rembg — fixes dark patches on black studio.
img.Image _restoreHairEdgesFromRembg(
  img.Image studio,
  img.Image rgba,
  FaceGlowMap? map,
) {
  if (map == null) return studio;

  final out = img.Image.from(studio);
  final b = _studioSubjectBounds(studio);
  if (b == null) return studio;

  final eyeY = (map.leftEye.dy + map.rightEye.dy) * 0.5;
  final s = map.faceScale;
  // Temple/hair only — never run through the eye band (was corrupting sclera).
  final hairBottom = (eyeY - s * 0.06).round();
  var n = 0;

  for (var y = b.top; y <= math.min(b.bottom, hairBottom); y++) {
    for (var x = b.left; x <= b.right; x++) {
      if (_eyeRegionWeight(map, x, y) > 0.04) continue;
      if (_scleraRegionWeight(map, x, y) > 0.04) continue;
      if (FaceLandmarkService.faceStudioSensorWeight(map, x, y) > 0.42) {
        continue;
      }

      final pf = rgba.getPixel(x, y);
      final a = pf.a / 255.0;
      if (a < 0.10 || _isLightWallHalo(pf)) continue;

      final ps = studio.getPixel(x, y);
      final lumS = _lum(ps);
      final ab = _hairCompositeAlpha(pf, a);
      if (ab < 0.12) continue;

      final nr = (pf.r * ab).round().clamp(0, 255);
      final ng = (pf.g * ab).round().clamp(0, 255);
      final nb = (pf.b * ab).round().clamp(0, 255);
      final lumN = _lumRgb(nr, ng, nb);

      final atEdge = _nearStudioBackdrop(studio, x, y, radius: 5);
      final tooDark = lumS < lumN - 12;
      if (!atEdge && !tooDark && lumS > 40) continue;

      out.setPixelRgb(x, y, nr, ng, nb);
      n++;
    }
  }

  if (n > 0) {
    debugPrint('[PhotoProcessor] restored $n hair-edge px from rembg');
  }
  return out;
}

/// Fills only tiny isolated black pinholes (not large rembg gaps).
img.Image _healBlackSpecksOnFace(img.Image im, {FaceGlowMap? map}) {
  final faceMap = map ?? FaceLandmarkService.detectFromImage(im);
  if (faceMap == null) return im;

  final out = img.Image.from(im);
  var healed = 0;
  const maxHeals = 120;

  for (var y = 0; y < im.height; y++) {
    if (healed >= maxHeals) break;
    for (var x = 0; x < im.width; x++) {
      if (healed >= maxHeals) break;
      if (_lum(im.getPixel(x, y)) > 28) continue;
      if (_eyeRegionWeight(faceMap, x, y) > 0.08) continue;
      if (_scleraRegionWeight(faceMap, x, y) > 0.06) continue;
      if (FaceLandmarkService.faceStudioSensorWeight(faceMap, x, y) < 0.12) {
        continue;
      }

      var blackN = 0;
      var skinN = 0;
      var sr = 0.0, sg = 0.0, sb = 0.0;
      for (var dy = -2; dy <= 2; dy++) {
        for (var dx = -2; dx <= 2; dx++) {
          if (dx == 0 && dy == 0) continue;
          final nx = x + dx;
          final ny = y + dy;
          if (nx < 0 || ny < 0 || nx >= im.width || ny >= im.height) continue;
          final np = im.getPixel(nx, ny);
          final l = _lum(np);
          if (l <= 32) {
            blackN++;
            continue;
          }
          if (l < 48 || _isLikelyHairOrSkinPixel(
            np.r.toInt(),
            np.g.toInt(),
            np.b.toInt(),
          )) {
            skinN++;
            sr += np.r;
            sg += np.g;
            sb += np.b;
          }
        }
      }
      if (blackN > 2 || skinN < 5) continue;

      out.setPixelRgb(
        x,
        y,
        (sr / skinN).round(),
        (sg / skinN).round(),
        (sb / skinN).round(),
      );
      healed++;
    }
  }

  if (healed > 0) {
    debugPrint('[PhotoProcessor] healed $healed isolated face pinholes');
  }
  return out;
}

/// Flood-fill from image border through backdrop-like pixels → pure black.
img.Image purgeBorderBackground(
  img.Image im, {
  bool aggressive = false,
  FaceGlowMap? protectMap,
}) {
  final w = im.width;
  final h = im.height;
  final n = w * h;
  final remove = Uint8List(n);
  final queue = <int>[];

  void seed(int x, int y) {
    final i = y * w + x;
    if (remove[i] != 0) return;
    if (aggressive) {
      if (!_canFloodFromBorder(im.getPixel(x, y))) return;
    } else if (!_isFloodableBackdrop(im.getPixel(x, y))) {
      return;
    }
    remove[i] = 1;
    queue.add(i);
  }

  for (var x = 0; x < w; x++) {
    seed(x, 0);
    seed(x, h - 1);
  }
  for (var y = 0; y < h; y++) {
    seed(0, y);
    seed(w - 1, y);
  }

  while (queue.isNotEmpty) {
    final i = queue.removeLast();
    final x = i % w;
    final y = i ~/ w;
    for (var dy = -1; dy <= 1; dy++) {
      for (var dx = -1; dx <= 1; dx++) {
        if (dx == 0 && dy == 0) continue;
        final nx = x + dx;
        final ny = y + dy;
        if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
        final ni = ny * w + nx;
        if (remove[ni] != 0) continue;
        if (_isProtectedFromRimCleanup(protectMap, nx, ny)) continue;
        if (aggressive) {
          if (!_canFloodFromBorder(im.getPixel(nx, ny))) continue;
        } else if (!_isFloodableBackdrop(im.getPixel(nx, ny))) {
          continue;
        }
        remove[ni] = 1;
        queue.add(ni);
      }
    }
  }

  var count = 0;
  final out = img.Image.from(im);
  for (var i = 0; i < n; i++) {
    if (remove[i] == 0) continue;
    final x = i % w;
    final y = i ~/ w;
    if (_isProtectedFromRimCleanup(protectMap, x, y)) continue;
    _paintStudioBackdrop(out, x, y);
    count++;
  }
  if (count > 0) {
    debugPrint('[PhotoProcessor] border flood removed $count backdrop px');
  }
  return out;
}

/// Pixels reachable from the frame edge that look like wall/sky/backdrop.
bool _isFloodableBackdrop(img.Pixel p) => _canFloodFromBorder(p);

/// Aggressive edge flood — walks through light walls; stops on dark hair / skin / pupils.
bool _canFloodFromBorder(img.Pixel p) {
  if (_isCoreSubjectPixel(p)) return false;
  final lum = _lum(p);
  // Do not treat pupils/irises as backdrop (rembg often leaves them dark).
  if (lum <= 32) {
    final r = p.r.toInt();
    final g = p.g.toInt();
    final b = p.b.toInt();
    final chroma = math.max(r, math.max(g, b)) - math.min(r, math.min(g, b));
    if (chroma >= 6) return false;
    return lum <= 18;
  }
  final r = p.r.toInt();
  final g = p.g.toInt();
  final b = p.b.toInt();
  final chroma = math.max(r, math.max(g, b)) - math.min(r, math.min(g, b));
  if (lum > 175 && chroma < 50) return true;
  if (lum > 130 && chroma < 32) return true;
  if (lum > 95 && chroma < 22) return true;
  if (lum > 72 && chroma < 14) return true;
  if (g > r + 8 && g > b + 8 && lum > 65) return true;
  return false;
}

bool _isCoreSubjectPixel(img.Pixel p) {
  final lum = _lum(p);
  if (lum < 52) return true;
  final r = p.r.toInt();
  final g = p.g.toInt();
  final b = p.b.toInt();
  final chroma = math.max(r, math.max(g, b)) - math.min(r, math.min(g, b));
  if (lum >= 55 && lum <= 210 && chroma >= 12 && chroma <= 95) return true;
  return false;
}

/// Removes light backdrop-colored pixels still touching black after border flood.
img.Image _peelAttachedBackdrop(img.Image im, {FaceGlowMap? protectMap}) {
  final w = im.width;
  final h = im.height;
  final out = img.Image.from(im);
  var n = 0;

  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final p = im.getPixel(x, y);
      if (_lum(p) <= 28) continue;
      if (_isCoreSubjectPixel(p)) continue;
      if (_isProtectedFromRimCleanup(protectMap, x, y)) continue;
      if (!_isAttachedBackdropPixel(im, x, y)) continue;
      _paintStudioBackdrop(out, x, y);
      n++;
    }
  }
  if (n > 0) {
    debugPrint('[PhotoProcessor] peeled $n attached backdrop px');
  }
  return out;
}

bool _isAttachedBackdropPixel(img.Image im, int x, int y) {
  final p = im.getPixel(x, y);
  if (!_isFloodableBackdrop(p) && _lum(p) < 140) return false;
  final lum = _lum(p);
  if (lum < 70) return false;
  var touchesBlack = false;
  var lightNeighbors = 0;
  for (var dy = -2; dy <= 2; dy++) {
    for (var dx = -2; dx <= 2; dx++) {
      if (dx == 0 && dy == 0) continue;
      final nx = x + dx;
      final ny = y + dy;
      if (nx < 0 || ny < 0 || nx >= im.width || ny >= im.height) continue;
      final np = im.getPixel(nx, ny);
      if (_lum(np) <= 28) touchesBlack = true;
      if (_isFloodableBackdrop(np)) lightNeighbors++;
    }
  }
  return touchesBlack && lightNeighbors >= 2;
}

/// Fraction of perimeter band pixels that are studio-black (0–1).
double blackStudioEdgeScore(img.Image im) {
  final t = math.max(4, (math.min(im.width, im.height) * 0.06).round());
  var black = 0;
  var total = 0;

  void sample(int x, int y) {
    if (x < 0 || y < 0 || x >= im.width || y >= im.height) return;
    total++;
    if (_lum(im.getPixel(x, y)) < 50) black++;
  }

  for (var x = 0; x < im.width; x++) {
    for (var d = 0; d < t; d++) {
      sample(x, d);
      sample(x, im.height - 1 - d);
    }
  }
  for (var y = 0; y < im.height; y++) {
    for (var d = 0; d < t; d++) {
      sample(d, y);
      sample(im.width - 1 - d, y);
    }
  }
  return total == 0 ? 0 : black / total;
}

Future<bool> looksLikeBlackStudioFile(String path) async {
  final bytes = await File(path).readAsBytes();
  final im = img.decodeImage(bytes);
  if (im == null) return false;
  final score = blackStudioEdgeScore(im);
  debugPrint('[PhotoProcessor] studio edge black score=$score');
  return score >= 0.52;
}

/// Full local cleanup after rembg or AI studio pass.
Future<String> enforceBlackStudioFile(String imagePath) async =>
    polishStudioBeforeFile(imagePath);

/// Strips rembg halos (white/gray/green) along the head and hair silhouette.
img.Image defringeBlackStudio(
  img.Image im, {
  int maxPasses = 8,
  FaceGlowMap? protectMap,
}) {
  var current = img.Image.from(im);
  var removed = 0;

  for (var pass = 0; pass < maxPasses; pass++) {
    final next = img.Image.from(current);
    var changed = false;

    for (var y = 0; y < current.height; y++) {
      for (var x = 0; x < current.width; x++) {
        final p = current.getPixel(x, y);
        if (_lum(p) <= 26) continue;
        if (_isProtectedFromRimCleanup(protectMap, x, y)) continue;
        if (!_isLightWallHalo(p)) continue;
        if (!_touchesBackground(current, x, y)) continue;
        if (_isLikelyHairOrSkinPixel(
          p.r.toInt(),
          p.g.toInt(),
          p.b.toInt(),
        )) {
          continue;
        }
        _paintStudioBackdrop(next, x, y);
        changed = true;
        removed++;
      }
    }

    current = next;
    if (!changed) break;
  }

  if (removed > 0) {
    debugPrint('[PhotoProcessor] defringe removed $removed halo pixels');
  }
  return current;
}

bool _touchesBackground(img.Image im, int x, int y) =>
    _nearStudioBackdrop(im, x, y, radius: 1);

bool _nearStudioBackdrop(img.Image im, int x, int y, {required int radius}) {
  for (var dy = -radius; dy <= radius; dy++) {
    for (var dx = -radius; dx <= radius; dx++) {
      if (dx == 0 && dy == 0) continue;
      final nx = x + dx;
      final ny = y + dy;
      if (nx < 0 || ny < 0 || nx >= im.width || ny >= im.height) continue;
      if (studioBackdrop().isBackdropPixel(im.getPixel(nx, ny))) {
        return true;
      }
    }
  }
  return false;
}

/// Light wall / rembg fringe only — not skin or brown hair.
bool _isLightWallHalo(img.Pixel p) => _isFringeHaloPixel(p) || _isRimGrayHalo(p);

bool _isLikelyHairOrSkinPixel(int r, int g, int b) {
  final lum = _lumRgb(r, g, b);
  final chroma = math.max(r, math.max(g, b)) - math.min(r, math.min(g, b));
  if (lum < 32 || lum > 210) return false;
  if (chroma >= 12) return true;
  return lum >= 40 && lum <= 165;
}

bool _isFringeHaloPixel(img.Pixel p) {
  final r = p.r.toInt();
  final g = p.g.toInt();
  final b = p.b.toInt();
  final lum = _lum(p);
  final chroma = math.max(r, math.max(g, b)) - math.min(r, math.min(g, b));

  if (g > r + 12 && g > b + 12 && lum > 90 && lum < 240) return true;
  if (lum > 215 && chroma < 42) return true;
  if (lum > 185 && chroma < 22) return true;
  if (lum > 155 && chroma < 14) return true;
  if (lum > 125 && chroma < 10) return true;
  return false;
}

bool _isLeakedBackground(int r, int g, int b, double alpha) {
  final lum = _lumRgb(r, g, b);
  final chroma = math.max(r, math.max(g, b)) - math.min(r, math.min(g, b));
  if (g > r + 12 && g > b + 12 && lum > 85) return true;
  if (lum > 232 && chroma < 28) return true;
  if (lum > 205 && chroma < 12 && alpha < 0.92) return true;
  if (lum > 188 && chroma < 8) return true;
  return false;
}

double _lum(img.Pixel p) => _lumRgb(p.r.toInt(), p.g.toInt(), p.b.toInt());

double _lumRgb(int r, int g, int b) => 0.299 * r + 0.587 * g + 0.114 * b;
