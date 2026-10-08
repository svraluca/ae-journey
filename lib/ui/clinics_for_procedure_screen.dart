import 'dart:async' show StreamSubscription, unawaited;

import 'package:flutter/material.dart';
import '../services/openai_service.dart';
import '../services/explore_comparison_session.dart';
import 'clinic_compare_price_display.dart';
import '../services/saved_clinics_store.dart';
import 'clinic_profile_screen.dart';
import 'location_change_sheet.dart';
import 'procedure_selection_theme.dart';
import 'widgets/procedure_selection_widgets.dart';
import 'widgets/step2_warm_background.dart';

enum _SortMode { bestMatch, priceAsc, rating, nearest }

extension on _SortMode {
  String get label => switch (this) {
        _SortMode.bestMatch => 'Best match',
        _SortMode.priceAsc => 'Price ↑',
        _SortMode.rating => 'Rating',
        _SortMode.nearest => 'Nearest',
      };
}

String _clinicPriceLabel(OpenAIClinic c) =>
    clinicCompareProcedurePriceDisplay(c);

/// Right-hand price or grey honesty chip when the procedure was not verified on site.
Widget _procedureComparePriceBlock(OpenAIClinic c, {required bool hero}) {
  if (!c.hasProcedure) {
    if (hero) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          'Procedure not listed',
          style: ProcedureSelectionTypography.label(
            size: 11,
            weight: FontWeight.w700,
            color: Colors.white.withValues(alpha: 0.88),
          ).copyWith(height: 1.2),
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: ProcedureSelectionTheme.fieldFill,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        'Procedure not listed',
        style: ProcedureSelectionTypography.label(
          size: 11,
          weight: FontWeight.w600,
          color: ProcedureSelectionTheme.muted,
        ).copyWith(height: 1),
      ),
    );
  }
  if (c.pricePending) {
    final spin = SizedBox(
      width: hero ? 24 : 18,
      height: hero ? 24 : 18,
      child: CircularProgressIndicator(
        strokeWidth: 2,
        color: hero
            ? Colors.white.withValues(alpha: 0.85)
            : ProcedureSelectionTheme.ink,
      ),
    );
    return Align(alignment: Alignment.centerRight, child: spin);
  }
  return Text(
    _clinicPriceLabel(c),
    style: ProcedureSelectionTypography.display(
      size: hero ? 26 : 18,
      color: hero ? Colors.white : ProcedureSelectionTheme.ink,
    ).copyWith(height: 1),
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    textAlign: TextAlign.end,
  );
}

String _starsForRating(double r) {
  final full = r.floor().clamp(0, 5);
  final hasHalf = (r - full) >= 0.5;
  final filled = '★' * full + (hasHalf ? '★' : '');
  final empty = '☆' * (5 - filled.length);
  return '$filled$empty';
}

// ── Constants ────────────────────────────────────────────────────────────────

const _allBrands = 'All brands';
const _pageSize = 5;

const _favPink = Color(0xFFE85C5C);

int _savedClinicAvatarColor(String name) {
  final h = name.hashCode & 0x7FFFFFFF;
  const palette = <int>[
    0xFF1A1A2E,
    0xFF5548A0,
    0xFF237A42,
    0xFFC4607A,
    0xFF2D6A8E,
  ];
  return palette[h % palette.length];
}

/// Splits combined brand strings from the model into separate filter labels.
List<String> _splitBrandTokens(String brand) {
  final s = brand.trim();
  if (s.isEmpty) return const [];
  return s
      .split(RegExp(r'[,;/|]+'))
      .map((t) => t.trim())
      .where((t) => t.isNotEmpty)
      .toList();
}

// ── Screen ───────────────────────────────────────────────────────────────────

class ClinicsForProcedureScreen extends StatefulWidget {
  const ClinicsForProcedureScreen({
    super.key,
    required this.procedureName,
    required this.city,
    this.aliases = const [],
    this.isClinicNameSearch = false,
    this.seedNames = const [],
  });

  final String procedureName;
  final String city;
  final List<String> aliases;
  final bool isClinicNameSearch;
  final List<String> seedNames;

  @override
  State<ClinicsForProcedureScreen> createState() =>
      _ClinicsForProcedureScreenState();
}

