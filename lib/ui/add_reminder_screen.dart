import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../data/procedure.dart';
import '../data/procedure_repository.dart';
import '../services/calendar_sync.dart';
import '../services/notifications_store.dart';
import 'formatters.dart';
import 'procedure_selection_theme.dart';
import 'widgets/procedure_selection_widgets.dart';
import 'widgets/step2_warm_background.dart';

/// Full-screen "Add reminder" flow — wizard step 2 warm glass aesthetic.
class AddReminderScreen extends StatefulWidget {
  const AddReminderScreen({super.key, required this.repo});

  final ProcedureRepository repo;

  static const ink = ProcedureSelectionTheme.ink;
  static const accent = ProcedureSelectionTheme.buttonPrimary;

  @override
  State<AddReminderScreen> createState() => _AddReminderScreenState();
}

class _RemCategory {
  const _RemCategory({
    required this.iconAsset,
    required this.shortTitle,
    required this.subtitle,
    required this.categoryValue,
    this.iconScale = 0.88,
  });

  final String iconAsset;
  final String shortTitle;
  final String subtitle;
  final String categoryValue;
  final double iconScale;
}

class _AddReminderScreenState extends State<AddReminderScreen> {
  static const double _procTypeChipW = 76;
  static const double _procTypeChipH = 100;

  late final TextEditingController _titleCtrl;
  late final TextEditingController _clinicCtrl;
  late final TextEditingController _doctorCtrl;
  late final TextEditingController _costCtrl;
  late final TextEditingController _dateCtrl;
  late final TextEditingController _timeCtrl;
  int? _categoryIndex;
  int _redoValue = 3;
  final List<String> _redoUnits = const ['days', 'weeks', 'months', 'years'];
  int? _redoUnitIndex;
  bool _aiSuggestionBusy = false;
  bool _notifyWeekBefore = false;
  bool _notifyDayBefore = false;
  bool _calendarSync = false;

  static const List<_RemCategory> _categories = [
    _RemCategory(iconAsset: 'assets/injection.png', shortTitle: 'Injectables', subtitle: 'Botox, fillers', categoryValue: 'Injectables'),
    _RemCategory(iconAsset: 'assets/microneedelingicon.png', shortTitle: 'Skin', subtitle: 'Peels, facials', categoryValue: 'Skin treatments'),
    _RemCategory(iconAsset: 'assets/co2laser.png', shortTitle: 'Laser', subtitle: 'CO2, IPL, HIFU', categoryValue: 'Laser', iconScale: 1.3),
    _RemCategory(iconAsset: 'assets/hifu.png', shortTitle: 'Hair removal', subtitle: 'Laser, IPL', categoryValue: 'Hair removal', iconScale: 1.3),
    _RemCategory(iconAsset: 'assets/knifeicon.png', shortTitle: 'Surgery', subtitle: 'Rhinoplasty', categoryValue: 'Surgery', iconScale: 1.35),
    _RemCategory(iconAsset: 'assets/bodyicon.png', shortTitle: 'Body', subtitle: 'HIFU, massage', categoryValue: 'Body treatments', iconScale: 1.35),
    _RemCategory(iconAsset: 'assets/staricon.png', shortTitle: 'Other', subtitle: 'Custom', categoryValue: 'Other'),
  ];

  @override
  void initState() {
    super.initState();
    _titleCtrl = TextEditingController(text: '');
    _clinicCtrl = TextEditingController();
    _doctorCtrl = TextEditingController();
    _costCtrl = TextEditingController();
    _dateCtrl = TextEditingController();
    _timeCtrl = TextEditingController();
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _clinicCtrl.dispose();
    _doctorCtrl.dispose();
    _costCtrl.dispose();
    _dateCtrl.dispose();
    _timeCtrl.dispose();
    super.dispose();
  }

  static DateTime? _parseDdMmYyyy(String raw) {
    final compact = raw.replaceAll(RegExp(r'\s+'), '');
    final m = RegExp(r'^(\d{1,2})[/-](\d{1,2})[/-](\d{4})$').firstMatch(compact);
    if (m == null) return null;
    final dd = int.tryParse(m.group(1)!);
    final mm = int.tryParse(m.group(2)!);
    final yy = int.tryParse(m.group(3)!);
    if (dd == null || mm == null || yy == null) return null;
    if (mm < 1 || mm > 12 || dd < 1 || dd > 31) return null;
    try {
      return DateTime(yy, mm, dd);
    } catch (_) {
      return null;
    }
  }

