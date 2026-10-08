import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/camera_bootstrap.dart';
import 'photo_storage.dart';

/// In-app before/after capture with a fixed 3:4 frame and optional ghost guide.
///
/// No face/body ML — works for face close-ups and full body the same way.
/// Returns a local image path, or null if cancelled / failed.
Future<String?> openProcedureBaCapture(
  BuildContext context, {
  required String label,
  String? referencePath,
}) {
  return Navigator.of(context).push<String>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => ProcedureBaCaptureScreen(
        label: label,
        referencePath: referencePath,
      ),
    ),
  );
}

class ProcedureBaCaptureScreen extends StatefulWidget {
  const ProcedureBaCaptureScreen({
    super.key,
    required this.label,
    this.referencePath,
  });

  final String label;
  final String? referencePath;

  @override
  State<ProcedureBaCaptureScreen> createState() => _ProcedureBaCaptureScreenState();
}

class _ProcedureBaCaptureScreenState extends State<ProcedureBaCaptureScreen>
    with WidgetsBindingObserver {
  CameraController? _camera;
  String? _localReference;
  var _ready = false;
  var _starting = true;
  var _capturing = false;
  var _showGhost = true;
  var _useFront = false;
  String? _error;

  static const _aspect = 3 / 4;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _bootstrap();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_camera?.dispose());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final cam = _camera;
    if (cam == null || !cam.value.isInitialized) return;
    if (state == AppLifecycleState.inactive) {
      unawaited(cam.dispose());
      _camera = null;
      if (mounted) setState(() => _ready = false);
    } else if (state == AppLifecycleState.resumed) {
      unawaited(_startCamera());
    }
  }

  Future<void> _bootstrap() async {
    final r = (widget.referencePath ?? '').trim();
    if (r.isNotEmpty) {
      try {
        final local = await resolveLocalPhotoPath(r);
        if (File(local).existsSync()) _localReference = local;
      } catch (_) {}
    }
    if (mounted) setState(() => _showGhost = _localReference != null);
    await _startCamera();
  }

  Future<void> _startCamera() async {
    setState(() {
      _starting = true;
      _error = null;
    });

    final status = await Permission.camera.request();
    if (!status.isGranted) {
      if (!mounted) return;
      setState(() {
        _starting = false;
        _ready = false;
        _error = 'Camera permission is required to take a photo.';
      });
      return;
    }

    try {
      await _camera?.dispose();
      _camera = null;

      final cameras = await loadCameras(forceRefresh: true);
      if (cameras.isEmpty) {
        if (!mounted) return;
        setState(() {
          _starting = false;
          _ready = false;
          _error = 'No camera available on this device.';
        });
        return;
      }

      // Prefer rear for body / procedure photos; front when user flips.
      final preferred = _useFront ? CameraLensDirection.front : CameraLensDirection.back;
      final lens = cameras.firstWhere(
        (c) => c.lensDirection == preferred,
        orElse: () => cameras.first,
      );

      final controller = CameraController(
        lens,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: Platform.isAndroid ? ImageFormatGroup.jpeg : ImageFormatGroup.bgra8888,
      );
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      try {
        await controller.setFlashMode(FlashMode.off);
      } catch (_) {}

      _camera = controller;
      setState(() {
        _ready = true;
        _starting = false;
        _error = null;
      });
    } catch (e) {
      debugPrint('[BaCapture] camera start failed: $e');
      if (!mounted) return;
      setState(() {
        _starting = false;
        _ready = false;
        _error = 'Could not start the camera. Try gallery instead.';
      });
    }
  }

  Future<void> _flipCamera() async {
    if (_capturing) return;
    setState(() => _useFront = !_useFront);
    await _startCamera();
  }

  Future<void> _capture() async {
    final cam = _camera;
    if (cam == null || !cam.value.isInitialized || _capturing) return;
    setState(() => _capturing = true);
    try {
      final shot = await cam.takePicture();
      if (!mounted) return;
      Navigator.of(context).pop(shot.path);
    } catch (e) {
      debugPrint('[BaCapture] capture failed: $e');
      if (mounted) {
        setState(() => _capturing = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not take photo. Try again.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    final bottom = MediaQuery.paddingOf(context).bottom;
    final sf = GoogleFonts.urbanist();
    final hasGhost = (_localReference ?? '').isNotEmpty;
    final cam = _camera;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Column(
        children: [
          SizedBox(height: top + 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                IconButton(
                  onPressed: _capturing ? null : () => Navigator.of(context).maybePop(),
                  icon: const Icon(Icons.close_rounded, color: Colors.white),
                ),
                Expanded(
                  child: Column(
                    children: [
                      Text(
                        'Capture ${widget.label}',
                        style: sf.copyWith(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Match distance & angle — face or body',
                        style: sf.copyWith(
                          fontSize: 12,
                          color: Colors.white.withValues(alpha: 0.55),
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: (_starting || _capturing) ? null : _flipCamera,
                  icon: const Icon(Icons.cameraswitch_rounded, color: Colors.white),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: Center(
                child: AspectRatio(
                  aspectRatio: _aspect,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(17),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          if (_ready && cam != null && cam.value.isInitialized)
                            FittedBox(
                              fit: BoxFit.cover,
                              child: SizedBox(
                                width: cam.value.previewSize?.height ?? 3,
                                height: cam.value.previewSize?.width ?? 4,
                                child: CameraPreview(cam),
                              ),
                            )
                          else
                            ColoredBox(
                              color: const Color(0xFF111111),
                              child: Center(
                                child: _starting
                                    ? const CircularProgressIndicator(color: Colors.white54)
                                    : Padding(
                                        padding: const EdgeInsets.all(24),
                                        child: Text(
                                          _error ?? 'Starting camera…',
                                          textAlign: TextAlign.center,
                                          style: sf.copyWith(color: Colors.white70, fontSize: 14),
                                        ),
                                      ),
                              ),
                            ),
                          if (hasGhost && _showGhost && _localReference != null)
                            IgnorePointer(
                              child: Opacity(
                                opacity: 0.38,
                                child: Image.file(
                                  File(_localReference!),
                                  fit: BoxFit.cover,
                                ),
                              ),
                            ),
                          // Body/face-agnostic composition guides.
                          IgnorePointer(
                            child: CustomPaint(
                              painter: _BaCaptureGuidesPainter(),
                            ),
                          ),
                          Positioned(
                            top: 12,
                            left: 12,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.55),
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
                              ),
                              child: Text(
                                widget.label.toUpperCase(),
                                style: sf.copyWith(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white,
                                  letterSpacing: 0.04 * 11,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(20, 12, 20, 16 + bottom),
            child: Column(
              children: [
                if (hasGhost)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Row(
                      children: [
                        Icon(Icons.compare_rounded, size: 18, color: Colors.white.withValues(alpha: 0.7)),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Show other photo as guide',
                            style: sf.copyWith(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: Colors.white.withValues(alpha: 0.78),
                            ),
                          ),
                        ),
                        Switch.adaptive(
                          value: _showGhost,
                          activeTrackColor: Colors.white54,
                          onChanged: (v) => setState(() => _showGhost = v),
                        ),
                      ],
                    ),
                  ),
                Text(
                  hasGhost
                      ? 'Line up the same spot on the faint guide — works for face or body.'
                      : 'Stand the same distance. Keep the subject in the frame guides.',
                  textAlign: TextAlign.center,
                  style: sf.copyWith(
                    fontSize: 12,
                    color: Colors.white.withValues(alpha: 0.45),
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 18),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    GestureDetector(
                      onTap: (_ready && !_capturing) ? _capture : null,
                      child: Container(
                        width: 74,
                        height: 74,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white.withValues(alpha: 0.85), width: 4),
                        ),
                        padding: const EdgeInsets.all(5),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: (_ready && !_capturing)
                                ? Colors.white
                                : Colors.white.withValues(alpha: 0.35),
                            shape: BoxShape.circle,
                          ),
                          child: _capturing
                              ? const Padding(
                                  padding: EdgeInsets.all(18),
                                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black54),
                                )
                              : null,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _BaCaptureGuidesPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = Colors.white.withValues(alpha: 0.22)
      ..strokeWidth = 1;

    // Rule-of-thirds — useful for face close-ups and body shots alike.
    canvas.drawLine(Offset(size.width / 3, 0), Offset(size.width / 3, size.height), line);
    canvas.drawLine(Offset(2 * size.width / 3, 0), Offset(2 * size.width / 3, size.height), line);
    canvas.drawLine(Offset(0, size.height / 3), Offset(size.width, size.height / 3), line);
    canvas.drawLine(Offset(0, 2 * size.height / 3), Offset(size.width, 2 * size.height / 3), line);

    // Soft center crosshair for vertical alignment.
    final cross = Paint()
      ..color = Colors.white.withValues(alpha: 0.35)
      ..strokeWidth = 1.2;
    final cx = size.width / 2;
    final cy = size.height / 2;
    canvas.drawLine(Offset(cx - 18, cy), Offset(cx + 18, cy), cross);
    canvas.drawLine(Offset(cx, cy - 18), Offset(cx, cy + 18), cross);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
