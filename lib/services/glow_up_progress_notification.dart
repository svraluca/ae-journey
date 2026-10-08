import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart' hide Priority;
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:live_activities/live_activities.dart';

import 'glow_up_job.dart';
import 'notification_service.dart';

/// Uber/Glovo-style live progress while a glow-up job runs (lock screen / shade).
class GlowUpProgressNotification {
  GlowUpProgressNotification._();

  static final GlowUpProgressNotification instance =
      GlowUpProgressNotification._();

  static const _notifId = 9001;
  static const _channelId = 'glow_up_live';
  static const _appGroupId = 'group.com.svapps.aestheticpass';
  static const _liveActivityId = 'glow_up_progress';

  final LiveActivities _liveActivities = LiveActivities();
  final FlutterLocalNotificationsPlugin _local =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;
  bool _liveAvailable = false;
  String? _activityId;
  Timer? _enhanceTicker;
  int _enhanceProgress = 38;

  /// Live Activities need the Widget Extension in Xcode — off by default on iOS.
  bool get _iosLiveEnabled {
    final v = (dotenv.env['GLOW_UP_IOS_LIVE_ACTIVITY'] ?? 'false')
        .trim()
        .toLowerCase();
    return v == 'true' || v == '1' || v == 'on';
  }

  bool get _shouldSurfaceOnLockScreen {
    final job = GlowUpJobController.instance;
    if (job.backgrounded) return true;
    final state = SchedulerBinding.instance.lifecycleState;
    return state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached;
  }

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    if (Platform.isAndroid) {
      const channel = AndroidNotificationChannel(
        _channelId,
        'Glow-up in progress',
        description: 'Live progress while your glow-up is being created',
        importance: Importance.low,
        playSound: false,
        enableVibration: false,
      );
      await _local
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(channel);
    }

