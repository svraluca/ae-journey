import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'filter_currency.dart';
import 'openai_service.dart';

/// Curated international clinics for the free Explore **Worldwide** view.
///
/// Prices are static figures copied from each clinic’s public price list /
/// website — no AI scrape. City-level AI pricing is subscription-gated.
abstract final class WorldwideCuratedClinics {
  static const cityName = 'Worldwide';

  /// Map camera center spanning EU / Middle East / Americas roughly.
  static const mapCenter = LatLng(30.0, 10.0);
  static const mapZoom = 1.85;

  static bool isWorldwide(String city) =>
      city.trim().toLowerCase() == cityName.toLowerCase();

  /// Filter procedure types shown in Filters (free curated preview).
  static const filterProcedureTypes = <String>[
    'Injectables',
    'Botox',
    'Fillers',
    'Hair removal',
    'Skin boosters',
    'Peels',
    'Surgery',
    'Skin treatments',
    'Body treatments',
  ];

  /// One clinic per flagship category when Explore pill is **All**.
  static const allMixedCategoryPills = <String>[
    'Botox',
    'Fillers',
    'Rhinoplasty',
    'Boob job',
    'Hair',
    'Polynucleotides',
  ];

  static OpenAIComparisonResult buildComparison({String pill = 'All'}) {
    final normalized = pill.trim();
    if (normalized.isEmpty || normalized == 'All') {
      return _buildAllMixed();
    }

    final topic = _topicForPill(normalized);
    final clinics = <OpenAIClinic>[];
    for (final c in _catalog) {
      final quote = c.quoteFor(normalized);
      if (!quote.isPublished) continue;
      clinics.add(
        _toClinic(
          c,
          rank: clinics.length + 1,
          quote: quote,
        ),
      );
    }

    return OpenAIComparisonResult(
      city: cityName,
      topic: topic,
      topicType: OpenAISearchItemType.procedure,
      summary:
          'Published guide prices from clinic websites. '
          'Subscribe to unlock AI prices for a selected city.',
      rangeLabel: _procedureTitleForPill(normalized),
      mapCenter: const OpenAICoord(30.0, 10.0),
      clinics: clinics,
    );
  }

  /// Mixed Worldwide preview: one published price per flagship category.
  static OpenAIComparisonResult _buildAllMixed() {
    final picks = <({_CuratedClinic clinic, _PriceQuote quote})>[];
    final usedClinics = <String>{};

    for (final pill in allMixedCategoryPills) {
      _CuratedClinic? bestClinic;
      _PriceQuote? bestQuote;
      var bestRating = -1.0;

      for (final c in _catalog) {
        if (usedClinics.contains(c.name)) continue;
        final quote = _quoteForAllCategory(c, pill);
        if (!quote.isPublished) continue;
        if (c.rating > bestRating) {
          bestRating = c.rating;
          bestClinic = c;
          bestQuote = quote;
        }
      }

      // Re-use a clinic if every option was already taken for another category.
      if (bestClinic == null || bestQuote == null) {
        for (final c in _catalog) {
          final quote = _quoteForAllCategory(c, pill);
          if (!quote.isPublished) continue;
          if (c.rating > bestRating) {
            bestRating = c.rating;
            bestClinic = c;
            bestQuote = quote;
          }
        }
      }

      if (bestClinic == null || bestQuote == null) continue;
      usedClinics.add(bestClinic.name);
      picks.add((clinic: bestClinic, quote: bestQuote));
    }

    final clinics = <OpenAIClinic>[
      for (var i = 0; i < picks.length; i++)
        _toClinic(
          picks[i].clinic,
          rank: i + 1,
          quote: picks[i].quote,
        ),
    ];

    return OpenAIComparisonResult(
      city: cityName,
      topic: 'Top clinics · Worldwide',
      topicType: OpenAISearchItemType.procedure,
      summary:
          'Published guide prices from clinic websites. '
          'Subscribe to unlock AI prices for a selected city.',
      rangeLabel: 'Treatments',
      mapCenter: const OpenAICoord(30.0, 10.0),
      clinics: clinics,
    );
  }

