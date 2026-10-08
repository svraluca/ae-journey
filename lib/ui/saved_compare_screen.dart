import 'package:flutter/material.dart';

import '../services/saved_bookmarks_store.dart';
import 'clinic_profile_screen.dart';
import 'filter_compare_screen.dart';
import 'procedure_selection_theme.dart';
import 'widgets/procedure_selection_widgets.dart';
import 'widgets/step2_warm_background.dart';

enum _CompareSort { priceLow, priceHigh, rating }

/// Compare clinics for a procedure using the user's Firestore-saved bookmarks.
class SavedCompareScreen extends StatefulWidget {
  const SavedCompareScreen({super.key, this.initialProcedure});

  /// Optional procedure to pre-select (case-insensitive match).
  final String? initialProcedure;

  @override
  State<SavedCompareScreen> createState() => _SavedCompareScreenState();
}

class _SavedCompareScreenState extends State<SavedCompareScreen> {
  final _bookmarks = SavedBookmarksStore.instance;

  String? _selectedProcedure;
  _CompareSort _sort = _CompareSort.priceLow;
  double _minRating = 0;

  // Category key used inside the Saved compare dropdown.
  static const String _catLipFillerKey = 'CAT:lip_filler';
  static const String _catLipFillerLabel = 'Lip filler';

  static const String _catBotoxKey = 'CAT:botox';
  static const String _catBotoxLabel = 'Botox';

  static const String _catFillerKey = 'CAT:filler';
  static const String _catFillerLabel = 'Filler';

  static const String _catBiostimKey = 'CAT:biostimulator';
  static const String _catBiostimLabel = 'Biostimulator';

  static const String _catPolynucleotidesKey = 'CAT:polynucleotides';
  static const String _catPolynucleotidesLabel = 'Polynucleotides';

  static const String _catMicroneedlingKey = 'CAT:microneedling';
  static const String _catMicroneedlingLabel = 'Microneedling';

  static const String _catLaserKey = 'CAT:laser';
  static const String _catLaserLabel = 'Laser';

  static const String _catHairRemovalKey = 'CAT:hair_removal';
  static const String _catHairRemovalLabel = 'Hair removal';

  static const String _catRhinoplastyKey = 'CAT:rhinoplasty';
  static const String _catRhinoplastyLabel = 'Rhinoplasty';

  static const String _catBlepharoplastyKey = 'CAT:blepharoplasty';
  static const String _catBlepharoplastyLabel = 'Blepharoplasty';

  static const String _catOtoplastyKey = 'CAT:otoplasty';
  static const String _catOtoplastyLabel = 'Otoplasty';

  static const String _catLiposuctionKey = 'CAT:liposuction';
  static const String _catLiposuctionLabel = 'Liposuction';

  static const String _catAbdominoplastyKey = 'CAT:abdominoplasty';
  static const String _catAbdominoplastyLabel = 'Abdominoplasty';

  static const String _catBreastKey = 'CAT:breast';
  static const String _catBreastLabel = 'Breast';

  static const String _catBBLKey = 'CAT:bbl';
  static const String _catBBLLabel = 'BBL';

  static const String _catFaceliftKey = 'CAT:facelift';
  static const String _catFaceliftLabel = 'Facelift';

  static const String _catHairTransplantKey = 'CAT:hair_transplant';
  static const String _catHairTransplantLabel = 'Hair transplant';

  static const String _catPostOpMassageKey = 'CAT:post_op_massage';
  static const String _catPostOpMassageLabel = 'Post-op massage';

  static const String _catLymphaticDrainageKey = 'CAT:lymphatic';
  static const String _catLymphaticDrainageLabel = 'Lymphatic drainage';

  static const String _catScarKey = 'CAT:scar';
  static const String _catScarLabel = 'Scar removal';

  String _selectionLabel(String key) {
    if (key == _catLipFillerKey) return _catLipFillerLabel;
    if (key == _catBotoxKey) return _catBotoxLabel;
    if (key == _catFillerKey) return _catFillerLabel;
    if (key == _catBiostimKey) return _catBiostimLabel;
    if (key == _catPolynucleotidesKey) return _catPolynucleotidesLabel;
    if (key == _catMicroneedlingKey) return _catMicroneedlingLabel;
    if (key == _catLaserKey) return _catLaserLabel;
    if (key == _catHairRemovalKey) return _catHairRemovalLabel;
    if (key == _catRhinoplastyKey) return _catRhinoplastyLabel;
    if (key == _catBlepharoplastyKey) return _catBlepharoplastyLabel;
    if (key == _catOtoplastyKey) return _catOtoplastyLabel;
    if (key == _catLiposuctionKey) return _catLiposuctionLabel;
    if (key == _catAbdominoplastyKey) return _catAbdominoplastyLabel;
    if (key == _catBreastKey) return _catBreastLabel;
    if (key == _catBBLKey) return _catBBLLabel;
    if (key == _catFaceliftKey) return _catFaceliftLabel;
    if (key == _catHairTransplantKey) return _catHairTransplantLabel;
    if (key == _catPostOpMassageKey) return _catPostOpMassageLabel;
    if (key == _catLymphaticDrainageKey) return _catLymphaticDrainageLabel;
    if (key == _catScarKey) return _catScarLabel;
    return key;
  }

