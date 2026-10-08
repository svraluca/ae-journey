import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import 'explore_price_evidence.dart';
import 'explore_price_verification.dart';
import 'explore_procedure_family.dart';
import 'explore_search_locale.dart';
import 'openai_service.dart';

/// Reader for the curated public-site price dataset.
///
/// Explore searches by city + procedure, so this queries the flattened
/// `explore_curated_prices` collection on exactly those two keys and lets
/// Firestore do the filtering — the client never downloads the whole city.
///
/// Rows are converted with the [OpenAIClinic] constructor rather than
/// `OpenAIClinic.fromJson`, because that factory downgrades any priced row
/// without DOM evidence to `legacyUnverified`. Curated rows legitimately have no
/// DOM evidence, and the strict rule must stay in place for AI and scraped rows,
/// so the curated path builds its own clinics and is trusted through
/// [exploreCuratedPriceIsTrusted] instead.
class ExploreCuratedPriceStore {
  ExploreCuratedPriceStore._();

  static final ExploreCuratedPriceStore instance = ExploreCuratedPriceStore._();

  static const String collection = 'explore_curated_prices';
  static const String clinicCollection = 'explore_curated_clinics';

  /// Rows fetched per family before reducing to one row per clinic. A family
  /// spreads over far fewer rows than the ~830 in the city, and the reduction
  /// needs several rows per clinic to pick a representative one. 200 covers
  /// Miami's ~70 filler rows plus a clinic that lists 15 syringe variants.
  static const int _fetchLimit = 200;

  /// Repeat tab switches must not re-hit Firestore; that round trip is what
  /// made switching pills feel slow.
  static const Duration _memoryTtl = Duration(minutes: 10);

  final Map<String, _CuratedCacheEntry> _memory = {};
  final Map<String, Future<List<OpenAIClinic>>> _inFlight = {};
  /// City-wide dump used only while the composite index is building. One
  /// equality filter on `city_key` needs no composite index.
  final Map<String, Future<List<Map<String, dynamic>>>> _cityDumpInFlight = {};
  final Map<String, List<Map<String, dynamic>>> _cityDump = {};

  static String _cacheKey(String cityKey, List<String> families) =>
      '$cityKey|${families.join(",")}';

  /// Metro-level search key. A Coral Gables clinic has to answer "Miami";
  /// Harley Street answers "London"; Manhattan answers "New York";
  /// Beverly Hills answers "Los Angeles"; The Woodlands answers "Houston";
  /// Plano answers "Dallas". Romanian accents fold via [exploreCanonicalCityKey].
  static String cityKeyFor(String city) {
    final canonical = exploreCanonicalCityKey(city);
    if (canonical.isEmpty) return '';
    for (final metro in _kMetroAliases.entries) {
      if (metro.value.contains(canonical) || metro.key == canonical) {
        return metro.key;
      }
      if (metro.value.contains(city.trim().toLowerCase())) return metro.key;
    }
    return canonical;
  }

  /// Drops the in-memory cache. Used after a background refresh writes.
  void invalidate({String city = ''}) {
    if (city.isEmpty) {
      _memory.clear();
      _cityDump.clear();
      return;
    }
    final ck = cityKeyFor(city);
    _memory.removeWhere((key, _) => key.startsWith('$ck|'));
    _cityDump.remove(ck);
  }

  /// Curated clinics for one city + procedure, best first, one row per clinic.
  ///
  /// Returns an empty list rather than throwing when the city or procedure is
  /// not covered, so callers can fall through to live discovery unchanged.
  Future<List<OpenAIClinic>> load({
    required String city,
    required String procedure,
    int limit = 12,
  }) async {
    final cityKey = cityKeyFor(city);
    if (cityKey.isEmpty) return const [];
    final families = exploreCuratedFamilyKeys(procedure);
    if (families.isEmpty) return const [];

    final key = _cacheKey(cityKey, families);
    final cached = _memory[key];
    if (cached != null && !cached.isExpired) {
      return cached.clinics.take(limit).toList();
    }
    final pending = _inFlight[key];
    if (pending != null) {
      final rows = await pending;
      return rows.take(limit).toList();
    }

    final future = _fetch(
      cityKey: cityKey,
      city: city,
      procedure: procedure,
      families: families,
    );
    _inFlight[key] = future;
    try {
      final rows = await future;
      _memory[key] = _CuratedCacheEntry(rows, DateTime.now());
      return rows.take(limit).toList();
    } finally {
      _inFlight.remove(key);
    }
  }