  static _PriceQuote _quoteForAllCategory(_CuratedClinic c, String pill) {
    switch (pill.trim()) {
      case 'Polynucleotides':
        final booster = c.skinBooster;
        if (!booster.isPublished) return _PriceQuote.none;
        final name = booster.procedureName.toLowerCase();
        if (name.contains('polynucleotide') ||
            name.contains('profhilo') ||
            name.contains('pdrn') ||
            name.contains('rejuran') ||
            name.contains('nucleofill') ||
            name.contains('skin booster')) {
          return _PriceQuote(
            label: booster.label,
            currency: booster.currency,
            procedureName: 'Polynucleotides',
            min: booster.min,
            max: booster.max,
            published: booster.published,
          );
        }
        return _PriceQuote.none;
      default:
        return c.quoteFor(pill);
    }
  }

  /// Free-tier preview for Filters → procedure types.
  /// Returns curated clinics that publish a matching procedure price.
  static OpenAIComparisonResult buildComparisonForFilterTypes(
    Set<String> types,
  ) {
    final selected = types.map((e) => e.trim()).where((e) => e.isNotEmpty).toSet();
    if (selected.isEmpty) return buildComparison(pill: 'All');

    // Map common multi-select combos back to Explore pills (keeps title in sync).
    final pillFromTypes = _pillForFilterTypes(selected);
    if (pillFromTypes != null) {
      return buildComparison(pill: pillFromTypes);
    }

    final clinics = <OpenAIClinic>[];
    final seen = <String>{};
    for (final type in filterProcedureTypes) {
      if (!selected.contains(type)) continue;
      for (final c in _catalog) {
        final quote = c.quoteForFilterType(type);
        if (!quote.isPublished) continue;
        final key = '${c.name}|${quote.procedureName}';
        if (!seen.add(key)) continue;
        clinics.add(
          _toClinic(
            c,
            rank: clinics.length + 1,
            quote: quote,
          ),
        );
      }
    }

    final label = selected.length == 1
        ? selected.first
        : '${selected.length} procedures';

    return OpenAIComparisonResult(
      city: cityName,
      topic: '$label · Worldwide',
      topicType: OpenAISearchItemType.procedure,
      summary:
          'Curated preview from published clinic price lists. '
          'Subscribe to unlock full AI search for any city.',
      rangeLabel: label,
      mapCenter: const OpenAICoord(30.0, 10.0),
      clinics: clinics,
    );
  }

  /// Apply price / rating / preference filters on top of procedure-type matches.
  ///
  /// [priceMaxOpen] = true means the UI slider is at the open-ended max (1000+).
  static OpenAIComparisonResult buildComparisonForFilters({
    required Set<String> types,
    FilterCurrency? currency,
    required double priceMin,
    required double priceMax,
    required bool priceMaxOpen,
    required double minRating,
    required bool doctorLedOnly,
    required bool verifiedOnly,
  }) {
    final base = buildComparisonForFilterTypes(types);
    final filtered = <OpenAIClinic>[];
    for (final c in base.clinics) {
      if (c.rating + 1e-9 < minRating) continue;
      if (doctorLedOnly && !_looksDoctorLed(c.name)) continue;
      // Curated catalog entries are treated as verified partners.
      if (verifiedOnly && !_looksVerified(c.name)) continue;

      final fromCode = c.currency.trim().isNotEmpty
          ? c.currency
          : FilterFx.detectCodeFromLabel(c.priceLabel, fallback: 'USD');
      final amount = c.priceMin > 0
          ? c.priceMin
          : (FilterFx.parseAmount(c.priceLabel) ?? 0);
      if (amount <= 0) continue;
      final compared = currency == null
          ? amount
          : FilterFx.convert(
              amount: amount,
              fromCode: fromCode,
              to: currency,
            );
      if (compared + 1e-9 < priceMin) continue;
      if (!priceMaxOpen && compared - 1e-9 > priceMax) continue;
      filtered.add(c);
    }

    final clinics = <OpenAIClinic>[
      for (var i = 0; i < filtered.length; i++)
        filtered[i].copyWith(rank: i + 1),
    ];

    return OpenAIComparisonResult(
      city: base.city,
      topic: base.topic,
      topicType: base.topicType,
      summary: base.summary,
      rangeLabel: base.rangeLabel,
      mapCenter: base.mapCenter,
      clinics: clinics,
    );
  }