  /// Categorizes any procedure name (any language) into compare-friendly
  /// buckets so different naming variants group together without AI.
  String? _categoryForProcedureName(String procedureName) {
    final p = procedureName.trim().toLowerCase();
    if (p.isEmpty) return null;

    bool hasWord(RegExp re) => re.hasMatch(p);
    bool containsAny(List<String> parts) {
      for (final s in parts) {
        if (s.isEmpty) continue;
        if (p.contains(s)) return true;
      }
      return false;
    }

    // Lip filler must be detected before generic fillers.
    final isLip =
        hasWord(RegExp(r'\blips?\b')) ||
        p.contains(' buze') ||
        p.contains(' buza') ||
        p.contains(' buz ') ||
        p.startsWith('buze') ||
        p.startsWith('buza') ||
        p.contains('buze') ||
        p.contains('buza') ||
        p.contains('russian lips');

    final isLipVolume = p.contains('volum') ||
        p.contains('augment') ||
        p.contains('russian') ||
        p.contains('lips');

    final isFillerLike = containsAny([
      'filler',
      'fill',
      'inject',
      'injection',
      'hialuron',
      'hyaluron',
      'acid',
      'hialuronic',
      'hyaluronic',
      'hialuronic',
      'hyaluronic',
      'volum',
    ]);

    // Avoid matching "liposuction" as "lip".
    final isLipo = p.contains('liposuc') || p.contains('liposuction') || p.contains('lipo');

    if (!isLipo && isLip && (isFillerLike || isLipVolume)) {
      return _catLipFillerKey;
    }

    // Generic fillers (non-lip).
    if (isFillerLike) {
      return _catFillerKey;
    }

    // Botox / toxin.
    if (containsAny(['botox', 'toxin'])) return _catBotoxKey;

    // Polynucleotides.
    if (containsAny(['polynucleotides', 'profhilo', 'rejuran'])) {
      return _catPolynucleotidesKey;
    }

    // Biostimulator.
    if (containsAny(['biostim', 'sculptra'])) return _catBiostimKey;

    // Microneedling / Morpheus.
    if (containsAny(['microneed', 'microned', 'morpheus'])) {
      return _catMicroneedlingKey;
    }

    // Hair removal (must come before laser/hifu).
    if (containsAny(['hair removal', 'epilare', 'epilat', 'depil'])) {
      return _catHairRemovalKey;
    }

    // Laser / energy.
    if (containsAny(['laser', 'co2', 'co₂', 'ultherapy', 'hifu'])) {
      return _catLaserKey;
    }

    if (containsAny(['rhino', 'rinoplast'])) return _catRhinoplastyKey;
    if (containsAny(['blephar', 'eyelid', 'blefaro'])) {
      return _catBlepharoplastyKey;
    }
    if (containsAny(['otoplast'])) return _catOtoplastyKey;

    if (containsAny(['lipo', 'liposuc', 'liposuction'])) return _catLiposuctionKey;
    if (containsAny(['abdomin', 'tummy tuck', 'abdominoplast'])) {
      return _catAbdominoplastyKey;
    }

    if (containsAny(['augmentare mamar', 'mamar', 'breast', 'mastopex', 'marire san', 'mărire sân'])) {
      return _catBreastKey;
    }
    if (containsAny(['bbl', 'brazilian', 'butt lift'])) return _catBBLKey;
    if (containsAny(['facelift', 'face lift', 'lifting facial', 'mini facelift'])) {
      return _catFaceliftKey;
    }
    if (containsAny(['hair transplant', 'transplant de par', 'transplant păr'])) {
      return _catHairTransplantKey;
    }

    if (containsAny(['lymphatic', 'limfatic'])) return _catLymphaticDrainageKey;
    if (containsAny(['post-op', 'post op', 'postop'])) return _catPostOpMassageKey;
    if (containsAny(['scar', 'cicatric'])) return _catScarKey;

    return null;
  }

  @override
  void initState() {
    super.initState();
    _bookmarks.addListener(_onChanged);
    _selectedProcedure = _resolveInitialProcedure();
  }

  @override
  void dispose() {
    _bookmarks.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (!mounted) return;
    final names = _procedureNames;
    if (_selectedProcedure == null || !names.contains(_selectedProcedure)) {
      _selectedProcedure = names.isEmpty ? null : names.first;
    }
    setState(() {});
  }

