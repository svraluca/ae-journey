import 'package:flutter/material.dart';

import '../services/filter_currency.dart';
import '../services/worldwide_curated_clinics.dart';
import 'procedure_selection_theme.dart';
import 'widgets/procedure_selection_widgets.dart';

export '../services/filter_currency.dart' show FilterCurrency, CityCurrency;

/// Result returned when the user taps Show results on Filters.
class CompareFilterResult {
  const CompareFilterResult({
    this.currency,
    required this.procedureTypes,
    this.priceMin = 0,
    this.priceMax = 1000,
    this.priceMaxOpen = true,
    this.minRating = 2.0,
    this.doctorLedOnly = false,
    this.verifiedOnly = false,
  });

  /// When null, Explore shows each clinic's website currency (no FX conversion).
  final FilterCurrency? currency;
  final Set<String> procedureTypes;

  /// Price bounds. When [currency] is set, amounts are compared after FX convert;
  /// otherwise native website amounts are used.
  final double priceMin;
  final double priceMax;
  final bool priceMaxOpen;
  final double minRating;
  final bool doctorLedOnly;
  final bool verifiedOnly;

  static const defaultProcedureTypes = {'Injectables', 'Botox'};

  static const Object _currencyUnset = Object();

  static const defaults = CompareFilterResult(
    currency: null,
    procedureTypes: defaultProcedureTypes,
  );

  CompareFilterResult copyWith({
    Object? currency = _currencyUnset,
    Set<String>? procedureTypes,
    double? priceMin,
    double? priceMax,
    bool? priceMaxOpen,
    double? minRating,
    bool? doctorLedOnly,
    bool? verifiedOnly,
  }) {
    return CompareFilterResult(
      currency: identical(currency, _currencyUnset)
          ? this.currency
          : currency as FilterCurrency?,
      procedureTypes: procedureTypes ?? this.procedureTypes,
      priceMin: priceMin ?? this.priceMin,
      priceMax: priceMax ?? this.priceMax,
      priceMaxOpen: priceMaxOpen ?? this.priceMaxOpen,
      minRating: minRating ?? this.minRating,
      doctorLedOnly: doctorLedOnly ?? this.doctorLedOnly,
      verifiedOnly: verifiedOnly ?? this.verifiedOnly,
    );
  }
}

/// Opens Filters as a full-screen page (not a bottom sheet).
Future<CompareFilterResult?> showFilterCompareSheet(
  BuildContext context, {
  CompareFilterResult initial = CompareFilterResult.defaults,
}) {
  return Navigator.of(context).push<CompareFilterResult>(
    MaterialPageRoute<CompareFilterResult>(
      builder: (_) => FilterCompareScreen(initial: initial),
    ),
  );
}

/// Filters UI — procedure-form warm glass light design.
class FilterCompareScreen extends StatefulWidget {
  const FilterCompareScreen({
    super.key,
    this.initial = CompareFilterResult.defaults,
  });

  final CompareFilterResult initial;

  @override
  State<FilterCompareScreen> createState() => _FilterCompareScreenState();
}

class _FilterCompareScreenState extends State<FilterCompareScreen> {
  static const _priceSliderMax = 1000.0;
  static const _ratingThresholds = <double>[2.0, 3.0, 4.0, 4.5];

  late Set<String> _procedureSelected;
  late FilterCurrency? _currency;
  late RangeValues _priceRange;
  late int _minRatingIndex;
  late bool _doctorLed;
  late bool _verifiedClinics;

  @override
  void initState() {
    super.initState();
    _hydrate(widget.initial);
  }

  void _hydrate(CompareFilterResult src) {
    _currency = src.currency;
    _procedureSelected = src.procedureTypes.isEmpty
        ? Set<String>.from(CompareFilterResult.defaultProcedureTypes)
        : Set<String>.from(src.procedureTypes);
    final end = src.priceMaxOpen
        ? _priceSliderMax
        : src.priceMax.clamp(0, _priceSliderMax);
    final start = src.priceMin.clamp(0, end);
    _priceRange = RangeValues(start.toDouble(), end.toDouble());
    _minRatingIndex = _indexForRating(src.minRating);
    _doctorLed = src.doctorLedOnly;
    _verifiedClinics = src.verifiedOnly;
  }

  int _indexForRating(double rating) {
    var best = 0;
    for (var i = 0; i < _ratingThresholds.length; i++) {
      if (rating + 1e-9 >= _ratingThresholds[i]) best = i;
    }
    return best;
  }

  bool get _priceMaxOpen => _priceRange.end >= _priceSliderMax - 0.5;

  double get _minRating => _ratingThresholds[_minRatingIndex.clamp(0, 3)];