  static int countForFilters({
    required Set<String> types,
    FilterCurrency? currency,
    required double priceMin,
    required double priceMax,
    required bool priceMaxOpen,
    required double minRating,
    required bool doctorLedOnly,
    required bool verifiedOnly,
  }) =>
      buildComparisonForFilters(
        types: types,
        currency: currency,
        priceMin: priceMin,
        priceMax: priceMax,
        priceMaxOpen: priceMaxOpen,
        minRating: minRating,
        doctorLedOnly: doctorLedOnly,
        verifiedOnly: verifiedOnly,
      ).clinics.length;

  static int countForFilterTypes(Set<String> types) =>
      buildComparisonForFilterTypes(types).clinics.length;

  static bool _looksDoctorLed(String name) {
    final n = name.trim().toLowerCase();
    if (n.startsWith('dr ') || n.startsWith('dr.') || n.startsWith('drs ')) {
      return true;
    }
    return RegExp(r'\bdr\.?\b').hasMatch(n);
  }

  static bool _looksVerified(String name) {
    // Free curated list = published price-list partners.
    return name.trim().isNotEmpty;
  }

  static String? _pillForFilterType(String type) {
    switch (type) {
      case 'Botox':
      case 'Injectables':
        return 'Botox';
      case 'Fillers':
        return 'Fillers';
      case 'Laser':
      case 'Skin laser':
      case 'Hair removal':
        return 'All';
      case 'Peels':
        return 'Peels';
      case 'Skin treatments':
      case 'Skin boosters':
        return 'Skin';
      case 'Surgery':
        return 'Rhinoplasty';
      case 'Body treatments':
        return 'Boob job';
      default:
        return null;
    }
  }

  /// Collapse filter-type sets that match an Explore pill (e.g. Injectables+Botox → Botox).
  static String? _pillForFilterTypes(Set<String> types) {
    if (types.isEmpty) return 'All';
    if (types.length == 1) return _pillForFilterType(types.first);

    final injectablesBotox = types.length == 2 &&
        types.contains('Injectables') &&
        types.contains('Botox');
    if (injectablesBotox) return 'Botox';

    final laserHair = types.length == 2 &&
        types.contains('Laser') &&
        types.contains('Hair removal');
    if (laserHair) return 'All';

    final skinPair = types.length == 2 &&
        types.contains('Skin treatments') &&
        types.contains('Skin boosters');
    if (skinPair) return 'Skin';

    return null;
  }

  /// Explore pill to seed Filters procedure selection.
  static Set<String> filterTypesForPill(String pill) {
    switch (pill.trim()) {
      case 'Botox':
        return {'Injectables', 'Botox'};
      case 'Fillers':
        return {'Fillers'};
      case 'Laser':
      case 'Hair removal':
      case 'Skin laser':
        return <String>{};
      case 'Peels':
        return {'Peels'};
      case 'Skin':
        return {'Skin treatments', 'Skin boosters'};
      case 'Rhinoplasty':
        return {'Surgery'};
      case 'Boob job':
        return {'Body treatments'};
      case 'Hair':
        return {'Surgery'};
      default:
        return <String>{};
    }
  }

