import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/camera_bootstrap.dart';
import '../services/face_scan_quality.dart';
import '../services/face_landmark_service.dart';
import '../services/photo_processor.dart';
import '../services/mlkit_face_scan_service.dart';
import 'glow_up_history_screen.dart';
import 'glow_up_photo_handoff.dart';

// glow_up_face_scan.html
const _bg = Color(0xFF000000);
const _camGradTop = Color(0xFF0A0A0A);
const _camGradBot = Color(0xFF050505);
const _faceInside = Color(0xFF1A1A1A);
const _frameRed = Color(0xFFEF4444);
const _frameGreen = Color(0xFF4ADE80);
const _frameAmber = Color(0xFFFBBF24);

/// Live camera + face guidance — opened from [GlowUpPhotoSourceScreen].
class GlowUpFaceScanScreen extends StatefulWidget {
  const GlowUpFaceScanScreen({super.key});

  @override
  State<GlowUpFaceScanScreen> createState() => _GlowUpFaceScanScreenState();
}

class _GlowUpFaceScanScreenState extends State<GlowUpFaceScanScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  CameraController? _camera;
  bool _cameraReady = false;
  bool _cameraStarting = true;
  bool _initInProgress = false;
  String? _cameraError;

  /// Live [CameraPreview] unavailable — use system camera via [ImagePicker].
  bool _systemCameraFallback = false;

  /// `availableCameras()` returned an empty list — device has no camera hardware
  /// (iOS Simulator, or a real device with the camera disabled). When true we
  /// must route capture taps to the photo library because the system camera
  /// UI cannot be opened either.
  bool _noCameraDevices = false;

  late final AnimationController _scanLine = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2500),
  )..repeat();

  late final AnimationController _ovalSpin = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 3),
  )..repeat();

  late final AnimationController _halo = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 3000),
  )..repeat(reverse: true);

  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat(reverse: true);

  bool _processingPhoto = false;

  final _qualityEvaluator = FaceScanQualityEvaluator();
  FaceScanQuality _scanQuality = FaceScanQuality.searching;
  bool _streamActive = false;
  bool _processingFrame = false;
  DateTime _lastFrameProcessed = DateTime.fromMillisecondsSinceEpoch(0);
  MlKitFaceScanService? _mlkit;

  bool get _isIosSimulator {
    if (kIsWeb || !Platform.isIOS) return false;
    return Platform.environment['SIMULATOR_DEVICE_NAME'] != null ||
        Platform.environment['SIMULATOR_HOST_HOME'] != null;
  }

  // Flutter does not reliably propagate the iOS simulator env vars into the
  // Dart isolate, so also treat "iOS + zero available cameras" as a simulator.
  bool get _treatAsSimulator =>
      _isIosSimulator || (!kIsWeb && Platform.isIOS && _noCameraDevices);

  /// ML Kit has no arm64 simulator slice; Rosetta + PHPicker causes a frozen,
  /// cloudy album on iOS Simulator. Use Dart landmarks there instead.
  bool get _useMlKit =>
      !kIsWeb &&
      (Platform.isIOS || Platform.isAndroid) &&
      !_treatAsSimulator;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (_useMlKit) {
      _mlkit = MlKitFaceScanService();
    }
    _initCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_stopFaceScanStream());
    _camera?.dispose();
    unawaited(_mlkit?.close());
    _scanLine.dispose();
    _ovalSpin.dispose();
    _halo.dispose();
    _pulse.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final camera = _camera;
    // Do not dispose on `inactive` — iOS fires that for the permission dialog and
    // would tear down the controller mid-initialize.
    if (state == AppLifecycleState.inactive && _processingPhoto) {
      return;
    }
    if (state == AppLifecycleState.paused) {
      if (_processingPhoto) return;
      if (camera != null) {
        unawaited(_stopFaceScanStream());
        camera.dispose();
        _camera = null;
        if (mounted) {
          setState(() {
            _cameraReady = false;
            _cameraStarting = false;
            _scanQuality = FaceScanQuality.searching;
          });
        }
      }
      return;
    }
    if (state == AppLifecycleState.resumed) {
      if (_processingPhoto) return;
      if (!_initInProgress &&
          (_camera == null || !(camera?.value.isInitialized ?? false))) {
        _initCamera();
      }
    }
  }

  Future<void> _initCamera() async {
    if (_camera != null || _initInProgress) return;
    if (!mounted) return;

    _initInProgress = true;
    setState(() {
      _cameraStarting = true;
      _cameraReady = false;
      _cameraError = null;
      _systemCameraFallback = false;
      _noCameraDevices = false;
    });

    try {
      final permission = await Permission.camera.request();
      if (!permission.isGranted) {
        if (!mounted) return;
        setState(() {
          _cameraStarting = false;
          _cameraError = permission.isPermanentlyDenied
              ? 'Camera access denied. Enable it in Settings, or choose a photo.'
              : 'Camera permission is required for the live preview.';
        });
        return;
      }

      final cameras = await loadCameras(forceRefresh: true);
      if (cameras.isEmpty) {
        if (_mlkit != null) {
          try {
            await _mlkit!.close();
          } catch (_) {}
          _mlkit = null;
        }
        if (!mounted) return;
        setState(() {
          _cameraStarting = false;
          _systemCameraFallback = true;
          _noCameraDevices = true;
          _cameraError = null;
        });
        return;
      }

      final lens = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        lens,
        ResolutionPreset.medium,
        enableAudio: false,
        // ML Kit expects nv21 on Android and bgra8888 on iOS (single plane).
        imageFormatGroup:
            Platform.isAndroid ? ImageFormatGroup.nv21 : ImageFormatGroup.bgra8888,
      );
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      await controller.setFlashMode(FlashMode.off);
      _camera = controller;
      await _startFaceScanStream();
      setState(() {
        _cameraReady = true;
        _cameraStarting = false;
        _cameraError = null;
      });
    } catch (_) {
      if (!mounted) return;
      final granted = await Permission.camera.isGranted;
      setState(() {
        _cameraReady = false;
        _cameraStarting = false;
        if (granted) {
          _systemCameraFallback = true;
          _cameraError = null;
        } else {
          _cameraError =
              'Could not start the camera. Try again or choose a photo.';
        }
      });
    } finally {
      _initInProgress = false;
    }
  }

  Future<void> _onPhotoPath(String path, PhotoSource source) async {
    if (_processingPhoto) return;
    setState(() => _processingPhoto = true);
    try {
      await glowUpHandoffPhoto(context, path: path, source: source);
    } finally {
      if (mounted) setState(() => _processingPhoto = false);
    }
  }

  Future<void> _startFaceScanStream() async {
    if (_systemCameraFallback) return;
    final camera = _camera;
    if (camera == null || !camera.value.isInitialized || _streamActive) {
      return;
    }
    try {
      await camera.startImageStream(_onCameraFrame);
      _streamActive = true;
    } catch (e) {
      debugPrint('[GlowScan] face stream failed: $e');
    }
  }

  Future<void> _stopFaceScanStream() async {
    final camera = _camera;
    if (camera == null || !_streamActive) return;
    try {
      await camera.stopImageStream();
    } catch (_) {}
    _streamActive = false;
    _processingFrame = false;
    _qualityEvaluator.reset();
  }

  Future<void> _onCameraFrame(CameraImage image) async {
    if (_processingFrame || _processingPhoto) {
      return;
    }
    final now = DateTime.now();
    final minMs = Platform.isIOS ? 200 : 180;
    if (now.difference(_lastFrameProcessed).inMilliseconds < minMs) return;
    _lastFrameProcessed = now;
    _processingFrame = true;

    try {
      final camera = _camera;
      FaceGlowMap? map;
      if (_mlkit != null && camera != null) {
        try {
          map = await _mlkit!.detectFromCameraImage(
            image,
            camera: camera.description,
            deviceOrientation: camera.value.deviceOrientation,
          );
        } catch (e) {
          debugPrint('[GlowScan] mlkit frame failed: $e');
        }
      }
      map ??= faceMapFromCameraImage(image);
      if (!mounted) return;

      FaceScanQuality next;
      if (map == null) {
        _qualityEvaluator.reset();
        next = FaceScanQuality.searching;
      } else {
        next = _qualityEvaluator.evaluateFromMap(
          map,
          Size(map.imageWidth.toDouble(), map.imageHeight.toDouble()),
          now: now,
        );
      }

      if (next.isReady != _scanQuality.isReady ||
          next.hint != _scanQuality.hint ||
          next.positionOk != _scanQuality.positionOk ||
          next.distanceOk != _scanQuality.distanceOk ||
          next.angleOk != _scanQuality.angleOk ||
          next.stillOk != _scanQuality.stillOk ||
          next.hasFace != _scanQuality.hasFace) {
        setState(() => _scanQuality = next);
      }
    } catch (e) {
      debugPrint('[GlowScan] frame analysis failed: $e');
    } finally {
      _processingFrame = false;
    }
  }

  bool get _liveScanActive => _cameraReady && !_systemCameraFallback;

  Color get _frameColor {
    if (!_liveScanActive) return _frameRed;
    final q = _scanQuality;
    if (q.isReady) return _frameGreen;
    if (q.hasFace && q.positionOk && q.distanceOk && q.angleOk) {
      return _frameAmber; // almost ready — waiting on stillness
    }
    return _frameRed;
  }

  double get _readinessProgress {
    if (!_liveScanActive) return 0;
    final q = _scanQuality;
    if (!q.hasFace) return 0;
    var score = 0;
    if (q.positionOk) score++;
    if (q.distanceOk) score++;
    if (q.angleOk) score++;
    if (q.stillOk) score++;
    return score / 4.0;
  }

  bool get _canTakePhoto => _cameraReady && _cameraError == null;

  String get _primaryCaptureLabel {
    if (_scanQuality.isReady) return 'Take photo';
    if (_scanQuality.hasFace) return 'Take photo anyway';
    return 'Take photo';
  }

  String? get _captureHint {
    if (_cameraStarting) return null;
    if (_cameraError != null) return _cameraError;
    if (_systemCameraFallback) {
      return 'Live preview unavailable. Go back and choose from library.';
    }
    return null;
  }

  Future<void> _takePhoto() async {
    if (!_canTakePhoto) return;

    final camera = _camera;
    if (camera == null || !camera.value.isInitialized) return;

    try {
      await _stopFaceScanStream();
      final file = await camera.takePicture();
      if (!mounted) return;
      await _onPhotoPath(file.path, PhotoSource.camera);
    } catch (_) {
      if (!mounted) return;
      await _startFaceScanStream();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not capture photo. Try again.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: Stack(
        fit: StackFit.expand,
        children: [
          _LiveCameraLayer(
            controller: _camera,
            ready: _cameraReady,
            starting: _cameraStarting,
          ),
          SafeArea(
            child: Column(
              children: [
                _TopBar(
                  onBack: () => Navigator.of(context).pop(),
                  onHistory: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const GlowUpHistoryScreen(),
                      ),
                    );
                  },
                ),
                const _BrandPill(),
                const Spacer(flex: 2),
                _FaceGuide(
                  scanLine: _scanLine,
                  ovalSpin: _ovalSpin,
                  halo: _halo,
                  pulse: _pulse,
                  showPlaceholder: !_cameraReady,
                  isReady: _liveScanActive && _scanQuality.isReady,
                  frameColor: _frameColor,
                  readinessProgress: _readinessProgress,
                ),
                const Spacer(flex: 2),
                _InstructionBlock(
                  hint: _captureHint,
                  scanHint: _liveScanActive ? _scanQuality.hint : null,
                  isReady: _liveScanActive && _scanQuality.isReady,
                  onRetry: _cameraError != null ? _initCamera : null,
                ),
                const SizedBox(height: 18),
                _StatusChecks(quality: _scanQuality, live: _liveScanActive),
                const SizedBox(height: 24),
                _BottomTakePhoto(
                  onPressed: _canTakePhoto ? _takePhoto : null,
                  primaryLabel: _primaryCaptureLabel,
                  enabled: _canTakePhoto,
                  isReady: _liveScanActive && _scanQuality.isReady,
                ),
              ],
            ),
          ),
          if (_processingPhoto)
            Positioned.fill(
              child: ColoredBox(
                color: Colors.black.withValues(alpha: 0.55),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2.5,
                      ),
                      const SizedBox(height: 14),
                      Text(
                        'Preparing your photo…',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: Colors.white.withValues(alpha: 0.85),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _LiveCameraLayer extends StatelessWidget {
  const _LiveCameraLayer({
    required this.controller,
    required this.ready,
    required this.starting,
  });

  final CameraController? controller;
  final bool ready;
  final bool starting;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        if (ready && controller != null)
          Positioned.fill(
            child: FittedBox(
              fit: BoxFit.cover,
              child: SizedBox(
                width: controller!.value.previewSize?.height ?? 1,
                height: controller!.value.previewSize?.width ?? 1,
                child: CameraPreview(controller!),
              ),
            ),
          )
        else
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [_camGradTop, _camGradBot],
              ),
            ),
          ),
        CustomPaint(painter: _GridOverlayPainter()),
        CustomPaint(painter: _GrainPainter()),
        if (!ready && starting)
          Center(
            child: Text(
              'Starting camera…',
              style: TextStyle(
                fontSize: 12,
                color: Colors.white.withValues(alpha: 0.35),
              ),
            ),
          ),
      ],
    );
  }
}

