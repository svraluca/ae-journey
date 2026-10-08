import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../ui/photo_storage.dart';

/// Zoom factors so before/after fill the compare frame at the same subject scale.
/// Used as a fallback for photos saved before normalize-on-crop.
class BaZoomMatch {
  const BaZoomMatch({
    required this.beforeZoom,
    required this.afterZoom,
    required this.beforeFocal,
    required this.afterFocal,
  });

  final double beforeZoom;
  final double afterZoom;
  final Offset beforeFocal;
  final Offset afterFocal;

  static const identity = BaZoomMatch(
    beforeZoom: 1,
    afterZoom: 1,
    beforeFocal: Offset.zero,
    afterFocal: Offset.zero,
  );
}

/// Consistent square framing for procedure before/after photos.
///
/// ImageCropper only locks aspect ratio — users can still crop tighter on
/// "after". [normalizeSquarePhoto] re-frames every pick to the same mouth /
/// subject fill so the compare slider lines up.
class ProcedureBaAlign {
  ProcedureBaAlign._();

  static const _canvas = 1024;
  /// Mouth / subject width as a fraction of the output square.
  static const _subjectFrac = 0.55;
  static const _centerYFrac = 0.50;

  static final Map<String, Future<BaZoomMatch>> _zoomInflight = {};