  String? _resolveInitialProcedure() {
    final names = _procedureNames;
    if (names.isEmpty) return null;
    final want = (widget.initialProcedure ?? '').trim();
    if (want.isNotEmpty) {
      // If the saved procedure name belongs to a known category, select the category.
      final cat = _categoryForProcedureName(want);
      if (cat != null && names.contains(cat)) return cat;

      for (final n in names) {
        if (!_isCategoryKey(n) && _norm(n) == _norm(want)) return n;
      }
    }
    return names.first;
  }

  bool _isCategoryKey(String key) => key.startsWith('CAT:');

  static String _norm(String s) => s.trim().toLowerCase();

  List<String> get _procedureNames {
    final out = <String>[];

    // Build category keys first so dropdown shows grouped procedure buckets.
    final categoryKeys = <String>[
      _catLipFillerKey,
      _catBotoxKey,
      _catFillerKey,
      _catBiostimKey,
      _catPolynucleotidesKey,
      _catMicroneedlingKey,
      _catLaserKey,
      _catHairRemovalKey,
      _catRhinoplastyKey,
      _catBlepharoplastyKey,
      _catOtoplastyKey,
      _catLiposuctionKey,
      _catAbdominoplastyKey,
      _catBreastKey,
      _catBBLKey,
      _catFaceliftKey,
      _catHairTransplantKey,
      _catPostOpMassageKey,
      _catLymphaticDrainageKey,
      _catScarKey,
    ];

    for (final catKey in categoryKeys) {
      final hasCat = _bookmarks.items.any((e) {
        final p = e.procedureName.trim();
        if (p.isEmpty) return false;
        return _categoryForProcedureName(p) == catKey;
      });
      if (hasCat) out.add(catKey);
    }

    final seen = <String>{};
    for (final e in _bookmarks.items) {
      final p = e.procedureName.trim();
      if (p.isEmpty) continue;

      final cat = _categoryForProcedureName(p);
      if (cat != null) continue; // grouped under a known category

      final key = _norm(p);
      if (seen.add(key)) out.add(p);
    }

    // Keep categories first, then alphabetical procedure names.
    out.sort((a, b) {
      final aCat = a.startsWith('CAT:') ? 0 : 1;
      final bCat = b.startsWith('CAT:') ? 0 : 1;
      if (aCat != bCat) return aCat.compareTo(bCat);
      return a.toLowerCase().compareTo(b.toLowerCase());
    });
    return out;
  }

  List<SavedBookmarkEntry> get _entriesForSelected {
    final selected = _selectedProcedure;
    if (selected == null) return const [];

    List<SavedBookmarkEntry> list;
    if (_isCategoryKey(selected)) {
      list = _bookmarks.items
          .where((e) {
            final p = e.procedureName.trim();
            if (p.isEmpty) return false;
            return _categoryForProcedureName(p) == selected;
          })
          .toList();
    } else {
      final key = _norm(selected);
      list = _bookmarks.items
          .where((e) => _norm(e.procedureName) == key)
          .toList();
    }

    if (_minRating > 0) {
      list = list.where((e) => e.rating >= _minRating).toList();
    }
    list.sort((a, b) {
      switch (_sort) {
        case _CompareSort.priceLow:
          return _priceEurAnchor(a.priceLabel).compareTo(_priceEurAnchor(b.priceLabel));
        case _CompareSort.priceHigh:
          return _priceEurAnchor(b.priceLabel).compareTo(_priceEurAnchor(a.priceLabel));
        case _CompareSort.rating:
          return b.rating.compareTo(a.rating);
      }
    });
    return list;
  }

  /// Lowest numeric amount found in a price label, converted into EUR.
  ///
  /// Handles thousands separators like "2,000" correctly (=> 2000).
  /// Used so sorting works even when labels are in different currencies
  /// (e.g. "from €450" vs "310–1910 RON").
  static double _priceEurAnchor(String raw) {
    final lower = raw.toLowerCase();
    final nums = RegExp(r'(\d+(?:[.,]\d+)?)')
        .allMatches(raw)
        .map((m) => _parsePriceNumber(m.group(1)!))
        .whereType<double>()
        .toList();
    if (nums.isEmpty) return 1e12;

    // For ranges like "310–1910 RON" we sort by the lowest possible value.
    final min = nums.reduce((a, b) => a < b ? a : b);

    // Offline, approximate conversion rates. We only need a stable ordering.
    if (lower.contains('ron') || lower.contains('lei')) {
      // 1 EUR ~= 4.97 RON
      return min / 4.97;
    }
    if (lower.contains('£') || lower.contains('gbp')) {
      // 1 GBP ~= 1.17 EUR
      return min * 1.17;
    }
    if (lower.contains('\$') || lower.contains('usd')) {
      // 1 USD ~= 0.92 EUR
      return min * 0.92;
    }
    // € or unknown -> assume EUR
    return min;
  }