  /// Cached rows without a Firestore round trip, for painting inside one frame.
  List<OpenAIClinic> peek({
    required String city,
    required String procedure,
    int limit = 12,
  }) {
    final families = exploreCuratedFamilyKeys(procedure);
    if (families.isEmpty) return const [];
    final entry = _memory[_cacheKey(cityKeyFor(city), families)];
    if (entry == null || entry.isExpired) return const [];
    return entry.clinics.take(limit).toList();
  }

  Future<List<OpenAIClinic>> _fetch({
    required String cityKey,
    required String city,
    required String procedure,
    required List<String> families,
  }) async {
    if (FirebaseAuth.instance.currentUser == null) return const [];
    final started = DateTime.now();
    List<Map<String, dynamic>> rows;
    try {
      final snap = await FirebaseFirestore.instance
          .collection(collection)
          .where('city_key', isEqualTo: cityKey)
          .where('procedure_family', whereIn: families)
          .orderBy('rating', descending: true)
          .limit(_fetchLimit)
          .get();
      rows = [for (final d in snap.docs) d.data()];
    } catch (e) {
      final indexNotReady = '$e'.contains('failed-precondition');
      if (!indexNotReady) {
        debugPrint('[CURATED] query failed · $city · $procedure · $e');
        return const [];
      }
      debugPrint(
        '[CURATED] index not ready · $city · $procedure · '
        'falling back to city_key scan',
      );
      rows = await _cityRows(cityKey);
      final want = families.toSet();
      rows = [
        for (final row in rows)
          if (want.contains('${row['procedure_family'] ?? ''}')) row,
      ];
      rows.sort((a, b) {
        final ra = (a['rating'] as num?)?.toDouble() ?? 0;
        final rb = (b['rating'] as num?)?.toDouble() ?? 0;
        return rb.compareTo(ra);
      });
      if (rows.length > _fetchLimit) rows = rows.take(_fetchLimit).toList();
    }

    return _reduceToClinics(
      rows: rows,
      families: families,
      city: city,
      procedure: procedure,
      started: started,
    );
  }

  Future<List<Map<String, dynamic>>> _cityRows(String cityKey) async {
    final cached = _cityDump[cityKey];
    if (cached != null) return cached;
    final pending = _cityDumpInFlight[cityKey];
    if (pending != null) return pending;
    final future = () async {
      final snap = await FirebaseFirestore.instance
          .collection(collection)
          .where('city_key', isEqualTo: cityKey)
          .get();
      final rows = [for (final d in snap.docs) d.data()];
      _cityDump[cityKey] = rows;
      debugPrint('[CURATED] city dump · $cityKey · ${rows.length} rows');
      return rows;
    }();
    _cityDumpInFlight[cityKey] = future;
    try {
      return await future;
    } finally {
      _cityDumpInFlight.remove(cityKey);
    }
  }

  List<OpenAIClinic> _reduceToClinics({
    required List<Map<String, dynamic>> rows,
    required List<String> families,
    required String city,
    required String procedure,
    required DateTime started,
  }) {
    final clinics = <OpenAIClinic>[];
    final bestByClinic = <String, _ScoredRow>{};
    for (final row in rows) {
      if (families.contains('filler') && _rowLooksLikeFillerDissolving(row)) {
        continue;
      }
      final clinic = _clinicFromRow(row);
      if (clinic == null) continue;
      final clinicId = '${row['clinic_id'] ?? clinic.name}';
      final score = _representativeScore(row, families);
      final prior = bestByClinic[clinicId];
      if (prior == null || score > prior.score) {
        bestByClinic[clinicId] = _ScoredRow(clinic, score);
      }
    }
    final seen = <String>{};
    for (final row in rows) {
      final clinicId = '${row['clinic_id'] ?? ''}';
      if (clinicId.isEmpty || !seen.add(clinicId)) continue;
      final best = bestByClinic[clinicId];
      if (best != null) clinics.add(best.clinic);
    }

    final ms = DateTime.now().difference(started).inMilliseconds;
    debugPrint(
      '[CURATED] $city · $procedure · ${clinics.length} rows · ${ms}ms',
    );
    return clinics;
  }