class _ClinicsForProcedureScreenState
    extends State<ClinicsForProcedureScreen> {
  late String _city;
  bool _isLoading = false;
  bool _isLoadingMore = false;
  bool _hasMore = false;
  String? _error;
  String? _loadMoreError;
  String _indexStatus = '';
  int _listBuildId = 0;
  /// After "Find more clinics" returns no new rows, hide that affordance.
  bool _aiExtendExhausted = false;

  final List<OpenAIClinic> _allClinics = [];
  String _rangeLabel = '';
  String _selectedBrand = _allBrands;
  _SortMode _sort = _SortMode.bestMatch;

  final _openAI = OpenAIService();
  StreamSubscription<OpenAIComparisonResult>? _clinicsSub;

  @override
  void initState() {
    super.initState();
    _city = widget.city;
    _loadFirstPage();
  }

  @override
  void dispose() {
    _clinicsSub?.cancel();
    super.dispose();
  }

  List<String> get _loadedNames => _allClinics.map((c) => c.name).toList();

  List<String> get _availableBrands {
    if (widget.isClinicNameSearch) return const [_allBrands];
    // Lowercase key → preferred display casing (first spelling seen).
    final byKey = <String, String>{};
    for (final c in _allClinics) {
      for (final t in _splitBrandTokens(c.brand)) {
        final key = t.toLowerCase();
        byKey.putIfAbsent(key, () => t);
      }
    }
    final sorted = byKey.values.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return [_allBrands, ...sorted];
  }

  List<OpenAIClinic> get _visibleClinics {
    Iterable<OpenAIClinic> filtered = _allClinics;
    if (!widget.isClinicNameSearch && _selectedBrand != _allBrands) {
      final want = _selectedBrand.toLowerCase();
      filtered = filtered.where(
        (c) => _splitBrandTokens(c.brand)
            .any((t) => t.toLowerCase() == want),
      );
    }
    final list = filtered.toList();
    switch (_sort) {
      case _SortMode.bestMatch:
        list.sort((a, b) => a.rank.compareTo(b.rank));
      case _SortMode.priceAsc:
        // When sorting by price, hide "Price on request" clinics — they
        // can't be compared meaningfully.
        final priced = list.where((c) => c.priceMin > 0).toList();
        double anchor(OpenAIClinic c) {
          if (!c.hasProcedure) return double.infinity;
          return c.priceMin > 0 ? c.priceMin : c.priceGbp.toDouble();
        }
        priced.sort((a, b) => anchor(a).compareTo(anchor(b)));
        list
          ..clear()
          ..addAll(priced);
      case _SortMode.rating:
        list.sort((a, b) => b.rating.compareTo(a.rating));
      case _SortMode.nearest:
        list.sort((a, b) => a.distanceMi.compareTo(b.distanceMi));
    }
    return [
      for (var i = 0; i < list.length; i++) list[i].copyWith(rank: i + 1),
    ];
  }

  int _bestValueIndex(List<OpenAIClinic> visible) {
    if (visible.isEmpty) return -1;
    double anchor(OpenAIClinic c) {
      if (!c.hasProcedure) return double.infinity;
      return c.priceMin > 0 ? c.priceMin : c.priceGbp.toDouble();
    }
    var idx = 0;
    var minP = anchor(visible.first);
    for (var i = 1; i < visible.length; i++) {
      final v = anchor(visible[i]);
      if (v < minP) {
        minP = v;
        idx = i;
      }
    }
    return idx;
  }

  Future<void> _mergeEnrichedProcedureBatch(List<String> excludeNames) async {
    if (widget.isClinicNameSearch) return;
    try {
      OpenAIComparisonResult? res;
      await for (final r in _openAI.buildClinicsList(
        procedure: widget.procedureName,
        city: _city,
        count: _pageSize,
        excludeNames: excludeNames,
        aliases: widget.aliases,
      )) {
        res = r;
      }
      if (res == null || !mounted) return;
      final merged = res;
      setState(() {
        for (final fresh in merged.clinics) {
          final ix = _allClinics.indexWhere((c) => c.name == fresh.name);
          if (ix >= 0) {
            _allClinics[ix] = fresh.copyWith(rank: _allClinics[ix].rank);
          }
        }
      });
    } catch (_) {}
  }

  /// Merges background price scrape results from cache into the visible list.
  void _startProcedurePriceRefreshPoll() {
    if (widget.isClinicNameSearch) return;
    unawaited(() async {
      for (var attempt = 0; attempt < 48 && mounted; attempt++) {
        if (!_allClinics.any((c) => c.pricePending)) return;
        await Future<void>.delayed(const Duration(milliseconds: 650));
        if (!mounted || !_allClinics.any((c) => c.pricePending)) return;

        await _mergeEnrichedProcedureBatch(const []);
        if (!mounted) return;

        if (_allClinics.length > 5) {
          final firstFive = _allClinics.take(5).map((c) => c.name).toList();
          if (_allClinics.skip(5).any((c) => c.pricePending)) {
            await _mergeEnrichedProcedureBatch(firstFive);
          }
        }
      }
    }());
  }

  Future<void> _loadFirstPage() async {
    final buildId = ++_listBuildId;
    final city = _city;
    await _clinicsSub?.cancel();
    if (!_isCurrentList(buildId, city)) return;
    _clinicsSub = null;
    setState(() {
      _isLoading = true;
      _isLoadingMore = false;
      _error = null;
      _loadMoreError = null;
      _indexStatus = '';
      _allClinics.clear();
      _selectedBrand = _allBrands;
      _hasMore = false;
      _aiExtendExhausted = false;
    });
    if (widget.isClinicNameSearch) {
      try {
        final res = await _openAI.buildClinicsListByNameSearch(
          nameQuery: widget.procedureName,
          city: _city,
          count: _pageSize,
          seedNames: widget.seedNames,
        );
        if (!_isCurrentList(buildId, city)) return;
        setState(() {
          _allClinics.addAll(res.clinics);
          _indexStatus = res.summary;
          _rangeLabel = res.rangeLabel;
          _isLoading = false;
          _hasMore = res.clinics.isNotEmpty;
        });
      } catch (e) {
        if (!_isCurrentList(buildId, city)) return;
        setState(() {
          _isLoading = false;
          _error = e.toString();
        });
      }
    } else {
      _loadPage();
      _startProcedurePriceRefreshPoll();
    }
  }

  bool _isCurrentList(int buildId, String city) =>
      mounted && buildId == _listBuildId && city == _city;

  void _mergeVisibleClinics(Iterable<OpenAIClinic> incoming) {
    for (final clinic in incoming) {
      final index = _allClinics.indexWhere(
        (old) => exploreClinicsAreSameProvider(old, clinic),
      );
      if (index >= 0) {
        final previous = _allClinics[index];
        final merged = mergeExploreClinicRecord(previous, clinic);
        final checkedAt = clinic.priceVerifiedAt;
        final adoptCheck = checkedAt != null &&
            (previous.priceVerifiedAt == null ||
                !checkedAt.isBefore(previous.priceVerifiedAt!)) &&
            merged.priceMin == clinic.priceMin &&
            merged.priceSourceUrl == clinic.priceSourceUrl;
        _allClinics[index] = merged.copyWith(
          rank: previous.rank,
          priceVerifiedAt: adoptCheck ? checkedAt : previous.priceVerifiedAt,
        );
      } else {
        _allClinics.add(clinic.copyWith(rank: _allClinics.length + 1));
      }
    }
  }

  void _updateHasMore() {
    final names = _allClinics.map((c) => c.name).toList();
    _hasMore = _openAI.getRemainingCount(
          procedure: widget.procedureName, city: _city,
          alreadyShownNames: names,
        ) > 0 ||
        (_openAI.reachedEndOfCachedBatch(
          procedure: widget.procedureName, city: _city,
          alreadyShownNames: names,
        ) && !_aiExtendExhausted);
  }

  void _loadPage() {
    final buildId = _listBuildId;
    final city = _city;
    _clinicsSub = _openAI
        .buildClinicsList(
          procedure: widget.procedureName,
          city: city,
          count: _pageSize,
          aliases: widget.aliases,
        )
        .listen(
          (result) {
            if (!_isCurrentList(buildId, city)) return;
            setState(() {
              _indexStatus = result.summary;
              _isLoading = false;
              _error = null;
              if (result.clinics.isEmpty) {
                // An empty initial snapshot leaves the worker subscription open.
                _hasMore = true;
                return;
              }
              final visible = _allClinics.isEmpty
                  ? [
                      ...result.clinics.where(
                        (c) => !c.pricePending || c.priceMin > 0,
                      ),
                      ...result.clinics.where(
                        (c) => c.pricePending && c.priceMin <= 0,
                      ).take(3),
                    ]
                  : result.clinics;
              // A background snapshot updates providers without erasing pages
              // already loaded or adding a second card for the same clinic.
              _mergeVisibleClinics(visible);
              _rangeLabel = result.rangeLabel;
              _updateHasMore();
            });
          },
          onError: (Object e) {
            debugPrint('[GP] Clinics stream error: $e');
            if (_isCurrentList(buildId, city)) {
              setState(() {
                _isLoading = false;
                _error = e.toString();
              });
            }
          },
          onDone: () {
            if (_isCurrentList(buildId, city)) {
              setState(() => _isLoading = false);
            }
          },
        );
  }

  Future<void> _loadMore() async {
    if (_isLoadingMore) return;
    final buildId = _listBuildId;
    final city = _city;
    setState(() {
      _isLoadingMore = true;
      _loadMoreError = null;
    });

    if (widget.isClinicNameSearch) {
      try {
        final resFinal = await _openAI.buildClinicsListByNameSearch(
          nameQuery: widget.procedureName,
          city: _city,
          count: _pageSize,
          excludeNames: _loadedNames,
          seedNames: widget.seedNames,
        );
        if (!_isCurrentList(buildId, city)) return;
        setState(() {
          _mergeVisibleClinics(resFinal.clinics);
          _isLoadingMore = false;
          _hasMore = resFinal.clinics.isNotEmpty;
        });
        _startProcedurePriceRefreshPoll();
      } catch (e) {
        if (e.toString().contains('insufficient_quota') ||
            e.toString().contains('quota exhausted')) {
          if (_isCurrentList(buildId, city)) {
            setState(() => _isLoadingMore = false);
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'Service temporarily unavailable — please try again later',
                ),
                duration: Duration(seconds: 4),
              ),
            );
          }
          return;
        }
        if (!_isCurrentList(buildId, city)) return;
        setState(() {
          _isLoadingMore = false;
          _loadMoreError = 'Could not load more. Tap to retry.';
        });
      }
      return;
    }

    try {
      final countBefore = _allClinics.length;
      final currentNames = _allClinics.map((c) => c.name).toList();

      final cached = _openAI.getNextPageFromCache(
        procedure: widget.procedureName,
        city: _city,
        alreadyShownNames: currentNames,
        pageSize: _pageSize,
      );

      if (cached != null && cached.isNotEmpty) {
        debugPrint('[GP] Load more from cache: ${cached.length} clinics');
        if (!_isCurrentList(buildId, city)) return;
        setState(() {
          _mergeVisibleClinics(cached);
          final names = _allClinics.map((c) => c.name).toList();
          _hasMore = _openAI.getRemainingCount(
                procedure: widget.procedureName,
                city: _city,
                alreadyShownNames: names,
              ) >
              0 ||
              (_openAI.reachedEndOfCachedBatch(
                    procedure: widget.procedureName,
                    city: _city,
                    alreadyShownNames: names,
                  ) &&
                  !_aiExtendExhausted);
        });
        _startProcedurePriceRefreshPoll();
        return;
      }

      debugPrint('[GP] Load more cache miss — requesting discovery');
      await for (final result in _openAI.buildClinicsList(
        procedure: widget.procedureName,
        city: _city,
        count: _pageSize,
        excludeNames: currentNames,
        aliases: widget.aliases,
      )) {
        if (!_isCurrentList(buildId, city)) return;
        setState(() {
          _indexStatus = result.summary;
          _mergeVisibleClinics(result.clinics);
          final names = _allClinics.map((c) => c.name).toList();
          _hasMore = _openAI.getRemainingCount(
                procedure: widget.procedureName,
                city: _city,
                alreadyShownNames: names,
              ) >
              0 ||
              (_openAI.reachedEndOfCachedBatch(
                    procedure: widget.procedureName,
                    city: _city,
                    alreadyShownNames: names,
                  ) &&
                  !_aiExtendExhausted);
        });
      }
      if (_isCurrentList(buildId, city) && _allClinics.length == countBefore) {
        setState(() => _aiExtendExhausted = true);
      }
      if (_isCurrentList(buildId, city)) _startProcedurePriceRefreshPoll();
    } catch (e) {
      debugPrint('[GP] Load more error: $e');
      if (e.toString().contains('insufficient_quota') ||
          e.toString().contains('quota exhausted')) {
        if (_isCurrentList(buildId, city)) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Service temporarily unavailable — please try again later',
              ),
              duration: Duration(seconds: 4),
            ),
          );
        }
      } else if (_isCurrentList(buildId, city)) {
        setState(() {
          _loadMoreError = 'Could not load more. Tap to retry.';
        });
      }
    } finally {
      if (_isCurrentList(buildId, city)) setState(() => _isLoadingMore = false);
    }
  }

  Future<void> _changeCity() async {
    final picked =
        await showLocationChangeSheet(context, selectedCity: _city);
    if (picked == null || !mounted) return;
    setState(() => _city = picked.displayName);
    _loadFirstPage();
  }

  /// Extracts the website URL from the area string.
  /// "București · drestetix.ro · 0.0 mi" → "https://drestetix.ro/"
  /// "Sector 1 · ultraestetic.ro · 1.2 mi" → "https://ultraestetic.ro/"
  String? _websiteFromArea(String area) {
    for (final part in area.split('·')) {
      final t = part.trim();
      if (t.contains('.') &&
          !t.contains(' ') &&
          !RegExp(r'^\d').hasMatch(t) &&
          t.length > 4) {
        final domain = t.endsWith('/') ? t : '$t/';
        return 'https://$domain';
      }
    }
    return null;
  }

  void _openClinicDetail(OpenAIClinic clinic) {
    if (!widget.isClinicNameSearch) return;
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ClinicProfileScreen(
          clinicName: clinic.name,
          city: _city,
          websiteUrl: _websiteFromArea(clinic.area),
        ),
      ),
    );
  }

  void _toggleFavorite(OpenAIClinic c) {
    final proc = widget.procedureName.trim();
    final store = SavedClinicsStore.instance;
    if (store.contains(c.name, proc)) {
      store.remove(c.name, proc);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Removed from saved clinics')),
      );
    } else {
      final tags = <String>[];
      if (c.brand.trim().isNotEmpty) tags.add(c.brand.trim());
      final price = _clinicPriceLabel(c);
      if (c.hasProcedure) {
        if (price.isNotEmpty) tags.add(price);
      } else {
        tags.add('Procedure not listed');
      }
      store.add(
        SavedClinicEntry(
          name: c.name,
          area: c.area,
          city: _city,
          priceLabel: price,
          rating: c.rating,
          tags: tags,
          avatarColor: _savedClinicAvatarColor(c.name),
          procedure: proc,
        ),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Saved — open Saved to view')),
      );
    }
  }

  bool _isFavorite(OpenAIClinic c) =>
      SavedClinicsStore.instance.contains(c.name, widget.procedureName.trim());

  // ── build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        const Step2WarmBackground(),
        Scaffold(
          backgroundColor: Colors.transparent,
          // Fixed nav + Expanded content — structure never changes on setState,
          // so the semantics tree stays stable across loading/content transitions.
          body: Column(
            children: [
              SafeArea(bottom: false, child: _buildTopNav()),
              Expanded(child: _buildBody()),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildBody() {
    if (_isLoading) return _buildLoading();
    if (_error != null) return _buildError();

    return AnimatedBuilder(
      animation: SavedClinicsStore.instance,
      builder: (context, _) {
        final visible = _visibleClinics;
        final bestIdx = _bestValueIndex(visible);
        return _buildList(visible, bestIdx);
      },
    );
  }

  // ── Loading ───────────────────────────────────────────────────────────────

  Widget _buildLoading() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: ProcedureSelectionTheme.ink,
              ),
            ),
            const SizedBox(height: 18),
            Text(
              'Finding clinics…',
              style: ProcedureSelectionTypography.label(
                size: 15,
                weight: FontWeight.w600,
                color: ProcedureSelectionTheme.ink,
              ).copyWith(letterSpacing: -0.2),
            ),
            const SizedBox(height: 8),
            Text(
              widget.isClinicNameSearch
                  ? _city
                  : '${widget.procedureName} · $_city',
              style: ProcedureSelectionTypography.body(
                size: 13,
                color: ProcedureSelectionTheme.muted,
              ),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  // ── Error ─────────────────────────────────────────────────────────────────

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline_rounded,
                size: 40, color: Color(0xFFDD4444)),
            const SizedBox(height: 12),
            Text(
              'Something went wrong',
              style: ProcedureSelectionTypography.label(
                size: 14,
                weight: FontWeight.w700,
                color: ProcedureSelectionTheme.ink,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              _error!,
              style: ProcedureSelectionTypography.body(
                size: 11,
                color: ProcedureSelectionTheme.muted,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(999),
                onTap: _loadFirstPage,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 24, vertical: 12),
                  decoration: BoxDecoration(
                    color: ProcedureSelectionTheme.buttonPrimary,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    'Try again',
                    style: ProcedureSelectionTypography.label(
                      size: 13,
                      weight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── List ──────────────────────────────────────────────────────────────────

  Widget _buildList(List<OpenAIClinic> visible, int bestIdx) {
    // Build a flat list of items so every child is a direct ListView item —
    // no Column-with-for-loop nesting. Keys prevent render-object reuse bugs.
    final items = <Widget>[
      const SizedBox(height: 16),
      _MetaTitle(
        key: const ValueKey('meta'),
        procedureName: widget.procedureName,
        city: _city,
        allClinics: _allClinics,
        visibleCount: visible.length,
        rangeLabel: _rangeLabel,
        selectedBrand: _selectedBrand,
        isClinicNameSearch: widget.isClinicNameSearch,
      ),
      if (!widget.isClinicNameSearch) ...[
        const SizedBox(height: 14),
        _BrandPillRow(
          key: const ValueKey('brands'),
          brands: _availableBrands,
          selected: _selectedBrand,
          onSelect: (b) => setState(() => _selectedBrand = b),
        ),
      ],
      const SizedBox(height: 10),
      _SortPillRow(
        key: const ValueKey('sorts'),
        current: _sort,
        onSelect: (m) => setState(() => _sort = m),
      ),
      const SizedBox(height: 18),
      Padding(
        key: const ValueKey('divider'),
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Container(
          height: 1,
          color: ProcedureSelectionTheme.ink.withValues(alpha: 0.06),
        ),
      ),
    ];

    if (visible.isEmpty) {
      items.add(
        Padding(
          key: const ValueKey('empty'),
          padding: const EdgeInsets.all(40),
          child: Center(
            child: Text(
              _allClinics.isEmpty
                  ? (_indexStatus.isNotEmpty
                      ? _indexStatus
                      : widget.isClinicNameSearch
                          ? 'No matching clinic found. Check the name or city.'
                          : 'No verified public prices found yet. Try Find more clinics.')
                  : 'No clinics match this filter.',
              style: ProcedureSelectionTypography.body(
                size: 13,
                color: ProcedureSelectionTheme.muted,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    } else {
      items.add(const SizedBox(key: ValueKey('gap-hero'), height: 16));
      items.add(
        Padding(
          key: ValueKey('hero-${visible.first.name}'),
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: _HeroTopCard(
            clinic: visible.first,
            onOpenTap: widget.isClinicNameSearch
                ? () => _openClinicDetail(visible.first)
                : null,
            favoriteEnabled: !widget.isClinicNameSearch,
            isFavorite: _isFavorite(visible.first),
            onFavoriteTap: !widget.isClinicNameSearch
                ? () => _toggleFavorite(visible.first)
                : null,
          ),
        ),
      );
      for (var i = 1; i < visible.length; i++) {
        final c = visible[i];
        items.add(
          Padding(
            key: ValueKey('row-${c.name}'),
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
            child: _ClinicRow(
              clinic: c,
              isBestValue: i == bestIdx,
              onOpenTap: widget.isClinicNameSearch
                  ? () => _openClinicDetail(c)
                  : null,
              favoriteEnabled: !widget.isClinicNameSearch,
              isFavorite: _isFavorite(c),
              onFavoriteTap:
                  !widget.isClinicNameSearch ? () => _toggleFavorite(c) : null,
            ),
          ),
        );
      }
    }

    items.add(const SizedBox(key: ValueKey('gap-btn'), height: 16));
    final remainingProc = !widget.isClinicNameSearch
        ? _openAI.getRemainingCount(
            procedure: widget.procedureName,
            city: _city,
            alreadyShownNames: _allClinics.map((c) => c.name).toList(),
          )
        : 0;
    final reachedEndOfBatch = !widget.isClinicNameSearch &&
        _openAI.reachedEndOfCachedBatch(
          procedure: widget.procedureName,
          city: _city,
          alreadyShownNames: _allClinics.map((c) => c.name).toList(),
        );
    final showLoadMore = widget.isClinicNameSearch
        ? (_hasMore || _isLoadingMore || _loadMoreError != null)
        : (_hasMore || remainingProc > 0 ||
            (reachedEndOfBatch && !_aiExtendExhausted) ||
            _isLoadingMore ||
            _loadMoreError != null);
    if (showLoadMore) {
      items.add(
        Padding(
          key: const ValueKey('load-more'),
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: _LoadMoreButton(
            isLoading: _isLoadingMore,
            error: _loadMoreError,
            label: !widget.isClinicNameSearch && remainingProc > 0
                ? 'Load more clinics ($remainingProc more)'
                : (!widget.isClinicNameSearch &&
                        reachedEndOfBatch &&
                        !_aiExtendExhausted
                    ? 'Find more clinics'
                    : null),
            onTap: _loadMoreError != null
                ? () {
                    setState(() => _loadMoreError = null);
                    _loadMore();
                  }
                : _loadMore,
          ),
        ),
      );
    }
    items.add(const SizedBox(key: ValueKey('bottom-pad'), height: 32));

    return ListView(
      padding: EdgeInsets.zero,
      // All children are keyed; no nested scrollables; no Column-with-for-loop.
      children: items,
    );
  }

  // ── Top nav ───────────────────────────────────────────────────────────────

  Widget _buildTopNav() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 6, 20, 6),
      child: Row(
        children: [
          ProcedureGlassSurface(
            borderRadius: BorderRadius.circular(999),
            compact: true,
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(999),
                onTap: () => Navigator.of(context).pop(),
                child: const SizedBox(
                  width: 40,
                  height: 40,
                  child: Icon(
                    Icons.chevron_left_rounded,
                    size: 22,
                    color: ProcedureSelectionTheme.ink,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: ProcedureGlassSurface(
              borderRadius: BorderRadius.circular(16),
              compact: true,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                child: Row(
                  children: [
                    Icon(Icons.search_rounded,
                        size: 16, color: ProcedureSelectionTheme.muted),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        widget.procedureName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ProcedureSelectionTypography.label(
                          size: 14,
                          weight: FontWeight.w700,
                          color: ProcedureSelectionTheme.ink,
                        ),
                      ),
                    ),
                    GestureDetector(
                      onTap: () => Navigator.of(context).pop(),
                      behavior: HitTestBehavior.opaque,
                      child: Icon(Icons.close_rounded,
                          size: 16, color: ProcedureSelectionTheme.muted),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          ProcedureGlassSurface(
            borderRadius: BorderRadius.circular(999),
            compact: true,
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(999),
                onTap: _changeCity,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.place_rounded,
                          size: 13, color: ProcedureSelectionTheme.ink),
                      const SizedBox(width: 4),
                      Text(
                        _city,
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
          ),
        ],
      ),
    );
  }
}

// ── Meta title ────────────────────────────────────────────────────────────────

class _MetaTitle extends StatelessWidget {
  const _MetaTitle({
    super.key,
    required this.procedureName,
    required this.city,
    required this.allClinics,
    required this.visibleCount,
    required this.rangeLabel,
    required this.selectedBrand,
    required this.isClinicNameSearch,
  });

  final String procedureName;
  final String city;
  final List<OpenAIClinic> allClinics;
  final int visibleCount;
  final String rangeLabel;
  final String selectedBrand;
  final bool isClinicNameSearch;

  @override
  Widget build(BuildContext context) {
    final count = visibleCount > 0 ? visibleCount : allClinics.length;
    final plus = visibleCount == allClinics.length ? '+' : '';
    final rangeSuffix = rangeLabel.isNotEmpty ? ' · $rangeLabel' : '';
    final brandSuffix =
        (!isClinicNameSearch && selectedBrand != _allBrands)
            ? ' · $selectedBrand'
            : '';
    final subtitle = isClinicNameSearch
        ? '$rangeSuffix · $city · Name search'
        : '$rangeSuffix$brandSuffix · AI results';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ProcedureSectionLabel(city),
          const SizedBox(height: 8),
          Text(
            procedureName,
            style: ProcedureSelectionTypography.display(
              size: 24,
              color: ProcedureSelectionTheme.ink,
            ),
          ),
          const SizedBox(height: 8),
          Text.rich(TextSpan(children: [
            TextSpan(
              text: '$count$plus clinics',
              style: ProcedureSelectionTypography.body(
                size: 13,
                weight: FontWeight.w700,
                color: ProcedureSelectionTheme.ink,
              ),
            ),
            TextSpan(
              text: subtitle,
              style: ProcedureSelectionTypography.body(
                size: 13,
                color: ProcedureSelectionTheme.muted,
              ),
            ),
          ])),
        ],
      ),
    );
  }
}

// ── Brand pill row ────────────────────────────────────────────────────────────

class _BrandPillRow extends StatelessWidget {
  const _BrandPillRow({
    super.key,
    required this.brands,
    required this.selected,
    required this.onSelect,
  });
  final List<String> brands;
  final String selected;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: [
          for (var i = 0; i < brands.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            _Pill(
              text: brands[i],
              active: brands[i] == selected,
              onTap: () => onSelect(brands[i]),
            ),
          ],
        ],
      ),
    );
  }
}

// ── Sort pill row ─────────────────────────────────────────────────────────────

class _SortPillRow extends StatelessWidget {
  const _SortPillRow({
    super.key,
    required this.current,
    required this.onSelect,
  });
  final _SortMode current;
  final ValueChanged<_SortMode> onSelect;

  @override
  Widget build(BuildContext context) {
    final modes = _SortMode.values;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: [
          for (var i = 0; i < modes.length; i++) ...[
            if (i > 0) const SizedBox(width: 7),
            _Pill(
              text: modes[i].label,
              active: modes[i] == current,
              onTap: () => onSelect(modes[i]),
            ),
          ],
        ],
      ),
    );
  }
}

// ── Reusable pill ─────────────────────────────────────────────────────────────

class _Pill extends StatelessWidget {
  const _Pill({
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
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            child: Text(
              text,
              style: ProcedureSelectionTypography.chip(
                size: 12,
                weight: FontWeight.w700,
                color: active ? Colors.white : ProcedureSelectionTheme.muted,
              ).copyWith(height: 1),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Hero top card ─────────────────────────────────────────────────────────────

class _HeroTopCard extends StatelessWidget {
  const _HeroTopCard({
    required this.clinic,
    this.onOpenTap,
    this.favoriteEnabled = false,
    this.isFavorite = false,
    this.onFavoriteTap,
  });
  final OpenAIClinic clinic;
  final VoidCallback? onOpenTap;
  final bool favoriteEnabled;
  final bool isFavorite;
  final VoidCallback? onFavoriteTap;

  @override
  Widget build(BuildContext context) {
    final whiteSoft = Colors.white.withValues(alpha: 0.55);
    final whiteFaint = Colors.white.withValues(alpha: 0.4);

    final content = Padding(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                alignment: Alignment.center,
                child: Text(
                  '${clinic.rank}',
                  style: ProcedureSelectionTypography.label(
                    size: 13,
                    weight: FontWeight.w800,
                    color: Colors.white,
                  ).copyWith(height: 1),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  'TOP MATCH',
                  style: ProcedureSelectionTypography.chip(
                    size: 10,
                    weight: FontWeight.w800,
                    color: whiteSoft,
                  ).copyWith(letterSpacing: 1.0),
                ),
              ),
              const Spacer(),
              if (favoriteEnabled) ...[
                Material(
                  color: Colors.white.withValues(alpha: 0.12),
                  shape: const CircleBorder(),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: onFavoriteTap,
                    child: Padding(
                      padding: const EdgeInsets.all(9),
                      child: Icon(
                        isFavorite
                            ? Icons.favorite_rounded
                            : Icons.favorite_border_rounded,
                        size: 20,
                        color: isFavorite
                            ? _favPink
                            : Colors.white.withValues(alpha: 0.55),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '★ Top rated',
                  style: ProcedureSelectionTypography.chip(
                    size: 11,
                    weight: FontWeight.w700,
                    color: Colors.white.withValues(alpha: 0.7),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            clinic.name,
            style: ProcedureSelectionTypography.display(
              size: 21,
              color: Colors.white,
            ).copyWith(height: 1.15),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Icon(Icons.place_rounded, size: 11, color: whiteSoft),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  clinic.distanceMi > 0
                      ? '${clinic.area} · ${clinic.distanceMi.toStringAsFixed(1)} mi'
                      : clinic.area,
                  style: ProcedureSelectionTypography.body(
                    size: 12,
                    color: whiteSoft,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Row(
                  children: [
                    const Text('★★★★★',
                        style: TextStyle(
                            color: Color(0xFFF5C842), fontSize: 13)),
                    const SizedBox(width: 5),
                    Text(
                      clinic.rating.toStringAsFixed(1),
                      style: ProcedureSelectionTypography.label(
                        size: 13,
                        weight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(width: 5),
                    Flexible(
                      child: Text(
                        '(${clinic.reviews} reviews)',
                        style: ProcedureSelectionTypography.body(
                          size: 12,
                          color: whiteFaint,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  _procedureComparePriceBlock(clinic, hero: true),
                  if (clinic.brand.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      clinic.brand.toUpperCase(),
                      style: ProcedureSelectionTypography.chip(
                        size: 10,
                        weight: FontWeight.w600,
                        color: whiteFaint,
                      ).copyWith(letterSpacing: 0.8),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ],
      ),
    );

    final card = ProcedureGlassSurface(
      borderRadius: BorderRadius.circular(20),
      selected: true,
      child: content,
    );

    if (onOpenTap != null) {
      return Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onOpenTap,
          child: card,
        ),
      );
    }
    return card;
  }
}

// ── Clinic row ────────────────────────────────────────────────────────────────

class _ClinicRow extends StatelessWidget {
  const _ClinicRow({
    required this.clinic,
    required this.isBestValue,
    this.onOpenTap,
    this.favoriteEnabled = false,
    this.isFavorite = false,
    this.onFavoriteTap,
  });

  final OpenAIClinic clinic;
  final bool isBestValue;
  final VoidCallback? onOpenTap;
  final bool favoriteEnabled;
  final bool isFavorite;
  final VoidCallback? onFavoriteTap;

  @override
  Widget build(BuildContext context) {
    final rankBg = isBestValue
        ? const Color(0xFFE8F5EE)
        : ProcedureSelectionTheme.fieldFill;
    final rankFg = isBestValue
        ? const Color(0xFF237A42)
        : ProcedureSelectionTheme.muted;
    final (tone, badgeText) = _resolveBadge(clinic, isBestValue);

    final body = Padding(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
                color: rankBg, borderRadius: BorderRadius.circular(8)),
            alignment: Alignment.center,
            child: Text(
              '${clinic.rank}',
              style: ProcedureSelectionTypography.label(
                size: 12,
                weight: FontWeight.w800,
                color: rankFg,
              ).copyWith(height: 1),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  clinic.name,
                  style: ProcedureSelectionTypography.label(
                    size: 15,
                    weight: FontWeight.w700,
                    color: ProcedureSelectionTheme.ink,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 3),
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        clinic.area,
                        style: ProcedureSelectionTypography.body(
                          size: 12,
                          color: ProcedureSelectionTheme.muted,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (clinic.distanceMi > 0) ...[
                      const SizedBox(width: 5),
                      Container(
                        width: 3,
                        height: 3,
                        decoration: BoxDecoration(
                          color:
                              ProcedureSelectionTheme.muted.withValues(alpha: 0.45),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 5),
                      Text(
                        '${clinic.distanceMi.toStringAsFixed(1)} mi',
                        style: ProcedureSelectionTypography.body(
                          size: 12,
                          color: ProcedureSelectionTheme.muted,
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 5),
                Row(
                  children: [
                    Text(
                      _starsForRating(clinic.rating),
                      style: const TextStyle(
                          color: Color(0xFFF5C842),
                          fontSize: 11,
                          letterSpacing: -1),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      clinic.rating.toStringAsFixed(1),
                      style: ProcedureSelectionTypography.label(
                        size: 12,
                        weight: FontWeight.w700,
                        color: ProcedureSelectionTheme.ink,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '(${clinic.reviews})',
                      style: ProcedureSelectionTypography.body(
                        size: 11,
                        color: ProcedureSelectionTheme.muted,
                      ),
                    ),
                    if (clinic.brand.isNotEmpty) ...[
                      const SizedBox(width: 6),
                      Flexible(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: ProcedureSelectionTheme.fieldFill,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            clinic.brand,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: ProcedureSelectionTypography.chip(
                              size: 10,
                              weight: FontWeight.w600,
                              color: ProcedureSelectionTheme.muted,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 140),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                _procedureComparePriceBlock(clinic, hero: false),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                      color: tone.$1, borderRadius: BorderRadius.circular(20)),
                  child: Text(
                    badgeText.toUpperCase(),
                    style: ProcedureSelectionTypography.chip(
                      size: 9,
                      weight: FontWeight.w700,
                      color: tone.$2,
                    ).copyWith(letterSpacing: 0.36, height: 1),
                  ),
                ),
                if (favoriteEnabled) ...[
                  const SizedBox(height: 2),
                  IconButton(
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 36,
                      minHeight: 36,
                    ),
                    visualDensity: VisualDensity.compact,
                    onPressed: onFavoriteTap,
                    icon: Icon(
                      isFavorite
                          ? Icons.favorite_rounded
                          : Icons.favorite_border_rounded,
                      size: 22,
                      color: isFavorite ? _favPink : const Color(0xFFCCCCCC),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );

    final card = ProcedureGlassSurface(
      borderRadius: BorderRadius.circular(16),
      compact: true,
      child: body,
    );

    if (onOpenTap != null) {
      return Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onOpenTap,
          child: card,
        ),
      );
    }
    return card;
  }

  static ((Color, Color), String) _resolveBadge(
      OpenAIClinic c, bool isBestValue) {
    if (isBestValue) {
      return (
        (const Color(0xFFE8F5EE), const Color(0xFF237A42)),
        'Good value'
      );
    }
    final label =
        c.badge.trim().isEmpty ? 'Recommended' : c.badge.trim();
    final lower = label.toLowerCase();
    if (lower.contains('popular')) {
      return (
        (const Color(0xFFFFF0ED), const Color(0xFFC44020)),
        label
      );
    }
    if (lower.contains('trust')) {
      return (
        (const Color(0xFFEDE8F8), const Color(0xFF5548A0)),
        label
      );
    }
    if (lower.contains('value') || lower.contains('best')) {
      return (
        (const Color(0xFFE8F5EE), const Color(0xFF237A42)),
        label
      );
    }
    if (c.badgeVariant == 'hi') {
      return (
        (const Color(0xFFEDE8F8), const Color(0xFF5548A0)),
        label
      );
    }
    return (
      (ProcedureSelectionTheme.fieldFill, ProcedureSelectionTheme.muted),
      label
    );
  }
}

// ── Load more button ──────────────────────────────────────────────────────────

class _LoadMoreButton extends StatelessWidget {
  const _LoadMoreButton({
    required this.isLoading,
    required this.error,
    this.label,
    required this.onTap,
  });
  final bool isLoading;
  final String? error;
  final String? label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 18),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          border: Border.all(
            color: ProcedureSelectionTheme.ink.withValues(alpha: 0.16),
            width: 1.5,
          ),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: ProcedureSelectionTheme.ink),
            ),
            const SizedBox(width: 10),
            Text(
              'Loading more clinics...',
              style: ProcedureSelectionTypography.label(
                size: 14,
                weight: FontWeight.w700,
                color: ProcedureSelectionTheme.ink,
              ),
            ),
          ],
        ),
      );
    }

    final isError = error != null;

    return Material(
      color:
          isError ? Colors.transparent : ProcedureSelectionTheme.buttonPrimary,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 15),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            border: isError
                ? Border.all(color: const Color(0xFFDD4444), width: 1.5)
                : null,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                error ?? label ?? 'Load more clinics',
                style: ProcedureSelectionTypography.label(
                  size: 14,
                  weight: FontWeight.w700,
                  color: isError ? const Color(0xFFDD4444) : Colors.white,
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                isError ? Icons.refresh_rounded : Icons.expand_more_rounded,
                size: 16,
                color: isError ? const Color(0xFFDD4444) : Colors.white,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