  static String _procedureTitleForPill(String pill) {
    switch (pill.trim()) {
      case 'Botox':
        return 'Botox';
      case 'Fillers':
        return 'Lip filler';
      case 'Laser':
      case 'Hair removal':
      case 'Skin laser':
        return 'Laser';
      case 'Peels':
        return 'Peels';
      case 'Skin':
        return 'Skin';
      case 'Rhinoplasty':
        return 'Rhinoplasty';
      case 'Boob job':
        return 'Breast augmentation';
      case 'Hair':
        return 'Hair transplant';
      default:
        return 'Treatments';
    }
  }

  /// Local-only search over the curated catalog (no live AI).
  static List<OpenAISearchItem> search(String query, {String pill = 'All'}) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return const [];

    final cmp = buildComparison(pill: pill);
    final out = <OpenAISearchItem>[];

    final procedureHints = <String, String>{
      'botox': 'Botox',
      'toxin': 'Botox',
      'filler': 'Lip filler',
      'voluma': 'Voluma',
      'volift': 'Volift',
      'juvederm': 'Juvederm',
      'laser': 'Laser hair removal',
      'fractora': 'Fractora',
      'moxi': 'MOXI laser',
      'peel': 'Chemical peel',
      'endolift': 'Endolift',
      'rhino': 'Rhinoplasty',
      'nose': 'Rhinoplasty',
      'boob': 'Breast augmentation',
      'breast': 'Breast augmentation',
      'hair': 'Hair transplant',
      'fue': 'Hair transplant',
      'profhilo': 'Skin booster',
      'polynucleotide': 'Skin booster',
    };
    for (final e in procedureHints.entries) {
      if (q.contains(e.key) || e.key.contains(q)) {
        out.add(
          OpenAISearchItem(
            title: e.value,
            subtitle: 'Procedure · Worldwide curated',
            type: OpenAISearchItemType.procedure,
            priceHint: cmp.rangeLabel,
          ),
        );
        break;
      }
    }

    for (final c in cmp.clinics) {
      final hay =
          '${c.name} ${c.area} ${c.brand} ${c.priceLabel}'.toLowerCase();
      if (!hay.contains(q)) continue;
      out.add(
        OpenAISearchItem(
          title: c.name,
          subtitle: '${c.area} · Clinic',
          type: OpenAISearchItemType.clinic,
          priceHint: c.priceLabel.isEmpty ? null : c.priceLabel,
        ),
      );
    }
    return out;
  }

  static String _topicForPill(String pill) {
    switch (pill.trim()) {
      case 'Botox':
        return 'Botox · Worldwide';
      case 'Fillers':
        return 'Lip filler · Worldwide';
      case 'Laser':
      case 'Hair removal':
      case 'Skin laser':
        return 'Laser · Worldwide';
      case 'Peels':
        return 'Peels & skin · Worldwide';
      case 'Skin':
        return 'Skin treatments · Worldwide';
      case 'Rhinoplasty':
        return 'Rhinoplasty · Worldwide';
      case 'Boob job':
        return 'Breast augmentation · Worldwide';
      case 'Hair':
        return 'Hair transplant · Worldwide';
      default:
        return 'Top clinics · Worldwide';
    }
  }

  static OpenAIClinic _toClinic(
    _CuratedClinic c, {
    required int rank,
    required _PriceQuote quote,
  }) {
    return OpenAIClinic(
      rank: rank,
      name: c.name,
      area: c.city,
      distanceMi: 0,
      rating: c.rating,
      reviews: c.reviews,
      priceGbp: quote.min.round(),
      priceMin: quote.min,
      priceMax: quote.max > 0 ? quote.max : quote.min,
      priceLabel: quote.label,
      currency: quote.currency,
      currencyConfirmed: true,
      brand: quote.procedureName,
      badge: rank == 1 ? 'Featured' : '',
      badgeVariant: rank == 1 ? 'best' : 'hi',
      coord: OpenAICoord(c.lat, c.lng),
      hasProcedure: true,
      pricePending: false,
    );
  }
}