  /// Which row best represents a clinic for this family. A four-pack bundle or a
  /// new-client teaser is a real published price but a poor headline, and an
  /// exactly-canonical row ("Botox") beats an adjacent one ("Gummy Smile Tox").
  static double _representativeScore(
    Map<String, dynamic> row,
    List<String> families,
  ) {
    var score = 0.0;
    if (row['is_package'] != true) score += 4;
    if (row['is_promotional'] != true) score += 3;
    final family = '${row['procedure_family'] ?? ''}';
    final canonical = '${row['procedure_canonical'] ?? ''}';
    // The first key is the pill the user tapped. A cheaper Arm Lift in the
    // same `surgery` fallback bucket must not beat Breast Augmentation.
    if (families.isNotEmpty && family == families.first) score += 8;
    if (canonical.isNotEmpty && families.contains(canonical)) score += 2;
    if ('${row['procedure_family_source'] ?? ''}' == 'explore_matcher') {
      score += 1;
    }
    if (families.contains('filler') && _rowLooksLikeFillerDissolving(row)) {
      score -= 20;
    }
    // Cheaper of two equally good rows: Explore cards read as "from" prices.
    final min = (row['price_min'] as num?)?.toDouble() ?? 0;
    if (min > 0) score += 1 / (1 + min);
    return score;
  }

  static bool _rowLooksLikeFillerDissolving(Map<String, dynamic> row) {
    return looksLikeFillerDissolvingLabel(
      '${row['procedure_name'] ?? ''} ${row['procedure_canonical'] ?? ''}',
    );
  }

  /// Build a trusted curated clinic, or null when the row is unusable.
  static OpenAIClinic? _clinicFromRow(Map<String, dynamic> row) {
    final name = '${row['clinic_name'] ?? ''}'.trim();
    final priceMin = (row['price_min'] as num?)?.toDouble() ?? 0;
    final sourceUrl = '${row['source_url'] ?? ''}'.trim();
    final currency = '${row['currency'] ?? ''}'.trim();
    if (name.isEmpty || priceMin <= 0 || sourceUrl.isEmpty || currency.isEmpty) {
      return null;
    }
    // Curated rows are trusted by source + check date, not by the HTML
    // extract revision. Stamping EXTRACT_REVISION on import is diagnostic;
    // requiring it here would hide every Miami card the next time extraction
    // rules bump (the e12/e13 client-zeroing failure mode).
    final revision = '${row['price_extract_revision'] ?? ''}'.trim();

    final checkedAt = _parseCuratedDate(row['checked_at']);
    if (checkedAt == null) return null;

    final priceMaxRaw = (row['price_max'] as num?)?.toDouble() ?? 0;
    final priceMax = priceMaxRaw < priceMin ? priceMin : priceMaxRaw;
    final procedureName = '${row['procedure_name'] ?? ''}'.trim();
    final address = '${row['address'] ?? ''}'.trim();

    return OpenAIClinic(
      rank: 0,
      distanceMi: 0,
      priceGbp: 0,
      badge: '',
      badgeVariant: 'mid',
      // The dataset has street addresses, not coordinates. Explore already
      // treats (0, 0) as "unknown" and skips distance for such rows.
      coord: const OpenAICoord(0, 0),
      name: name,
      // `area` is the card's location line; the source URL rides along in the
      // same `src:` form the rest of the pipeline uses for host identity.
      area: address.isEmpty ? sourceUrl : '$address · src:$sourceUrl',
      rating: (row['rating'] as num?)?.toDouble() ?? 0,
      reviews: (row['rating_count'] as num?)?.toInt() ?? 0,
      priceMin: priceMin,
      priceMax: priceMax,
      priceLabel: _curatedPriceLabel(
        priceMin: priceMin,
        priceMax: priceMax,
        currency: currency,
        priceType: '${row['price_type'] ?? ''}',
        unit: '${row['unit'] ?? ''}',
      ),
      currency: currency,
      currencyConfirmed: true,
      // The published name is what the card shows: "HydraFacial Platinum"
      // must never collapse to "Facial".
      brand: procedureName,
      rawProcedureText: procedureName,
      hasProcedure: true,
      priceSourceUrl: sourceUrl,
      priceVerificationStatus: PriceVerificationStatus.curatedPublicSite,
      priceVerificationConfidence: 1,
      lastCheckedAt: checkedAt,
      priceType: '${row['price_type'] ?? ''}'.trim(),
      priceUnit: '${row['unit'] ?? ''}'.trim(),
      priceQuantity: (row['unit_quantity'] as num?)?.toDouble(),
      sourceType: kExploreCuratedSourceType,
      procedureFamily: '${row['procedure_family'] ?? ''}'.trim(),
      procedureCanonical: '${row['procedure_canonical'] ?? ''}'.trim(),
      priceExtractRevision: revision,
      // Query-established match; see the curated branch in
      // exploreClinicEligibleForVerifiedPool.
      procedureRelation: 'exact',
    );
  }