class _GridOverlayPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.015)
      ..strokeWidth = 1;
    const step = 40.0;
    for (var x = 0.0; x < size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (var y = 0.0; y < size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _GrainPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = Colors.white.withValues(alpha: 0.04),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.onBack,
    required this.onHistory,
  });

  final VoidCallback onBack;
  final VoidCallback onHistory;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 0),
      child: Row(
        children: [
          _TopBarCircleBtn(icon: Icons.chevron_left, onTap: onBack),
          Expanded(
            child: Column(
              children: [
                Text(
                  'GLOW UP AI',
                  style: TextStyle(
                    fontSize: 8,
                    letterSpacing: 1.44,
                    fontWeight: FontWeight.w500,
                    color: Colors.white.withValues(alpha: 0.3),
                  ),
                ),
                const SizedBox(height: 2),
                const Text(
                  'Position your face',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ),
          _TopBarCircleBtn(icon: Icons.history_rounded, onTap: onHistory),
        ],
      ),
    );
  }
}

class _TopBarCircleBtn extends StatelessWidget {
  const _TopBarCircleBtn({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: 0.07),
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: 32,
          height: 32,
          child: Icon(
            icon,
            size: 20,
            color: Colors.white.withValues(alpha: 0.7),
          ),
        ),
      ),
    );
  }
}

