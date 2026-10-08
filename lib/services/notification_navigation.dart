import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../data/procedure_repository.dart';
import '../ui/procedure_detail_screen.dart';
import 'app_navigator.dart';
import 'glow_up_job.dart';

enum _NotificationRoute { reminder, glow, checkpoint, export, tip, home }

/// Routes the user to the right screen when a notification is opened.
class NotificationNavigation {
  NotificationNavigation._();

  static void handlePayload(String payload) {
    if (payload == 'glow_up_step') {
      _openGlowUp('glow_up_step');
      return;
    }
    navigateFrom(type: payload);
  }

  static void navigateFrom({
    required String type,
    String title = '',
    String body = '',
    String? procedureId,
    ProcedureRepository? repo,
    BuildContext? context,
    bool popCurrentRoute = false,
  }) {
    void go() => _navigate(
          type: type,
          title: title,
          body: body,
          procedureId: procedureId,
          repo: repo,
        );

    if (popCurrentRoute && context != null && context.mounted) {
      Navigator.of(context).pop();
      SchedulerBinding.instance.addPostFrameCallback((_) => go());
      return;
    }

    go();
  }

  static void _navigate({
    required String type,
    required String title,
    required String body,
    String? procedureId,
    ProcedureRepository? repo,
  }) {
    switch (_routeFor(type: type, title: title, body: body)) {
      case _NotificationRoute.reminder:
        _openReminders(upcoming: true);
      case _NotificationRoute.glow:
        _openGlowUp(type.toLowerCase());
      case _NotificationRoute.checkpoint:
        _switchTab(1);
        if (procedureId != null && repo != null) {
          _push(
            MaterialPageRoute<void>(
              builder: (_) => ProcedureDetailScreen(repo: repo, procedureId: procedureId),
            ),
          );
        }
      case _NotificationRoute.export:
        _switchTab(3);
      case _NotificationRoute.tip:
        _switchTab(2);
      case _NotificationRoute.home:
        _switchTab(0);
    }
  }

  static _NotificationRoute _routeFor({
    required String type,
    required String title,
    required String body,
  }) {
    final t = type.toLowerCase().trim();
    final text = '${title.toLowerCase()} ${body.toLowerCase()}';

    if (_isReminder(t, text)) return _NotificationRoute.reminder;

    if (t.contains('glow') || t.contains('report') || t == 'glow_up_step') {
      return _NotificationRoute.glow;
    }
    if (text.contains('glow-up is ready') ||
        text.contains('glow report') ||
        text.contains('studio portrait is ready') ||
        text.contains('glow-up preview')) {
      return _NotificationRoute.glow;
    }

    if (t.contains('checkpoint')) return _NotificationRoute.checkpoint;
    if (t.contains('export')) return _NotificationRoute.export;
    if (t.contains('tip') || t.contains('ai')) return _NotificationRoute.tip;

    return _NotificationRoute.home;
  }

  static bool _isReminder(String type, String text) {
    if (type.contains('reminder') || type.contains('redo') || type.contains('topup')) {
      return true;
    }
    if (text.contains('glowpass reminder')) return true;
    if (text.contains('is tomorrow') || text.contains('is in one week')) return true;
    return false;
  }

  static void _openReminders({required bool upcoming}) {
    RemindersOpenNavigation.instance.open(upcoming: upcoming);
  }

  static void _openGlowUp(String type) {
    final job = GlowUpJobController.instance;
    final t = type.toLowerCase();

    if (t.contains('report')) {
      if (job.status == GlowUpJobStatus.done) {
        job.openCurrentStep();
        return;
      }
      _switchTab(0);
      _showStaleGlowMessage('Your glow report is no longer available. Start a new glow-up from Home.');
      return;
    }

    if (t.contains('studio')) {
      if (job.status == GlowUpJobStatus.studioReady || job.isRunningStudio) {
        job.openCurrentStep();
        return;
      }
      _switchTab(0);
      _showStaleGlowMessage('Your studio preview expired. Start a new glow-up from Home.');
      return;
    }

    if (job.status != GlowUpJobStatus.idle && job.status != GlowUpJobStatus.error) {
      job.openCurrentStep();
      return;
    }

    _switchTab(0);
  }

  static void _showStaleGlowMessage(String message) {
    appMessengerKey.currentState?.showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  static void _switchTab(int index) {
    AppTabNavigation.instance.switchTo(index);
  }

  static void _push(Route<void> route) {
    appNavigatorKey.currentState?.push(route);
  }
}
