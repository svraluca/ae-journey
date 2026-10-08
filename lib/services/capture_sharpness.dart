import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:image/image.dart' as img;

import 'face_landmark_service.dart';

/// Laplacian variance on the face — lower values mean a softer / blurrier capture.
Future<double> faceLaplacianVariance(String imagePath) async {
  try {
    final bytes = await File(imagePath).readAsBytes();
    final im = img.decodeImage(bytes);
    if (im == null) return 0;
    return _laplacianVarianceOnFace(im);
  } catch (e) {
    debugPrint('[CaptureSharpness] measure failed: $e');
    return 0;
  }
}

/// True when the portrait looks out-of-focus (AI sharpening will exaggerate lines).
Future<bool> isSoftCapture(String imagePath) async {
  final variance = await faceLaplacianVariance(imagePath);
  final threshold = _softCaptureThreshold;
  final soft = variance > 0 && variance < threshold;
  debugPrint(
    '[CaptureSharpness] laplacian=$variance threshold=$threshold soft=$soft',
  );
  return soft;
}

double get _softCaptureThreshold {
  final raw = dotenv.env['GLOW_UP_SOFT_CAPTURE_VARIANCE'] ?? '95';
  return (double.tryParse(raw) ?? 95).clamp(35.0, 220.0);
}

double _laplacianVarianceOnFace(img.Image im) {
  final map = FaceLandmarkService.detectFromImage(im);
  final eyeY = map != null
      ? (map.leftEye.dy + map.rightEye.dy) / 2
      : im.height * 0.43;
  final scale = map?.faceScale ?? im.width * 0.22;
  final cx = map?.faceCenter.dx ?? im.width / 2;
  final left = (cx - scale * 0.55).round().clamp(0, im.width - 1);
  final right = (cx + scale * 0.55).round().clamp(left + 1, im.width);
  final top = (eyeY - scale * 0.55).round().clamp(0, im.height - 1);
  final bottom = (eyeY + scale * 0.95).round().clamp(top + 1, im.height);

  var sum = 0.0;
  var sumSq = 0.0;
  var n = 0;
  for (var y = top + 1; y < bottom - 1; y++) {
    for (var x = left + 1; x < right - 1; x++) {
      if (_lum(im.getPixel(x, y)) <= 28) continue;
      final c = _lum(im.getPixel(x, y));
      final lap = 4 * c -
          _lum(im.getPixel(x - 1, y)) -
          _lum(im.getPixel(x + 1, y)) -
          _lum(im.getPixel(x, y - 1)) -
          _lum(im.getPixel(x, y + 1));
      sum += lap;
      sumSq += lap * lap;
      n++;
    }
  }
  if (n < 64) return 0;
  final mean = sum / n;
  return math.max(0, sumSq / n - mean * mean);
}

double _lum(img.Pixel p) => 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
