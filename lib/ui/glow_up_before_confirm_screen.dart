import 'dart:io';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/app_navigator.dart';
import '../services/glow_up_pipeline.dart';
import 'glow_up_loading_screen.dart';
import 'photo_storage.dart';
import 'widgets/notification_permission_sheet.dart';

const _bg = Color(0xFF0C0C0E);
const _surface2 = Color(0xFF1A1A1F);
const _border = Color(0xFF1E1E24);
const _photoBefore = Color(0xFF0E0E12);
const _faceBg = Color(0xFF1A1A20);
const _cyan = Color(0xFF22D3EE);
const _cyanMid = Color(0xFF0EA5E9);
const _indigo = Color(0xFF6366F1);
const _frameRadius = 20.0;

/// Dedicated step: confirm the studio-edited before photo before glow-up AI runs.
class GlowUpBeforeConfirmScreen extends StatefulWidget {
  const GlowUpBeforeConfirmScreen({
    super.key,
    required this.before,
    this.pipeline,
    this.source = PhotoSource.camera,
  });

  final GlowStudioBeforeResult before;
  final GlowUpPipeline? pipeline;
  final PhotoSource source;

  @override
  State<GlowUpBeforeConfirmScreen> createState() =>
      _GlowUpBeforeConfirmScreenState();
}

class _GlowUpBeforeConfirmScreenState extends State<GlowUpBeforeConfirmScreen> {
  String? _displayPath;
  bool _preparingPreview = true;

  @override
  void initState() {
    super.initState();
    _loadDisplayPreview();
  }

  Future<void> _loadDisplayPreview() async {
    final studio = widget.before.studioPath.trim();
    if (mounted) {
      setState(() {
        // Show the real studio JPEG — no second crop/zoom (was cutting hair).
        _displayPath = studio;
        _preparingPreview = false;
      });
    }
  }