  /// True when every curated row for this search is past its 30-day TTL, so a
  /// background refresh is worth scheduling. Stale rows still paint.
  bool isStale(List<OpenAIClinic> clinics) {
    if (clinics.isEmpty) return false;
    final now = DateTime.now();
    return clinics.every((c) {
      final checked = c.lastCheckedAt;
      if (checked == null) return true;
      return now.difference(checked) > kExploreCuratedStaleAfter;
    });
  }
}

String _curatedPriceLabel({
  required double priceMin,
  required double priceMax,
  required String currency,
  required String priceType,
  required String unit,
}) {
  final symbol = switch (currency.trim().toUpperCase()) {
    'USD' || r'$' => r'$',
    'GBP' || '£' => '£',
    'EUR' || '€' => '€',
    final code => '$code ',
  };
  String amount(double v) =>
      v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(2);
  final type = PriceType.fromWire(priceType);
  final suffix = switch (type) {
    PriceType.perUnit => unit.isEmpty ? '' : ' per $unit',
    PriceType.perArea => ' per area',
    _ => '',
  };
  if (priceMax > priceMin) {
    return '$symbol${amount(priceMin)}–$symbol${amount(priceMax)}$suffix';
  }
  final prefix = type == PriceType.from ? 'from ' : '';
  return '$prefix$symbol${amount(priceMin)}$suffix';
}

DateTime? _parseCuratedDate(Object? raw) {
  if (raw == null) return null;
  if (raw is Timestamp) return raw.toDate();
  if (raw is DateTime) return raw;
  final s = '$raw'.trim();
  if (s.isEmpty) return null;
  return DateTime.tryParse(s);
}

class _CuratedCacheEntry {
  _CuratedCacheEntry(this.clinics, this.at);

  final List<OpenAIClinic> clinics;
  final DateTime at;

  bool get isExpired =>
      DateTime.now().difference(at) > ExploreCuratedPriceStore._memoryTtl;
}

class _ScoredRow {
  _ScoredRow(this.clinic, this.score);

  final OpenAIClinic clinic;
  final double score;
}

