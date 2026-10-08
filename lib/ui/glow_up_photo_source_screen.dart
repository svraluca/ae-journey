import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/camera_bootstrap.dart';
import '../services/glow_up_job.dart';
import '../services/photo_processor.dart';
import 'glow_up_face_scan_screen.dart';
import 'glow_up_history_screen.dart';
import 'glow_up_photo_handoff.dart';

const _bg = Color(0xFF000000);

/// Step 0: choose live face scan or an existing photo (no camera preview here).
class GlowUpPhotoSourceScreen extends StatefulWidget {
  const GlowUpPhotoSourceScreen({super.key});

  @override
  State<GlowUpPhotoSourceScreen> createState() => _GlowUpPhotoSourceScreenState();
}

class _GlowUpPhotoSourceScreenState extends State<GlowUpPhotoSourceScreen> {
  final _picker = ImagePicker();
  bool _processing = false;
  bool _checkingCamera = true;
  bool _liveScanAvailable = true;

  @override
  void initState() {
    super.initState();
    _probeCamera();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final job = GlowUpJobController.instance;
      if (!mounted || !job.hasActiveFlow) return;
      job.pushFlow(context, replace: true);
    });
  }

  Future<void> _probeCamera() async {
    if (kIsWeb) {
      if (mounted) {
        setState(() {
          _checkingCamera = false;
          _liveScanAvailable = false;
        });
      }
      return;
    }
    try {
      final cameras = await loadCameras(forceRefresh: false);
      if (mounted) {
        setState(() {
          _checkingCamera = false;
          _liveScanAvailable = cameras.isNotEmpty;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _checkingCamera = false;
          _liveScanAvailable = false;
        });
      }
    }
  }

  Future<void> _openLiveFaceScan() async {
    if (_processing || !_liveScanAvailable) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: 'glowUpLiveFaceScan'),
        builder: (_) => const GlowUpFaceScanScreen(),
      ),
    );
  }

  Future<void> _pickFromLibrary() async {
    if (_processing) return;

    if (!kIsWeb && (Platform.isIOS || Platform.isAndroid)) {
      final photos = await Permission.photos.request();
      if (!photos.isGranted && !photos.isLimited) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Allow photo access in Settings to choose a photo.',
            ),
          ),
        );
        return;
      }
    }

    try {
      final img = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 2048,
        maxHeight: 2048,
        imageQuality: 92,
        requestFullMetadata: false,
      );
      if (img == null || !mounted) return;
      setState(() => _processing = true);
      await glowUpHandoffPhoto(
        context,
        path: img.path,
        source: PhotoSource.library,
      );
    } catch (e) {
      debugPrint('[GlowUp] library pick failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not open your photo library.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: Stack(
        fit: StackFit.expand,
        children: [
          SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 8, 18, 0),
                  child: Row(
                    children: [
                      _CircleIconBtn(
                        icon: Icons.chevron_left,
                        onTap: () => Navigator.of(context).pop(),
                      ),
                      const Expanded(
                        child: Column(
                          children: [
                            Text(
                              'GLOW UP AI',
                              style: TextStyle(
                                fontSize: 8,
                                letterSpacing: 1.44,
                                fontWeight: FontWeight.w500,
                                color: Color(0x4DFFFFFF),
                              ),
                            ),
                            SizedBox(height: 2),
                            Text(
                              'Add your photo',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                                color: Colors.white,
                              ),
                            ),
                          ],
                        ),
                      ),
                      _CircleIconBtn(
                        icon: Icons.history_rounded,
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => const GlowUpHistoryScreen(),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
                const Spacer(flex: 2),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 28),
                  child: Text(
                    'Start with a live scan for the best framing, or pick a photo you already have.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.45,
                      color: Colors.white.withValues(alpha: 0.45),
                    ),
                  ),
                ),
                const Spacer(flex: 3),
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 0, 18, 28),
                  child: Column(
                    children: [
                      _SourceOption(
                        icon: Icons.face_retouching_natural_outlined,
                        title: 'Live face scan',
                        subtitle: _checkingCamera
                            ? 'Checking camera…'
                            : _liveScanAvailable
                            ? 'Position your face with real-time guidance'
                            : 'Camera unavailable on this device',
                        enabled: !_processing && !_checkingCamera && _liveScanAvailable,
                        highlighted: true,
                        onTap: _openLiveFaceScan,
                      ),
                      const SizedBox(height: 12),
                      _SourceOption(
                        icon: Icons.photo_outlined,
                        title: 'Choose from library',
                        subtitle: 'Use a photo already on your phone',
                        enabled: !_processing,
                        onTap: _pickFromLibrary,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (_processing)
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

class _CircleIconBtn extends StatelessWidget {
  const _CircleIconBtn({required this.icon, required this.onTap});

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
          child: Icon(icon, size: 20, color: Colors.white.withValues(alpha: 0.7)),
        ),
      ),
    );
  }
}

class _SourceOption extends StatelessWidget {
  const _SourceOption({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.enabled = true,
    this.highlighted = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool enabled;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final fg = enabled ? Colors.white : Colors.white.withValues(alpha: 0.35);
    return Material(
      color: highlighted && enabled
          ? Colors.white.withValues(alpha: 0.10)
          : Colors.white.withValues(alpha: 0.06),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: Colors.white.withValues(alpha: enabled ? 0.12 : 0.06),
              width: 0.8,
            ),
          ),
          child: Row(
            children: [
              Icon(icon, size: 22, color: fg.withValues(alpha: 0.75)),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: fg,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 11,
                        color: fg.withValues(alpha: 0.45),
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right,
                size: 20,
                color: fg.withValues(alpha: 0.35),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
