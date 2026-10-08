import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'face_landmark_service.dart';

/// Post-capture crop so the user doesn't need to "nail" distance while shooting.
class GlowScanCropper {
  GlowScanCropper._();

  static final FaceDetector _detector = FaceDetector(
    options: FaceDetectorOptions(
      performanceMode: FaceDetectorMode.fast,
      enableLandmarks: false,
      enableContours: false,
      enableClassification: false,
      enableTracking: true,
    ),
  );

  static Future<String> cropToPortraitFrame(String path) async {
    final src = File(path);
    if (!await src.exists()) return path;

    try {
      final raw = await src.readAsBytes();
      var decoded = img.decodeImage(raw);
      if (decoded == null) return path;
      decoded = img.bakeOrientation(decoded);

      final orientedPath = await _writeOrientedTemp(decoded);
      var box = await _largestFaceBox(orientedPath);
      box ??= _boxFromLandmarks(FaceLandmarkService.detectFromImage(decoded));
      if (box == null) {
        debugPrint('[GlowScan] post-crop: no face detected, using original');
        return path;
      }

      // 4:5 portrait headshot — tighter than studio bust framing.
      final faceH = box.height;
      final faceW = box.width;
      final cropH = (faceH * 1.72)
          .clamp(faceH * 1.48, decoded.height * 0.88)
          .clamp(360.0, decoded.height.toDouble());
      final cropW = (cropH * 0.80)
          .clamp(faceW * 1.25, decoded.width * 0.88)
          .clamp(280.0, decoded.width.toDouble());

      final cx = box.center.dx;
      final cy = box.center.dy - faceH * 0.12; // bias up: keep hair

      var left = (cx - cropW / 2).round();
      var top = (cy - cropH / 2).round();
      var w = cropW.round();
      var h = cropH.round();

      left = left.clamp(0, decoded.width - 1);
      top = top.clamp(0, decoded.height - 1);
      if (left + w > decoded.width) w = decoded.width - left;
      if (top + h > decoded.height) h = decoded.height - top;

      // Keep aspect stable by trimming the other axis if needed.
      final targetAspect = 0.80;
      final currentAspect = w / math.max(1, h);
      if ((currentAspect - targetAspect).abs() > 0.02) {
        if (currentAspect > targetAspect) {
          // too wide → trim width
          final newW = (h * targetAspect).round().clamp(1, w);
          left = (left + (w - newW) / 2).round().clamp(0, decoded.width - newW);
          w = newW;
        } else {
          // too tall → trim height
          final newH = (w / targetAspect).round().clamp(1, h);
          top = (top + (h - newH) / 2).round().clamp(0, decoded.height - newH);
          h = newH;
        }
      }

      final cropped = img.copyCrop(decoded, x: left, y: top, width: w, height: h);

      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}/photos');
      if (!await dir.exists()) await dir.create(recursive: true);
      final out = File('${dir.path}/glow_scan_crop_${const Uuid().v4()}.jpg');
      await out.writeAsBytes(img.encodeJpg(cropped, quality: 92), flush: true);
      debugPrint('[GlowScan] post-crop → ${out.path}');
      return out.path;
    } catch (e, st) {
      debugPrint('[GlowScan] post-crop skipped: $e\n$st');
      return path;
    }
  }

  static Future<String> _writeOrientedTemp(img.Image decoded) async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/photos');
    if (!await dir.exists()) await dir.create(recursive: true);
    final out = File('${dir.path}/glow_scan_orient_${const Uuid().v4()}.jpg');
    await out.writeAsBytes(img.encodeJpg(decoded, quality: 95), flush: true);
    return out.path;
  }

  static Future<Rect?> _largestFaceBox(String orientedPath) async {
    final faces = await _detector.processImage(
      InputImage.fromFilePath(orientedPath),
    );
    if (faces.isEmpty) return null;
    faces.sort((a, b) {
      final aa = a.boundingBox.width * a.boundingBox.height;
      final bb = b.boundingBox.width * b.boundingBox.height;
      return bb.compareTo(aa);
    });
    final b = faces.first.boundingBox;
    return Rect.fromLTWH(b.left, b.top, b.width, b.height);
  }

  static Rect? _boxFromLandmarks(FaceGlowMap? map) {
    if (map == null) return null;
    final mouthMid = (map.leftMouth != null && map.rightMouth != null)
        ? Offset(
            (map.leftMouth!.dx + map.rightMouth!.dx) * 0.5,
            (map.leftMouth!.dy + map.rightMouth!.dy) * 0.5,
          )
        : map.mouthBottom;
    final pts = [
      map.leftEye,
      map.rightEye,
      map.nose,
      map.mouthBottom,
      mouthMid,
    ];
    var minX = pts.first.dx;
    var maxX = minX;
    var minY = pts.first.dy;
    var maxY = minY;
    for (final p in pts.skip(1)) {
      minX = math.min(minX, p.dx);
      maxX = math.max(maxX, p.dx);
      minY = math.min(minY, p.dy);
      maxY = math.max(maxY, p.dy);
    }
    final padX = (maxX - minX) * 0.55;
    final padY = (maxY - minY) * 0.70;
    return Rect.fromLTRB(
      (minX - padX).clamp(0.0, map.imageWidth.toDouble()),
      (minY - padY).clamp(0.0, map.imageHeight.toDouble()),
      (maxX + padX).clamp(0.0, map.imageWidth.toDouble()),
      (maxY + padY).clamp(0.0, map.imageHeight.toDouble()),
    );
  }
}