class _BrandPill extends StatelessWidget {
  const _BrandPill();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.12),
            width: 0.5,
          ),
        ),
        child: Text(
          'ÆSTHETIC JOURNEY',
          style: GoogleFonts.inter(
            fontSize: 9,
            letterSpacing: 2.5,
            fontWeight: FontWeight.w500,
            color: Colors.white.withValues(alpha: 0.4),
          ),
        ),
      ),
    );
  }
}

class _FaceGuide extends StatelessWidget {
  const _FaceGuide({
    required this.scanLine,
    required this.ovalSpin,
    required this.halo,
    required this.pulse,
    required this.showPlaceholder,
    required this.isReady,
    required this.frameColor,
    required this.readinessProgress,
  });

  final AnimationController scanLine;
  final AnimationController ovalSpin;
  final AnimationController halo;
  final AnimationController pulse;
  final bool showPlaceholder;
  final bool isReady;
  final Color frameColor;
  final double readinessProgress;

  @override
  Widget build(BuildContext context) {
    const w = 248.0;
    const h = 312.0;

    return SizedBox(
      width: w + 48,
      height: h + 48,
      child: Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          AnimatedBuilder(
            animation: Listenable.merge([halo, pulse]),
            builder: (context, child) {
              final pulseScale = isReady ? 1.0 : 1.0 + pulse.value * 0.06;
              final glowAlpha = isReady
                  ? 0.28 + halo.value * 0.12
                  : 0.18 + pulse.value * 0.14;
              return Transform.scale(
                scale: pulseScale,
                child: Container(
                  width: w + 36,
                  height: h + 36,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.all(
                      Radius.elliptical((w + 36) / 2, (h + 36) / 2),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: frameColor.withValues(alpha: glowAlpha),
                        blurRadius: isReady ? 28 : 18,
                        spreadRadius: isReady ? 2 : 0,
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
          AnimatedBuilder(
            animation: ovalSpin,
            builder: (context, _) => CustomPaint(
              size: const Size(w, h),
              painter: _AnimatedOvalBorderPainter(
                progress: ovalSpin.value,
                frameColor: frameColor,
                isReady: isReady,
                readinessProgress: readinessProgress,
              ),
            ),
          ),
          if (showPlaceholder)
            ClipOval(
              child: Container(
                width: w - 16,
                height: h - 16,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      _faceInside,
                      _faceInside.withValues(alpha: 0.85),
                    ],
                  ),
                  border: Border.all(
                    color: frameColor.withValues(alpha: 0.35),
                    width: 1.5,
                  ),
                ),
                child: Icon(
                  Icons.person,
                  size: 96,
                  color: frameColor.withValues(alpha: 0.25),
                ),
              ),
            ),
          _CornerBracket(
            alignment: Alignment.topLeft,
            color: frameColor,
            isReady: isReady,
          ),
          _CornerBracket(
            alignment: Alignment.topRight,
            color: frameColor,
            isReady: isReady,
          ),
          _CornerBracket(
            alignment: Alignment.bottomLeft,
            color: frameColor,
            isReady: isReady,
          ),
          _CornerBracket(
            alignment: Alignment.bottomRight,
            color: frameColor,
            isReady: isReady,
          ),
          AnimatedBuilder(
            animation: scanLine,
            builder: (context, _) {
              if (isReady) return const SizedBox.shrink();
              final t = Curves.easeInOut.transform(scanLine.value);
              final top = h * (0.1 + t * 0.8);
              final opacity = t < 0.1 || t > 0.9 ? 0.0 : 0.85;
              return Positioned(
                left: 12,
                right: 12,
                top: top,
                child: Opacity(
                  opacity: opacity,
                  child: Container(
                    height: 2,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          Colors.transparent,
                          frameColor.withValues(alpha: 0.85),
                          Colors.transparent,
                        ],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: frameColor.withValues(alpha: 0.45),
                          blurRadius: 6,
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _AnimatedOvalBorderPainter extends CustomPainter {
  const _AnimatedOvalBorderPainter({
    required this.progress,
    required this.frameColor,
    required this.isReady,
    required this.readinessProgress,
  });

  final double progress;
  final Color frameColor;
  final bool isReady;
  final double readinessProgress;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(4, 4, size.width - 8, size.height - 8);
    final oval = Path()..addOval(rect);

    if (!isReady) {
      final p = readinessProgress.clamp(0.0, 1.0);
      final arcColor = _progressColor(p);
      final sweep = 2 * math.pi * p;
      if (sweep > 0.01) {
        canvas.drawArc(
          rect,
          -math.pi / 2,
          sweep,
          false,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 4
            ..strokeCap = StrokeCap.round
            ..color = arcColor.withValues(alpha: 0.92),
        );
      }
    }

    canvas.drawOval(
      rect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = isReady ? 3 : 2.5
        ..color = frameColor.withValues(alpha: isReady ? 0.95 : 0.75),
    );

    _drawDashedOval(
      canvas,
      oval,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = frameColor.withValues(alpha: 0.35),
      dash: 6,
      gap: 5,
      phase: 0,
    );

    if (isReady) return;

    final metric = oval.computeMetrics().first;
    final total = metric.length;
    const highlightLen = 72.0;
    final start = (progress % 1.0) * total;
    final end = start + highlightLen;

    final highlight = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..color = frameColor.withValues(alpha: 0.95);

    if (end <= total) {
      canvas.drawPath(metric.extractPath(start, end), highlight);
    } else {
      canvas.drawPath(metric.extractPath(start, total), highlight);
      canvas.drawPath(metric.extractPath(0, end - total), highlight);
    }
  }

  void _drawDashedOval(
    Canvas canvas,
    Path oval,
    Paint paint, {
    required double dash,
    required double gap,
    required double phase,
  }) {
    final metric = oval.computeMetrics().first;
    final total = metric.length;
    var distance = phase;
    while (distance < total) {
      final next = math.min(distance + dash, total);
      canvas.drawPath(metric.extractPath(distance, next), paint);
      distance = next + gap;
    }
  }

  @override
  bool shouldRepaint(_AnimatedOvalBorderPainter old) =>
      old.progress != progress ||
      old.frameColor != frameColor ||
      old.isReady != isReady ||
      old.readinessProgress != readinessProgress;

  Color _progressColor(double p) {
    // Red → amber → green
    if (p <= 0) return _frameRed;
    if (p >= 1) return _frameGreen;
    if (p < 0.66) {
      return Color.lerp(_frameRed, _frameAmber, (p / 0.66).clamp(0.0, 1.0)) ??
          _frameAmber;
    }
    return Color.lerp(
          _frameAmber,
          _frameGreen,
          ((p - 0.66) / 0.34).clamp(0.0, 1.0),
        ) ??
        _frameGreen;
  }
}

class _CornerBracket extends StatelessWidget {
  const _CornerBracket({
    required this.alignment,
    required this.color,
    required this.isReady,
  });

  final Alignment alignment;
  final Color color;
  final bool isReady;

  @override
  Widget build(BuildContext context) {
    final side = BorderSide(
      color: color.withValues(alpha: isReady ? 1.0 : 0.9),
      width: isReady ? 3.5 : 3,
    );
    return Align(
      alignment: alignment,
      child: Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: 0.45),
              blurRadius: 8,
            ),
          ],
          border: Border(
            top: alignment.y < 0 ? side : BorderSide.none,
            bottom: alignment.y > 0 ? side : BorderSide.none,
            left: alignment.x < 0 ? side : BorderSide.none,
            right: alignment.x > 0 ? side : BorderSide.none,
          ),
        ),
      ),
    );
  }
}

class _InstructionBlock extends StatelessWidget {
  const _InstructionBlock({
    this.hint,
    this.scanHint,
    this.isReady = false,
    this.onRetry,
  });

  final String? hint;
  final String? scanHint;
  final bool isReady;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final primary = scanHint ?? 'Centre your face in the oval';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        children: [
          Text(
            primary,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              fontWeight: isReady ? FontWeight.w600 : FontWeight.w500,
              color: isReady
                  ? _frameGreen
                  : Colors.white.withValues(alpha: 0.82),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            isReady
                ? 'Hold this distance for the best glow-up result'
                : 'Keep still · Natural expression',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 11,
              color: Colors.white.withValues(alpha: 0.35),
            ),
          ),
          if (!isReady) ...[
            const SizedBox(height: 8),
            Text(
              'Tip: use soft, even lighting and a plain one-colour wall behind you',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11,
                height: 1.35,
                color: Colors.white.withValues(alpha: 0.42),
              ),
            ),
          ],
          if (hint != null) ...[
            const SizedBox(height: 10),
            Text(
              hint!,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11,
                height: 1.35,
                color: Colors.white.withValues(alpha: 0.45),
              ),
            ),
          ],
          if (onRetry != null) ...[
            const SizedBox(height: 8),
            TextButton(
              onPressed: onRetry,
              child: const Text('Retry camera', style: TextStyle(fontSize: 12)),
            ),
          ],
        ],
      ),
    );
  }
}

