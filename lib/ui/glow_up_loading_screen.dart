import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/app_navigator.dart';
import '../services/glow_up_job.dart';
import '../services/glow_up_pipeline.dart';
import 'glow_up_before_confirm_screen.dart';
import 'glow_up_result_screen.dart';
import 'widgets/airdrop_light_field.dart';
import 'widgets/notification_permission_sheet.dart';

enum GlowUpLoadingPhase {
  /// Stage 1 — black studio before photo, then before confirm screen.
  studioBefore,

  /// Stages 2–3 — analysis + after preview, then full glow report.
  enhance,
}

/// AirDrop-style loading between capture, before confirm, and glow report.
class GlowUpLoadingScreen extends StatefulWidget {
  const GlowUpLoadingScreen({
    super.key,
    this.photoPath,
    this.studioPath,
    this.source = PhotoSource.camera,
    this.pipeline,
    this.phase = GlowUpLoadingPhase.studioBefore,
  });

  final String? photoPath;

  /// Required when [phase] is [GlowUpLoadingPhase.enhance].
  final String? studioPath;

  final PhotoSource source;
  final GlowUpPipeline? pipeline;
  final GlowUpLoadingPhase phase;

  @override
  State<GlowUpLoadingScreen> createState() => _GlowUpLoadingScreenState();
}