  static TimeOfDay? _parseTime24(String raw) {
    final compact = raw.replaceAll(RegExp(r'\s+'), '');
    if (compact.isEmpty) return null;
    final m = RegExp(r'^(\d{1,2}):(\d{1,2})$').firstMatch(compact);
    if (m == null) return null;
    final h = int.tryParse(m.group(1)!);
    final min = int.tryParse(m.group(2)!);
    if (h == null || min == null) return null;
    if (h < 0 || h > 23 || min < 0 || min > 59) return null;
    return TimeOfDay(hour: h, minute: min);
  }

  (int value, int unitIndex) _heuristicRedoSuggestion() {
    final t = _titleCtrl.text.toLowerCase();
    final cat = _categoryIndex == null ? '' : _categories[_categoryIndex!].categoryValue.toLowerCase();
    final c = cat;
    if (t.contains('botox') || t.contains('anti-wrinkle') || t.contains('dysport') || t.contains('xeomin')) {
      return (4, 2);
    }
    if (t.contains('profhilo') || t.contains('skin booster')) {
      return (6, 2);
    }
    if (t.contains('filler') || t.contains('juvederm') || t.contains('restylane')) {
      return (12, 2);
    }
    if (t.contains('hair') || t.contains('wax') || c.contains('hair removal')) {
      return (6, 1);
    }
    if (t.contains('co2') || t.contains('fraxel') || t.contains('ipl') || t.contains('laser') || c == 'laser') {
      return (8, 1);
    }
    if (t.contains('peel') || t.contains('facial') || t.contains('microneedling') || c.contains('skin')) {
      return (6, 1);
    }
    if (c.contains('surgery')) {
      return (12, 2);
    }
    if (c.contains('body')) {
      return (4, 1);
    }
    return (3, 1);
  }