/// Metro key -> municipalities the curated audit folds into it.
const Map<String, Set<String>> _kMetroAliases = {
  'miami': {
    'miami',
    'miami beach',
    'miami-dade',
    'miami dade',
    'coral gables',
    'south miami',
    'north miami',
    'north miami beach',
    'miami lakes',
    'brickell',
    'aventura',
    'doral',
    'hialeah',
    'key biscayne',
    'coconut grove',
    'kendall',
    'pinecrest',
    'sunny isles beach',
    'bal harbour',
  },
  'london': {
    'london',
    'westminster',
    'chelsea',
    'kensington',
    'mayfair',
    'marylebone',
    'harley street',
    'knightsbridge',
    'soho',
    'fitzrovia',
    'canary wharf',
    'shoreditch',
    'islington',
    'notting hill',
  },
  'new york': {
    'new york',
    'nyc',
    'new york city',
    'manhattan',
    'brooklyn',
    'queens',
    'bronx',
    'staten island',
    'midtown',
    'upper east side',
    'tribeca',
    'williamsburg',
    'long island city',
  },
  'los angeles': {
    'los angeles',
    'la',
    'l.a.',
    'l.a',
    'los angeles county',
    'beverly hills',
    'west hollywood',
    'weho',
    'hollywood',
    'santa monica',
    'burbank',
    'glendale',
    'pasadena',
    'redondo beach',
    'torrance',
    'century city',
    'brentwood',
    'westwood',
    'culver city',
    'venice',
    'malibu',
    'studio city',
    'sherman oaks',
    'encino',
    'dtla',
    'downtown la',
    'koreatown',
    'silver lake',
  },
  'houston': {
    'houston',
    'greater houston',
    'houston tx',
    'bellaire',
    'sugar land',
    'sugarland',
    'cypress',
    'the woodlands',
    'woodlands',
    'katy',
    'river oaks',
    'galleria',
    'memorial',
    'spring valley',
  },
  'dallas': {
    'dallas',
    'dfw',
    'dallas-fort worth',
    'dallas fort worth',
    'fort worth',
    'plano',
    'frisco',
    'allen',
    'arlington',
    'highland park',
    'university park',
    'preston hollow',
    'addison',
    'richardson',
    'irving',
    'mckinney',
  },
  'atlanta': {
    'atlanta',
    'atl',
    'roswell',
    'alpharetta',
    'marietta',
    'dunwoody',
    'peachtree corners',
    'acworth',
    'brookhaven',
    'smyrna',
    'johns creek',
    'buckhead',
    'sandy springs',
    'decatur',
  },
  'austin': {
    'austin',
    'round rock',
    'cedar park',
    'pflugerville',
  },
  'boston': {
    'boston',
    'cambridge',
    'brookline',
    'somerville',
    'back bay',
  },
  'charlotte': {
    'charlotte',
    'clt',
  },
  'chicago': {
    'chicago',
    'chi',
  },
  'denver': {
    'denver',
    'lone tree',
    'englewood',
    'cherry creek',
    'lodo',
  },
  'las vegas': {
    'las vegas',
    'vegas',
    'henderson',
  },
  'nashville': {
    'nashville',
    'brentwood',
    'nashville tn',
  },
  'orlando': {
    'orlando',
    'winter park',
    'altamonte springs',
    'lake mary',
    'maitland',
    'ocoee',
    'winter garden',
    'celebration',
    'longwood',
  },
  'phoenix': {
    'phoenix',
    'scottsdale',
    'tempe',
    'mesa',
    'chandler',
    'paradise valley',
  },
  'washington dc': {
    'washington dc',
    'washington d.c.',
    'washington d.c',
    'washington',
    'dc',
    'd.c.',
    'd.c',
    'district of columbia',
    'reston',
    'bethesda',
  },
  'tampa': {
    'tampa',
    'tampa bay',
    'clearwater',
    'st. petersburg',
    'st petersburg',
    'saint petersburg',
    'seminole',
  },
  'san diego': {
    'san diego',
    'la jolla',
    'la mesa',
    'del mar',
    'solana beach',
    'carlsbad',
    'oceanside',
  },
  'toronto': {
    'toronto',
    'markham',
    'mississauga',
    'oakville',
    'richmond hill',
    'vaughan',
    'gta',
    'greater toronto',
    'north york',
    'etobicoke',
    'scarborough',
  },
  'vancouver': {
    'vancouver',
    'burnaby',
    'surrey',
    'north vancouver',
    'west vancouver',
  },
  'calgary': {
    'calgary',
  },
  'edmonton': {
    'edmonton',
  },
  'halifax': {
    'halifax',
  },
  'hamilton': {
    'hamilton',
  },
  'kelowna': {
    'kelowna',
  },
  'montreal': {
    'montreal',
    'montréal',
  },
  'ottawa': {
    'ottawa',
    'gatineau',
  },
  'quebec city': {
    'quebec city',
    'quebec',
    'québec',
    'québec city',
    'ville de québec',
  },
  'saskatoon': {
    'saskatoon',
  },
  'victoria': {
    'victoria',
  },
  'winnipeg': {
    'winnipeg',
  },
};

