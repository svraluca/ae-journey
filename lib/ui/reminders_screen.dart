import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../data/procedure.dart';
import '../data/procedure_repository.dart';
import '../services/app_navigator.dart';
import 'add_reminder_screen.dart';
import 'delete_procedure_sheet.dart';
import 'procedure_selection_theme.dart';
import 'widgets/procedure_selection_widgets.dart';
import 'widgets/step2_warm_background.dart';

class RemindersScreen extends StatefulWidget {
  const RemindersScreen({super.key, required this.repo});

  final ProcedureRepository repo;

  @override
  State<RemindersScreen> createState() => _RemindersScreenState();
}

class _RemindersScreenState extends State<RemindersScreen> {
  int _tab = 0; // 0 upcoming, 1 done

  static const _reminderTag = 'reminder';
  static const _reminderCompletedTag = 'reminder_completed';

  DateTime _stripTime(DateTime d) => DateTime(d.year, d.month, d.day);

  DateTime _suggestedDate(Procedure p) {
    final manual = p.followUpDate;
    if (manual != null) return _stripTime(manual);
    final redo = p.suggestedRedoAppointmentDate;
    if (redo != null) return _stripTime(redo);
    return _stripTime(p.date.add(const Duration(days: 90)));
  }

  String _initials(String? name) {
    final raw = (name ?? '').trim();
    if (raw.isEmpty) return '—';
    final parts = raw.split(RegExp(r'\s+')).where((e) => e.isNotEmpty).toList();
    final a = parts.isNotEmpty ? parts.first[0] : '';
    final b = parts.length > 1 ? parts.last[0] : '';
    final out = (a + b).toUpperCase();
    return out.isEmpty ? '—' : out;
  }

  String _doctorAvatarInitials(String? practitioner, String? clinic) {
    final c = (clinic ?? '').trim();
    if (c.isNotEmpty && RegExp(r'^Dr\.?\b', caseSensitive: false).hasMatch(c)) {
      return 'DR';
    }
    return _initials(practitioner);
  }

  String _weekdayShort(DateTime d) {
    const wds = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return wds[d.weekday - 1];
  }

  String _monthShort(DateTime d) {
    const mos = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return mos[d.month - 1];
  }

  String _sheetDate(DateTime d) => '${_weekdayShort(d)}, ${d.day} ${_monthShort(d)}';

  String _dueInText(DateTime today, DateTime dueDate) {
    final days = dueDate.difference(today).inDays;
    if (days <= 0) return 'Today';
    if (days == 1) return '1 day';
    return '$days days';
  }

  String _sheetTime(DateTime d) {
    final h = d.hour;
    final m = d.minute;
    if (h == 0 && m == 0) return 'Anytime';
    final hour12 = h % 12 == 0 ? 12 : h % 12;
    final mm = m.toString().padLeft(2, '0');
    final ampm = h >= 12 ? 'PM' : 'AM';
    return '$hour12:$mm $ampm';
  }

  static const _deleteRed = Color(0xFFDD4444);