  int get _matchCount => WorldwideCuratedClinics.countForFilters(
        types: _procedureSelected,
        currency: _currency,
        priceMin: _priceRange.start,
        priceMax: _priceRange.end,
        priceMaxOpen: _priceMaxOpen,
        minRating: _minRating,
        doctorLedOnly: _doctorLed,
        verifiedOnly: _verifiedClinics,
      );

  void _resetAll() {
    setState(() => _hydrate(CompareFilterResult.defaults));
  }

  void _apply() {
    final types = _procedureSelected.isEmpty
        ? Set<String>.from(CompareFilterResult.defaultProcedureTypes)
        : Set<String>.from(_procedureSelected);
    Navigator.of(context).pop(
      CompareFilterResult(
        currency: _currency,
        procedureTypes: types,
        priceMin: _priceRange.start,
        priceMax: _priceRange.end,
        priceMaxOpen: _priceMaxOpen,
        minRating: _minRating,
        doctorLedOnly: _doctorLed,
        verifiedOnly: _verifiedClinics,
      ),
    );
  }

  String _formatPrice(double v) {
    final tick = _currency?.symbol ?? '';
    if (v >= _priceSliderMax - 0.5) {
      return tick.isEmpty ? '1000+' : '1000+ $tick';
    }
    return tick.isEmpty ? '${v.round()}' : '${v.round()} $tick';
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    return Scaffold(
      backgroundColor: ProcedureSelectionTheme.pageBackground,
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              ProcedureSelectionTheme.pageBackgroundTop,
              ProcedureSelectionTheme.pageBackground,
              ProcedureSelectionTheme.pageBackgroundBottom,
            ],
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SafeArea(
              bottom: false,
              child: _TopBar(
                onClose: () => Navigator.of(context).pop(),
                onReset: _resetAll,
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
                children: [
                  const _SectionLabel('Procedure type'),
                  const SizedBox(height: 10),
                  _ProcedureGrid(
                    types: WorldwideCuratedClinics.filterProcedureTypes,
                    selected: _procedureSelected,
                    onToggle: (label) => setState(() {
                      final next = Set<String>.from(_procedureSelected);
                      if (next.contains(label)) {
                        next.remove(label);
                      } else {
                        next.add(label);
                      }
                      _procedureSelected = next;
                    }),
                  ),
                  const SizedBox(height: 22),
                  const _SectionLabel('Currency'),
                  const SizedBox(height: 6),
                  Text(
                    'Optional — tap again to clear. Convert only when selected.',
                    style: ProcedureSelectionTypography.body(
                      size: 11,
                      color: ProcedureSelectionTheme.muted,
                    ),
                  ),
                  const SizedBox(height: 10),
                  _CurrencyGrid(
                    selected: _currency,
                    onChanged: (c) => setState(() => _currency = c),
                  ),
                  const SizedBox(height: 22),
                  const _SectionLabel('Price range'),
                  const SizedBox(height: 10),
                  _PriceRangeCard(
                    range: _priceRange,
                    currency: _currency,
                    onChanged: (v) => setState(() => _priceRange = v),
                    formatPrice: _formatPrice,
                  ),
                  const SizedBox(height: 22),
                  const _SectionLabel('Minimum rating'),
                  const SizedBox(height: 10),
                  _RatingRow(
                    selectedIndex: _minRatingIndex,
                    onChanged: (i) => setState(() => _minRatingIndex = i),
                  ),
                  const SizedBox(height: 22),
                  const _SectionLabel('Preferences'),
                  const SizedBox(height: 10),
                  _PreferencesCard(
                    doctorLed: _doctorLed,
                    verified: _verifiedClinics,
                    onDoctorLed: (v) => setState(() => _doctorLed = v),
                    onVerified: (v) => setState(() => _verifiedClinics = v),
                  ),
                  const SizedBox(height: 12),
                ],
              ),
            ),
            _ApplyBar(
              bottomInset: bottomInset,
              matchCount: _matchCount,
              onApply: _apply,
            ),
          ],
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.onClose, required this.onReset});

  final VoidCallback onClose;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
      child: Row(
        children: [
          Material(
            color: Colors.transparent,
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onClose,
              child: ProcedureGlassSurface(
                borderRadius: BorderRadius.circular(999),
                compact: true,
                child: const SizedBox(
                  width: 40,
                  height: 40,
                  child: Icon(
                    Icons.close_rounded,
                    size: 18,
                    color: ProcedureSelectionTheme.ink,
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: Text(
              'Filters',
              textAlign: TextAlign.center,
              style: ProcedureSelectionTypography.display(
                size: 22,
                color: ProcedureSelectionTheme.ink,
              ),
            ),
          ),
          TextButton(
            onPressed: onReset,
            style: TextButton.styleFrom(
              foregroundColor: ProcedureSelectionTheme.muted,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(
              'Reset all',
              style: ProcedureSelectionTypography.label(
                size: 13,
                weight: FontWeight.w600,
                color: ProcedureSelectionTheme.muted,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return ProcedureSectionLabel(text);
  }
}

class _ProcedureGrid extends StatelessWidget {
  const _ProcedureGrid({
    required this.types,
    required this.selected,
    required this.onToggle,
  });

  final List<String> types;
  final Set<String> selected;
  final ValueChanged<String> onToggle;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: EdgeInsets.zero,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: types.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        mainAxisExtent: 52,
      ),
      itemBuilder: (context, i) {
        final label = types[i];
        final on = selected.contains(label);
        return Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => onToggle(label),
            child: ProcedureGlassSurface(
              borderRadius: BorderRadius.circular(14),
              selected: on,
              compact: true,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    Container(
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(
                        shape: on ? BoxShape.circle : BoxShape.rectangle,
                        borderRadius: on ? null : BorderRadius.circular(6),
                        color: on
                            ? Colors.white.withValues(alpha: 0.18)
                            : Colors.transparent,
                        border: Border.all(
                          color: on
                              ? Colors.white.withValues(alpha: 0.7)
                              : ProcedureSelectionTheme.muted
                                  .withValues(alpha: 0.35),
                          width: 1.4,
                        ),
                      ),
                      alignment: Alignment.center,
                      child: on
                          ? const Icon(
                              Icons.check_rounded,
                              size: 13,
                              color: Colors.white,
                            )
                          : null,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ProcedureSelectionTypography.chip(
                          size: 13,
                          color: on
                              ? Colors.white
                              : ProcedureSelectionTheme.ink
                                  .withValues(alpha: 0.88),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _CurrencyGrid extends StatelessWidget {
  const _CurrencyGrid({
    required this.selected,
    required this.onChanged,
  });

  final FilterCurrency? selected;
  final ValueChanged<FilterCurrency?> onChanged;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: EdgeInsets.zero,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: FilterCurrency.values.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        mainAxisExtent: 56,
      ),
      itemBuilder: (context, i) {
        final c = FilterCurrency.values[i];
        final on = selected == c;
        return Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => onChanged(on ? null : c),
            child: ProcedureGlassSurface(
              borderRadius: BorderRadius.circular(14),
              selected: on,
              compact: true,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    c.symbol,
                    style: ProcedureSelectionTypography.display(
                      size: 14,
                      color: on ? Colors.white : ProcedureSelectionTheme.ink,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    c.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ProcedureSelectionTypography.label(
                      size: 9,
                      weight: FontWeight.w600,
                      color: on
                          ? Colors.white.withValues(alpha: 0.85)
                          : ProcedureSelectionTheme.muted,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _PriceRangeCard extends StatelessWidget {
  const _PriceRangeCard({
    required this.range,
    required this.currency,
    required this.onChanged,
    required this.formatPrice,
  });

  final RangeValues range;
  final FilterCurrency? currency;
  final ValueChanged<RangeValues> onChanged;
  final String Function(double) formatPrice;

  @override
  Widget build(BuildContext context) {
    final tick = currency?.symbol ?? '';

    return ProcedureGlassSurface(
      borderRadius: BorderRadius.circular(16),
      compact: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
        child: Column(
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        formatPrice(range.start),
                        style: ProcedureSelectionTypography.display(
                          size: 16,
                          color: ProcedureSelectionTheme.ink,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        'Minimum',
                        style: ProcedureSelectionTypography.body(
                          size: 11,
                          color: ProcedureSelectionTheme.muted,
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    '—',
                    style: ProcedureSelectionTypography.body(
                      size: 13,
                      color: ProcedureSelectionTheme.muted,
                    ),
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        formatPrice(range.end),
                        style: ProcedureSelectionTypography.display(
                          size: 16,
                          color: ProcedureSelectionTheme.ink,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        'Maximum',
                        style: ProcedureSelectionTypography.body(
                          size: 11,
                          color: ProcedureSelectionTheme.muted,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 4,
                rangeThumbShape:
                    const RoundRangeSliderThumbShape(enabledThumbRadius: 10),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
                activeTrackColor: ProcedureSelectionTheme.buttonPrimary,
                inactiveTrackColor:
                    ProcedureSelectionTheme.muted.withValues(alpha: 0.18),
                thumbColor: Colors.white,
                overlappingShapeStrokeColor:
                    ProcedureSelectionTheme.buttonPrimary,
              ),
              child: RangeSlider(
                values: range,
                min: 0,
                max: 1000,
                divisions: 40,
                onChanged: onChanged,
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                for (final mark in ['0', '250', '500', '1000+'])
                  Text(
                    tick.isEmpty ? mark : '$mark $tick',
                    style: ProcedureSelectionTypography.body(
                      size: 10,
                      color: ProcedureSelectionTheme.muted
                          .withValues(alpha: 0.75),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _RatingRow extends StatelessWidget {
  const _RatingRow({required this.selectedIndex, required this.onChanged});

  final int selectedIndex;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    const labels = ['2.0+', '3.0+', '4.0+', '4.5+'];
    return Row(
      children: List.generate(4, (i) {
        final on = selectedIndex == i;
        return Expanded(
          child: Padding(
            padding:
                EdgeInsets.only(left: i == 0 ? 0 : 5, right: i == 3 ? 0 : 5),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () => onChanged(i),
                child: ProcedureGlassSurface(
                  borderRadius: BorderRadius.circular(14),
                  selected: on,
                  compact: true,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Column(
                      children: [
                        Text(
                          '★' * (i + 2),
                          style: TextStyle(
                            fontSize: 10,
                            height: 1,
                            color: on
                                ? const Color(0xFFF5C842)
                                : const Color(0xFFD4B84A),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          labels[i],
                          style: ProcedureSelectionTypography.label(
                            size: 11,
                            weight: FontWeight.w700,
                            color: on
                                ? Colors.white
                                : ProcedureSelectionTheme.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      }),
    );
  }
}

class _PreferencesCard extends StatelessWidget {
  const _PreferencesCard({
    required this.doctorLed,
    required this.verified,
    required this.onDoctorLed,
    required this.onVerified,
  });

  final bool doctorLed;
  final bool verified;
  final ValueChanged<bool> onDoctorLed;
  final ValueChanged<bool> onVerified;

  @override
  Widget build(BuildContext context) {
    return ProcedureGlassSurface(
      borderRadius: BorderRadius.circular(16),
      compact: true,
      child: Column(
        children: [
          _PrefRow(
            icon: Icons.person_outline_rounded,
            title: 'Doctor-led only',
            subtitle: 'Procedures by qualified doctors',
            value: doctorLed,
            onChanged: onDoctorLed,
            showDivider: true,
          ),
          _PrefRow(
            icon: Icons.verified_user_outlined,
            title: 'Verified clinics only',
            subtitle: 'Passport-verified partners',
            value: verified,
            onChanged: onVerified,
            showDivider: false,
          ),
        ],
      ),
    );
  }
}

class _PrefRow extends StatelessWidget {
  const _PrefRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
    required this.showDivider,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () => onChanged(!value),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: ProcedureSelectionTheme.cardBorder,
                      ),
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      icon,
                      size: 17,
                      color: ProcedureSelectionTheme.muted,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: ProcedureSelectionTypography.label(
                            size: 14,
                            weight: FontWeight.w700,
                            color: ProcedureSelectionTheme.ink,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          style: ProcedureSelectionTypography.body(
                            size: 11,
                            color: ProcedureSelectionTheme.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Switch.adaptive(
                    value: value,
                    activeThumbColor: Colors.white,
                    activeTrackColor: ProcedureSelectionTheme.buttonPrimary,
                    onChanged: onChanged,
                  ),
                ],
              ),
            ),
          ),
        ),
        if (showDivider)
          Divider(
            height: 1,
            thickness: 1,
            color: ProcedureSelectionTheme.muted.withValues(alpha: 0.12),
          ),
      ],
    );
  }
}

class _ApplyBar extends StatelessWidget {
  const _ApplyBar({
    required this.bottomInset,
    required this.matchCount,
    required this.onApply,
  });

  final double bottomInset;
  final int matchCount;
  final VoidCallback onApply;

  @override
  Widget build(BuildContext context) {
    return ProcedureGlassSurface(
      borderRadius: BorderRadius.zero,
      compact: true,
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 12, 16, 12 + bottomInset),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '✨  $matchCount clinics match your filters',
              style: ProcedureSelectionTypography.body(
                size: 12,
                color: ProcedureSelectionTheme.muted,
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: FilledButton(
                onPressed: onApply,
                style: FilledButton.styleFrom(
                  backgroundColor: ProcedureSelectionTheme.buttonPrimary,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.search_rounded, size: 18),
                    const SizedBox(width: 8),
                    Text(
                      'Show $matchCount results',
                      style: ProcedureSelectionTypography.label(
                        size: 14,
                        weight: FontWeight.w700,
                        color: Colors.white,
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
