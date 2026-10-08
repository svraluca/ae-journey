import 'dart:math' as math;
import 'dart:ui';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import 'face_landmark_service.dart';

/// Live guidance state for the face-scan capture frame.
@immutable
class FaceScanQuality {
  const FaceScanQuality({
    this.hasFace = false,
    this.positionOk = false,
    this.distanceOk = false,
    this.angleOk = false,
    this.stillOk = false,
    this.hint,
  });

  final bool hasFace;
  final bool positionOk;
  final bool distanceOk;
  final bool angleOk;
  final bool stillOk;
  final String? hint;

  bool get isReady =>
      hasFace && positionOk && distanceOk && angleOk && stillOk;

  static const searching = FaceScanQuality(
    hint: 'Look at the camera and fill the oval',
  );
}

/// Maps face landmarks to distance / pose guidance (pure Dart — no ML Kit).
class FaceScanQualityEvaluator {
  Offset? _lastCenter;
  int _stableFrames = 0;
  double? _interEyeEma;
  DateTime? _readyHoldUntil;
  FaceGlowMap? _lastGoodMap;

  // Calibrated to the UI oval: users should not need to be extremely close.
  static const _minFaceHeightFrac = 0.30;
  static const _maxFaceHeightFrac = 0.72;
  static const _targetCenterY = 0.46;
  static const _centerToleranceX = 0.14;
  static const _centerToleranceY = 0.14;

  void reset() {
    _lastCenter = null;
    _stableFrames = 0;
    _interEyeEma = null;
    _readyHoldUntil = null;
    _lastGoodMap = null;
  }

  FaceScanQuality evaluateFromMap(
    FaceGlowMap map,
    Size imageSize, {
    DateTime? now,
  }) {
    final tNow = now ?? DateTime.now();
    final w = imageSize.width;
    final h = imageSize.height;
    if (w <= 1 || h <= 1) return FaceScanQuality.searching;

    // If this frame is a clear outlier (wrong "eyes"), fall back to the last good map
    // so the UI doesn't flicker red/green.
    final rawInterEye = map.interEye;
    final prevEma = _interEyeEma;
    _interEyeEma ??= rawInterEye;
    if (prevEma != null) {
      _interEyeEma = prevEma * 0.82 + rawInterEye * 0.18;
    }
    final ema = _interEyeEma ?? rawInterEye;
    final outlier = ema > 1 &&
        ((rawInterEye - ema).abs() > ema * 0.38) &&
        ((rawInterEye - ema).abs() > 18);

    final m = (!outlier && rawInterEye >= 18) ? map : _lastGoodMap ?? map;

    // Head height ≈ 2.4× inter-eye distance (frontal portrait).
    final faceH = (m.faceScale * 2.4) / h;
    final cx = m.faceCenter.dx / w;
    final cy = m.faceCenter.dy / h;

    String? hint;
    var distanceOk = false;
    if (faceH < _minFaceHeightFrac) {
      hint = 'Move closer — fill the oval with your face';
    } else if (faceH > _maxFaceHeightFrac) {
      hint = 'Move back a little';
    } else {
      distanceOk = true;
    }

    var positionOk = false;
    if ((cx - 0.5).abs() <= _centerToleranceX &&
        (cy - _targetCenterY).abs() <= _centerToleranceY) {
      positionOk = true;
    } else if (hint == null) {
      hint = 'Centre your face in the oval';
    }

    final eyeTilt = (m.rightEye.dy - m.leftEye.dy).abs();
    final angleOk = eyeTilt <= m.faceScale * 0.09;
    if (!angleOk && hint == null) {
      hint = 'Face the camera directly';
    }

    final center = Offset(cx, cy);
    if (_lastCenter != null && (center - _lastCenter!).distance > 0.024) {
      _stableFrames = 0;
    } else {
      _stableFrames++;
    }
    _lastCenter = center;
    // Outliers should not instantly drop us to zero; just pause progress.
    if (outlier && _stableFrames > 0) {
      _stableFrames = math.max(0, _stableFrames - 1);
    }
    var stillOk = _stableFrames >= 5 && !outlier;
    if (!stillOk && hint == null && distanceOk && positionOk && angleOk) {
      hint = 'Almost there — hold still';
    }

    var isReady = distanceOk && positionOk && angleOk && stillOk;

    // Hysteresis: once ready, keep it green briefly unless face is truly lost.
    if (isReady) {
      _readyHoldUntil = tNow.add(const Duration(milliseconds: 1800));
      _lastGoodMap = m;
      hint = 'Perfect — tap Take photo';
    } else if (_readyHoldUntil != null && tNow.isBefore(_readyHoldUntil!)) {
      if (distanceOk && positionOk && angleOk) {
        stillOk = true;
        isReady = true;
        hint ??= 'Perfect — tap Take photo';
      } else if (hint == null && distanceOk && positionOk && angleOk) {
        hint = 'Almost there — hold still';
      }
    }

    return FaceScanQuality(
      hasFace: true,
      positionOk: positionOk,
      distanceOk: distanceOk,
      angleOk: angleOk,
      stillOk: stillOk,
      hint: hint ?? 'Adjust your position',
    );
  }
}