class _StatusChecks extends StatelessWidget {
  const _StatusChecks({required this.quality, required this.live});

  final FaceScanQuality quality;
  final bool live;

  static const _labels = ['Position', 'Distance', 'Angle', 'Still'];

  @override
  Widget build(BuildContext context) {
    final checks = live
        ? [
            quality.positionOk,
            quality.distanceOk,
            quality.angleOk,
            quality.stillOk,
          ]
        : [false, false, false, false];

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < _labels.length; i++) ...[
          if (i > 0) const SizedBox(width: 16),
          _CheckItem(
            label: _labels[i],
            ok: checks[i],
            warn: live && quality.hasFace && !checks[i],
          ),
        ],
      ],
    );
  }
}

class _CheckItem extends StatelessWidget {
  const _CheckItem({
    required this.label,
    required this.ok,
    this.warn = false,
  });

  final String label;
  final bool ok;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    final dotColor = ok
        ? _frameGreen
        : warn
            ? _frameRed
            : Colors.white.withValues(alpha: 0.2);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: dotColor,
            boxShadow: ok || warn
                ? [
                    BoxShadow(
                      color: dotColor.withValues(alpha: 0.65),
                      blurRadius: 7,
                    ),
                  ]
                : null,
          ),
        ),
        const SizedBox(width: 5),
        Text(
          label,
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.2,
            color: ok
                ? Colors.white.withValues(alpha: 0.9)
                : warn
                    ? Colors.white.withValues(alpha: 0.75)
                    : Colors.white.withValues(alpha: 0.45),
          ),
        ),
      ],
    );
  }
}