/// Deterministic search term -> curated family keys, applied before any AI.
///
/// Ordered most specific first: "prp hair" must resolve to prp, not hair, and
/// "laser hair removal" must not be read as a hair transplant.
const List<(String, List<String>)> _kCuratedFamilyAliases = [
  (r'laser hair removal|hair removal|depilaci|laser', ['laser']),
  (r'\bprp\b|\bprf\b|platelet', ['prp']),
  (r'hydrafacial|hydra facial|diamondglow', ['hydrafacial']),
  (r'microneedl|morpheus|rf needling', ['microneedling']),
  (r'\bhifu\b|ultherapy|sofwave', ['hifu']),
  (
    r'hair transplant|\bfue\b|\bfut\b|\bdhi\b|hair restoration|'
    r'hair loss|capilar',
    ['hair_transplant', 'hair'],
  ),
  (
    r'breast augmentation|boob job|breast implant|breast lift|'
    r'breast reduction|augmentation mammoplasty',
    ['breast_augmentation'],
  ),
  (r'rhinoplasty|nose job|nose reshaping|rinoplast', ['rhinoplasty']),
  (
    r'botox|dysport|xeomin|daxxify|jeuveau|botulinum|anti[- ]?wrinkle|'
    r'wrinkle relaxer|neuromodulator|\btox\b',
    ['botox'],
  ),
  (
    r'filler|juvederm|restylane|lip injection|dermal filler',
    ['filler'],
  ),
  (r'sculptra|radiesse|profhilo|skin booster', ['skin']),
  (
    r'chemical peel|\bpeel\b|vi peel|biorepeel|prx|dermaplan',
    ['peel'],
  ),
  (r'facial|dermaplaning|glow', ['facials']),
  (r'\biv\b|drip|infusion|nad\+?|vitamin', ['iv_therapy']),
  (r'tattoo removal|tattoo', ['tattoo_removal']),
  (
    r'coolsculpt|emsculpt|body contour|liposuction|lipo\b|cellulite|'
    r'tummy tuck|abdominoplasty',
    ['body_contouring', 'surgery'],
  ),
  (r'weight loss|semaglutide|tirzepatide|ozempic|retatrutide', ['weight_loss']),
  (r'exosome|regenerat|\bpdrn\b', ['regenerative']),
  (r'\bwax\b|waxing|brazilian', ['waxing']),
  (r'lash|brow', ['lashes_brows']),
  (r'massage|cupping|lymphatic', ['massage_wellness']),
  (r'facelift|blepharoplast|tummy|surgery|lift\b', ['surgery']),
  (r'thread lift|\bthreads?\b', ['threads']),
  (r'\bskin\b|acne|melasma|pigment', ['skin']),
  (r'wellness|b12|glutathione|injection', ['wellness']),
];

/// Curated family keys to query for a search term.
///
/// Runs the coarse Explore family classifier first so the six flagship pills
/// behave exactly as the rest of the pipeline expects, then falls back to the
/// deterministic alias table so terms like "Morpheus8" or "VI Peel" resolve
/// without asking OpenAI to classify them.
List<String> exploreCuratedFamilyKeys(String procedure) {
  final raw = procedure.trim();
  if (raw.isEmpty) return const [];
  final family = exploreTreatmentFamily(raw);
  switch (family) {
    case ExploreTreatmentFamily.botox:
      return const ['botox'];
    case ExploreTreatmentFamily.filler:
      // Not `skin`: Profhilo / Sculptra / boosters crowd the 60-row fetch
      // the same way `surgery` crowded Boob job.
      return const ['filler'];
    case ExploreTreatmentFamily.laser:
      return const ['laser'];
    case ExploreTreatmentFamily.peel:
      return const ['peel'];
    case ExploreTreatmentFamily.rhinoplasty:
      // Not `surgery`: that bucket is facelifts, BBLs and tummy tucks, which
      // crowded rhinoplasty clinics out of the 60-row fetch.
      return const ['rhinoplasty'];
    case ExploreTreatmentFamily.breast:
      // Same `surgery` trap as rhinoplasty: Boob job must not load Arm Lift.
      return const ['breast_augmentation'];
    case ExploreTreatmentFamily.hair:
      return const ['hair_transplant', 'hair'];
    case ExploreTreatmentFamily.skin:
    case ExploreTreatmentFamily.other:
      break;
  }
  final lower = raw.toLowerCase();
  for (final (pattern, families) in _kCuratedFamilyAliases) {
    if (RegExp(pattern, caseSensitive: false).hasMatch(lower)) {
      return families;
    }
  }
  return family == ExploreTreatmentFamily.skin ? const ['skin'] : const [];
}