  /// Parses a numeric token from a price label.
  ///
  /// Examples:
  /// - "2,000" -> 2000
  /// - "450" -> 450
  /// - "1.200" -> 1200 (if it's a thousands separator)
  static double? _parsePriceNumber(String token) {
    final t = token.trim();
    if (t.isEmpty) return null;

    final hasComma = t.contains(',');
    final hasDot = t.contains('.');

    // Both separators: assume the last one is the decimal separator.
    if (hasComma && hasDot) {
      final lastComma = t.lastIndexOf(',');
      final lastDot = t.lastIndexOf('.');
      final decimalIsComma = lastComma > lastDot;
      final normalized = decimalIsComma
          ? t.replaceAll('.', '').replaceAll(',', '.')
          : t.replaceAll(',', '').replaceAll('.', '.'); // keep dots as decimal
      return double.tryParse(normalized);
    }

    // Only comma: either thousands ("2,000") or decimal ("2,50").
    if (hasComma && !hasDot) {
      final lastComma = t.lastIndexOf(',');
      final decimals = t.length - lastComma - 1;
      if (decimals == 3) {
        // Thousands separator
        return double.tryParse(t.replaceAll(',', ''));
      }
      // Decimal separator
      return double.tryParse(t.replaceAll(',', '.'));
    }

    // Only dot: either thousands ("1.200") or decimal ("1.20").
    if (hasDot && !hasComma) {
      final lastDot = t.lastIndexOf('.');
      final decimals = t.length - lastDot - 1;
      if (decimals == 3) {
        // Thousands separator
        return double.tryParse(t.replaceAll('.', ''));
      }
      // Decimal separator
      return double.tryParse(t);
    }

    // Plain integer
    return double.tryParse(t);
  }

  static String _compactPrice(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return '—';
    if (t.toLowerCase().startsWith('from ')) return t.substring(5).trim();
    return t;
  }