/// Downsampled decode of a camera frame for landmark detection.
FaceGlowMap? faceMapFromCameraImage(CameraImage image) {
  final decoded = _decodeCameraFrame(image);
  if (decoded == null) return null;

  // Downsample by the *long* edge so portrait iOS frames keep enough pixels.
  const maxLong = 540;
  final longer = math.max(decoded.width, decoded.height);
  final im = longer <= maxLong
      ? decoded
      : (decoded.width >= decoded.height
          ? img.copyResize(
              decoded,
              width: maxLong,
              interpolation: img.Interpolation.average,
            )
          : img.copyResize(
              decoded,
              height: maxLong,
              interpolation: img.Interpolation.average,
            ));

  return FaceLandmarkService.detectFromOriginalCapture(im);
}

img.Image? _decodeCameraFrame(CameraImage image) {
  try {
    if (image.planes.isEmpty) return null;

    if (image.format.group == ImageFormatGroup.bgra8888) {
      final plane = image.planes.first;
      return img.Image.fromBytes(
        width: image.width,
        height: image.height,
        bytes: plane.bytes.buffer,
        bytesOffset: plane.bytes.offsetInBytes,
        numChannels: 4,
        order: img.ChannelOrder.bgra,
        rowStride: plane.bytesPerRow,
      );
    }

    if (image.format.group == ImageFormatGroup.nv21 ||
        image.format.group == ImageFormatGroup.yuv420) {
      return _yuv420ToRgb(image);
    }
  } catch (e) {
    debugPrint('[FaceScan] frame decode failed: $e');
  }
  return null;
}

img.Image? _yuv420ToRgb(CameraImage image) {
  final yPlane = image.planes[0];
  final uPlane = image.planes.length > 1 ? image.planes[1] : null;
  final vPlane = image.planes.length > 2 ? image.planes[2] : null;
  if (uPlane == null || vPlane == null) return null;

  final w = image.width;
  final h = image.height;
  final out = img.Image(width: w, height: h);

  for (var row = 0; row < h; row++) {
    for (var col = 0; col < w; col++) {
      final yIndex = row * yPlane.bytesPerRow + col;
      final uvRow = row >> 1;
      final uvCol = col >> 1;
      final uvIndex = uvRow * uPlane.bytesPerRow + uvCol;

      final y = yPlane.bytes[yIndex];
      final u = uPlane.bytes[uvIndex] - 128;
      final v = vPlane.bytes[uvIndex] - 128;

      final r = (y + 1.402 * v).round().clamp(0, 255);
      final g = (y - 0.344 * u - 0.714 * v).round().clamp(0, 255);
      final b = (y + 1.772 * u).round().clamp(0, 255);
      out.setPixelRgb(col, row, r, g, b);
    }
  }
  return out;
}