  Future<void> _generateRedoWithAi() async {
    if (_aiSuggestionBusy) return;
    FocusScope.of(context).unfocus();
    setState(() => _aiSuggestionBusy = true);
    await Future<void>.delayed(const Duration(milliseconds: 520));
    if (!mounted) return;
    final s = _heuristicRedoSuggestion();
    setState(() {
      _aiSuggestionBusy = false;
      _redoValue = s.$1.clamp(1, 999);
      _redoUnitIndex = s.$2.clamp(0, _redoUnits.length - 1);
    });
    final unitLabel = _redoUnits[_redoUnitIndex!];
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('AI suggested $_redoValue $unitLabel — adjust if needed')),
    );
  }

  num? _parseCost(String value) {
    final cleaned = value.trim().replaceAll(',', '.');
    if (cleaned.isEmpty) return null;
    return num.tryParse(cleaned);
  }

  Future<void> _saveReminder() async {
    final title = _titleCtrl.text.trim();
    if (title.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Add a procedure name')));
      return;
    }
    if (_categoryIndex == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Choose a procedure type')));
      return;
    }
    final day = _parseDdMmYyyy(_dateCtrl.text);
    if (day == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Enter date as DD / MM / YYYY')));
      return;
    }
    final t = _parseTime24(_timeCtrl.text);
    if (t == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Enter time as HH : MM')));
      return;
    }
    final dt = DateTime(day.year, day.month, day.day, t.hour, t.minute);
    final fu = DateTime(day.year, day.month, day.day);
    final cost = _parseCost(_costCtrl.text);

    try {
      await widget.repo.upsertReminder(
        Procedure(
          title: title,
          date: dt,
          category: _categories[_categoryIndex!].categoryValue,
          clinic: _clinicCtrl.text.trim().isEmpty ? null : _clinicCtrl.text.trim(),
          practitioner: _doctorCtrl.text.trim().isEmpty ? null : _doctorCtrl.text.trim(),
          cost: cost,
          redoAfterValue: _redoUnitIndex == null ? null : _redoValue,
          redoAfterUnit: _redoUnitIndex == null ? null : _redoUnits[_redoUnitIndex!],
          followUpDate: fu,
          zones: const [],
          tags: const ['reminder'],
        ),
      );

      if (_notifyWeekBefore) {
        final at = day.subtract(const Duration(days: 7));
        if (at.isAfter(DateTime.now())) {
          await NotificationsStore.schedulePush(
            title: 'ÆSTHETIC JOURNEY reminder',
            body: '$title is in one week (${formatDate(day)})',
            deliverAt: DateTime(at.year, at.month, at.day, 9),
          );
        }
      }
      if (_notifyDayBefore) {
        final at = day.subtract(const Duration(days: 1));
        if (at.isAfter(DateTime.now())) {
          await NotificationsStore.schedulePush(
            title: 'ÆSTHETIC JOURNEY reminder',
            body: '$title is tomorrow',
            deliverAt: DateTime(at.year, at.month, at.day, 9),
          );
        }
      }

      if (_calendarSync) {
        final added = await CalendarSync.addAppointmentEvent(
          title: title,
          start: dt,
          clinic: _clinicCtrl.text.trim(),
          doctor: _doctorCtrl.text.trim(),
          category: _categories[_categoryIndex!].categoryValue,
        );
        if (!mounted) return;
        if (!added) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Reminder saved — calendar event was not added')),
          );
          Navigator.of(context).pop();
          return;
        }
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_calendarSync ? 'Reminder saved and added to calendar' : 'Reminder saved'),
        ),
      );
      Navigator.of(context).pop();
    } on FirebaseException catch (e) {
      if (!mounted) return;
      final msg = e.code == 'permission-denied'
          ? 'Can’t save yet: Firestore rules deny writes. Deploy the rules for `users/{uid}/procedure_reminder`.'
          : 'Couldn’t save (${e.code}).';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Couldn’t save. Please try again.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final parsedDay = _parseDdMmYyyy(_dateCtrl.text);
    final notifWeek = parsedDay?.subtract(const Duration(days: 7));
    final notifDay = parsedDay?.subtract(const Duration(days: 1));
    final bottomPad = MediaQuery.paddingOf(context).bottom;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          const Step2WarmBackground(),
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Row(
                    children: [
                      _GlassCircleButton(
                        icon: Icons.close_rounded,
                        onTap: () => Navigator.of(context).pop(),
                      ),
                      Expanded(
                        child: Text(
                          'Add reminder',
                          textAlign: TextAlign.center,
                          style: ProcedureSelectionTypography.display(size: 16, weight: FontWeight.w700),
                        ),
                      ),
                      FilledButton(
                        onPressed: _saveReminder,
                        style: FilledButton.styleFrom(
                          backgroundColor: ProcedureSelectionTheme.buttonPrimary,
                          foregroundColor: Colors.white,
                          elevation: 0,
                          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
                        ),
                        child: Text(
                          'Save',
                          style: ProcedureSelectionTypography.chip(size: 12, color: Colors.white),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
                  children: [
                    ProcedureSelectionPanel(
                      title: 'Procedure name',
                      subtitle: 'e.g. Botox, Profhilo, CO2 Laser, Hair removal',
                      compactTitle: true,
                      child: TextField(
                        controller: _titleCtrl,
                        onChanged: (_) => setState(() {}),
                        textCapitalization: TextCapitalization.words,
                        cursorColor: ProcedureSelectionTheme.ink,
                        style: ProcedureSelectionTypography.label(size: 15, weight: FontWeight.w600, color: ProcedureSelectionTheme.ink),
                        decoration: InputDecoration(
                          hintText: 'What are you booking?',
                          hintStyle: ProcedureSelectionTypography.body(
                            size: 14,
                            color: ProcedureSelectionTheme.muted.withValues(alpha: 0.55),
                          ),
                          filled: true,
                          fillColor: ProcedureSelectionTheme.fieldFillLight,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(color: ProcedureSelectionTheme.cardBorder),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(color: ProcedureSelectionTheme.ink.withValues(alpha: 0.2)),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    ProcedureSectionLabel('Procedure type'),
                    const SizedBox(height: 10),
                    SizedBox(
                      height: _procTypeChipH,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: _categories.length,
                        separatorBuilder: (_, index) => const SizedBox(width: 8),
                        itemBuilder: (context, i) {
                          final c = _categories[i];
                          final on = _categoryIndex == i;
                          return _CategoryChip(
                            width: _procTypeChipW,
                            height: _procTypeChipH,
                            iconAsset: c.iconAsset,
                            iconScale: c.iconScale,
                            title: c.shortTitle,
                            subtitle: c.subtitle,
                            selected: on,
                            onTap: () => setState(() {
                              _categoryIndex = _categoryIndex == i ? null : i;
                            }),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 12),
                    ProcedureSelectionPanel(
                      title: 'Clinic & doctor',
                      compactTitle: true,
                      child: Column(
                        children: [
                          _WarmReminderField(
                            controller: _clinicCtrl,
                            label: 'Clinic',
                            hint: 'Add clinic name',
                            icon: Icons.business_outlined,
                          ),
                          const SizedBox(height: 10),
                          _WarmReminderField(
                            controller: _doctorCtrl,
                            label: 'Doctor',
                            hint: 'Add doctor name',
                            icon: Icons.person_outline_rounded,
                          ),
                          const SizedBox(height: 10),
                          _WarmReminderField(
                            controller: _costCtrl,
                            label: 'Cost',
                            hint: 'Add cost',
                            icon: Icons.sell_outlined,
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    ProcedureSelectionPanel(
                      title: 'When',
                      compactTitle: true,
                      child: Column(
                        children: [
                          _DateTimeField(
                            label: 'Date',
                            hint: 'DD / MM / YYYY',
                            controller: _dateCtrl,
                            icon: Icons.calendar_today_outlined,
                            onChanged: () => setState(() {}),
                          ),
                          const SizedBox(height: 12),
                          _DateTimeField(
                            label: 'Time',
                            hint: 'HH : MM',
                            controller: _timeCtrl,
                            icon: Icons.access_time_rounded,
                            helper: '24h format (leave blank → 09:00)',
                            onChanged: () => setState(() {}),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    ProcedureSelectionPanel(
                      title: 'Redo after (optional)',
                      subtitle: 'When should we remind you to rebook?',
                      compactTitle: true,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: double.infinity,
                            child: OutlinedButton.icon(
                              onPressed: _aiSuggestionBusy ? null : _generateRedoWithAi,
                              style: OutlinedButton.styleFrom(
                                foregroundColor: ProcedureSelectionTheme.ink,
                                side: BorderSide(color: ProcedureSelectionTheme.ink.withValues(alpha: 0.2)),
                                padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
                                backgroundColor: ProcedureSelectionTheme.fieldFillLight,
                              ),
                              icon: _aiSuggestionBusy
                                  ? SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: ProcedureSelectionTheme.ink.withValues(alpha: 0.7),
                                      ),
                                    )
                                  : Icon(Icons.auto_awesome_rounded, size: 16, color: ProcedureSelectionTheme.ink),
                              label: Text(
                                _aiSuggestionBusy ? 'Generating…' : 'Generate with AI',
                                style: ProcedureSelectionTypography.label(size: 12, weight: FontWeight.w700),
                              ),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Suggests timing from procedure name & type — review before saving',
                            style: ProcedureSelectionTypography.body(size: 10, color: ProcedureSelectionTheme.muted),
                          ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: List.generate(4, (i) {
                              final labels = ['Days', 'Weeks', 'Months', 'Years'];
                              final on = _redoUnitIndex == i;
                              return _UnitChip(
                                label: labels[i],
                                selected: on,
                                onTap: () => setState(() {
                                  _redoUnitIndex = _redoUnitIndex == i ? null : i;
                                }),
                              );
                            }),
                          ),
                          const SizedBox(height: 12),
                          ProcedureStepperControl(
                            label: 'In',
                            value: '$_redoValue',
                            onWarmBackground: true,
                            onDecrement: () {
                              if (_redoUnitIndex == null) return;
                              setState(() => _redoValue = _redoValue > 1 ? _redoValue - 1 : 1);
                            },
                            onIncrement: () {
                              if (_redoUnitIndex == null) return;
                              setState(() => _redoValue = (_redoValue + 1).clamp(1, 999));
                            },
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    ProcedureSelectionPanel(
                      title: 'Notifications',
                      compactTitle: true,
                      child: Column(
                        children: [
                          _NotifRow(
                            title: 'Remind me 1 week before',
                            subtitle: _notifyWeekBefore
                                ? 'Push notification · ${notifWeek != null ? formatDate(notifWeek) : 'Enter a valid date'}'
                                : 'Off',
                            on: _notifyWeekBefore,
                            onChanged: (v) => setState(() => _notifyWeekBefore = v),
                          ),
                          const SizedBox(height: 8),
                          _NotifRow(
                            title: 'Remind me 1 day before',
                            subtitle: _notifyDayBefore
                                ? 'Push notification · ${notifDay != null ? formatDate(notifDay) : 'Enter a valid date'}'
                                : 'Off',
                            on: _notifyDayBefore,
                            onChanged: (v) => setState(() => _notifyDayBefore = v),
                          ),
                          const SizedBox(height: 8),
                          _NotifRow(
                            icon: Icons.calendar_month_outlined,
                            title: 'Add to calendar',
                            subtitle: 'Sync with Apple / Google Calendar',
                            on: _calendarSync,
                            onChanged: (v) => setState(() => _calendarSync = v),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(height: 88 + bottomPad),
                  ],
                ),
              ),
              Container(
                padding: EdgeInsets.fromLTRB(20, 12, 20, 12 + bottomPad),
                decoration: BoxDecoration(
                  color: ProcedureSelectionTheme.pageBackground.withValues(alpha: 0.92),
                  border: Border(
                    top: BorderSide(color: ProcedureSelectionTheme.ink.withValues(alpha: 0.06)),
                  ),
                ),
                child: FilledButton.icon(
                  onPressed: _saveReminder,
                  icon: const Icon(Icons.check_rounded, size: 18),
                  label: Text(
                    'Save reminder',
                    style: ProcedureSelectionTypography.label(size: 14, weight: FontWeight.w700, color: Colors.white),
                  ),
                  style: FilledButton.styleFrom(
                    backgroundColor: ProcedureSelectionTheme.buttonPrimary,
                    foregroundColor: Colors.white,
                    minimumSize: const Size(double.infinity, 52),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _GlassCircleButton extends StatelessWidget {
  const _GlassCircleButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ProcedureGlassSurface(
      borderRadius: BorderRadius.circular(999),
      compact: true,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: onTap,
          child: SizedBox(
            width: 38,
            height: 38,
            child: Icon(icon, size: 18, color: ProcedureSelectionTheme.ink),
          ),
        ),
      ),
    );
  }
}

class _CategoryChip extends StatelessWidget {
  const _CategoryChip({
    required this.width,
    required this.height,
    required this.iconAsset,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
    this.iconScale = 0.88,
  });

  final double width;
  final double height;
  final String iconAsset;
  final double iconScale;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: ProcedureGlassSurface(
          borderRadius: BorderRadius.circular(14),
          selected: selected,
          compact: true,
          child: SizedBox(
            width: width,
            height: height,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ProcedureCategoryIconBadge(
                    iconAsset: iconAsset,
                    selected: selected,
                    size: 32,
                    iconScale: iconScale,
                  ),
                  const SizedBox(height: 5),
                  Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: ProcedureSelectionTypography.chip(
                      size: 9,
                      color: selected ? Colors.white : ProcedureSelectionTheme.ink,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: ProcedureSelectionTypography.body(
                      size: 8,
                      color: selected ? Colors.white.withValues(alpha: 0.65) : ProcedureSelectionTheme.muted,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _WarmReminderField extends StatelessWidget {
  const _WarmReminderField({
    required this.controller,
    required this.label,
    required this.hint,
    required this.icon,
    this.keyboardType,
  });

  final TextEditingController controller;
  final String label;
  final String hint;
  final IconData icon;
  final TextInputType? keyboardType;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label.toUpperCase(),
          style: ProcedureSelectionTypography.label(
            size: 9,
            color: ProcedureSelectionTheme.sectionLabel,
          ),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          keyboardType: keyboardType,
          textCapitalization: keyboardType == null ? TextCapitalization.words : TextCapitalization.none,
          cursorColor: ProcedureSelectionTheme.ink,
          style: ProcedureSelectionTypography.label(size: 13, weight: FontWeight.w600),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: ProcedureSelectionTypography.body(size: 13, color: ProcedureSelectionTheme.muted),
            filled: true,
            fillColor: ProcedureSelectionTheme.fieldFillLight,
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: ProcedureSelectionTheme.cardBorder),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: ProcedureSelectionTheme.ink.withValues(alpha: 0.18)),
            ),
          prefixIcon: Padding(
            padding: const EdgeInsets.only(left: 10, right: 4),
            child: ProcedureFieldIconTray(icon: icon, size: 30),
          ),
          prefixIconConstraints: const BoxConstraints(minWidth: 44, minHeight: 0),
          ),
        ),
      ],
    );
  }
}

class _DateTimeField extends StatelessWidget {
  const _DateTimeField({
    required this.label,
    required this.hint,
    required this.controller,
    required this.icon,
    required this.onChanged,
    this.helper,
  });

  final String label;
  final String hint;
  final TextEditingController controller;
  final IconData icon;
  final VoidCallback onChanged;
  final String? helper;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ProcedureFieldIconTray(icon: icon),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label.toUpperCase(),
                style: ProcedureSelectionTypography.label(size: 9, color: ProcedureSelectionTheme.sectionLabel),
              ),
              const SizedBox(height: 4),
              TextField(
                controller: controller,
                onChanged: (_) => onChanged(),
                cursorColor: ProcedureSelectionTheme.ink,
                keyboardType: TextInputType.datetime,
                style: ProcedureSelectionTypography.label(size: 15, weight: FontWeight.w600, color: ProcedureSelectionTheme.ink),
                decoration: InputDecoration(
                  hintText: hint,
                  hintStyle: ProcedureSelectionTypography.body(
                    size: 14,
                    color: ProcedureSelectionTheme.muted.withValues(alpha: 0.5),
                  ),
                  isDense: true,
                  contentPadding: const EdgeInsets.only(bottom: 6),
                  border: UnderlineInputBorder(
                    borderSide: BorderSide(color: ProcedureSelectionTheme.ink.withValues(alpha: 0.12)),
                  ),
                  enabledBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: ProcedureSelectionTheme.ink.withValues(alpha: 0.12)),
                  ),
                  focusedBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: ProcedureSelectionTheme.ink.withValues(alpha: 0.35)),
                  ),
                ),
              ),
              if (helper != null) ...[
                const SizedBox(height: 2),
                Text(helper!, style: ProcedureSelectionTypography.body(size: 9, color: ProcedureSelectionTheme.muted)),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _UnitChip extends StatelessWidget {
  const _UnitChip({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
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
          selected: selected,
          compact: true,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Text(
              label,
              style: ProcedureSelectionTypography.chip(
                size: 11,
                color: selected ? Colors.white : ProcedureSelectionTheme.muted,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _WarmPillSwitch extends StatelessWidget {
  const _WarmPillSwitch({required this.on, required this.onChanged});

  final bool on;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => onChanged(!on),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 44,
        height: 26,
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: on ? ProcedureSelectionTheme.buttonPrimary : ProcedureSelectionTheme.muted.withValues(alpha: 0.25),
          borderRadius: BorderRadius.circular(13),
        ),
        child: Align(
          alignment: on ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            width: 20,
            height: 20,
            decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
          ),
        ),
      ),
    );
  }
}

class _NotifRow extends StatelessWidget {
  const _NotifRow({
    required this.title,
    required this.subtitle,
    required this.on,
    required this.onChanged,
    this.icon = Icons.notifications_outlined,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool on;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => onChanged(!on),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              ProcedureFieldIconTray(icon: icon, size: 32),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: ProcedureSelectionTypography.label(size: 12, weight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(subtitle, style: ProcedureSelectionTypography.body(size: 10, color: ProcedureSelectionTheme.muted)),
                  ],
                ),
              ),
              _WarmPillSwitch(on: on, onChanged: onChanged),
            ],
          ),
        ),
      ),
    );
  }
}
