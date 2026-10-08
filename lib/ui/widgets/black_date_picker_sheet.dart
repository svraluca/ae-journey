import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

/// Dark calendar bottom sheet matching GlowPass black modal sheets
/// (photo pick, custom procedure, etc.).
Future<DateTime?> showBlackDatePickerSheet(
  BuildContext context, {
  required DateTime initialDate,
  DateTime? firstDate,
  DateTime? lastDate,
  String title = 'Select date',
  String? subtitle,
}) {
  final first = firstDate ?? DateTime(2000);
  final last = lastDate ?? DateTime.now().add(const Duration(days: 365 * 5));
  var initial = initialDate;
  if (initial.isBefore(first)) initial = first;
  if (initial.isAfter(last)) initial = last;

  return showModalBottomSheet<DateTime>(
    context: context,
    isScrollControlled: true,
    barrierColor: Colors.black.withValues(alpha: 0.50),
    backgroundColor: Colors.transparent,
    builder: (ctx) => _BlackDatePickerSheet(
      initialDate: initial,
      firstDate: first,
      lastDate: last,
      title: title,
      subtitle: subtitle ?? 'When did this procedure happen?',
    ),
  );
}

class _BlackDatePickerSheet extends StatefulWidget {
  const _BlackDatePickerSheet({
    required this.initialDate,
    required this.firstDate,
    required this.lastDate,
    required this.title,
    required this.subtitle,
  });

  final DateTime initialDate;
  final DateTime firstDate;
  final DateTime lastDate;
  final String title;
  final String subtitle;

  @override
  State<_BlackDatePickerSheet> createState() => _BlackDatePickerSheetState();
}

class _BlackDatePickerSheetState extends State<_BlackDatePickerSheet> {
  late DateTime _selected;
  late DateTime _visibleMonth;

