import 'package:add_2_calendar/add_2_calendar.dart';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

/// Adds ÆSTHETIC JOURNEY reminder appointments to the device calendar.
class CalendarSync {
  CalendarSync._();

  /// Opens the native calendar UI so the user can confirm and save the event.
  /// Returns `true` when the platform reports the event was added.
  static Future<bool> addAppointmentEvent({
    required String title,
    required DateTime start,
    String? clinic,
    String? doctor,
    String? category,
  }) async {
    await _ensureCalendarAccess();

    final end = start.add(const Duration(hours: 1));
    final description = <String>[
      if ((doctor ?? '').trim().isNotEmpty) 'Doctor: ${doctor!.trim()}',
      if ((category ?? '').trim().isNotEmpty) 'Type: ${category!.trim()}',
      'Added from ÆSTHETIC JOURNEY',
    ].join('\n');

    final event = Event(
      title: title,
      description: description,
      location: (clinic ?? '').trim().isEmpty ? null : clinic!.trim(),
      startDate: start,
      endDate: end,
      iosParams: const IOSParams(
        reminder: Duration(hours: 1),
      ),
    );

    try {
      final added = await Add2Calendar.addEvent2Cal(event);
      return added;
    } catch (e, st) {
      debugPrint('CalendarSync.addAppointmentEvent failed: $e\n$st');
      return false;
    }
  }

  static Future<void> _ensureCalendarAccess() async {
    if (defaultTargetPlatform != TargetPlatform.iOS) return;

    var status = await Permission.calendarFullAccess.status;
    if (status.isGranted) return;

    status = await Permission.calendarFullAccess.request();
    if (status.isGranted) return;

    await Permission.calendarWriteOnly.request();
  }
}
