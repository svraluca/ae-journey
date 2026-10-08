import 'package:camera/camera.dart';

List<CameraDescription>? _cameras;

/// Pre-warm the camera list. Does not cache an empty result (plugin may not be ready yet).
Future<void> bootstrapCameras() async {
  try {
    final list = await availableCameras();
    if (list.isNotEmpty) _cameras = list;
  } catch (_) {
    // Leave cache unset so the face-scan screen can retry.
  }
}

/// Returns cameras for live preview. Retries when the cache is empty or missing.
Future<List<CameraDescription>> loadCameras({bool forceRefresh = false}) async {
  if (!forceRefresh && _cameras != null && _cameras!.isNotEmpty) {
    return _cameras!;
  }

  Object? lastError;
  for (var attempt = 0; attempt < 3; attempt++) {
    if (attempt > 0) {
      await Future<void>.delayed(Duration(milliseconds: 200 * attempt));
    }
    try {
      final list = await availableCameras();
      if (list.isNotEmpty) {
        _cameras = list;
        return list;
      }
    } catch (e) {
      lastError = e;
    }
  }

  _cameras = const [];
  if (lastError != null) {
    // ignore: avoid_print
    print('[GP] availableCameras failed: $lastError');
  }
  return _cameras!;
}