  Future<void> _continue(BuildContext context) async {
    await NotificationPermissionSheet.promptForGlowUpIfNeeded(context);
    if (!context.mounted) return;
    Navigator.of(context).pushReplacement(
      PageRouteBuilder<void>(
        settings: const RouteSettings(name: glowUpFlowRoute),
        transitionDuration: const Duration(milliseconds: 400),
        pageBuilder: (context, animation, secondaryAnimation) =>
            GlowUpLoadingScreen(
              phase: GlowUpLoadingPhase.enhance,
              photoPath: widget.before.rawPhotoPath,
              studioPath: widget.before.studioPath,
              source: widget.source,
              pipeline: widget.pipeline,
            ),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(
            opacity: CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
            ),
            child: child,
          );
        },
      ),
    );
  }

  void _retake(BuildContext context) {
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final studioPath = widget.before.studioPath.trim();
    final previewPath = (_displayPath ?? studioPath).trim();
    final error = widget.before.error?.trim();
    final mono = GoogleFonts.jetBrainsMono;

    return Scaffold(
      backgroundColor: _bg,
      body: Stack(
        children: [
          Positioned(
            top: -120,
            left: -80,
            right: -80,
            height: 280,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: Alignment.topCenter,
                  radius: 0.9,
                  colors: [
                    _cyan.withValues(alpha: 0.12),
                    _indigo.withValues(alpha: 0.06),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
          SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 4, 16, 0),
                  child: Row(
                    children: [
                      IconButton(
                        onPressed: () => _retake(context),
                        icon: Icon(
                          Icons.arrow_back_ios_new,
                          size: 18,
                          color: Colors.white.withValues(alpha: 0.5),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          'GLOW UP AI',
                          textAlign: TextAlign.center,
                          style: mono(
                            fontSize: 9,
                            fontWeight: FontWeight.w500,
                            letterSpacing: 2.4,
                            color: Colors.white.withValues(alpha: 0.35),
                          ),
                        ),
                      ),
                      const SizedBox(width: 48),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: _cyan.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: _cyan.withValues(alpha: 0.28),
                        width: 0.5,
                      ),
                    ),
                    child: Text(
                      'STEP 1 · STUDIO EDIT',
                      style: mono(
                        fontSize: 9,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 1.6,
                        color: _cyan.withValues(alpha: 0.9),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 28),
                  child: Text(
                    'Your photo,\nstudio-edited',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w600,
                      height: 1.15,
                      letterSpacing: -0.6,
                      color: Colors.white.withValues(alpha: 0.95),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Text(
                    'We turned your shot into a pro studio portrait on black — '
                    'before the glow-up preview. Your face stays exactly the same.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 14,
                      height: 1.45,
                      color: Colors.white.withValues(alpha: 0.45),
                    ),
                  ),
                ),
                if (error != null && error.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 28),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1A1014),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: const Color(0xFFFB7185).withValues(alpha: 0.35),
                        ),
                      ),
                      child: Text(
                        error,
                        style: TextStyle(
                          fontSize: 11,
                          height: 1.35,
                          color: Colors.white.withValues(alpha: 0.72),
                        ),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        const aspect = 4 / 5;
                        var height = constraints.maxHeight;
                        var width = height * aspect;
                        if (width > constraints.maxWidth) {
                          width = constraints.maxWidth;
                          height = width / aspect;
                        }
                        return Center(
                          child: SizedBox(
                            width: width,
                            height: height,
                            child: _StudioPhotoFrame(
                              photoPath: previewPath,
                              loading: _preparingPreview,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
                  child: Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 8,
                    runSpacing: 8,
                    children: const [
                      _StudioChip(icon: Icons.dark_mode_outlined, label: 'Black backdrop'),
                      _StudioChip(icon: Icons.wb_incandescent_outlined, label: 'Even studio light'),
                      _StudioChip(icon: Icons.face_retouching_natural, label: 'Face unchanged'),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 14, 24, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(14),
                          gradient: const LinearGradient(
                            colors: [_cyan, _cyanMid],
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: _cyan.withValues(alpha: 0.25),
                              blurRadius: 20,
                              offset: const Offset(0, 6),
                            ),
                          ],
                        ),
                        child: FilledButton(
                          onPressed: studioPath.isEmpty || _preparingPreview
                              ? null
                              : () => _continue(context),
                          style: FilledButton.styleFrom(
                            backgroundColor: Colors.transparent,
                            foregroundColor: Colors.black,
                            shadowColor: Colors.transparent,
                            disabledBackgroundColor: Colors.transparent,
                            disabledForegroundColor:
                                Colors.black.withValues(alpha: 0.35),
                            minimumSize: const Size.fromHeight(52),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          child: const Text(
                            'Continue to glow-up preview',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Step 2 applies your treatment preview on this studio photo',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 11,
                          height: 1.35,
                          color: Colors.white.withValues(alpha: 0.28),
                        ),
                      ),
                      const SizedBox(height: 6),
                      TextButton(
                        onPressed: () => _retake(context),
                        style: TextButton.styleFrom(
                          minimumSize: const Size.fromHeight(44),
                          foregroundColor: Colors.white.withValues(alpha: 0.5),
                        ),
                        child: const Text(
                          'Retake photo',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StudioPhotoFrame extends StatelessWidget {
  const _StudioPhotoFrame({
    required this.photoPath,
    this.loading = false,
  });

  final String photoPath;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(_frameRadius),
        border: Border.all(
          color: _cyan.withValues(alpha: 0.22),
          width: 0.75,
        ),
        boxShadow: [
          BoxShadow(
            color: _cyan.withValues(alpha: 0.08),
            blurRadius: 32,
            spreadRadius: 2,
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(
            color: _photoBefore,
            child: loading
                ? Center(
                    child: SizedBox(
                      width: 28,
                      height: 28,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: _cyan.withValues(alpha: 0.7),
                      ),
                    ),
                  )
                : _BeforePreviewImage(photoPath: photoPath),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 72,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Colors.black.withValues(alpha: 0.65),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            top: 14,
            left: 14,
            child: _StudioBadge(
              icon: Icons.camera_enhance_outlined,
              label: 'STUDIO BEFORE',
            ),
          ),
          Positioned(
            bottom: 14,
            left: 14,
            right: 14,
            child: Text(
              'This is your before photo in the glow report',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: Colors.white.withValues(alpha: 0.72),
                shadows: const [
                  Shadow(color: Colors.black54, blurRadius: 8),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StudioBadge extends StatelessWidget {
  const _StudioBadge({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _cyan.withValues(alpha: 0.35), width: 0.5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: _cyan.withValues(alpha: 0.9)),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 9,
              letterSpacing: 1.2,
              fontWeight: FontWeight.w600,
              color: _cyan.withValues(alpha: 0.95),
            ),
          ),
        ],
      ),
    );
  }
}

class _StudioChip extends StatelessWidget {
  const _StudioChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: _surface2,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _border, width: 0.5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 13,
            color: Colors.white.withValues(alpha: 0.38),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: Colors.white.withValues(alpha: 0.5),
            ),
          ),
        ],
      ),
    );
  }
}

class _BeforePreviewImage extends StatelessWidget {
  const _BeforePreviewImage({required this.photoPath});

  final String photoPath;

  @override
  Widget build(BuildContext context) {
    if (!_photoExists(photoPath)) {
      return Center(
        child: Icon(
          Icons.person_outline,
          size: 64,
          color: _faceBg.withValues(alpha: 0.9),
        ),
      );
    }

    return Image(
      key: ValueKey(photoPath),
      image: _imageProvider(photoPath),
      fit: BoxFit.contain,
      alignment: Alignment(0, -0.08),
      width: double.infinity,
      height: double.infinity,
      gaplessPlayback: true,
      filterQuality: FilterQuality.medium,
    );
  }
}

bool _photoExists(String? path) {
  final p = (path ?? '').trim();
  if (p.isEmpty) return false;
  return isRemoteUrl(p) || File(p).existsSync();
}

ImageProvider _imageProvider(String path) {
  if (isRemoteUrl(path)) return NetworkImage(path);
  return FileImage(File(path));
}