    if (Platform.isIOS) {
      try {
        await _liveActivities.init(appGroupId: _appGroupId);
        _liveAvailable = true;
        debugPrint('[GlowUpLive] ActivityKit bridge ready');
      } catch (e) {
        _liveAvailable = false;
        debugPrint('[GlowUpLive] ActivityKit init skipped: $e');
      }
    }
  }

  /// Keeps the live card in sync with [GlowUpJobController].
  Future<void> syncFromJob(GlowUpJobController job) async {
    await initialize();

    switch (job.status) {
      case GlowUpJobStatus.idle:
      case GlowUpJobStatus.error:
        await dismiss();
      case GlowUpJobStatus.runningStudio:
        _stopEnhanceTicker();
        if (!_shouldSurfaceOnLockScreen) {
          await dismiss();
          return;
        }
        await _show(
          headline: 'Preparing your studio portrait',
          detail: 'Standardizing lighting on a clean background',
          progress: 18,
          eta: '~1 min',
        );
      case GlowUpJobStatus.studioReady:
        _stopEnhanceTicker();
        if (!job.backgrounded) {
          await dismiss();
          return;
        }
        await _show(
          headline: 'Portrait ready',
          detail: 'Tap to continue your glow-up preview',
          progress: 100,
          eta: 'Continue',
        );
      case GlowUpJobStatus.runningEnhance:
        if (!_shouldSurfaceOnLockScreen) {
          await dismiss();
          return;
        }
        _startEnhanceTicker();
        await _show(
          headline: 'Creating your glow-up',
          detail: 'Analyzing your face and building your preview',
          progress: _enhanceProgress,
          eta: '~2 min',
        );
      case GlowUpJobStatus.done:
        _stopEnhanceTicker();
        if (job.backgrounded) {
          await complete(
            title: 'Your glow-up is ready',
            body: 'Tap to open your glow report',
          );
        } else {
          await dismiss();
        }
    }
  }

  Future<void> _show({
    required String headline,
    required String detail,
    required int progress,
    required String eta,
  }) async {
    final model = <String, dynamic>{
      'headline': headline,
      'detail': detail,
      'progress': progress.clamp(0, 100),
      'eta': eta,
      'brand': 'Glow Up AI',
    };

    var liveOk = false;
    if (Platform.isAndroid) {
      liveOk = await _tryLiveActivity(model);
    } else if (Platform.isIOS && _iosLiveEnabled && _liveAvailable) {
      final enabled = await _liveActivities.areActivitiesEnabled();
      if (enabled) {
        liveOk = await _tryLiveActivity(model);
      }
    }

    // iOS: always show a visible lock-screen notification (Live Activities need
    // the Widget Extension target in Xcode; Simulator never shows Live Activities).
    await _showLockScreenNotification(
      headline: headline,
      detail: detail,
      progress: progress,
      eta: eta,
      silent: liveOk && Platform.isAndroid,
    );
  }

  Future<bool> _tryLiveActivity(Map<String, dynamic> model) async {
    try {
      await _liveActivities.createOrUpdateActivity(
        _liveActivityId,
        model,
        removeWhenAppIsKilled: true,
      );
      _activityId = _liveActivityId;
      return true;
    } catch (e) {
      debugPrint('[GlowUpLive] activity update failed: $e');
      return false;
    }
  }

  Future<bool> _ensureNotificationPermission() async {
    await NotificationService.instance.initialize(requestPermission: false);
    if (await NotificationService.instance.hasNotificationPermission()) {
      return true;
    }
    await NotificationService.instance.requestPermissionAfterAuth();
    final ok = await NotificationService.instance.hasNotificationPermission();
    if (!ok) {
      debugPrint('[GlowUpLive] notification permission denied — lock screen hidden');
    }
    return ok;
  }

  Future<void> _showLockScreenNotification({
    required String headline,
    required String detail,
    required int progress,
    required String eta,
    bool silent = false,
  }) async {
    if (silent) return;

    if (!await _ensureNotificationPermission()) return;

    final android = AndroidNotificationDetails(
      _channelId,
      'Glow-up in progress',
      channelDescription: 'Live progress while your glow-up is being created',
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
      ongoing: true,
      onlyAlertOnce: true,
      showProgress: true,
      maxProgress: 100,
      progress: progress.clamp(0, 100),
      indeterminate: false,
      visibility: NotificationVisibility.public,
      category: AndroidNotificationCategory.progress,
      subText: 'Glow Up AI',
      styleInformation: BigTextStyleInformation(
        detail,
        contentTitle: headline,
        summaryText: eta.isNotEmpty ? eta : 'In progress',
      ),
      actions: const <AndroidNotificationAction>[
        AndroidNotificationAction(
          'glow_up_open',
          'Open',
          showsUserInterface: true,
        ),
      ],
    );

    final ios = DarwinNotificationDetails(
      presentAlert: true,
      presentBanner: true,
      presentList: true,
      presentSound: false,
      threadIdentifier: 'glow_up_live',
      interruptionLevel: InterruptionLevel.timeSensitive,
    );

    await _local.show(
      _notifId,
      headline,
      '$detail · $eta',
      NotificationDetails(android: android, iOS: ios),
      payload: 'glow_up_step',
    );
  }

  Future<void> complete({
    required String title,
    required String body,
  }) async {
    if (_activityId != null) {
      try {
        await _liveActivities.updateActivity(
          _liveActivityId,
          {
            'headline': title,
            'detail': body,
            'progress': 100,
            'eta': 'Done',
            'brand': 'Glow Up AI',
          },
        );
        await Future<void>.delayed(const Duration(seconds: 2));
        await _liveActivities.endActivity(_liveActivityId);
      } catch (e) {
        debugPrint('[GlowUpLive] end failed: $e');
      }
      _activityId = null;
    }

    await _local.cancel(_notifId);
    await NotificationService.instance.showLocalNotification(
      title: title,
      body: body,
      payload: 'glow_up_step',
    );
  }

  Future<void> dismiss() async {
    _stopEnhanceTicker();
    if (_activityId != null) {
      try {
        await _liveActivities.endActivity(_liveActivityId);
      } catch (e) {
        debugPrint('[GlowUpLive] dismiss end failed: $e');
      }
      _activityId = null;
    }
    await _local.cancel(_notifId);
  }

  void _startEnhanceTicker() {
    _enhanceTicker ??= Timer.periodic(const Duration(seconds: 2), (_) async {
      if (_enhanceProgress < 92) {
        _enhanceProgress += 4;
        final job = GlowUpJobController.instance;
        if (job.isRunningEnhance && _shouldSurfaceOnLockScreen) {
          await _show(
            headline: 'Creating your glow-up',
            detail: 'Analyzing your face and building your preview',
            progress: _enhanceProgress,
            eta: '~2 min',
          );
        }
      }
    });
  }

  void _stopEnhanceTicker() {
    _enhanceTicker?.cancel();
    _enhanceTicker = null;
    _enhanceProgress = 38;
  }
}
