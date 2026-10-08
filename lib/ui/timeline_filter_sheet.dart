import 'package:flutter/material.dart';

import '../data/procedure.dart';
import 'formatters.dart';
import 'procedure_selection_theme.dart';
import 'timeline_theme.dart';

/// Unique procedure titles the user has saved, sorted A–Z (case-insensitive).
List<String> timelineSavedProcedureTypes(List<Procedure> procedures) {
  final seen = <String>{};
  final result = <String>[];
  for (final p in procedures) {
    final title = p.title.trim();
    if (title.isEmpty) continue;
    final key = title.toLowerCase();
    if (seen.add(key)) result.add(title);
  }
  result.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return result;
}

bool _titleMatches(String a, String b) => a.trim().toLowerCase() == b.trim().toLowerCase();

const kTimelinePriceFilterStops = <double>[
  50,
  100,
  200,
  300,
  400,
  500,
  600,
  700,
  800,
  900,
  1000,
  1500,
  2000,
  2500,
  3000,
  3500,
  4000,
  4500,
  5000,
  5500,
  6000,
  6500,
  7000,
  7500,
  8000,
  8500,
  9000,
];

double get kTimelinePriceFilterMin => kTimelinePriceFilterStops.first;

double get kTimelinePriceFilterMax => kTimelinePriceFilterStops.last;

int _priceStopIndex(double price) {
  var bestIndex = 0;
  var bestDistance = double.infinity;
  for (var i = 0; i < kTimelinePriceFilterStops.length; i++) {
    final distance = (kTimelinePriceFilterStops[i] - price).abs();
    if (distance < bestDistance) {
      bestDistance = distance;
      bestIndex = i;
    }
  }
  return bestIndex;
}

double _priceAtStopIndex(int index) {
  return kTimelinePriceFilterStops[index.clamp(0, kTimelinePriceFilterStops.length - 1)];
}

class TimelineFilterCriteria {
  const TimelineFilterCriteria({
    this.procedureTitle,
    this.priceMin,
    this.priceMax,
  });

  /// `null` = all procedure types.
  final String? procedureTitle;
  final double? priceMin;
  final double? priceMax;

  bool get isActive => procedureTitle != null || priceMin != null || priceMax != null;

  bool matches(Procedure p) {
    if (procedureTitle != null && !_titleMatches(p.title, procedureTitle!)) {
      return false;
    }
    if (priceMin != null || priceMax != null) {
      final cost = p.cost;
      if (cost == null) return false;
      if (priceMin != null && cost < priceMin!) return false;
      if (priceMax != null && cost > priceMax!) return false;
    }
    return true;
  }

  TimelineFilterCriteria copyWith({
    String? procedureTitle,
    double? priceMin,
    double? priceMax,
    bool clearProcedureTitle = false,
    bool clearPriceMin = false,
    bool clearPriceMax = false,
  }) {
    return TimelineFilterCriteria(
      procedureTitle: clearProcedureTitle ? null : (procedureTitle ?? this.procedureTitle),
      priceMin: clearPriceMin ? null : (priceMin ?? this.priceMin),
      priceMax: clearPriceMax ? null : (priceMax ?? this.priceMax),
    );
  }

  static const empty = TimelineFilterCriteria();
}

TimelineFilterCriteria effectiveTimelineFilterCriteria(
  TimelineFilterCriteria criteria,
  List<String> savedTypes,
) {
  final title = criteria.procedureTitle;
  if (title == null) return criteria;
  if (savedTypes.any((t) => _titleMatches(t, title))) return criteria;
  return criteria.copyWith(clearProcedureTitle: true);
}

Future<TimelineFilterCriteria?> showTimelineFilterSheet(
  BuildContext context, {
  required TimelineFilterCriteria initial,
  required List<String> procedureTypes,
  required String currency,
}) {
  return showModalBottomSheet<TimelineFilterCriteria>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.45),
    builder: (sheetContext) => _TimelineFilterSheet(
      initial: initial,
      procedureTypes: procedureTypes,
      currency: currency,
    ),
  );
}

class _TimelineFilterSheet extends StatefulWidget {
  const _TimelineFilterSheet({
    required this.initial,
    required this.procedureTypes,
    required this.currency,
  });

  final TimelineFilterCriteria initial;
  final List<String> procedureTypes;
  final String currency;

  @override
  State<_TimelineFilterSheet> createState() => _TimelineFilterSheetState();
}

class _TimelineFilterSheetState extends State<_TimelineFilterSheet> {
  String? _selectedTitle;
  int _minStopIndex = 0;
  int _maxStopIndex = kTimelinePriceFilterStops.length - 1;