  static final _monthFmt = DateFormat('MMMM yyyy');
  static const _weekdays = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];

  @override
  void initState() {
    super.initState();
    _selected = DateTime(widget.initialDate.year, widget.initialDate.month, widget.initialDate.day);
    _visibleMonth = DateTime(_selected.year, _selected.month);
  }

  bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  bool _isSelectable(DateTime d) {
    final day = DateTime(d.year, d.month, d.day);
    final first = DateTime(widget.firstDate.year, widget.firstDate.month, widget.firstDate.day);
    final last = DateTime(widget.lastDate.year, widget.lastDate.month, widget.lastDate.day);
    return !day.isBefore(first) && !day.isAfter(last);
  }

  void _shiftMonth(int delta) {
    final next = DateTime(_visibleMonth.year, _visibleMonth.month + delta);
    final firstMonth = DateTime(widget.firstDate.year, widget.firstDate.month);
    final lastMonth = DateTime(widget.lastDate.year, widget.lastDate.month);
    if (next.isBefore(firstMonth) || next.isAfter(lastMonth)) return;
    setState(() => _visibleMonth = next);
  }

  List<DateTime?> _daysInGrid() {
    final first = DateTime(_visibleMonth.year, _visibleMonth.month, 1);
    // Monday-based week: weekday 1 = Mon … 7 = Sun
    final lead = (first.weekday + 6) % 7;
    final daysInMonth = DateTime(_visibleMonth.year, _visibleMonth.month + 1, 0).day;
    final cells = <DateTime?>[];
    for (var i = 0; i < lead; i++) {
      cells.add(null);
    }
    for (var d = 1; d <= daysInMonth; d++) {
      cells.add(DateTime(_visibleMonth.year, _visibleMonth.month, d));
    }
    while (cells.length % 7 != 0) {
      cells.add(null);
    }
    return cells;
  }

  @override
  Widget build(BuildContext context) {
    final bottomSafe = MediaQuery.paddingOf(context).bottom;
    final sf = GoogleFonts.urbanist();
    final serif = GoogleFonts.dmSerifDisplay();
    final today = DateTime.now();
    final todayDay = DateTime(today.year, today.month, today.day);
    final cells = _daysInGrid();

    final canPrev = DateTime(_visibleMonth.year, _visibleMonth.month)
        .isAfter(DateTime(widget.firstDate.year, widget.firstDate.month));
    final canNext = DateTime(_visibleMonth.year, _visibleMonth.month)
        .isBefore(DateTime(widget.lastDate.year, widget.lastDate.month));

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Container(
        padding: EdgeInsets.fromLTRB(22, 0, 22, 16 + bottomSafe),
        decoration: BoxDecoration(
          color: const Color(0xFF000000),
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(24),
            topRight: Radius.circular(24),
          ),
          border: Border(top: BorderSide(color: Colors.white.withValues(alpha: 0.08))),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 12),
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.22),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.title,
                      style: serif.copyWith(fontSize: 22, color: Colors.white, height: 1.15),
                    ),
                  ),
                  InkWell(
                    onTap: () => Navigator.of(context).pop(),
                    customBorder: const CircleBorder(),
                    child: Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.10),
                        shape: BoxShape.circle,
                      ),
                      alignment: Alignment.center,
                      child: const Icon(Icons.close_rounded, size: 18, color: Colors.white),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 5),
              Text(
                widget.subtitle,
                style: sf.copyWith(fontSize: 13, color: Colors.white.withValues(alpha: 0.65), height: 1.5),
              ),
              const SizedBox(height: 18),
              Container(
                padding: const EdgeInsets.fromLTRB(12, 14, 12, 14),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
                ),
                child: Column(
                  children: [
                    Row(
                      children: [
                        _MonthNavButton(
                          icon: Icons.chevron_left_rounded,
                          enabled: canPrev,
                          onTap: () => _shiftMonth(-1),
                        ),
                        Expanded(
                          child: Text(
                            _monthFmt.format(_visibleMonth),
                            textAlign: TextAlign.center,
                            style: sf.copyWith(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              color: Colors.white.withValues(alpha: 0.92),
                            ),
                          ),
                        ),
                        _MonthNavButton(
                          icon: Icons.chevron_right_rounded,
                          enabled: canNext,
                          onTap: () => _shiftMonth(1),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        for (final w in _weekdays)
                          Expanded(
                            child: Text(
                              w,
                              textAlign: TextAlign.center,
                              style: sf.copyWith(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.06 * 11,
                                color: Colors.white.withValues(alpha: 0.40),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    for (var row = 0; row < cells.length / 7; row++)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Row(
                          children: [
                            for (var col = 0; col < 7; col++)
                              Expanded(
                                child: _DayCell(
                                  date: cells[row * 7 + col],
                                  selected: cells[row * 7 + col] != null &&
                                      _sameDay(cells[row * 7 + col]!, _selected),
                                  isToday: cells[row * 7 + col] != null &&
                                      _sameDay(cells[row * 7 + col]!, todayDay),
                                  enabled: cells[row * 7 + col] != null &&
                                      _isSelectable(cells[row * 7 + col]!),
                                  onTap: (d) => setState(() => _selected = d),
                                ),
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(_selected),
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.white.withValues(alpha: 0.16),
                  foregroundColor: Colors.white,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(vertical: 15),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  textStyle: sf.copyWith(fontSize: 14, fontWeight: FontWeight.w700),
                  side: BorderSide(color: Colors.white.withValues(alpha: 0.16)),
                ),
                child: Text('Confirm · ${DateFormat('d MMM yyyy').format(_selected)}'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MonthNavButton extends StatelessWidget {
  const _MonthNavButton({
    required this.icon,
    required this.enabled,
    required this.onTap,
  });

  final IconData icon;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: enabled ? onTap : null,
      customBorder: const CircleBorder(),
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: enabled ? 0.10 : 0.04),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white.withValues(alpha: enabled ? 0.14 : 0.06)),
        ),
        alignment: Alignment.center,
        child: Icon(
          icon,
          size: 20,
          color: Colors.white.withValues(alpha: enabled ? 0.90 : 0.28),
        ),
      ),
    );
  }
}

class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.date,
    required this.selected,
    required this.isToday,
    required this.enabled,
    required this.onTap,
  });

  final DateTime? date;
  final bool selected;
  final bool isToday;
  final bool enabled;
  final ValueChanged<DateTime> onTap;

  @override
  Widget build(BuildContext context) {
    if (date == null) {
      return const SizedBox(height: 40);
    }

    final sf = GoogleFonts.urbanist();
    Color fg;
    if (!enabled) {
      fg = Colors.white.withValues(alpha: 0.22);
    } else if (selected) {
      fg = Colors.black;
    } else if (isToday) {
      fg = Colors.white;
    } else {
      fg = Colors.white.withValues(alpha: 0.82);
    }

    return SizedBox(
      height: 40,
      child: Center(
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: enabled ? () => onTap(date!) : null,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOutCubic,
              width: 36,
              height: 36,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected
                    ? Colors.white
                    : (isToday ? Colors.white.withValues(alpha: 0.12) : Colors.transparent),
                border: isToday && !selected
                    ? Border.all(color: Colors.white.withValues(alpha: 0.35))
                    : null,
              ),
              child: Text(
                '${date!.day}',
                style: sf.copyWith(
                  fontSize: 13,
                  fontWeight: selected || isToday ? FontWeight.w700 : FontWeight.w600,
                  color: fg,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