class _PriceQuote {
  const _PriceQuote({
    required this.label,
    required this.currency,
    required this.procedureName,
    this.min = 0,
    this.max = 0,
    this.published = true,
  });

  final String label;
  final String currency;
  final String procedureName;
  final double min;
  final double max;
  final bool published;

  bool get isPublished =>
      published &&
      label.trim().isNotEmpty &&
      procedureName.trim().isNotEmpty &&
      min > 0;

  static const none = _PriceQuote(
    label: '',
    currency: '',
    procedureName: '',
    min: 0,
    max: 0,
    published: false,
  );
}

class _CuratedClinic {
  const _CuratedClinic({
    required this.name,
    required this.city,
    required this.cityFlag,
    required this.lat,
    required this.lng,
    required this.rating,
    required this.reviews,
    required this.highlight,
    required this.allFeatured,
    required this.botox,
    required this.filler,
    required this.laser,
    required this.peel,
    required this.hairRemoval,
    required this.skinBooster,
    required this.surgeryA,
    required this.surgeryB,
  });

  final String name;
  final String city;
  final String cityFlag;
  final double lat;
  final double lng;
  final double rating;
  final int reviews;
  final String highlight;
  final _PriceQuote allFeatured;
  final _PriceQuote botox;
  final _PriceQuote filler;
  final _PriceQuote laser;
  final _PriceQuote peel;
  final _PriceQuote hairRemoval;
  final _PriceQuote skinBooster;
  final _PriceQuote surgeryA;
  final _PriceQuote surgeryB;

  _PriceQuote quoteFor(String pill) {
    switch (pill.trim()) {
      case 'Botox':
        return botox;
      case 'Fillers':
        return filler;
      case 'Laser':
      case 'Hair removal':
      case 'Skin laser':
        return laser.isPublished ? laser : hairRemoval;
      case 'Peels':
        return peel.isPublished ? peel : laser;
      case 'Skin':
        if (skinBooster.isPublished) return skinBooster;
        if (peel.isPublished) return peel;
        return laser;
      case 'Rhinoplasty':
        return _quoteMatching(
          (n) => n.contains('rhino') || n.contains('nose'),
        );
      case 'Boob job':
        return _quoteMatching(
          (n) =>
              n.contains('breast') ||
              n.contains('boob') ||
              n.contains('augment'),
        );
      case 'Hair':
        return _quoteMatching(
          (n) => n.contains('hair transplant') || n.contains('fue'),
        );
      default:
        return allFeatured.isPublished ? allFeatured : _PriceQuote.none;
    }
  }

  _PriceQuote _quoteMatching(bool Function(String name) test) {
    for (final q in [allFeatured, surgeryA, surgeryB]) {
      if (q.isPublished && test(q.procedureName.toLowerCase())) return q;
    }
    return _PriceQuote.none;
  }

  _PriceQuote quoteForFilterType(String type) {
    switch (type.trim()) {
      case 'Injectables':
        return botox.isPublished ? botox : filler;
      case 'Botox':
        return botox;
      case 'Fillers':
        return filler;
      case 'Laser':
        return laser;
      case 'Hair removal':
        return hairRemoval;
      case 'Skin boosters':
        return skinBooster;
      case 'Peels':
        return peel;
      case 'Surgery':
        return surgeryA.isPublished ? surgeryA : surgeryB;
      case 'Skin treatments':
        if (laser.isPublished) return laser;
        if (peel.isPublished) return peel;
        return skinBooster;
      case 'Body treatments':
        return surgeryB.isPublished ? surgeryB : surgeryA;
      default:
        return _PriceQuote.none;
    }
  }
}