class _GlowUpLoadingScreenState extends State<GlowUpLoadingScreen>
    with SingleTickerProviderStateMixin {
  static const _animCycle = Duration(milliseconds: 4800);
  static const _minHold = Duration(milliseconds: 1200);

  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: _animCycle,
  )..repeat();

  final _job = GlowUpJobController.instance;
  late final DateTime _startedAt;
  bool _navigated = false;
  bool _started = false;
  bool _minimizing = false;

  @override
  void initState() {
    super.initState();
    _startedAt = DateTime.now();
    _job.addListener(_onJob);
    _ensureStarted();
  }

  void _ensureStarted() {
    if (_started) return;
    _started = true;
    final path = widget.photoPath;

    if (widget.phase == GlowUpLoadingPhase.enhance) {
      if (_job.isRunningEnhance) {
        _job.backgrounded = false;
        _onJob();
        return;
      }
      if (_job.status == GlowUpJobStatus.done && _job.analysisResult != null) {
        _onJob();
        return;
      }
      final studio = widget.studioPath?.trim() ?? '';
      if (path == null || path.isEmpty || studio.isEmpty) {
        _finishThen(
          () => _openResult(GlowAnalysisResult.fallback(originalPath: path)),
        );
        return;
      }
      _job.startEnhance(
        studioPath: studio,
        rawPhotoPath: path,
        source: widget.source,
        pipeline: widget.pipeline,
      );
      _onJob();
      return;
    }

    if (_job.isRunningStudio) {
      _job.backgrounded = false;
      _onJob();
      return;
    }
    if (_job.status == GlowUpJobStatus.studioReady && _job.studioResult != null) {
      _onJob();
      return;
    }

    if (path == null || path.isEmpty) {
      _finishThen(
        () => _openBeforeConfirm(
          GlowStudioBeforeResult(
            studioPath: '',
            rawPhotoPath: '',
            error: 'No photo path.',
          ),
        ),
      );
      return;
    }

    _job.startStudio(
      photoPath: path,
      source: widget.source,
      pipeline: widget.pipeline,
    );
    _onJob();
  }

  /// Foreground completion → navigate after the minimum hold. When the user
  /// has minimized (job.backgrounded), the controller fires a notification
  /// instead and this screen no longer exists.
  void _onJob() {
    if (!mounted || _navigated || _job.backgrounded) return;
    if (widget.phase == GlowUpLoadingPhase.studioBefore) {
      if (_job.status == GlowUpJobStatus.studioReady &&
          _job.studioResult != null) {
        _finishThen(() => _openBeforeConfirm(_job.studioResult!));
      }
    } else {
      if (_job.status == GlowUpJobStatus.done && _job.analysisResult != null) {
        _finishThen(() => _openResult(_job.analysisResult!));
      }
    }
  }

  Future<void> _finishThen(VoidCallback navigate) async {
    if (_navigated) return;
    _navigated = true;
    final elapsed = DateTime.now().difference(_startedAt);
    final remaining = _minHold - elapsed;
    if (remaining > Duration.zero) {
      await Future<void>.delayed(remaining);
    }
    if (!mounted || _job.backgrounded) {
      _navigated = false;
      return;
    }
    navigate();
  }

  /// Leave the loading screen but keep the current step running. Pops the
  /// whole glow-up flow back to the app; a notification + in-app banner will
  /// surface when the step is ready.
  Future<void> _minimize() async {
    if (_minimizing || !mounted) return;
    _minimizing = true;
    try {
      _job.markBackgrounded();

      Navigator.of(context, rootNavigator: true).popUntil((route) {
        if (route.isFirst) return true;
        return route.settings.name != glowUpFlowRoute;
      });

      // Prompt on the home/root context after the flow is gone (avoids orphan
      // modal barriers that dim the screen and block touches).
      final rootCtx = appNavigatorKey.currentContext;
      if (rootCtx != null && rootCtx.mounted) {
        await NotificationPermissionSheet.promptForGlowUpIfNeeded(rootCtx);
      }
    } finally {
      _minimizing = false;
    }
  }

  void _openBeforeConfirm(GlowStudioBeforeResult before) {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      PageRouteBuilder<void>(
        settings: const RouteSettings(name: glowUpFlowRoute),
        transitionDuration: const Duration(milliseconds: 500),
        pageBuilder: (context, animation, secondaryAnimation) =>
            GlowUpBeforeConfirmScreen(
              before: before,
              pipeline: widget.pipeline,
              source: widget.source,
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

  void _openResult(GlowAnalysisResult result) {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      PageRouteBuilder<void>(
        settings: const RouteSettings(name: glowUpFlowRoute),
        transitionDuration: const Duration(milliseconds: 500),
        pageBuilder: (context, animation, secondaryAnimation) =>
            GlowUpResultScreen(photoPath: widget.photoPath, analysis: result),
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
    unawaited(GlowUpJobController.instance.reset());
  }

  String get _statusLine {
    switch (widget.phase) {
      case GlowUpLoadingPhase.studioBefore:
        return 'Preparing your studio portrait';
      case GlowUpLoadingPhase.enhance:
        return 'Analyzing your face\nand creating your glow-up';
    }
  }

  String? get _statusSubline {
    switch (widget.phase) {
      case GlowUpLoadingPhase.studioBefore:
        return 'AI is standardising your photo for accurate analysis';
      case GlowUpLoadingPhase.enhance:
        return null;
    }
  }

  @override
  void dispose() {
    _job.removeListener(_onJob);
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mono = GoogleFonts.jetBrainsMono;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _minimize();
      },
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final t = _c.value;
          final labelOpacity = Curves.easeOut.transform(
            ((t - 0.12) / 0.35).clamp(0.0, 1.0),
          );

          return Scaffold(
            backgroundColor: Colors.black,
            body: Stack(
              fit: StackFit.expand,
              children: [
                AirdropLightField(progress: t.clamp(0.0, 1.0)),
                SafeArea(
                  child: Stack(
                    children: [
                      Center(
                        child: Opacity(
                          opacity: labelOpacity,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                'GLOW UP AI',
                                style: mono(
                                  fontSize: 9,
                                  fontWeight: FontWeight.w500,
                                  letterSpacing: 2.2,
                                  color: Colors.white.withValues(alpha: 0.45),
                                ),
                              ),
                              const SizedBox(height: 14),
                              Text(
                                _statusLine,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w500,
                                  color: Colors.white.withValues(alpha: 0.88),
                                  height: 1.35,
                                  letterSpacing: -0.2,
                                ),
                              ),
                              if (_statusSubline != null) ...[
                                const SizedBox(height: 10),
                                Padding(
                                  padding:
                                      const EdgeInsets.symmetric(horizontal: 36),
                                  child: Text(
                                    _statusSubline!,
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      fontSize: 13,
                                      height: 1.4,
                                      color: Colors.white.withValues(alpha: 0.42),
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                      Align(
                        alignment: Alignment.bottomCenter,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(32, 0, 32, 28),
                          child: TextButton.icon(
                            onPressed: _minimize,
                            icon: Icon(
                              Icons.check_circle_outline_rounded,
                              size: 18,
                              color: Colors.white.withValues(alpha: 0.55),
                            ),
                            label: Text(
                              'Go home while we get your glow up ready',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                color: Colors.white.withValues(alpha: 0.6),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
