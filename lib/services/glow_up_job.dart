import 'dart:async';

import 'package:flutter/material.dart';

import '../ui/glow_up_before_confirm_screen.dart';
import '../ui/glow_up_photo_source_screen.dart';
import '../ui/glow_up_loading_screen.dart';
import '../ui/glow_up_result_screen.dart';
import '../ui/widgets/glow_up_ready_announcement.dart';
import 'app_navigator.dart';
import 'glow_up_job_persistence.dart';
import 'glow_up_pipeline.dart';
import 'glow_up_progress_notification.dart';
import 'notification_service.dart';
import 'notifications_store.dart';

enum GlowUpJobStatus {
  idle,
  runningStudio,
  studioReady,
  runningEnhance,
  done,
  error,
}

class _GlowUpJobLifecycleObserver with WidgetsBindingObserver {
  _GlowUpJobLifecycleObserver(this._job);

  final GlowUpJobController _job;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _job._onAppLifecycle(state);
  }
}

/// Owns the long-running glow-up pipeline work. Persists to disk so jobs
/// survive the user leaving the app, switching apps, or fully restarting.
class GlowUpJobController extends ChangeNotifier {
  GlowUpJobController._();

  static final GlowUpJobController instance = GlowUpJobController._();

  GlowUpJobStatus status = GlowUpJobStatus.idle;

  /// True once the user has left the foreground loading screen and let the
  /// current step finish in the background.
  bool backgrounded = false;

  /// Whether we already surfaced the ready announcement / push for this step.
  bool _notified = false;

  GlowUpPipeline? _pipeline;
  PhotoSource _source = PhotoSource.camera;

  String? _photoPath;
  String? _studioPath;
  String? _rawPhotoPath;

  GlowStudioBeforeResult? studioResult;
  GlowAnalysisResult? analysisResult;
  String? error;

  /// Bumped on every (re)start so superseded async results are ignored.
  int _runId = 0;

  /// True while an async pipeline call is in flight.
  bool _runActive = false;

  _GlowUpJobLifecycleObserver? _lifecycleObserver;
  bool _initialized = false;

  @override
  void notifyListeners() {
    super.notifyListeners();
    unawaited(GlowUpProgressNotification.instance.syncFromJob(this));
  }

  bool get isRunningStudio => status == GlowUpJobStatus.runningStudio;
  bool get isRunningEnhance => status == GlowUpJobStatus.runningEnhance;
  bool get isRunning => isRunningStudio || isRunningEnhance;

  /// In-progress glow-up (loading or before confirm) — not a finished report.
  bool get hasActiveFlow => isRunning || status == GlowUpJobStatus.studioReady;