class _BottomTakePhoto extends StatelessWidget {
  const _BottomTakePhoto({
    required this.onPressed,
    required this.primaryLabel,
    required this.enabled,
    this.isReady = false,
  });

  final VoidCallback? onPressed;
  final String primaryLabel;
  final bool enabled;
  final bool isReady;

  @override
  Widget build(BuildContext context) {
    final label = enabled && isReady ? 'Take photo' : primaryLabel;
    final bg = enabled
        ? (isReady ? _frameGreen : Colors.white.withValues(alpha: 0.14))
        : Colors.white.withValues(alpha: 0.10);
    final fg = enabled
        ? (isReady ? Colors.black : Colors.white.withValues(alpha: 0.90))
        : Colors.white.withValues(alpha: 0.55);

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 28),
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.transparent, Colors.black.withValues(alpha: 0.95)],
            stops: const [0.0, 0.3],
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.only(top: 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: onPressed,
                  icon: Icon(
                    enabled ? Icons.camera_alt_outlined : Icons.lock_outline_rounded,
                    size: 18,
                    color: fg,
                  ),
                  label: Text(
                    label,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: fg,
                    ),
                  ),
                  style: FilledButton.styleFrom(
                    backgroundColor: bg,
                    disabledBackgroundColor: bg,
                    padding: const EdgeInsets.symmetric(vertical: 15),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    side: BorderSide(
                      color: Colors.white.withValues(alpha: enabled ? 0.14 : 0.10),
                      width: 0.8,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