  /// Re-frame [path] to a consistent square (fixed subject fill).
  /// Returns a new local JPEG path, or the original path if unchanged / failed.
  static Future<String> normalizeSquarePhoto(String path) async {
    final srcPath = path.trim();
    if (srcPath.isEmpty) return srcPath;

    try {
      final local = await resolveLocalPhotoPath(srcPath);
      final file = File(local);
      if (!await file.exists()) return srcPath;

      final decoded = img.decodeImage(await file.readAsBytes());
      if (decoded == null) return srcPath;
      final oriented = img.bakeOrientation(decoded);

      final anchor = _detectSubject(oriented);
      final framed = _renderSquare(oriented, anchor);

      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}/photos');
      if (!await dir.exists()) await dir.create(recursive: true);
      final out = File('${dir.path}/ba_norm_${const Uuid().v4()}.jpg');
      await out.writeAsBytes(img.encodeJpg(framed, quality: 92), flush: true);

      debugPrint(
        '[BaAlign] normalized ${oriented.width}x${oriented.height} '
        '→ ${_canvas}x$_canvas src=${anchor.source} '
        'scale=${anchor.scale.toStringAsFixed(1)}',
      );
      return out.path;
    } catch (e, st) {
      debugPrint('[BaAlign] normalize skipped: $e\n$st');
      return srcPath;
    }
  }

  /// Display-time zoom match for older mismatched pairs.
  static Future<BaZoomMatch> matchZoom({
    required String beforePath,
    required String afterPath,
  }) {
    final b = beforePath.trim();
    final a = afterPath.trim();
    if (b.isEmpty || a.isEmpty) return Future.value(BaZoomMatch.identity);

    final key = 'zoom_v2|$b|$a';
    return _zoomInflight.putIfAbsent(key, () => _matchZoomUncached(b, a));
  }

  static Future<BaZoomMatch> _matchZoomUncached(
    String beforePath,
    String afterPath,
  ) async {
    try {
      final beforeLocal = await resolveLocalPhotoPath(beforePath);
      final afterLocal = await resolveLocalPhotoPath(afterPath);
      final beforeStats = await _subjectFill(beforeLocal);
      final afterStats = await _subjectFill(afterLocal);
      if (beforeStats == null || afterStats == null) {
        return BaZoomMatch.identity;
      }

      final target = math.max(beforeStats.fill, afterStats.fill).clamp(0.35, 0.92);
      final beforeZoom = (target / beforeStats.fill).clamp(1.0, 2.6);
      final afterZoom = (target / afterStats.fill).clamp(1.0, 2.6);

      debugPrint(
        '[BaAlign] zoom before=${beforeZoom.toStringAsFixed(2)} '
        'after=${afterZoom.toStringAsFixed(2)} '
        '(${beforeStats.source}/${afterStats.source})',
      );

      return BaZoomMatch(
        beforeZoom: beforeZoom,
        afterZoom: afterZoom,
        beforeFocal: beforeStats.focal,
        afterFocal: afterStats.focal,
      );
    } catch (e, st) {
      debugPrint('[BaAlign] zoom match failed: $e\n$st');
      return BaZoomMatch.identity;
    }
  }

  static Future<_FillStats?> _subjectFill(String path) async {
    final file = File(path);
    if (!await file.exists()) return null;
    final decoded = img.decodeImage(await file.readAsBytes());
    if (decoded == null) return null;
    final oriented = img.bakeOrientation(decoded);
    final preview = img.copyResize(
      oriented,
      width: 160,
      interpolation: img.Interpolation.linear,
    );
    final anchor = _detectSubject(preview);
    final fill = (anchor.scale / math.min(preview.width, preview.height))
        .clamp(0.15, 0.95);
    final cx = (anchor.center.dx / preview.width) * 2 - 1;
    final cy = (anchor.center.dy / preview.height) * 2 - 1;
    return _FillStats(
      fill: fill,
      focal: Offset(cx.clamp(-0.45, 0.45), cy.clamp(-0.45, 0.45)),
      source: anchor.source,
    );
  }

  static _SubjectAnchor _detectSubject(img.Image im) {
    return _anchorFromLipBand(im) ??
        _anchorFromCenterSquare(im);
  }

  static _SubjectAnchor? _anchorFromLipBand(img.Image im) {
    final w = im.width;
    final h = im.height;
    final rowScore = List<double>.filled(h, 0);

    for (var y = 0; y < h; y++) {
      var score = 0.0;
      var n = 0;
      for (var x = 0; x < w; x++) {
        final lip = _lipScore(im.getPixel(x, y));
        if (lip <= 0) continue;
        score += lip;
        n++;
      }
      rowScore[y] = n == 0 ? 0 : score / n;
    }

    var peakY = h ~/ 2;
    var peak = -1.0;
    for (var y = (h * 0.12).round(); y < (h * 0.88).round(); y++) {
      if (rowScore[y] > peak) {
        peak = rowScore[y];
        peakY = y;
      }
    }
    if (peak < 0.06) return null;

    var top = peakY;
    var bottom = peakY;
    final thresh = peak * 0.42;
    while (top > 0 && rowScore[top - 1] >= thresh) {
      top--;
    }
    while (bottom < h - 1 && rowScore[bottom + 1] >= thresh) {
      bottom++;
    }

    var minX = w;
    var maxX = 0;
    var sumX = 0.0;
    var sumY = 0.0;
    var n = 0;
    for (var y = top; y <= bottom; y++) {
      for (var x = 0; x < w; x++) {
        if (_lipScore(im.getPixel(x, y)) < thresh) continue;
        minX = math.min(minX, x);
        maxX = math.max(maxX, x);
        sumX += x;
        sumY += y;
        n++;
      }
    }
    if (n < 16 || maxX <= minX) return null;

    final bandW = (maxX - minX + 1).toDouble();
    final bandH = (bottom - top + 1).toDouble();
    return _SubjectAnchor(
      center: Offset(sumX / n, sumY / n),
      scale: math.max(bandW, bandH * 1.25).clamp(12.0, w * 0.95),
      source: 'lipBand',
    );
  }

  static _SubjectAnchor _anchorFromCenterSquare(img.Image im) {
    final side = math.min(im.width, im.height).toDouble();
    return _SubjectAnchor(
      center: Offset(im.width / 2, im.height / 2),
      scale: side * _subjectFrac,
      source: 'center',
    );
  }

  static double _lipScore(img.Pixel p) {
    final r = p.r.toInt();
    final g = p.g.toInt();
    final b = p.b.toInt();
    if (r < 50) return 0;
    final redPush = (r - g).toDouble() + (r - b) * 0.6;
    if (redPush < 12) return 0;
    final lum = (r * 3 + g * 6 + b) / 10.0;
    if (lum < 35 || lum > 230) return 0;
    return (redPush / 80.0).clamp(0.0, 1.5);
  }

  static img.Image _renderSquare(img.Image src, _SubjectAnchor anchor) {
    final minSide = math.min(src.width, src.height).toDouble();
    var cropSize = (anchor.scale / _subjectFrac)
        .clamp(48.0, math.max(src.width, src.height).toDouble() * 1.5);

    // Already a tight square crop — don't invent padded "zoom out" edges.
    // Just center-crop to square and resize to the canvas.
    if (cropSize >= minSide * 0.92) {
      final side = minSide.round().clamp(32, 4096);
      final left = ((src.width - side) / 2).round();
      final top = ((src.height - side) / 2).round();
      final tile = img.copyCrop(src, x: left, y: top, width: side, height: side);
      return img.copyResize(
        tile,
        width: _canvas,
        height: _canvas,
        interpolation: img.Interpolation.linear,
      );
    }

    final side = cropSize.round().clamp(32, 4096);
    final left = (anchor.center.dx - side / 2).round();
    final top = (anchor.center.dy - side * _centerYFrac).round();

    final tile = img.Image(width: side, height: side);
    for (var y = 0; y < side; y++) {
      final sy = (top + y).clamp(0, src.height - 1);
      for (var x = 0; x < side; x++) {
        final sx = (left + x).clamp(0, src.width - 1);
        final p = src.getPixel(sx, sy);
        tile.setPixelRgb(x, y, p.r, p.g, p.b);
      }
    }

    return img.copyResize(
      tile,
      width: _canvas,
      height: _canvas,
      interpolation: img.Interpolation.linear,
    );
  }
}

class _SubjectAnchor {
  const _SubjectAnchor({
    required this.center,
    required this.scale,
    required this.source,
  });

  final Offset center;
  final double scale;
  final String source;
}

class _FillStats {
  const _FillStats({
    required this.fill,
    required this.focal,
    required this.source,
  });

  final double fill;
  final Offset focal;
  final String source;
}