  /// Call once at app startup (before [runApp] navigation settles).
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    _lifecycleObserver = _GlowUpJobLifecycleObserver(this);
    WidgetsBinding.instance.addObserver(_lifecycleObserver!);
    await restoreAndResume();
  }

  GlowUpPipeline _resolvePipeline(GlowUpPipeline? override) {
    final pipeline = override ?? _pipeline ?? GlowUpPipeline();
    _pipeline = pipeline;
    return pipeline;
  }

  Future<void> _persist() {
    return GlowUpJobPersistence.save(
      status: status.name,
      backgrounded: backgrounded,
      notified: _notified,
      source: _source,
      photoPath: _photoPath,
      studioPath: _studioPath ?? studioResult?.studioPath,
      rawPhotoPath: _rawPhotoPath ?? studioResult?.rawPhotoPath,
      studioResult: studioResult,
      analysisResult: analysisResult,
    );
  }

  void _onAppLifecycle(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      if (isRunning) {
        backgrounded = true;
        unawaited(_persist());
        notifyListeners();
      }
      return;
    }
    if (state == AppLifecycleState.resumed) {
      unawaited(_resumeIfInterrupted());
    }
  }

  Future<void> restoreAndResume() async {
    final snap = await GlowUpJobPersistence.load();
    if (snap == null || !snap.hasWork) return;
    if (!GlowUpJobPersistence.pathsValid(snap)) {
      await GlowUpJobPersistence.clear();
      return;
    }

    backgrounded = snap.backgrounded;
    _notified = snap.notified;
    _source = snap.source;
    _photoPath = snap.photoPath;
    _studioPath = snap.studioPath;
    _rawPhotoPath = snap.rawPhotoPath;

    switch (snap.status) {
      case 'runningStudio':
        status = GlowUpJobStatus.runningStudio;
        backgrounded = true;
        notifyListeners();
        if (!_runActive) {
          startStudio(
            photoPath: snap.photoPath!,
            source: snap.source,
            resume: true,
          );
        }
      case 'runningEnhance':
        status = GlowUpJobStatus.runningEnhance;
        backgrounded = true;
        notifyListeners();
        if (!_runActive) {
          startEnhance(
            studioPath: snap.studioPath!,
            rawPhotoPath: snap.rawPhotoPath!,
            source: snap.source,
            resume: true,
          );
        }
      case 'studioReady':
        status = GlowUpJobStatus.studioReady;
        studioResult = GlowStudioBeforeResult(
          studioPath: snap.studioPath ?? '',
          rawPhotoPath: snap.rawPhotoPath ?? snap.photoPath ?? '',
          error: snap.studioError,
        );
        notifyListeners();
        if (backgrounded && !_notified) {
          _notifyAndOfferResume(
            title: 'Your studio portrait is ready',
            body: 'Tap to continue your glow-up preview.',
            type: 'glow_studio',
          );
        }
      case 'done':
        status = GlowUpJobStatus.done;
        analysisResult = snap.analysisResult;
        notifyListeners();
        if (backgrounded && !_notified) {
          _notifyAndOfferResume(
            title: 'Your glow-up is ready',
            body: 'Tap to see your glow report.',
            type: 'glow_report',
          );
        }
      default:
        break;
    }
  }

  Future<void> _resumeIfInterrupted() async {
    if (!_runActive && isRunning) {
      if (isRunningStudio && (_photoPath ?? '').isNotEmpty) {
        startStudio(photoPath: _photoPath!, source: _source, resume: true);
      } else if (isRunningEnhance &&
          (_studioPath ?? '').isNotEmpty &&
          (_rawPhotoPath ?? '').isNotEmpty) {
        startEnhance(
          studioPath: _studioPath!,
          rawPhotoPath: _rawPhotoPath!,
          source: _source,
          resume: true,
        );
      }
    }
  }

  Future<void> reset() async {
    _runId++;
    _runActive = false;
    status = GlowUpJobStatus.idle;
    backgrounded = false;
    _notified = false;
    studioResult = null;
    analysisResult = null;
    error = null;
    _photoPath = null;
    _studioPath = null;
    _rawPhotoPath = null;
    await GlowUpJobPersistence.clear();
    notifyListeners();
  }

  /// Marks the job as backgrounded (user went home). Persists immediately.
  void markBackgrounded() {
    backgrounded = true;
    notifyListeners();
    unawaited(_persist());
  }

  // ---- Step 1: black-studio "before" ----------------------------------------

  void startStudio({
    required String photoPath,
    required PhotoSource source,
    GlowUpPipeline? pipeline,
    bool resume = false,
  }) {
    final pipe = _resolvePipeline(pipeline);
    _source = source;
    _photoPath = photoPath;
    if (!resume) {
      backgrounded = false;
      _notified = false;
      studioResult = null;
      analysisResult = null;
      error = null;
    }
    status = GlowUpJobStatus.runningStudio;
    final runId = ++_runId;
    notifyListeners();
    unawaited(_persist());
    _runStudio(pipe, photoPath, runId);
  }

  Future<void> _runStudio(
    GlowUpPipeline pipe,
    String photoPath,
    int runId,
  ) async {
    _runActive = true;
    GlowStudioBeforeResult result;
    try {
      result = await pipe.prepareStudioBefore(photoPath, source: _source);
    } catch (e) {
      result = GlowStudioBeforeResult(
        studioPath: photoPath,
        rawPhotoPath: photoPath,
        error: '$e',
      );
    } finally {
      if (runId == _runId) _runActive = false;
    }
    if (runId != _runId) return;
    studioResult = result;
    _studioPath = result.studioPath;
    _rawPhotoPath = result.rawPhotoPath;
    status = GlowUpJobStatus.studioReady;
    notifyListeners();
    await _persist();
    if (backgrounded && !_notified) {
      _notifyAndOfferResume(
        title: 'Your studio portrait is ready',
        body: 'Tap to continue your glow-up preview.',
        type: 'glow_studio',
      );
    }
  }

  // ---- Step 2: analysis + after preview -------------------------------------

  void startEnhance({
    required String studioPath,
    required String rawPhotoPath,
    PhotoSource? source,
    GlowUpPipeline? pipeline,
    bool resume = false,
  }) {
    final pipe = _resolvePipeline(pipeline);
    if (source != null) _source = source;
    _studioPath = studioPath;
    _rawPhotoPath = rawPhotoPath;
    _photoPath = rawPhotoPath;
    if (!resume) {
      backgrounded = false;
      _notified = false;
      analysisResult = null;
      error = null;
    }
    status = GlowUpJobStatus.runningEnhance;
    final runId = ++_runId;
    notifyListeners();
    unawaited(_persist());
    _runEnhance(pipe, studioPath, rawPhotoPath, runId);
  }

  Future<void> _runEnhance(
    GlowUpPipeline pipe,
    String studioPath,
    String rawPhotoPath,
    int runId,
  ) async {
    _runActive = true;
    GlowAnalysisResult result;
    try {
      result = await pipe.completeGlowUp(
        studioPath: studioPath,
        rawPhotoPath: rawPhotoPath,
      );
    } catch (e) {
      result = GlowAnalysisResult.fallback(
        originalPath: rawPhotoPath,
        error: '$e',
      );
    } finally {
      if (runId == _runId) _runActive = false;
    }
    if (runId != _runId) return;
    analysisResult = result;
    status = GlowUpJobStatus.done;
    notifyListeners();
    await _persist();
    if (backgrounded && !_notified) {
      _notifyAndOfferResume(
        title: 'Your glow-up is ready',
        body: 'Tap to see your glow report.',
        type: 'glow_report',
      );
    }
  }

  // ---- Background completion: notify + resume -------------------------------

  void _notifyAndOfferResume({
    required String title,
    required String body,
    String type = 'glow',
  }) {
    if (_notified) return;
    _notified = true;
    unawaited(_persist());

    unawaited(
      NotificationService.instance.showLocalNotification(
        title: title,
        body: body,
        payload: 'glow_up_step',
      ),
    );
    unawaited(
      NotificationsStore.recordInApp(
        title: title,
        body: body,
        type: type,
        pushSent: true,
      ),
    );

    final isReport = status == GlowUpJobStatus.done;
    final scores = analysisResult?.scores;

    // Delay slightly so navigator context exists after cold start.
    Future<void>.delayed(const Duration(milliseconds: 600), () {
      if (appNavigatorKey.currentContext == null) return;
      unawaited(
        showGlowUpReadyAnnouncement(
          kind: isReport
              ? GlowUpAnnouncementKind.reportReady
              : GlowUpAnnouncementKind.studioReady,
          glowScore: scores?.glowScore,
          potentialScore: scores?.potentialScore,
          upliftPercent: scores?.deltaPercent,
          onView: openCurrentStep,
        ),
      );
    });
  }

  /// Routes to the correct glow-up screen for the current job (loading, confirm, or report).
  void openCurrentStep() {
    final ctx = appNavigatorKey.currentContext;
    if (ctx != null) {
      pushFlow(ctx);
      return;
    }
    appNavigatorKey.currentState?.push(_routeForCurrentStep());
  }

  /// Opens the in-progress flow instead of a fresh face scan when a job exists.
  void pushFlow(BuildContext context, {bool replace = false}) {
    if (isRunning) {
      backgrounded = false;
      unawaited(_persist());
    }
    final wasFinishedReport = status == GlowUpJobStatus.done;
    final route = _routeForCurrentStep();
    if (replace) {
      Navigator.of(context).pushReplacement(route);
    } else {
      Navigator.of(context).push(route);
    }
    // Report data lives on [GlowUpResultScreen]; clear job so re-entry starts at camera.
    if (wasFinishedReport) {
      unawaited(reset());
    }
  }

  Route<void> _routeForCurrentStep() {
    switch (status) {
      case GlowUpJobStatus.runningStudio:
        return MaterialPageRoute<void>(
          settings: const RouteSettings(name: glowUpFlowRoute),
          builder: (_) => GlowUpLoadingScreen(
            photoPath: _photoPath,
            source: _source,
            pipeline: _pipeline,
            phase: GlowUpLoadingPhase.studioBefore,
          ),
        );
      case GlowUpJobStatus.runningEnhance:
        return MaterialPageRoute<void>(
          settings: const RouteSettings(name: glowUpFlowRoute),
          builder: (_) => GlowUpLoadingScreen(
            photoPath: _rawPhotoPath ?? _photoPath,
            studioPath: _studioPath ?? studioResult?.studioPath,
            source: _source,
            pipeline: _pipeline,
            phase: GlowUpLoadingPhase.enhance,
          ),
        );
      case GlowUpJobStatus.studioReady:
        final before = studioResult ??
            GlowStudioBeforeResult(
              studioPath: _studioPath ?? '',
              rawPhotoPath: _rawPhotoPath ?? _photoPath ?? '',
              error: error,
            );
        backgrounded = false;
        unawaited(_persist());
        return MaterialPageRoute<void>(
          settings: const RouteSettings(name: glowUpFlowRoute),
          builder: (_) => GlowUpBeforeConfirmScreen(
            before: before,
            pipeline: _pipeline,
            source: _source,
          ),
        );
      case GlowUpJobStatus.done:
        final result = analysisResult ??
            GlowAnalysisResult.fallback(originalPath: _photoPath);
        backgrounded = false;
        unawaited(_persist());
        unawaited(GlowUpJobPersistence.clear());
        return MaterialPageRoute<void>(
          settings: const RouteSettings(name: glowUpFlowRoute),
          builder: (_) => GlowUpResultScreen(
            photoPath: result.rawPhotoPath ?? _photoPath,
            analysis: result,
          ),
        );
      case GlowUpJobStatus.idle:
      case GlowUpJobStatus.error:
        return MaterialPageRoute<void>(
          settings: const RouteSettings(name: glowUpFlowRoute),
          builder: (_) => const GlowUpPhotoSourceScreen(),
        );
    }
  }
}