  void _showSnack(String message) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      appMessengerKey.currentState?.showSnackBar(SnackBar(content: Text(message)));
    });
  }

  @override
  void initState() {
    super.initState();
    RemindersTabNavigation.instance.register((tab) {
      if (!mounted) return;
      setState(() => _tab = tab);
    });
  }

  @override
  void dispose() {
    RemindersTabNavigation.instance.unregister();
    super.dispose();
  }

  Future<void> _markReminderDone(Procedure p) async {
    final tags = [...p.tags];
    tags.remove(_reminderTag);
    if (!tags.contains(_reminderCompletedTag)) {
      tags.add(_reminderCompletedTag);
    }
    // Timeline / passport date = day the user confirmed they had the appointment.
    final completedOn = _stripTime(DateTime.now());
    final completed = p.copyWith(date: completedOn, tags: tags);
    try {
      await widget.repo.upsertDone(completed);
      await widget.repo.deleteReminder(p.id);
      if (!mounted) return;
      setState(() => _tab = 1);
      _showSnack('${p.title} added to your passport');
    } on FirebaseException catch (e) {
      if (!mounted) return;
      final msg = e.code == 'permission-denied'
          ? 'Can’t save yet — check your connection and try again.'
          : 'Couldn’t save (${e.code}).';
      _showSnack(msg);
    } catch (_) {
      if (!mounted) return;
      _showSnack('Couldn’t mark as done. Please try again.');
    }
  }

  Future<void> _snoozeReminder(Procedure p) async {
    final next = _stripTime(DateTime.now()).add(const Duration(days: 7));
    try {
      await widget.repo.upsertReminder(p.copyWith(followUpDate: next));
      if (!mounted) return;
      _showSnack('Reminder moved — we’ll nudge you again in 7 days');
    } on FirebaseException catch (e) {
      if (!mounted) return;
      _showSnack(e.code == 'permission-denied' ? 'Can’t update reminder right now.' : 'Couldn’t update (${e.code}).');
    } catch (_) {
      if (!mounted) return;
      _showSnack('Couldn’t update reminder. Please try again.');
    }
  }

  void _openReminderSheet({required Procedure p, required DateTime dueDate}) {
    final parentContext = context;
    final today = _stripTime(DateTime.now());

    final doctor = (p.practitioner ?? '').trim().isEmpty ? 'Doctor' : p.practitioner!.trim();
    final clinic = (p.clinic ?? '').trim();
    final subtitle = clinic.isEmpty ? '' : clinic;
    final initials = _doctorAvatarInitials(p.practitioner, p.clinic);
    final notes = (p.notes ?? '').trim().isEmpty
        ? 'Add a note for this reminder.'
        : p.notes!.trim();

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      barrierColor: Colors.black.withValues(alpha: 0.45),
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        final bottomInset = MediaQuery.of(sheetContext).viewInsets.bottom;
        final bottomSafe = MediaQuery.of(sheetContext).padding.bottom;

        return Padding(
          padding: EdgeInsets.only(bottom: bottomInset),
          child: Container(
            margin: const EdgeInsets.only(top: 12),
            padding: EdgeInsets.fromLTRB(20, 0, 20, 28 + bottomSafe),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  ProcedureSelectionTheme.pageBackgroundTop,
                  Colors.white,
                ],
              ),
              borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 12),
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: ProcedureSelectionTheme.muted.withValues(alpha: 0.25),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        p.title,
                        style: ProcedureSelectionTypography.display(size: 20, color: ProcedureSelectionTheme.ink),
                      ),
                    ),
                    const SizedBox(width: 12),
                    _RemindersCircleButton(
                      icon: Icons.close_rounded,
                      onTap: () => Navigator.of(sheetContext).pop(),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(child: _SheetMiniStat(label: 'Date', value: _sheetDate(dueDate))),
                    const SizedBox(width: 8),
                    Expanded(child: _SheetMiniStat(label: 'Time', value: _sheetTime(p.date))),
                    const SizedBox(width: 8),
                    Expanded(child: _SheetMiniStat(label: 'Due in', value: _dueInText(today, dueDate))),
                  ],
                ),
                const SizedBox(height: 14),
                ProcedureSelectionPanel(
                  title: doctor,
                  subtitle: subtitle.isEmpty ? null : subtitle,
                  compactTitle: true,
                  child: Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: ProcedureSelectionTheme.buttonPrimary,
                          shape: BoxShape.circle,
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          initials,
                          style: ProcedureSelectionTypography.chip(size: 12, color: Colors.white),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          notes,
                          style: ProcedureSelectionTypography.body(size: 12, color: ProcedureSelectionTheme.muted),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  'Did you have this appointment?',
                  style: ProcedureSelectionTypography.label(size: 12, color: ProcedureSelectionTheme.muted),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: ProcedureSelectionTheme.buttonPrimary,
                          foregroundColor: Colors.white,
                          elevation: 0,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
                        ),
                        onPressed: () {
                          Navigator.of(sheetContext).pop();
                          unawaited(_markReminderDone(p));
                        },
                        icon: const Icon(Icons.check_rounded, size: 18),
                        label: Text(
                          'Yes, I had it',
                          style: ProcedureSelectionTypography.label(size: 14, weight: FontWeight.w700, color: Colors.white),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: ProcedureSelectionTheme.fieldFill,
                          foregroundColor: ProcedureSelectionTheme.ink,
                          elevation: 0,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
                        ),
                        onPressed: () {
                          Navigator.of(sheetContext).pop();
                          unawaited(_snoozeReminder(p));
                        },
                        child: Text(
                          'Not yet',
                          style: ProcedureSelectionTypography.label(size: 14, weight: FontWeight.w600),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      Navigator.of(sheetContext).pop();
                      if (!parentContext.mounted) return;
                      final ok = await showDeleteProcedureSheet(parentContext, procedure: p);
                      if (ok == true && mounted) {
                        await widget.repo.deleteReminder(p.id);
                      }
                    },
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _deleteRed,
                      side: BorderSide(color: _deleteRed.withValues(alpha: 0.28)),
                      backgroundColor: const Color(0xFFFFF5F5),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(vertical: 13),
                    ),
                    icon: const Icon(Icons.delete_outline_rounded, size: 18, color: _deleteRed),
                    label: Text(
                      'Delete reminder',
                      style: ProcedureSelectionTypography.label(size: 13, weight: FontWeight.w700, color: _deleteRed),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  bool _isCompletedReminder(Procedure p) {
    if (p.tags.contains(_reminderCompletedTag)) return true;
    // Legacy rows completed before we tagged them (e.g. laser marked done → timeline only).
    final fu = p.followUpDate;
    if (fu == null) return false;
    final follow = DateTime(fu.year, fu.month, fu.day);
    final proc = DateTime(p.date.year, p.date.month, p.date.day);
    return follow == proc &&
        p.zones.isEmpty &&
        p.beforePhotoPath == null &&
        p.afterPhotoPath == null;
  }

  @override
  Widget build(BuildContext context) {
    RemindersTabNavigation.instance.register((tab) {
      if (!mounted) return;
      setState(() => _tab = tab);
    });

    return ListenableBuilder(
      listenable: widget.repo,
      builder: (context, _) {
        final now = DateTime.now();
        final today = _stripTime(now);
        final items = widget.repo.allReminders().toList();

        final reminders = items
            .map((p) => (p: p, d: _suggestedDate(p)))
            .toList()
          ..sort((a, b) => a.d.compareTo(b.d));

        final upcoming = reminders.where((x) => !x.d.isBefore(today)).toList();
        final done = widget.repo
            .allDone()
            .where(_isCompletedReminder)
            .map((p) => (p: p, d: _stripTime(p.date)))
            .toList()
          ..sort((a, b) => b.d.compareTo(a.d));

        final list = _tab == 0 ? upcoming : done;
        final urgent = upcoming.isNotEmpty ? upcoming.first : null;

        return Stack(
          children: [
            const Step2WarmBackground(),
            Scaffold(
              backgroundColor: Colors.transparent,
              body: SafeArea(
                bottom: false,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 120),
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (Navigator.of(context).canPop()) ...[
                          _RemindersCircleButton(
                            icon: Icons.chevron_left_rounded,
                            onTap: () => Navigator.of(context).maybePop(),
                          ),
                          const SizedBox(width: 10),
                        ],
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              ProcedureSectionLabel(_weekdayDate(now)),
                              const SizedBox(height: 8),
                              Text(
                                'My reminders',
                                style: ProcedureSelectionTypography.display(size: 18, color: ProcedureSelectionTheme.ink),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                'Stay on top of follow-ups and redo appointments.',
                                style: ProcedureSelectionTypography.body(size: 11, color: ProcedureSelectionTheme.muted),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        _RemindersCircleButton(
                          icon: Icons.add_rounded,
                          filled: true,
                          onTap: () async {
                            await Navigator.of(context).push<void>(
                              MaterialPageRoute<void>(
                                builder: (_) => AddReminderScreen(repo: widget.repo),
                              ),
                            );
                            if (mounted) setState(() {});
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    if (urgent != null && _tab == 0) ...[
                      _AlertBanner(
                        date: urgent.d,
                        eyebrow: _urgentEyebrow(today, urgent.d),
                        title: urgent.p.title,
                        subtitle: [
                          (urgent.p.practitioner ?? '').trim(),
                          (urgent.p.clinic ?? '').trim(),
                        ].where((e) => e.isNotEmpty).join(' · '),
                        onOpenDetails: () => _openReminderSheet(p: urgent.p, dueDate: urgent.d),
                        onMarkDone: () => unawaited(_markReminderDone(urgent.p)),
                        onNotYet: () => unawaited(_snoozeReminder(urgent.p)),
                      ),
                      const SizedBox(height: 14),
                    ],
                    ProcedureSelectionPanel(
                      title: 'This week',
                      compactTitle: true,
                      child: _CompactWeek(
                        today: today,
                        eventDays: upcoming.map((e) => e.d).toSet(),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        Expanded(
                          child: _RemindersTab(
                            text: 'Upcoming',
                            active: _tab == 0,
                            onTap: () => setState(() => _tab = 0),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _RemindersTab(
                            text: 'Done',
                            active: _tab == 1,
                            onTap: () => setState(() => _tab = 1),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    if (list.isEmpty)
                      ProcedureSelectionPanel(
                        title: _tab == 0 ? 'No upcoming reminders' : 'No completed reminders',
                        compactTitle: true,
                        child: Text(
                          _tab == 0
                              ? 'Add a reminder to track your next appointment.'
                              : 'Completed reminders will show up here.',
                          style: ProcedureSelectionTypography.body(size: 12, color: ProcedureSelectionTheme.muted),
                        ),
                      )
                    else
                      Column(
                        children: [
                          for (final x in list) ...[
                            _wrapSwipeToDelete(
                              p: x.p,
                              child: _tab == 0
                                  ? _ReminderCard(
                                      date: x.d,
                                      title: x.p.title,
                                      badge: _daysBadge(today, x.d),
                                      meta: [
                                        (x.p.practitioner ?? '').trim(),
                                        (x.p.clinic ?? '').trim(),
                                      ].where((e) => e.isNotEmpty).join(' · '),
                                      initials: _doctorAvatarInitials(x.p.practitioner, x.p.clinic),
                                      docName: (x.p.practitioner ?? '').trim().isEmpty ? 'Doctor' : x.p.practitioner!.trim(),
                                      tag: (x.p.category ?? '').trim().isEmpty ? 'Procedure' : x.p.category!.trim(),
                                      onTap: () => _openReminderSheet(p: x.p, dueDate: x.d),
                                    )
                                  : _DoneCard(
                                      date: x.d,
                                      title: x.p.title,
                                      subtitle: [
                                        (x.p.practitioner ?? '').trim().isEmpty
                                            ? 'Doctor'
                                            : x.p.practitioner!.trim(),
                                        'Completed',
                                      ].join(' · '),
                                    ),
                            ),
                            const SizedBox(height: 10),
                          ],
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  String _weekdayDate(DateTime d) {
    const wd = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    const mo = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${wd[d.weekday - 1]}, ${d.day} ${mo[d.month - 1]}';
  }

  String _daysBadge(DateTime today, DateTime date) {
    final days = date.difference(today).inDays;
    if (days <= 0) return 'Today';
    return '$days days';
  }

  String _urgentEyebrow(DateTime today, DateTime date) {
    final days = date.difference(today).inDays;
    if (days <= 0) return 'Urgent · today';
    if (days == 1) return 'Urgent · 1 day away';
    return 'Urgent · $days days away';
  }

  Widget _wrapSwipeToDelete({required Procedure p, required Widget child}) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(ProcedureSelectionTheme.cardRadius),
      child: Dismissible(
        key: ValueKey<String>('swipe-reminder-${p.id}'),
        direction: DismissDirection.endToStart,
        background: const ColoredBox(color: Colors.transparent),
        secondaryBackground: Container(
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.only(right: 22),
          color: _deleteRed,
          child: Icon(Icons.delete_outline_rounded, color: Colors.white.withValues(alpha: 0.95), size: 26),
        ),
        confirmDismiss: (direction) async {
          if (direction != DismissDirection.endToStart) return false;
          final ok = await showDeleteProcedureSheet(context, procedure: p);
          return ok == true;
        },
        onDismissed: (_) {
          unawaited(widget.repo.deleteReminder(p.id));
        },
        child: child,
      ),
    );
  }
}

class _RemindersCircleButton extends StatelessWidget {
  const _RemindersCircleButton({
    required this.icon,
    required this.onTap,
    this.filled = false,
  });

  final IconData icon;
  final VoidCallback onTap;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    if (filled) {
      return Material(
        color: ProcedureSelectionTheme.buttonPrimary,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: 40,
            height: 40,
            child: Icon(icon, color: Colors.white, size: 20),
          ),
        ),
      );
    }

    return ProcedureGlassSurface(
      borderRadius: BorderRadius.circular(999),
      compact: true,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: onTap,
          child: SizedBox(
            width: 36,
            height: 36,
            child: Icon(icon, size: 18, color: ProcedureSelectionTheme.ink),
          ),
        ),
      ),
    );
  }
}

class _RemindersTab extends StatelessWidget {
  const _RemindersTab({
    required this.text,
    required this.active,
    required this.onTap,
  });

  final String text;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: ProcedureGlassSurface(
          borderRadius: BorderRadius.circular(999),
          selected: active,
          compact: true,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 11),
            child: Center(
              child: Text(
                text,
                style: ProcedureSelectionTypography.chip(
                  size: 12,
                  color: active ? Colors.white : ProcedureSelectionTheme.muted,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AlertBanner extends StatelessWidget {
  const _AlertBanner({
    required this.date,
    required this.eyebrow,
    required this.title,
    required this.subtitle,
    required this.onOpenDetails,
    required this.onMarkDone,
    required this.onNotYet,
  });

  final DateTime date;
  final String eyebrow;
  final String title;
  final String subtitle;
  final VoidCallback onOpenDetails;
  final VoidCallback onMarkDone;
  final VoidCallback onNotYet;

  @override
  Widget build(BuildContext context) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

    return ProcedureGlassSurface(
      borderRadius: BorderRadius.circular(ProcedureSelectionTheme.cardRadius),
      selected: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: onOpenDetails,
                  borderRadius: BorderRadius.circular(12),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(
                          children: [
                            Text(
                              '${date.day}',
                              style: ProcedureSelectionTypography.display(size: 24, color: Colors.white),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              months[date.month - 1].toUpperCase(),
                              style: ProcedureSelectionTypography.label(
                                size: 9,
                                color: Colors.white.withValues(alpha: 0.55),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              eyebrow.toUpperCase(),
                              style: ProcedureSelectionTypography.label(
                                size: 9,
                                color: Colors.white.withValues(alpha: 0.5),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              title,
                              style: ProcedureSelectionTypography.display(size: 14, color: Colors.white),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (subtitle.isNotEmpty) ...[
                              const SizedBox(height: 2),
                              Text(
                                subtitle,
                                style: ProcedureSelectionTypography.body(
                                  size: 11,
                                  color: Colors.white.withValues(alpha: 0.55),
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _UrgentConfirmButton(label: 'Done', icon: Icons.check_rounded, filled: true, onTap: onMarkDone),
                const SizedBox(height: 6),
                _UrgentConfirmButton(label: 'Not yet', icon: Icons.schedule_rounded, filled: false, onTap: onNotYet),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _UrgentConfirmButton extends StatelessWidget {
  const _UrgentConfirmButton({
    required this.label,
    required this.icon,
    required this.filled,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool filled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: filled ? Colors.white : Colors.white.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 14,
                color: filled ? ProcedureSelectionTheme.ink : Colors.white.withValues(alpha: 0.9),
              ),
              const SizedBox(width: 4),
              Text(
                label,
                style: ProcedureSelectionTypography.chip(
                  size: 10,
                  color: filled ? ProcedureSelectionTheme.ink : Colors.white.withValues(alpha: 0.92),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CompactWeek extends StatelessWidget {
  const _CompactWeek({required this.today, required this.eventDays});

  final DateTime today;
  final Set<DateTime> eventDays;

  @override
  Widget build(BuildContext context) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final start = today.subtract(Duration(days: today.weekday - 1));
    final days = List.generate(7, (i) => DateTime(start.year, start.month, start.day + i));
    final label = '${months[today.month - 1]} ${today.year}';

    bool hasEvent(DateTime d) => eventDays.any((e) => e.year == d.year && e.month == d.month && e.day == d.day);

    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: ProcedureSelectionTypography.label(size: 12, color: ProcedureSelectionTheme.ink)),
            Row(
              children: [
                Icon(Icons.chevron_left_rounded, size: 18, color: ProcedureSelectionTheme.muted.withValues(alpha: 0.7)),
                const SizedBox(width: 8),
                Icon(Icons.chevron_right_rounded, size: 18, color: ProcedureSelectionTheme.muted.withValues(alpha: 0.7)),
              ],
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            for (final d in days)
              Expanded(
                child: Column(
                  children: [
                    Text(
                      _wd3(d).toUpperCase(),
                      style: ProcedureSelectionTypography.label(
                        size: 8,
                        color: ProcedureSelectionTheme.sectionLabel,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _isSameDay(d, today)
                            ? ProcedureSelectionTheme.buttonPrimary
                            : hasEvent(d)
                                ? ProcedureSelectionTheme.ink.withValues(alpha: 0.08)
                                : Colors.transparent,
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        '${d.day}',
                        style: ProcedureSelectionTypography.chip(
                          size: 12,
                          color: _isSameDay(d, today)
                              ? Colors.white
                              : hasEvent(d)
                                  ? ProcedureSelectionTheme.ink
                                  : ProcedureSelectionTheme.muted,
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Container(
                      width: 4,
                      height: 4,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: hasEvent(d) && !_isSameDay(d, today)
                            ? ProcedureSelectionTheme.muted
                            : Colors.transparent,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ],
    );
  }

  static String _wd3(DateTime d) => const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][d.weekday - 1];
  static bool _isSameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;
}

class _ReminderCard extends StatelessWidget {
  const _ReminderCard({
    required this.date,
    required this.title,
    required this.badge,
    required this.meta,
    required this.initials,
    required this.docName,
    required this.tag,
    required this.onTap,
  });

  final DateTime date;
  final String title;
  final String badge;
  final String meta;
  final String initials;
  final String docName;
  final String tag;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    const wds = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final month = months[date.month - 1];
    final wd = wds[date.weekday - 1];

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(ProcedureSelectionTheme.cardRadius),
        onTap: onTap,
        child: ProcedureGlassSurface(
          borderRadius: BorderRadius.circular(ProcedureSelectionTheme.cardRadius),
          compact: true,
          child: Row(
            children: [
              SizedBox(
                width: 72,
                child: Center(
                  child: Container(
                    width: 54,
                    padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
                    decoration: BoxDecoration(
                      color: ProcedureSelectionTheme.fieldFill,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Column(
                      children: [
                        Text(
                          month.toUpperCase(),
                          style: ProcedureSelectionTypography.label(
                            size: 8,
                            color: ProcedureSelectionTheme.sectionLabel,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${date.day}',
                          style: ProcedureSelectionTypography.display(size: 22, color: ProcedureSelectionTheme.ink),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          wd.toUpperCase(),
                          style: ProcedureSelectionTypography.label(
                            size: 8,
                            color: ProcedureSelectionTheme.sectionLabel,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 14, 14, 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Text(
                              title,
                              style: ProcedureSelectionTypography.display(size: 13, color: ProcedureSelectionTheme.ink),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                            decoration: BoxDecoration(
                              color: ProcedureSelectionTheme.buttonPrimary,
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              badge,
                              style: ProcedureSelectionTypography.chip(size: 10, color: Colors.white),
                            ),
                          ),
                        ],
                      ),
                      if (meta.isNotEmpty) ...[
                        const SizedBox(height: 5),
                        Text(
                          meta,
                          style: ProcedureSelectionTypography.body(size: 11, color: ProcedureSelectionTheme.muted),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                      const SizedBox(height: 10),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              Container(
                                width: 22,
                                height: 22,
                                decoration: const BoxDecoration(
                                  color: ProcedureSelectionTheme.buttonPrimary,
                                  shape: BoxShape.circle,
                                ),
                                alignment: Alignment.center,
                                child: Text(
                                  initials,
                                  style: ProcedureSelectionTypography.chip(size: 8, color: Colors.white),
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                docName,
                                style: ProcedureSelectionTypography.body(size: 10, color: ProcedureSelectionTheme.muted),
                              ),
                            ],
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: ProcedureSelectionTheme.fieldFill,
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              tag,
                              style: ProcedureSelectionTypography.chip(
                                size: 9,
                                weight: FontWeight.w600,
                                color: ProcedureSelectionTheme.muted,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
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

class _DoneCard extends StatelessWidget {
  const _DoneCard({
    required this.date,
    required this.title,
    required this.subtitle,
  });

  final DateTime date;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final month = months[date.month - 1];

    return Opacity(
      opacity: 0.62,
      child: ProcedureGlassSurface(
        borderRadius: BorderRadius.circular(ProcedureSelectionTheme.cardRadius),
        compact: true,
        child: Row(
          children: [
            SizedBox(
              width: 72,
              child: Center(
                child: Container(
                  width: 54,
                  padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
                  decoration: BoxDecoration(
                    color: ProcedureSelectionTheme.fieldFill,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Column(
                    children: [
                      Text(
                        month.toUpperCase(),
                        style: ProcedureSelectionTypography.label(
                          size: 8,
                          color: ProcedureSelectionTheme.sectionLabel,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${date.day}',
                        style: ProcedureSelectionTypography.display(
                          size: 20,
                          color: ProcedureSelectionTheme.muted,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 14, 14, 14),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: ProcedureSelectionTypography.display(
                              size: 12,
                              color: ProcedureSelectionTheme.muted,
                            ).copyWith(decoration: TextDecoration.lineThrough),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 3),
                          Text(
                            subtitle,
                            style: ProcedureSelectionTypography.body(size: 10, color: ProcedureSelectionTheme.muted),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                      decoration: BoxDecoration(
                        color: ProcedureSelectionTheme.fieldFill,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        '✓ Done',
                        style: ProcedureSelectionTypography.chip(
                          size: 9,
                          weight: FontWeight.w600,
                          color: ProcedureSelectionTheme.muted,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SheetMiniStat extends StatelessWidget {
  const _SheetMiniStat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return ProcedureGlassSurface(
      borderRadius: BorderRadius.circular(14),
      compact: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label.toUpperCase(),
              style: ProcedureSelectionTypography.label(
                size: 9,
                color: ProcedureSelectionTheme.sectionLabel,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              value,
              style: ProcedureSelectionTypography.label(size: 12, color: ProcedureSelectionTheme.ink),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}