/// Free-tier curated catalog — enough coverage so Filters always show something
/// before subscription unlocks full AI city search.
const _catalog = <_CuratedClinic>[
  _CuratedClinic(
    name: 'Dubai Cosmetic Surgery Clinic',
    city: 'Dubai, UAE',
    cityFlag: '🇦🇪',
    lat: 25.2335,
    lng: 55.3236,
    rating: 4.8,
    reviews: 920,
    highlight: 'Dubai',
    allFeatured: _PriceQuote(
      label: 'from 27,000 AED',
      currency: 'AED',
      min: 27000,
      procedureName: 'Breast augmentation',
    ),
    botox: _PriceQuote(
      label: '42 AED',
      currency: 'AED',
      min: 42,
      procedureName: 'Botox wrinkles',
    ),
    filler: _PriceQuote(
      label: 'from 1,500 AED',
      currency: 'AED',
      min: 1500,
      procedureName: 'Belotero filler',
    ),
    laser: _PriceQuote(
      label: 'from 800 AED',
      currency: 'AED',
      min: 800,
      procedureName: 'Fractional laser face',
    ),
    peel: _PriceQuote(
      label: 'from 450 AED',
      currency: 'AED',
      min: 450,
      procedureName: 'Chemical peel',
    ),
    hairRemoval: _PriceQuote(
      label: 'from 300 AED',
      currency: 'AED',
      min: 300,
      procedureName: 'Laser hair removal',
    ),
    skinBooster: _PriceQuote(
      label: 'from 1,800 AED',
      currency: 'AED',
      min: 1800,
      procedureName: 'Skin booster',
    ),
    surgeryA: _PriceQuote(
      label: 'from 25,000 AED',
      currency: 'AED',
      min: 25000,
      procedureName: 'Rhinoplasty',
    ),
    surgeryB: _PriceQuote(
      label: 'from 27,000 AED',
      currency: 'AED',
      min: 27000,
      procedureName: 'Breast augmentation',
    ),
  ),
  _CuratedClinic(
    name: 'Harley Street Skin Clinic',
    city: 'London, UK',
    cityFlag: '🇬🇧',
    lat: 51.5205,
    lng: -0.1470,
    rating: 4.9,
    reviews: 1100,
    highlight: 'London',
    allFeatured: _PriceQuote(
      label: 'from 9,000 £',
      currency: '£',
      min: 9000,
      procedureName: 'Rhinoplasty',
    ),
    botox: _PriceQuote(
      label: 'from 200 £',
      currency: '£',
      min: 200,
      procedureName: 'Botox 1 area',
    ),
    filler: _PriceQuote(
      label: 'from 480 £',
      currency: '£',
      min: 480,
      procedureName: 'Lip filler 1ml',
    ),
    laser: _PriceQuote(
      label: 'from 400 £',
      currency: '£',
      min: 400,
      procedureName: 'Fractora Forma',
    ),
    peel: _PriceQuote(
      label: 'from 150 £',
      currency: '£',
      min: 150,
      procedureName: 'Chemical peel',
    ),
    hairRemoval: _PriceQuote(
      label: 'from 120 £',
      currency: '£',
      min: 120,
      procedureName: 'Laser hair removal',
    ),
    skinBooster: _PriceQuote(
      label: 'from 350 £',
      currency: '£',
      min: 350,
      procedureName: 'Profhilo skin booster',
    ),
    surgeryA: _PriceQuote(
      label: 'from 9,000 £',
      currency: '£',
      min: 9000,
      procedureName: 'Rhinoplasty',
    ),
    surgeryB: _PriceQuote(
      label: 'from 6,500 £',
      currency: '£',
      min: 6500,
      procedureName: 'Tip rhinoplasty',
    ),
  ),
  _CuratedClinic(
    name: 'Dr. Serkan Aygin Clinic',
    city: 'Istanbul, Turkey',
    cityFlag: '🇹🇷',
    lat: 41.0682,
    lng: 28.9870,
    rating: 4.8,
    reviews: 4200,
    highlight: 'Istanbul',
    allFeatured: _PriceQuote(
      label: 'from 1,690 €',
      currency: '€',
      min: 1690,
      procedureName: 'Hair transplant FUE',
    ),
    botox: _PriceQuote(
      label: 'from 100 €',
      currency: '€',
      min: 100,
      procedureName: 'Forehead Botox',
    ),
    filler: _PriceQuote(
      label: 'from 250 €',
      currency: '€',
      min: 250,
      procedureName: 'Lip filler 1ml',
    ),
    laser: _PriceQuote.none,
    peel: _PriceQuote(
      label: 'from 90 €',
      currency: '€',
      min: 90,
      procedureName: 'Medical peel',
    ),
    hairRemoval: _PriceQuote(
      label: 'from 80 €',
      currency: '€',
      min: 80,
      procedureName: 'Laser hair removal',
    ),
    skinBooster: _PriceQuote(
      label: 'from 180 €',
      currency: '€',
      min: 180,
      procedureName: 'Skin booster',
    ),
    surgeryA: _PriceQuote(
      label: 'from 1,690 €',
      currency: '€',
      min: 1690,
      procedureName: 'Hair transplant FUE',
    ),
    surgeryB: _PriceQuote(
      label: 'from 2,450 €',
      currency: '€',
      min: 2450,
      procedureName: 'Rhinoplasty',
    ),
  ),
  _CuratedClinic(
    name: 'Dr. Gökhan Beyhan',
    city: 'Istanbul, Turkey',
    cityFlag: '🇹🇷',
    lat: 41.0781,
    lng: 29.0161,
    rating: 4.7,
    reviews: 59,
    highlight: 'Istanbul',
    allFeatured: _PriceQuote(
      label: 'from 2,450 €',
      currency: '€',
      min: 2450,
      procedureName: 'Rhinoplasty',
    ),
    botox: _PriceQuote(
      label: 'from 100 €',
      currency: '€',
      min: 100,
      procedureName: 'Forehead Botox',
    ),
    filler: _PriceQuote(
      label: 'from 5,000 ₺',
      currency: 'TRY',
      min: 5000,
      procedureName: 'Lip filler 1ml',
    ),
    laser: _PriceQuote.none,
    peel: _PriceQuote.none,
    hairRemoval: _PriceQuote.none,
    skinBooster: _PriceQuote.none,
    surgeryA: _PriceQuote(
      label: 'from 2,450 €',
      currency: '€',
      min: 2450,
      procedureName: 'Rhinoplasty',
    ),
    surgeryB: _PriceQuote(
      label: 'from 3,200 €',
      currency: '€',
      min: 3200,
      procedureName: 'Breast augmentation',
    ),
  ),
  _CuratedClinic(
    name: 'Dr. Paul Afrooz',
    city: 'Miami, USA',
    cityFlag: '🇺🇸',
    lat: 25.7617,
    lng: -80.1918,
    rating: 4.9,
    reviews: 380,
    highlight: 'Miami',
    allFeatured: _PriceQuote(
      label: r'from 12,000 $',
      currency: r'$',
      min: 12000,
      procedureName: 'Rhinoplasty',
    ),
    botox: _PriceQuote(
      label: r'12–16 $',
      currency: r'$',
      min: 12,
      max: 16,
      procedureName: 'Botox / Dysport',
    ),
    filler: _PriceQuote(
      label: r'800–950 $',
      currency: r'$',
      min: 800,
      max: 950,
      procedureName: 'Lip filler syringe',
    ),
    laser: _PriceQuote(
      label: r'750 $',
      currency: r'$',
      min: 750,
      procedureName: 'MOXI laser face',
    ),
    peel: _PriceQuote(
      label: r'from 250 $',
      currency: r'$',
      min: 250,
      procedureName: 'Chemical peel',
    ),
    hairRemoval: _PriceQuote(
      label: r'from 200 $',
      currency: r'$',
      min: 200,
      procedureName: 'Laser hair removal',
    ),
    skinBooster: _PriceQuote(
      label: r'from 700 $',
      currency: r'$',
      min: 700,
      procedureName: 'Skin booster',
    ),
    surgeryA: _PriceQuote(
      label: r'from 12,000 $',
      currency: r'$',
      min: 12000,
      procedureName: 'Rhinoplasty',
    ),
    surgeryB: _PriceQuote.none,
  ),
  _CuratedClinic(
    name: 'Miami Plastic Surgery',
    city: 'Miami, USA',
    cityFlag: '🇺🇸',
    lat: 25.7907,
    lng: -80.1300,
    rating: 4.7,
    reviews: 510,
    highlight: 'Miami',
    allFeatured: _PriceQuote(
      label: r'from 6,500 $',
      currency: r'$',
      min: 6500,
      procedureName: 'Breast augmentation',
    ),
    botox: _PriceQuote(
      label: r'from 12 $',
      currency: r'$',
      min: 12,
      procedureName: 'Botox unit',
    ),
    filler: _PriceQuote.none,
    laser: _PriceQuote.none,
    peel: _PriceQuote.none,
    hairRemoval: _PriceQuote.none,
    skinBooster: _PriceQuote.none,
    surgeryA: _PriceQuote(
      label: r'from 6,500 $',
      currency: r'$',
      min: 6500,
      procedureName: 'Breast augmentation',
    ),
    surgeryB: _PriceQuote(
      label: r'from 8,500 $',
      currency: r'$',
      min: 8500,
      procedureName: 'Tummy tuck',
    ),
  ),
  _CuratedClinic(
    name: 'Bosley Hair Restoration',
    city: 'Los Angeles, USA',
    cityFlag: '🇺🇸',
    lat: 34.0689,
    lng: -118.4050,
    rating: 4.6,
    reviews: 890,
    highlight: 'Los Angeles',
    allFeatured: _PriceQuote(
      label: r'from 7,000 $',
      currency: r'$',
      min: 7000,
      procedureName: 'Hair transplant',
    ),
    botox: _PriceQuote.none,
    filler: _PriceQuote.none,
    laser: _PriceQuote.none,
    peel: _PriceQuote.none,
    hairRemoval: _PriceQuote.none,
    skinBooster: _PriceQuote.none,
    surgeryA: _PriceQuote(
      label: r'from 7,000 $',
      currency: r'$',
      min: 7000,
      procedureName: 'Hair transplant',
    ),
    surgeryB: _PriceQuote.none,
  ),
  _CuratedClinic(
    name: 'ALTA Medi',
    city: 'Los Angeles, USA',
    cityFlag: '🇺🇸',
    lat: 34.0901,
    lng: -118.3850,
    rating: 4.7,
    reviews: 210,
    highlight: 'Los Angeles',
    allFeatured: _PriceQuote.none,
    botox: _PriceQuote(
      label: r'12–16 $',
      currency: r'$',
      min: 12,
      max: 16,
      procedureName: 'Upper-face Botox',
    ),
    filler: _PriceQuote(
      label: r'from 850 $',
      currency: r'$',
      min: 850,
      procedureName: 'Facial balancing filler',
    ),
    laser: _PriceQuote(
      label: r'from 450 $',
      currency: r'$',
      min: 450,
      procedureName: 'Laser facial',
    ),
    peel: _PriceQuote(
      label: r'from 195 $',
      currency: r'$',
      min: 195,
      procedureName: 'Glycolic enzyme peel',
    ),
    hairRemoval: _PriceQuote(
      label: r'from 150 $',
      currency: r'$',
      min: 150,
      procedureName: 'Laser hair removal',
    ),
    skinBooster: _PriceQuote(
      label: r'from 600 $',
      currency: r'$',
      min: 600,
      procedureName: 'Skin booster',
    ),
    surgeryA: _PriceQuote.none,
    surgeryB: _PriceQuote.none,
  ),
];