  final GlobalKey<_ProcedureTypeChipsSectionState> _chipsKey = GlobalKey();
  final GlobalKey<_TimelinePriceRangeControlState> _priceKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    final effective = effectiveTimelineFilterCriteria(widget.initial, widget.procedureTypes);
    _selectedTitle = effective.procedureTitle;
    _minStopIndex = _priceStopIndex(effective.priceMin ?? kTimelinePriceFilterMin);
    _maxStopIndex = effective.priceMax == null
        ? kTimelinePriceFilterStops.length - 1
        : _priceStopIndex(effective.priceMax!);
    if (_minStopIndex > _maxStopIndex) {
      _minStopIndex = 0;
      _maxStopIndex = kTimelinePriceFilterStops.length - 1;
    }
  }

  TimelineFilterCriteria _buildResult() {
    final min = _minStopIndex == 0 ? null : _priceAtStopIndex(_minStopIndex);
    final max = _maxStopIndex == kTimelinePriceFilterStops.length - 1
        ? null
        : _priceAtStopIndex(_maxStopIndex);
    if (min == null && max == null && _selectedTitle == null) {
      return TimelineFilterCriteria.empty;
    }
    return TimelineFilterCriteria(
      procedureTitle: _selectedTitle,
      priceMin: min,
      priceMax: max,
    );
  }

  void _resetFilters() {
    _selectedTitle = null;
    _minStopIndex = 0;
    _maxStopIndex = kTimelinePriceFilterStops.length - 1;
    _chipsKey.currentState?.reset();
    _priceKey.currentState?.reset();
  }

  @override
  Widget build(BuildContext context) {
    final bottomPad = MediaQuery.paddingOf(context).bottom;

    return Align(
      alignment: Alignment.bottomCenter,
      child: Container(
        width: double.infinity,
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
        decoration: const BoxDecoration(
          color: TimelineTheme.card,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: EdgeInsets.fromLTRB(20, 12, 20, 16 + bottomPad),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: TimelineTheme.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Text(
                  'Filters',
                  style: ProcedureSelectionTypography.display(size: 20, color: TimelineTheme.ink),
                ),
                const Spacer(),
                TextButton(
                  onPressed: _resetFilters,
                  child: Text(
                    'Reset',
                    style: ProcedureSelectionTypography.label(
                      size: 13,
                      weight: FontWeight.w600,
                      color: TimelineTheme.muted,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Material(
                  color: TimelineTheme.fill,
                  shape: const CircleBorder(),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () => Navigator.of(context).pop(),
                    child: const SizedBox(
                      width: 36,
                      height: 36,
                      child: Icon(
                        Icons.close_rounded,
                        size: 18,
                        color: TimelineTheme.ink,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Text(
              'Procedure type',
              style: ProcedureSelectionTypography.label(size: 12, weight: FontWeight.w700, color: TimelineTheme.ink),
            ),
            const SizedBox(height: 10),
            if (widget.procedureTypes.isEmpty)
              Text(
                'No saved procedures yet.',
                style: ProcedureSelectionTypography.body(size: 12, color: TimelineTheme.mutedLight),
              )
            else
              RepaintBoundary(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 148),
                  child: _ProcedureTypeChipsSection(
                    key: _chipsKey,
                    procedureTypes: widget.procedureTypes,
                    initialTitle: _selectedTitle,
                    onSelected: (title) => _selectedTitle = title,
                  ),
                ),
              ),
            const SizedBox(height: 24),
            RepaintBoundary(
              child: _TimelinePriceRangeControl(
                key: _priceKey,
                initialMinIndex: _minStopIndex,
                initialMaxIndex: _maxStopIndex,
                currency: widget.currency,
                onChanged: (minIndex, maxIndex) {
                  _minStopIndex = minIndex;
                  _maxStopIndex = maxIndex;
                },
              ),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () => Navigator.pop(context, _buildResult()),
                style: FilledButton.styleFrom(
                  backgroundColor: TimelineTheme.ink,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 15),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
                ),
                child: Text(
                  'Apply filters',
                  style: ProcedureSelectionTypography.label(size: 14, weight: FontWeight.w700, color: Colors.white),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProcedureTypeChipsSection extends StatefulWidget {
  const _ProcedureTypeChipsSection({
    super.key,
    required this.procedureTypes,
    required this.initialTitle,
    required this.onSelected,
  });

  final List<String> procedureTypes;
  final String? initialTitle;
  final ValueChanged<String?> onSelected;

  @override
  State<_ProcedureTypeChipsSection> createState() => _ProcedureTypeChipsSectionState();
}

class _ProcedureTypeChipsSectionState extends State<_ProcedureTypeChipsSection> {
  late String? _selectedTitle;

  @override
  void initState() {
    super.initState();
    _selectedTitle = widget.initialTitle;
  }

  void reset() {
    setState(() => _selectedTitle = null);
    widget.onSelected(null);
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _SheetFilterChip(
            text: 'All',
            active: _selectedTitle == null,
            onTap: () {
              setState(() => _selectedTitle = null);
              widget.onSelected(null);
            },
          ),
          for (final title in widget.procedureTypes)
            _SheetFilterChip(
              text: title,
              active: _selectedTitle != null && _titleMatches(_selectedTitle!, title),
              onTap: () {
                setState(() => _selectedTitle = title);
                widget.onSelected(title);
              },
            ),
        ],
      ),
    );
  }
}

class _TimelinePriceRangeControl extends StatefulWidget {
  const _TimelinePriceRangeControl({
    super.key,
    required this.initialMinIndex,
    required this.initialMaxIndex,
    required this.currency,
    required this.onChanged,
  });

  final int initialMinIndex;
  final int initialMaxIndex;
  final String currency;
  final void Function(int minIndex, int maxIndex) onChanged;

  @override
  State<_TimelinePriceRangeControl> createState() => _TimelinePriceRangeControlState();
}

class _TimelinePriceRangeControlState extends State<_TimelinePriceRangeControl> {
  late int _minStopIndex;
  late int _maxStopIndex;
  late String _openMaxSuffix;

  @override
  void initState() {
    super.initState();
    _minStopIndex = widget.initialMinIndex;
    _maxStopIndex = widget.initialMaxIndex;
    _openMaxSuffix = _currencyOpenMaxSuffix(widget.currency);
  }

  void reset() {
    setState(() {
      _minStopIndex = 0;
      _maxStopIndex = kTimelinePriceFilterStops.length - 1;
    });
    widget.onChanged(_minStopIndex, _maxStopIndex);
  }

  String _currencyOpenMaxSuffix(String currency) {
    final ref = formatMoney(10000, currency);
    final kIndex = ref.indexOf('k');
    return kIndex >= 0 ? ref.substring(kIndex + 1) : '';
  }

  String _priceLabel(double amount, {required bool isOpenMax}) {
    if (isOpenMax) {
      if (amount >= 1000) {
        final k = amount / 1000.0;
        final compact = k == k.truncateToDouble() ? '${k.toInt()}k' : '${k.toStringAsFixed(1)}k';
        return '$compact$_openMaxSuffix+';
      }
      return '${formatMoney(amount.round(), widget.currency)}+';
    }
    return formatMoney(amount.round(), widget.currency);
  }

  @override
  Widget build(BuildContext context) {
    final minPrice = _priceAtStopIndex(_minStopIndex);
    final maxPrice = _priceAtStopIndex(_maxStopIndex);
    final atMax = _maxStopIndex == kTimelinePriceFilterStops.length - 1;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Price range',
          style: ProcedureSelectionTypography.label(
            size: 12,
            weight: FontWeight.w700,
            color: TimelineTheme.ink,
          ),
        ),
        const SizedBox(height: 4),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              _priceLabel(minPrice, isOpenMax: false),
              style: ProcedureSelectionTypography.body(size: 12, color: TimelineTheme.muted),
            ),
            Text(
              _priceLabel(maxPrice, isOpenMax: atMax),
              style: ProcedureSelectionTypography.body(size: 12, color: TimelineTheme.muted),
            ),
          ],
        ),
        RangeSlider(
          values: RangeValues(_minStopIndex.toDouble(), _maxStopIndex.toDouble()),
          min: 0,
          max: (kTimelinePriceFilterStops.length - 1).toDouble(),
          divisions: kTimelinePriceFilterStops.length - 1,
          activeColor: TimelineTheme.ink,
          inactiveColor: TimelineTheme.iconBg,
          onChanged: (v) {
            final start = v.start.round().clamp(0, kTimelinePriceFilterStops.length - 1);
            final end = v.end.round().clamp(0, kTimelinePriceFilterStops.length - 1);
            final nextMin = start;
            final nextMax = end < start ? start : end;
            if (nextMin == _minStopIndex && nextMax == _maxStopIndex) return;
            setState(() {
              _minStopIndex = nextMin;
              _maxStopIndex = nextMax;
            });
            widget.onChanged(_minStopIndex, _maxStopIndex);
          },
        ),
      ],
    );
  }
}

class _SheetFilterChip extends StatelessWidget {
  const _SheetFilterChip({
    required this.text,
    required this.active,
    required this.onTap,
  });

  final String text;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: active ? TimelineTheme.ink : TimelineTheme.card,
          borderRadius: BorderRadius.circular(20),
          border: active ? null : Border.all(color: TimelineTheme.border),
        ),
        child: Text(
          text,
          style: ProcedureSelectionTypography.chip(
            size: 11,
            weight: FontWeight.w600,
            color: active ? Colors.white : TimelineTheme.muted,
          ),
        ),
      ),
    );
  }
}