  Future<void> _pickProcedure() async {
    final names = _procedureNames;
    if (names.isEmpty) return;
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        final bottomSafe = MediaQuery.paddingOf(ctx).bottom;
        return Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
          child: Container(
            padding: EdgeInsets.fromLTRB(22, 0, 22, 16 + bottomSafe),
            decoration: BoxDecoration(
              color: const Color(0xFF000000),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(24),
                topRight: Radius.circular(24),
              ),
              border: Border(
                top: BorderSide(
                  color: Colors.white.withValues(alpha: 0.08),
                ),
              ),
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
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Select procedure',
                          style: ProcedureSelectionTypography.display(
                            size: 18,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      Material(
                        color: Colors.white.withValues(alpha: 0.10),
                        shape: const CircleBorder(),
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: () => Navigator.of(ctx).pop(),
                          child: const SizedBox(
                            width: 32,
                            height: 32,
                            child: Icon(
                              Icons.close_rounded,
                              size: 18,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
                      itemCount: names.length,
                      separatorBuilder: (context, index) => Divider(
                        height: 1,
                        color: Colors.white.withValues(alpha: 0.16),
                      ),
                      itemBuilder: (_, i) {
                        final name = names[i];
                        final on = name == (_selectedProcedure ?? '');
                        final count = _bookmarks.items
                            .where((e) {
                              final p = e.procedureName.trim();
                              if (p.isEmpty) return false;
                              if (_isCategoryKey(name)) {
                                return _categoryForProcedureName(p) == name;
                              }
                              return _norm(p) == _norm(name);
                            })
                            .length;
                        return ListTile(
                          dense: true,
                          title: Text(
                            _selectionLabel(name),
                            style: ProcedureSelectionTypography.label(
                              size: 14,
                              weight: FontWeight.w600,
                              color: Colors.white,
                            ),
                          ),
                          subtitle: Text(
                            '$count clinic${count == 1 ? '' : 's'} saved',
                            style: ProcedureSelectionTypography.body(
                              size: 11,
                              color: Colors.white.withValues(alpha: 0.65),
                            ),
                          ),
                          trailing: on
                              ? Icon(
                                  Icons.check_rounded,
                                  color: Colors.white.withValues(alpha: 0.92),
                                  size: 20,
                                )
                              : null,
                          onTap: () => Navigator.pop(ctx, name),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
    if (picked != null && mounted) {
      setState(() => _selectedProcedure = picked);
    }
  }

  Future<void> _openFilters() async {
    final result = await showModalBottomSheet<(_CompareSort, double)>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        var sort = _sort;
        var minRating = _minRating;
        return StatefulBuilder(
          builder: (ctx, setModal) {
            final bottomSafe = MediaQuery.paddingOf(ctx).bottom;
            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.viewInsetsOf(ctx).bottom,
              ),
              child: Container(
                padding: EdgeInsets.fromLTRB(22, 0, 22, 16 + bottomSafe),
                decoration: BoxDecoration(
                  color: const Color(0xFF000000),
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(24),
                    topRight: Radius.circular(24),
                  ),
                  border: Border(
                    top: BorderSide(
                      color: Colors.white.withValues(alpha: 0.08),
                    ),
                  ),
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
                      const SizedBox(height: 18),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Filters',
                              style: ProcedureSelectionTypography.display(
                                size: 18,
                                color: Colors.white,
                              ),
                            ),
                          ),
                          Material(
                            color: Colors.white.withValues(alpha: 0.10),
                            shape: const CircleBorder(),
                            child: InkWell(
                              customBorder: const CircleBorder(),
                              onTap: () => Navigator.of(ctx).pop(),
                              child: const SizedBox(
                                width: 32,
                                height: 32,
                                child: Icon(
                                  Icons.close_rounded,
                                  size: 18,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Text(
                        'Sort by',
                        style: ProcedureSelectionTypography.label(
                          size: 11,
                          weight: FontWeight.w700,
                          color: Colors.white.withValues(alpha: 0.70),
                        ),
                      ),
                      const SizedBox(height: 8),
                      for (final opt in _CompareSort.values)
                        Material(
                          color: Colors.transparent,
                          child: InkWell(
                            borderRadius: BorderRadius.circular(10),
                            onTap: () => setModal(() => sort = opt),
                            child: Padding(
                              padding:
                                  const EdgeInsets.symmetric(vertical: 10),
                              child: Row(
                                children: [
                                  Icon(
                                    sort == opt
                                        ? Icons
                                            .radio_button_checked_rounded
                                        : Icons.radio_button_off_rounded,
                                    size: 20,
                                    color: Colors.white.withValues(alpha: 0.92),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      switch (opt) {
                                        _CompareSort.priceLow =>
                                          'Price — low to high',
                                        _CompareSort.priceHigh =>
                                          'Price — high to low',
                                        _CompareSort.rating => 'Rating',
                                      },
                                      style: ProcedureSelectionTypography.label(
                                        size: 13,
                                        weight: FontWeight.w600,
                                        color: Colors.white.withValues(alpha: 0.92),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      const SizedBox(height: 8),
                      Text(
                        'Minimum rating',
                        style: ProcedureSelectionTypography.label(
                          size: 11,
                          weight: FontWeight.w700,
                          color: Colors.white.withValues(alpha: 0.70),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        children: [
                          for (final r in const [0.0, 3.0, 4.0, 4.5])
                            _MinRatingChip(
                              value: r,
                              selected: minRating == r,
                              onTap: () => setModal(() => minRating = r),
                            ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Material(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(999),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(999),
                          onTap: () =>
                              Navigator.pop(ctx, (sort, minRating)),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              vertical: 14,
                            ),
                            child: Text(
                              'Apply',
                              textAlign: TextAlign.center,
                              style: ProcedureSelectionTypography.label(
                                size: 14,
                                weight: FontWeight.w700,
                                color: ProcedureSelectionTheme.ink,
                              ),
                            ),
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: () {
                          showFilterCompareSheet(context);
                        },
                        child: Text(
                          'More filters',
                          style: ProcedureSelectionTypography.label(
                            size: 12,
                            weight: FontWeight.w600,
                            color: Colors.white.withValues(alpha: 0.70),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
    if (result != null && mounted) {
      setState(() {
        _sort = result.$1;
        _minRating = result.$2;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomPad = MediaQuery.paddingOf(context).bottom;
    final procedures = _procedureNames;
    final selected = _selectedProcedure;
    final entries = _entriesForSelected;

    SavedBookmarkEntry? bestPrice;
    SavedBookmarkEntry? bestRating;
    String topCity = '—';
    var topCityCount = 0;

    if (entries.isNotEmpty) {
      final priced = entries.where((e) => e.priceLabel.trim().isNotEmpty).toList()
        ..sort((a, b) => _priceEurAnchor(a.priceLabel).compareTo(_priceEurAnchor(b.priceLabel)));
      if (priced.isNotEmpty && _priceEurAnchor(priced.first.priceLabel) < 1e12) {
        bestPrice = priced.first;
      }
      final rated = [...entries]..sort((a, b) => b.rating.compareTo(a.rating));
      if (rated.isNotEmpty && rated.first.rating > 0) bestRating = rated.first;

      final cityCounts = <String, int>{};
      for (final e in entries) {
        final c = e.city.trim().isNotEmpty ? e.city.trim() : e.locationLabel;
        if (c.isEmpty || c == '—') continue;
        cityCounts[c] = (cityCounts[c] ?? 0) + 1;
      }
      if (cityCounts.isNotEmpty) {
        final top = cityCounts.entries.reduce((a, b) => a.value >= b.value ? a : b);
        topCity = top.key;
        topCityCount = top.value;
      }
    }

    final bestPriceId = bestPrice?.id;
    final bestRatingId = bestRating?.id;
    final topRatingValue = bestRating?.rating ?? 0;
    final topRatingCount =
        entries.where((e) => e.rating > 0 && (e.rating - topRatingValue).abs() < 0.05).length;

    return Stack(
      children: [
        const Step2WarmBackground(),
        Scaffold(
          backgroundColor: Colors.transparent,
          body: SafeArea(
            bottom: false,
            child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: Row(
                      children: [
                        _CircleBtn(
                          icon: Icons.chevron_left_rounded,
                          onTap: () => Navigator.of(context).maybePop(),
                        ),
                        Expanded(
                          child: Column(
                            children: [
                              Text(
                                'Compare',
                                style: ProcedureSelectionTypography.display(
                                  size: 18,
                                  color: ProcedureSelectionTheme.ink,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Pick a saved procedure to compare clinics',
                                textAlign: TextAlign.center,
                                style: ProcedureSelectionTypography.body(
                                  size: 11,
                                  color: ProcedureSelectionTheme.muted,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 36),
                      ],
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const ProcedureSectionLabel('Select procedure'),
                        const SizedBox(height: 8),
                        ProcedureGlassSurface(
                          borderRadius: BorderRadius.circular(16),
                          compact: true,
                          child: Material(
                            color: Colors.transparent,
                            child: InkWell(
                              borderRadius: BorderRadius.circular(16),
                              onTap: procedures.isEmpty ? null : _pickProcedure,
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                                child: Row(
                                  children: [
                                    Container(
                                      width: 40,
                                      height: 40,
                                      decoration: BoxDecoration(
                                        color: ProcedureSelectionTheme.buttonPrimary,
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      alignment: Alignment.center,
                                      child: Text(
                                        _initials(selected ?? '?'),
                                        style: ProcedureSelectionTypography.display(
                                          size: 13,
                                          color: Colors.white,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Text(
                                        selected == null
                                            ? (procedures.isEmpty
                                                ? 'No saved procedures yet'
                                                : 'Choose a procedure')
                                            : _selectionLabel(selected),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: ProcedureSelectionTypography.label(
                                          size: 14,
                                          weight: FontWeight.w600,
                                          color: ProcedureSelectionTheme.ink,
                                        ),
                                      ),
                                    ),
                                    Icon(
                                      Icons.keyboard_arrow_down_rounded,
                                      color: ProcedureSelectionTheme.muted,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (procedures.isEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
                      child: ProcedureGlassSurface(
                        borderRadius: BorderRadius.circular(ProcedureSelectionTheme.cardRadius),
                        compact: true,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(20, 28, 20, 28),
                          child: Column(
                            children: [
                              Icon(Icons.compare_arrows_rounded,
                                  size: 28, color: ProcedureSelectionTheme.muted),
                              const SizedBox(height: 12),
                              Text(
                                'Nothing to compare yet',
                                style: ProcedureSelectionTypography.display(
                                  size: 15,
                                  color: ProcedureSelectionTheme.ink,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                'Save procedures from clinic profiles to compare prices here.',
                                textAlign: TextAlign.center,
                                style: ProcedureSelectionTypography.body(
                                  size: 12,
                                  color: ProcedureSelectionTheme.muted,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  )
                else ...[
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
                      child: ProcedureGlassSurface(
                        borderRadius: BorderRadius.circular(20),
                        compact: true,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'Comparison overview',
                                          style: ProcedureSelectionTypography.display(
                                            size: 15,
                                            color: ProcedureSelectionTheme.ink,
                                          ),
                                        ),
                                        const SizedBox(height: 3),
                                        Text(
                                          '${entries.length} clinic${entries.length == 1 ? '' : 's'} found',
                                          style: ProcedureSelectionTypography.body(
                                            size: 11,
                                            color: ProcedureSelectionTheme.muted,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  Material(
                                    color: ProcedureSelectionTheme.fieldFill,
                                    borderRadius: BorderRadius.circular(999),
                                    child: InkWell(
                                      borderRadius: BorderRadius.circular(999),
                                      onTap: _openFilters,
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 12,
                                          vertical: 8,
                                        ),
                                        child: Row(
                                          children: [
                                            Icon(Icons.tune_rounded,
                                                size: 14,
                                                color: ProcedureSelectionTheme.ink),
                                            const SizedBox(width: 6),
                                            Text(
                                              'Filters',
                                              style: ProcedureSelectionTypography.label(
                                                size: 12,
                                                weight: FontWeight.w600,
                                                color: ProcedureSelectionTheme.ink,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 14),
                              Row(
                                children: [
                                  Expanded(
                                    child: _OverviewTile(
                                    iconBg: ProcedureSelectionTheme.fieldFillLight,
                                    iconColor: ProcedureSelectionTheme.ink.withValues(alpha: 0.72),
                                      icon: Icons.attach_money_outlined,
                                      label: 'Lowest price',
                                      value: bestPrice == null
                                          ? '—'
                                          : _compactPrice(bestPrice.priceLabel),
                                      caption: bestPrice?.clinicName ?? '—',
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: _OverviewTile(
                                      iconBg: ProcedureSelectionTheme.fieldFillLight,
                                      iconColor: ProcedureSelectionTheme.ink.withValues(alpha: 0.72),
                                      icon: Icons.star_outline_rounded,
                                      label: 'Highest rating',
                                      value: bestRating == null
                                          ? '—'
                                          : '${bestRating.rating.toStringAsFixed(1)} ★',
                                      caption: topRatingCount == 0
                                          ? '—'
                                          : '$topRatingCount clinic${topRatingCount == 1 ? '' : 's'}',
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: _OverviewTile(
                                      iconBg: ProcedureSelectionTheme.fieldFillLight,
                                      iconColor: ProcedureSelectionTheme.ink.withValues(alpha: 0.72),
                                      icon: Icons.place_outlined,
                                      label: 'Most clinics',
                                      value: topCity,
                                      caption: topCityCount == 0
                                          ? '—'
                                          : '$topCityCount clinic${topCityCount == 1 ? '' : 's'}',
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (entries.isEmpty)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                        child: Text(
                          'No clinics match these filters.',
                          style: ProcedureSelectionTypography.body(
                            size: 12,
                            color: ProcedureSelectionTheme.muted,
                          ),
                        ),
                      ),
                    )
                  else
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(20, 14, 20, 16 + bottomPad),
                      sliver: SliverList(
                        delegate: SliverChildBuilderDelegate(
                          (context, index) {
                            final entry = entries[index];
                            return Padding(
                              padding: EdgeInsets.only(
                                bottom: index == entries.length - 1 ? 0 : 10,
                              ),
                              child: _CompareClinicCard(
                                entry: entry,
                                isBestPrice: entry.id == bestPriceId,
                                isHighestRating: entry.id == bestRatingId &&
                                    entry.rating > 0,
                                onUnsave: () => _bookmarks.remove(
                                  entry.clinicName,
                                  procedureName: entry.procedureName,
                                ),
                                onOpen: () {
                                  Navigator.of(context).push<void>(
                                    MaterialPageRoute<void>(
                                      builder: (_) => ClinicProfileScreen(
                                        clinicName: entry.clinicName,
                                        city: entry.city.isNotEmpty
                                            ? entry.city
                                            : entry.locationLabel,
                                      ),
                                    ),
                                  );
                                },
                              ),
                            );
                          },
                          childCount: entries.length,
                        ),
                      ),
                    ),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(24, 4, 24, 28 + bottomPad),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.info_outline_rounded,
                              size: 14, color: ProcedureSelectionTheme.muted),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Prices are per session / procedure and may vary.\nRatings based on patient reviews.',
                              style: ProcedureSelectionTypography.body(
                                size: 10,
                                color: ProcedureSelectionTheme.muted,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  static String _initials(String name) {
    if (name == _catLipFillerKey) return 'LF';
    if (name.startsWith('CAT:')) {
      final raw = name.substring('CAT:'.length);
      if (raw.isEmpty) return '?';
      // Use first two letters of the bucket key for a consistent badge.
      return raw.length == 1
          ? raw.toUpperCase()
          : raw.substring(0, 2).toUpperCase();
    }
    final parts = name.split(RegExp(r'\s+')).where((e) => e.isNotEmpty).take(2);
    if (parts.isEmpty) return '?';
    return parts.map((p) => p[0].toUpperCase()).join();
  }
}

class _CircleBtn extends StatelessWidget {
  const _CircleBtn({required this.icon, required this.onTap});

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
            width: 36,
            height: 36,
            child: Icon(icon, size: 18, color: ProcedureSelectionTheme.ink),
          ),
        ),
      ),
    );
  }
}

class _MinRatingChip extends StatelessWidget {
  const _MinRatingChip({
    required this.value,
    required this.selected,
    required this.onTap,
  });

  final double value;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final label = value == 0 ? 'Any' : '${value.toStringAsFixed(1)}+';
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: selected ? 0.28 : 0.18),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: Colors.white.withValues(alpha: selected ? 0.38 : 0.18),
            width: 1,
          ),
        ),
        child: Text(
          label,
          style: ProcedureSelectionTypography.label(
            size: 12,
            weight: FontWeight.w600,
            color: Colors.white.withValues(alpha: selected ? 0.92 : 0.72),
          ),
        ),
      ),
    );
  }
}

class _OverviewTile extends StatelessWidget {
  const _OverviewTile({
    required this.iconBg,
    required this.iconColor,
    required this.icon,
    required this.label,
    required this.value,
    required this.caption,
  });

  final Color iconBg;
  final Color iconColor;
  final IconData icon;
  final String label;
  final String value;
  final String caption;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 12, 10, 12),
      decoration: BoxDecoration(
        color: ProcedureSelectionTheme.fieldFill,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: iconBg,
              borderRadius: BorderRadius.circular(8),
            ),
            alignment: Alignment.center,
            child: Icon(icon, size: 16, color: iconColor),
          ),
          const SizedBox(height: 10),
          Text(
            label,
            style: ProcedureSelectionTypography.body(
              size: 10,
              color: ProcedureSelectionTheme.muted,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: ProcedureSelectionTypography.label(
              size: 13,
              weight: FontWeight.w700,
              color: ProcedureSelectionTheme.ink,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            caption,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: ProcedureSelectionTypography.body(
              size: 10,
              color: ProcedureSelectionTheme.muted,
            ),
          ),
        ],
      ),
    );
  }
}

class _CompareClinicCard extends StatelessWidget {
  const _CompareClinicCard({
    required this.entry,
    required this.isBestPrice,
    required this.isHighestRating,
    required this.onUnsave,
    required this.onOpen,
  });

  final SavedBookmarkEntry entry;
  final bool isBestPrice;
  final bool isHighestRating;
  final VoidCallback onUnsave;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final price = entry.priceLabel.trim();
    final procedure = entry.procedureName.trim();

    return ProcedureGlassSurface(
      borderRadius: BorderRadius.circular(ProcedureSelectionTheme.cardRadius),
      compact: true,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(ProcedureSelectionTheme.cardRadius),
          onTap: onOpen,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 12, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (isBestPrice || isHighestRating)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        if (isBestPrice)
                          _Badge(
                            label: 'BEST PRICE',
                            bg: const Color(0xFFE8F5E9),
                            fg: const Color(0xFF2E7D32),
                          ),
                        if (isHighestRating)
                          _Badge(
                            label: 'HIGHEST RATING',
                            bg: const Color(0xFFFFF8E1),
                            fg: const Color(0xFFF9A825),
                          ),
                      ],
                    ),
                  ),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: Color(entry.avatarColor),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        entry.initials,
                        style: ProcedureSelectionTypography.display(
                          size: 14,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            procedure.isEmpty ? entry.clinicName : procedure,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: ProcedureSelectionTypography.label(
                              size: 12,
                              weight: FontWeight.w700,
                              color: ProcedureSelectionTheme.ink,
                            ),
                          ),
                          if (procedure.isNotEmpty) ...[
                            const SizedBox(height: 3),
                            Row(
                              children: [
                                if (entry.rating > 0) ...[
                                  Icon(
                                    Icons.star_outline_rounded,
                                    size: 12,
                                    color: ProcedureSelectionTheme.ink.withValues(alpha: 0.9),
                                  ),
                                  const SizedBox(width: 2),
                                  Text(
                                    entry.rating.toStringAsFixed(1),
                                    style: ProcedureSelectionTypography.label(
                                      size: 11,
                                      weight: FontWeight.w700,
                                      color: ProcedureSelectionTheme.ink,
                                    ),
                                  ),
                                  const SizedBox(width: 5),
                                ],
                                Expanded(
                                  child: Text(
                                    entry.clinicName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: ProcedureSelectionTypography.label(
                                      size: 11,
                                      weight: FontWeight.w600,
                                      color: ProcedureSelectionTheme.ink
                                          .withValues(alpha: 0.78),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              Icon(Icons.place_outlined,
                                  size: 12,
                                  color: ProcedureSelectionTheme.ink),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  entry.locationLabel,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: ProcedureSelectionTypography.body(
                                    size: 11,
                                    color: ProcedureSelectionTheme.muted,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        if (price.isNotEmpty)
                          Text(
                            price,
                            textAlign: TextAlign.right,
                            style: ProcedureSelectionTypography.label(
                              size: 13,
                              weight: FontWeight.w700,
                              color: ProcedureSelectionTheme.ink,
                            ),
                          ),
                        SizedBox(height: price.isNotEmpty ? 10 : 0),
                        Material(
                          color: ProcedureSelectionTheme.buttonPrimary,
                          shape: const CircleBorder(),
                          child: InkWell(
                            customBorder: const CircleBorder(),
                            onTap: onUnsave,
                            child: const SizedBox(
                              width: 32,
                              height: 32,
                              child: Icon(Icons.favorite_rounded,
                                  size: 15, color: Colors.white),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.label, required this.bg, required this.fg});

  final String label;
  final Color bg;
  final Color fg;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: ProcedureSelectionTypography.label(
          size: 9,
          weight: FontWeight.w800,
          color: fg,
        ),
      ),
    );
  }
}
