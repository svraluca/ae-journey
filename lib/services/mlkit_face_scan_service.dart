import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

import 'face_landmark_service.dart';

/// Stable, on-device face landmarks for the live scan oval (ML Kit).
class MlKitFaceScanService {
  MlKitFaceScanService()
      : _detector = FaceDetector(
          options: FaceDetectorOptions(
            enableLandmarks: true,
            enableTracking: true,
            performanceMode: FaceDetectorMode.fast,
          ),
        );

  final FaceDetector _detector;
  int? _lastTrackingId;

  static const Map<DeviceOrientation, int> _orientations = {
    DeviceOrientation.portraitUp: 0,
    DeviceOrientation.landscapeLeft: 90,
    DeviceOrientation.portraitDown: 180,
    DeviceOrientation.landscapeRight: 270,
  };

  Future<void> close() => _detector.close();

  Future<FaceGlowMap?> detectFromCameraImage(
    CameraImage image, {
    required CameraDescription camera,
    required DeviceOrientation deviceOrientation,
  }) async {
    final input = _toInputImage(
      image,
      camera: camera,
      deviceOrientation: deviceOrientation,
    );
    if (input == null) return null;

    final faces = await _detector.processImage(input);
    if (faces.isEmpty) return null;

    final face = _pickBestFace(faces);
    if (face.trackingId != null) _lastTrackingId = face.trackingId;

    final leftEye = face.landmarks[FaceLandmarkType.leftEye]?.position;
    final rightEye = face.landmarks[FaceLandmarkType.rightEye]?.position;
    final nose = face.landmarks[FaceLandmarkType.noseBase]?.position;
    final mouthL = face.landmarks[FaceLandmarkType.leftMouth]?.position;
    final mouthR = face.landmarks[FaceLandmarkType.rightMouth]?.position;
    final mouthB = face.landmarks[FaceLandmarkType.bottomMouth]?.position;

    if (leftEye == null || rightEye == null) return null;

    final w = input.metadata?.size.width.round() ?? image.width;
    final h = input.metadata?.size.height.round() ?? image.height;

    final lEye = Offset(leftEye.x.toDouble(), leftEye.y.toDouble());
    final rEye = Offset(rightEye.x.toDouble(), rightEye.y.toDouble());
    final eyeMid = Offset((lEye.dx + rEye.dx) * 0.5, (lEye.dy + rEye.dy) * 0.5);
    final interEye = (rEye - lEye).distance;

    final nosePt = nose != null
        ? Offset(nose.x.toDouble(), nose.y.toDouble())
        : Offset(eyeMid.dx, eyeMid.dy + interEye * 0.78);

    final mouthMid = (mouthL != null && mouthR != null)
        ? Offset(
            (mouthL.x + mouthR.x) * 0.5,
            (mouthL.y + mouthR.y) * 0.5,
          )
        : Offset(eyeMid.dx, eyeMid.dy + interEye * 1.85);

    final mouthBottom = mouthB != null
        ? Offset(mouthB.x.toDouble(), mouthB.y.toDouble())
        : Offset(mouthMid.dx, mouthMid.dy + interEye * 0.20);

    return FaceGlowMap(
      imageWidth: w,
      imageHeight: h,
      leftEye: lEye,
      rightEye: rEye,
      nose: nosePt,
      mouthBottom: mouthBottom,
      leftMouth: mouthL != null ? Offset(mouthL.x.toDouble(), mouthL.y.toDouble()) : null,
      rightMouth: mouthR != null ? Offset(mouthR.x.toDouble(), mouthR.y.toDouble()) : null,
    );
  }

  Face _pickBestFace(List<Face> faces) {
    final id = _lastTrackingId;
    if (id != null) {
      for (final f in faces) {
        if (f.trackingId == id) return f;
      }
    }
    faces.sort((a, b) {
      final aa = a.boundingBox.width * a.boundingBox.height;
      final bb = b.boundingBox.width * b.boundingBox.height;
      return bb.compareTo(aa);
    });
    return faces.first;
  }

  InputImage? _toInputImage(
    CameraImage image, {
    required CameraDescription camera,
    required DeviceOrientation deviceOrientation,
  }) {
    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    if (format == null) return null;

    // Plugin guidance: one plane for nv21 (Android) and bgra8888 (iOS).
    if (Platform.isAndroid && format != InputImageFormat.nv21) return null;
    if (Platform.isIOS && format != InputImageFormat.bgra8888) return null;
    if (image.planes.length != 1) return null;

    final rotation = _rotationFor(camera, deviceOrientation);
    if (rotation == null) return null;

    final plane = image.planes.first;
    return InputImage.fromBytes(
      bytes: Uint8List.fromList(plane.bytes),
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: format,
        bytesPerRow: plane.bytesPerRow,
      ),
    );
  }

  InputImageRotation? _rotationFor(
    CameraDescription camera,
    DeviceOrientation deviceOrientation,
  ) {
    final sensorOrientation = camera.sensorOrientation;
    if (Platform.isIOS) {
      return InputImageRotationValue.fromRawValue(sensorOrientation);
    }
    if (!Platform.isAndroid) return null;

    var rotationCompensation = _orientations[deviceOrientation];
    if (rotationCompensation == null) return null;

    if (camera.lensDirection == CameraLensDirection.front) {
      rotationCompensation = (sensorOrientation + rotationCompensation) % 360;
    } else {
      rotationCompensation = (sensorOrientation - rotationCompensation + 360) % 360;
    }
    return InputImageRotationValue.fromRawValue(rotationCompensation);
  }
}

