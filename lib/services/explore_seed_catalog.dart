import 'dart:math' as math;

import 'filter_currency.dart';
import 'openai_service.dart';

/// Bundled Explore clinics so users see content instantly (no Google wait).
///
/// On each search we randomly sample Firestore clinics from the shared
/// city+procedure pool (up to [kExploreFirestorePoolMax]) per [planExplorePoolMix]
/// and mix with live Google finds when the pool is still growing.
abstract final class ExploreSeedCatalog {
  /// Instant clinics for [city] + procedure/pill. Empty when unknown.
  static List<OpenAIClinic> clinicsFor({
    required String city,
    required String queryOrSelection,
    required String categoryPill,
  }) {
    final cityKey = _cityKey(city);
    if (cityKey.isEmpty) return const [];
    final procKey = _procedureKey(categoryPill, queryOrSelection);
    if (procKey == null) return const [];

    final rows = _byCity[cityKey]?[procKey];
    if (rows == null || rows.isEmpty) return const [];

    final currency = CityCurrency.localCode(city);
    final cur = currency.isNotEmpty
        ? currency
        : (rows.first.currency.isNotEmpty ? rows.first.currency : '€');

    return [
      for (var i = 0; i < rows.length; i++)
        rows[i].toClinic(rank: i + 1, fallbackCurrency: cur),
    ];
  }

  /// True when this city has any bundled Explore clinics (not an unknown market).
  static bool hasCityCoverage(String city) {
    final key = _cityKey(city);
    if (key.isEmpty) return false;
    final rows = _byCity[key];
    return rows != null && rows.isNotEmpty;
  }

  /// Unknown markets hide AI guesses until the clinic website confirms them.
  /// HTML-verified quotes must stay visible (Abu Dhabi, Sharjah, …).
  static bool shouldHoldUnverifiedPrice({
    required bool cityHasCatalog,
    required bool hasPrice,
    required bool alreadyPending,
    required bool verified,
  }) {
    if (cityHasCatalog || !hasPrice || alreadyPending || verified) {
      return false;
    }
    return true;
  }

  /// Whether we ship enough seeds to paint the list without waiting on AI.
  static bool hasInstantCoverage({
    required String city,
    required String queryOrSelection,
    required String categoryPill,
  }) {
    return clinicsFor(
          city: city,
          queryOrSelection: queryOrSelection,
          categoryPill: categoryPill,
        ).length >=
        3;
  }

  /// Mix a random cached half with a fresh internet half.
  ///
  /// Samples up to [seedCount] clinics from the full [seeds] pool (capped at
  /// [kExploreFirestorePoolMax]), excluding any name already taken by [fresh]
  /// so the two halves never duplicate. Up to [freshCount] new clinics are
  /// kept. If either half is short, leftover clinics from the other half fill
  /// remaining slots up to [maxShow]. The combined list is then sorted by
  /// Google Maps popularity for display — selection is random, ranking is not.
  static List<OpenAIClinic> mixSeedsWithFresh({
    required List<OpenAIClinic> seeds,
    required List<OpenAIClinic> fresh,
    int maxShow = kExploreCompareMaxClinics,
    int freshCount = kExploreAiFreshClinics,
    int seedCount = kExploreFirestoreSeedClinics,
    Set<String>? avoidKeys,
    math.Random? random,
  }) {
    final rng = random ?? math.Random();
    final cachePool = _cappedCachePool(seeds);
    final shuffledSeeds = cachePool..shuffle(rng);
    final shuffledFresh = List<OpenAIClinic>.of(fresh)..shuffle(rng);
    final avoid = avoidKeys ?? const <String>{};

    final preferredSeeds = <OpenAIClinic>[];
    final overlapSeeds = <OpenAIClinic>[];
    for (final c in shuffledSeeds) {
      final keys = exploreClinicIdentityKeys(c);
      if (keys.isNotEmpty && keys.any(avoid.contains)) {
        overlapSeeds.add(c);
      } else {
        preferredSeeds.add(c);
      }
    }

    final out = <OpenAIClinic>[];
    final used = <String>{};

    bool tryAdd(OpenAIClinic c) {
      // Domain + normalized name: "Cronos Med" with cronosmed.ro in area
      // and a later "Cronos Med" with no host still collapse to one card.
      final keys = exploreClinicIdentityKeys(c);
      if (keys.isEmpty || keys.any(used.contains)) return false;
      used.addAll(keys);
      out.add(c);
      return true;
    }

    final wantFresh = freshCount.clamp(0, maxShow);
    final wantCached = seedCount.clamp(0, maxShow);

    for (final c in shuffledFresh) {
      if (out.length >= wantFresh) break;
      final keys = exploreClinicIdentityKeys(c);
      if (keys.isNotEmpty && keys.any(avoid.contains)) continue;
      tryAdd(c);
    }
    final freshPicked = out.length;

    // Cached half: clinics not already on another procedure tab first.
    for (final c in preferredSeeds) {
      if (out.length >= freshPicked + wantCached) break;
      tryAdd(c);
    }
    for (final c in overlapSeeds) {
      if (out.length >= freshPicked + wantCached) break;
      tryAdd(c);
    }

    // Only pad the Firestore half from leftover cache when Google has not
    // reserved slots. Filling leftover cache into the Google half makes every
    // visit look like the same 4 clinics.
    if (wantFresh == 0) {
      for (final c in preferredSeeds) {
        if (out.length >= maxShow) break;
        tryAdd(c);
      }
      for (final c in overlapSeeds) {
        if (out.length >= maxShow) break;
        tryAdd(c);
      }
    }
    // Firestore short → fill remaining from leftover AI (empty-cache cities).
    for (final c in shuffledFresh) {
      if (out.length >= maxShow) break;
      tryAdd(c);
    }

    // Cached pair first, then new Google — do not re-rank by popularity
    // or the first two cards jump when the extra clinics arrive.
    return [
      for (var i = 0; i < out.length; i++) out[i].copyWith(rank: i + 1),
    ];
  }

  static List<OpenAIClinic> _cappedCachePool(List<OpenAIClinic> seeds) {
    if (seeds.length <= kExploreFirestorePoolMax) {
      return List<OpenAIClinic>.of(seeds);
    }
    final ranked = List<OpenAIClinic>.of(seeds)
      ..sort(compareClinicsByGoogleMapsPopularity);
    return ranked.take(kExploreFirestorePoolMax).toList();
  }

  static String _cityKey(String city) {
    final c = normalizeExploreCity(city).toLowerCase().trim();
    if (c.isEmpty) return '';
    if (c.contains('milan') || c.contains('milano')) return 'milan';
    if (c.contains('london')) return 'london';
    if (c.contains('paris')) return 'paris';
    if (c.contains('dubai')) return 'dubai';
    if (c.contains('seoul') || c.contains('korea')) return 'seoul';
    if (c.contains('hong kong') || c == 'hk') return 'hong kong';
    if (c.contains('new york') || c == 'nyc') return 'new york';
    if (c.contains('miami')) return 'miami';
    if (c.contains('los angeles') || c == 'la') return 'los angeles';
    if (c.contains('istanbul')) return 'istanbul';
    if (c.contains('barcelona')) return 'barcelona';
    if (c.contains('bucure') || c.contains('bucharest')) return 'bucharest';
    if (c.contains('delhi') || c.contains('mumbai') || c.contains('bangalore')) {
      if (c.contains('mumbai')) return 'mumbai';
      if (c.contains('bangalore') || c.contains('bengaluru')) return 'bangalore';
      return 'new delhi';
    }
    return c;
  }

  static String? _procedureKey(String pill, String query) {
    final p = pill.trim().toLowerCase();
    final q = query.trim().toLowerCase();
    if (p == 'botox' || q.contains('botox') || q.contains('anti-wrinkle')) {
      return 'botox';
    }
    if (p == 'fillers' ||
        q.contains('filler') ||
        q.contains('dermal filler')) {
      return 'fillers';
    }
    if (p == 'laser' || q.contains('laser')) return 'laser';
    if (p == 'peels' || q.contains('peel')) return 'peels';
    if (p == 'skin' ||
        q.contains('profhilo') ||
        q.contains('skin booster') ||
        q.contains('polynucleotide')) {
      return 'skin';
    }
    if (p == 'rhinoplasty' ||
        q.contains('rhinoplasty') ||
        q.contains('nose job')) {
      return 'rhinoplasty';
    }
    if (p == 'boob job' ||
        q.contains('breast') ||
        q.contains('augmentation')) {
      return 'boob';
    }
    if (p == 'hair' ||
        q.contains('hair transplant') ||
        q.contains('fue') ||
        q.contains('dhi')) {
      return 'hair';
    }
    return null;
  }

  /// city → procedure → seed rows
  static final Map<String, Map<String, List<_SeedClinic>>> _byCity = {
    'milan': {
      'botox': [
        _s('Clinica del Viso', 'Brera', 4.8, 420, 180, '€', 'Forehead Botox', 45.4642, 9.1900),
        _s('Istituto Dermopatico', 'Navigli', 4.7, 310, 150, '€', '3-area Botox', 45.4440, 9.1740),
        _s('Beauty Medical Milano', 'Porta Nuova', 4.9, 580, 200, '€', 'Crow\'s feet Botox', 45.4850, 9.1905),
        _s('Studio Soft Surgery', 'Centro', 4.6, 240, 160, '€', 'Masseter Botox', 45.4680, 9.1820),
        _s('Face Clinic Milano', 'Isola', 4.8, 390, 175, '€', 'Anti-wrinkle injection', 45.4875, 9.1880),
      ],
      'fillers': [
        _s('Lip Art Studio', 'Brera', 4.9, 510, 350, '€', 'Russian lip filler', 45.4710, 9.1870),
        _s('Aesthetic Lab Milano', 'Corso Como', 4.7, 280, 320, '€', 'Cheek filler 1ml', 45.4830, 9.1860),
        _s('Glow Face Clinic', 'Navigli', 4.8, 360, 280, '€', 'Jawline filler', 45.4460, 9.1750),
        _s('Dermal Atelier', 'Porta Venezia', 4.6, 190, 300, '€', 'Tear trough filler', 45.4750, 9.2050),
        _s('Milano Fillers Hub', 'Duomo', 4.8, 440, 340, '€', 'Lip filler 1ml', 45.4640, 9.1910),
      ],
      'laser': [
        _s('Laser Center Milano', 'Loreto', 4.7, 620, 25, '€', 'Laser hair removal underarms', 45.4855, 9.2160),
        _s('Epilazione Expert', 'Città Studi', 4.6, 340, 35, '€', 'Diode laser legs', 45.4780, 9.2280),
        _s('Skin Laser Milano', 'San Babila', 4.8, 410, 80, '€', 'IPL photofacial', 45.4670, 9.1980),
        _s('Luce Estetica', 'Navigli', 4.5, 220, 45, '€', 'Laser hair removal face', 45.4470, 9.1720),
        _s('CO2 Studio Milano', 'Garibaldi', 4.9, 290, 120, '€', 'Fractional CO2 laser', 45.4820, 9.1850),
      ],
      'rhinoplasty': [
        _s('San Raffaele Aesthetic', 'Segrate', 4.6, 890, 13000, '€', 'Rhinoplasty', 45.4760, 9.2800),
        _s('Galeazzi Rhino Unit', 'San Siro', 4.9, 720, 3900, '€', 'Rhinoplasty', 45.4785, 9.1300),
        _s('San Donato Nose Clinic', 'San Donato', 4.8, 650, 7963, '€', 'Rhinoplasty', 45.4200, 9.2600),
        _s('Milano Nose Atelier', 'Centro', 4.7, 310, 8500, '€', 'Primary rhinoplasty', 45.4660, 9.1890),
        _s('Face Surgery Milano', 'Porta Nuova', 4.8, 280, 9800, '€', 'Ultrasonic rhinoplasty', 45.4840, 9.1920),
      ],
      'hair': [
        _s('FUE Milano Clinic', 'Città Studi', 4.8, 540, 3, '€', 'FUE hair transplant', 45.4790, 9.2250, perGraft: true),
        _s('Hairline Milano', 'Lambrate', 4.7, 380, 2.5, '€', 'FUE per graft', 45.4840, 9.2350, perGraft: true),
        _s('DHI Milano', 'Porta Romana', 4.9, 410, 4, '€', 'DHI hair transplant', 45.4520, 9.2020, perGraft: true),
        _s('Capelli Clinic', 'Isola', 4.6, 260, 3500, '€', 'FUE package from', 45.4860, 9.1870),
        _s('Restore Hair Milano', 'Navigli', 4.8, 330, 3.5, '€', 'FUE hair transplant', 45.4450, 9.1730, perGraft: true),
      ],
      'skin': [
        _s('Profhilo Milano', 'Brera', 4.9, 470, 350, '€', 'Profhilo face', 45.4700, 9.1860),
        _s('Skin Booster Lab', 'Duomo', 4.7, 290, 280, '€', 'Skin booster', 45.4635, 9.1905),
        _s('Polynucleotides Studio', 'Porta Venezia', 4.8, 210, 320, '€', 'Polynucleotides', 45.4740, 9.2040),
        _s('Glow Skin Milano', 'Corso Magenta', 4.6, 180, 250, '€', 'Mesotherapy face', 45.4665, 9.1700),
        _s('Bio Remodel Clinic', 'Garibaldi', 4.8, 350, 380, '€', 'Profhilo Structura', 45.4810, 9.1840),
      ],
      'boob': [
        _s('Breast Aesthetic Milano', 'San Donato', 4.7, 520, 7500, '€', 'Breast augmentation', 45.4220, 9.2550),
        _s('Humanitas Breast Unit', 'Rozzano', 4.8, 680, 8200, '€', 'Breast implants', 45.3800, 9.1600),
        _s('Milano Contour Clinic', 'Centro', 4.6, 240, 6900, '€', 'Breast augmentation 300cc', 45.4650, 9.1880),
        _s('Soft Body Surgery', 'Porta Nuova', 4.9, 310, 9100, '€', 'Fat transfer breasts', 45.4835, 9.1910),
        _s('Estetica Petto Milano', 'Lodi', 4.5, 190, 6500, '€', 'Breast lift', 45.4400, 9.2200),
      ],
      'peels': [
        _s('Peel Lab Milano', 'Brera', 4.7, 260, 90, '€', 'Glycolic peel', 45.4690, 9.1850),
        _s('Medical Peel Studio', 'Navigli', 4.8, 310, 150, '€', 'TCA peel', 45.4480, 9.1740),
        _s('Skin Renew Milano', 'Isola', 4.6, 180, 120, '€', 'Jessner peel', 45.4865, 9.1890),
        _s('Dermapeel Center', 'San Babila', 4.9, 400, 180, '€', 'Medical peel', 45.4665, 9.1970),
      ],
    },
    'london': {
      'botox': [
        _s('Harley Street Injectables', 'Marylebone', 4.9, 890, 180, '£', '3-area Botox', 51.5205, -0.1478),
        _s('The London Clinic Aesthetic', 'Mayfair', 4.8, 720, 220, '£', 'Forehead Botox', 51.5100, -0.1470),
        _s('Sk:n London', 'Oxford Circus', 4.6, 1100, 149, '£', 'Anti-wrinkle injection', 51.5154, -0.1419),
        _s('Dr Rita Rakus Clinic', 'Knightsbridge', 4.9, 640, 250, '£', 'Botox', 51.5010, -0.1610),
        _s('Facial Aesthetic London', 'Chelsea', 4.7, 410, 195, '£', 'Crow\'s feet Botox', 51.4875, -0.1687),
      ],
      'fillers': [
        _s('Lip Clinic London', 'Soho', 4.8, 560, 350, '£', 'Lip filler 1ml', 51.5130, -0.1360),
        _s('Mayfair Fillers', 'Mayfair', 4.9, 480, 450, '£', 'Cheek filler', 51.5105, -0.1450),
        _s('Dermal London', 'Canary Wharf', 4.6, 320, 320, '£', 'Jawline filler', 51.5054, -0.0235),
        _s('Glow Aesthetics UK', 'Shoreditch', 4.7, 290, 300, '£', 'Tear trough filler', 51.5230, -0.0780),
        _s('Inject London', 'Notting Hill', 4.8, 370, 380, '£', 'Russian lips', 51.5090, -0.1960),
      ],
      'laser': [
        _s('Pulse Light Clinic', 'Baker Street', 4.7, 780, 49, '£', 'Laser hair removal underarms', 51.5226, -0.1570),
        _s('The Laser Treatment Clinic', 'Harley Street', 4.8, 650, 89, '£', 'IPL photorejuvenation', 51.5200, -0.1460),
        _s('sk:n Laser London', 'Victoria', 4.6, 920, 39, '£', 'Laser hair removal face', 51.4965, -0.1447),
        _s('London Laser Clinic', 'City', 4.7, 410, 120, '£', 'Fractional laser', 51.5155, -0.0922),
      ],
      'hair': [
        _s('The Private Clinic Hair', 'Harley Street', 4.8, 710, 4, '£', 'FUE hair transplant', 51.5202, -0.1475, perGraft: true),
        _s('Wimpole Clinic', 'Marylebone', 4.9, 980, 3.5, '£', 'FUE per graft', 51.5208, -0.1490, perGraft: true),
        _s('Harley Street Hair Clinic', 'Marylebone', 4.7, 540, 5, '£', 'FUE hair transplant', 51.5195, -0.1465, perGraft: true),
        _s('London Hair Restoration', 'Canary Wharf', 4.6, 320, 4500, '£', 'FUE package from', 51.5050, -0.0220),
      ],
      'rhinoplasty': [
        _s('London Rhinoplasty Centre', 'Harley Street', 4.8, 620, 7500, '£', 'Rhinoplasty', 51.5203, -0.1472),
        _s('Face Clinic London', 'Marylebone', 4.7, 410, 6800, '£', 'Nose job', 51.5210, -0.1500),
        _s('Chelsea Nose Surgery', 'Chelsea', 4.9, 380, 8200, '£', 'Primary rhinoplasty', 51.4880, -0.1690),
        _s('UK Aesthetic Nose', 'Knightsbridge', 4.6, 290, 9000, '£', 'Rhinoplasty', 51.5015, -0.1605),
      ],
    },
    'seoul': {
      'botox': [
        _s('Gangnam Soft Clinic', 'Gangnam-gu', 4.9, 2100, 80000, '₩', 'Botox forehead', 37.4979, 127.0276),
        _s('Apgujeong Aesthetic', 'Apgujeong', 4.8, 1800, 70000, '₩', 'Botox 3 areas', 37.5270, 127.0400),
        _s('ID Hospital Injectables', 'Cheongdam', 4.7, 3200, 90000, '₩', 'Masseter Botox', 37.5240, 127.0480),
        _s('Banobagi Skin', 'Gangnam', 4.8, 1500, 75000, '₩', 'Anti-wrinkle Botox', 37.5000, 127.0360),
        _s('Oracle Dermatology', 'Seocho', 4.6, 980, 65000, '₩', 'Botox', 37.4830, 127.0320),
      ],
      'hair': [
        _s('Dream Hairline Clinic', 'Gangnam-gu', 5.0, 2400, 2500, '₩', 'Non-Shaven FUE', 37.5010, 127.0280, perGraft: true),
        _s('Motion Clinic', 'Seocho-gu', 4.9, 1900, 2200, '₩', 'FUE hair transplant', 37.4860, 127.0300, perGraft: true),
        _s('Forhair Korea', 'Gangnam-gu', 4.6, 1600, 2800, '₩', 'High-Density FUE', 37.4990, 127.0350, perGraft: true),
        _s('Moarm Hair', 'Gangnam-gu', 4.8, 1200, 2000, '₩', 'Non-Shaving FUE', 37.5020, 127.0260, perGraft: true),
        _s('Hairon Clinic', 'Seocho-gu', 4.5, 890, 2300, '₩', 'Stem Cell FUE', 37.4840, 127.0330, perGraft: true),
      ],
      'fillers': [
        _s('Gangnam Filler Lab', 'Gangnam', 4.8, 1400, 350000, '₩', 'Lip filler', 37.4985, 127.0270),
        _s('Cheongdam Contour', 'Cheongdam', 4.9, 1100, 450000, '₩', 'Jawline filler', 37.5235, 127.0470),
        _s('Seoul Volume Clinic', 'Apgujeong', 4.7, 980, 400000, '₩', 'Cheek filler', 37.5265, 127.0390),
        _s('ID Filler Center', 'Gangnam', 4.8, 2200, 380000, '₩', 'Lip filler 1ml', 37.5005, 127.0290),
      ],
      'rhinoplasty': [
        _s('ID Hospital Rhino', 'Gangnam', 4.8, 4500, 3500000, '₩', 'Rhinoplasty', 37.5015, 127.0285),
        _s('Banobagi Nose', 'Gangnam', 4.9, 3800, 4200000, '₩', 'Rhinoplasty', 37.5002, 127.0365),
        _s('JW Plastic Surgery', 'Gangnam', 4.7, 2900, 3900000, '₩', 'Nose surgery', 37.4970, 127.0310),
        _s('View Plastic Surgery', 'Gangnam', 4.8, 2600, 4500000, '₩', 'Rhinoplasty', 37.4995, 127.0340),
      ],
    },
    'hong kong': {
      'botox': [
        _s('REDEFINE Medical Aesthetic', 'Causeway Bay', 4.8, 620, 2800, 'HKD', 'Botox 肉毒桿菌', 22.2800, 114.1850),
        _s('Central Injectables', 'Central', 4.7, 480, 2500, 'HKD', 'Botox 3 areas', 22.2810, 114.1550),
        _s('iCare Medical Clinic', 'Central', 4.6, 390, 2200, 'HKD', 'Anti-wrinkle', 22.2825, 114.1580),
        _s('HK Aesthetic Lab', 'Tsim Sha Tsui', 4.8, 510, 3000, 'HKD', 'Forehead Botox', 22.2970, 114.1720),
        _s('Glow HK Clinic', 'Admiralty', 4.5, 280, 2400, 'HKD', 'Botox', 22.2780, 114.1650),
      ],
      'fillers': [
        _s('iCare Medical Clinic', 'Central', 4.6, 390, 4800, 'HKD', 'Lip filler', 22.2825, 114.1580),
        _s('HK Lip Studio', 'Causeway Bay', 4.8, 440, 5200, 'HKD', 'Lip filler 1ml', 22.2795, 114.1840),
        _s('Central Dermal', 'Central', 4.7, 360, 5500, 'HKD', 'Cheek filler', 22.2805, 114.1560),
        _s('TST Filler Hub', 'Tsim Sha Tsui', 4.5, 290, 4500, 'HKD', 'Jawline filler', 22.2965, 114.1730),
      ],
      'rhinoplasty': [
        _s('ENT & Face Clinic', 'Central', 4.7, 310, 45000, 'HKD', 'Rhinoplasty', 22.2815, 114.1570),
        _s('HK Nose Surgery', 'Admiralty', 4.6, 240, 52000, 'HKD', 'Rhinoplasty', 22.2785, 114.1660),
        _s('Central Plastic Surgery', 'Central', 4.8, 420, 68000, 'HKD', 'Nose job', 22.2800, 114.1545),
        _s('Island Aesthetic', 'Causeway Bay', 4.5, 180, 40000, 'HKD', 'Rhinoplasty', 22.2790, 114.1860),
      ],
      'hair': [
        _s('HK Hair Transplant', 'Central', 4.7, 520, 25, 'HKD', 'FUE hair transplant', 22.2812, 114.1555, perGraft: true),
        _s('Central FUE Clinic', 'Central', 4.8, 410, 28, 'HKD', 'FUE per graft', 22.2808, 114.1565, perGraft: true),
        _s('TST Hair Restore', 'Tsim Sha Tsui', 4.6, 330, 22000, 'HKD', 'FUE package from', 22.2975, 114.1710),
        _s('Asia Hair HK', 'Causeway Bay', 4.5, 260, 30, 'HKD', 'FUE hair transplant', 22.2802, 114.1855, perGraft: true),
      ],
    },
    'dubai': {
      'botox': [
        _s('Aesthetics by Couto', 'Jumeirah', 4.9, 780, 900, 'AED', 'Botox 3 areas', 25.1972, 55.2744),
        _s('Dubai Cosmetic Surgery', 'Jumeirah', 4.8, 1200, 800, 'AED', 'Forehead Botox', 25.2048, 55.2708),
        _s('CosmeSurge Dubai', 'JLT', 4.7, 950, 750, 'AED', 'Anti-wrinkle', 25.0690, 55.1410),
        _s('American Academy Dubai', 'Healthcare City', 4.8, 640, 850, 'AED', 'Botox', 25.2340, 55.3200),
      ],
      'hair': [
        _s('Dubai Hair Club', 'Jumeirah', 4.8, 890, 12, 'AED', 'FUE per graft', 25.2000, 55.2700, perGraft: true),
        _s('CosmeSurge Hair', 'JLT', 4.7, 720, 15, 'AED', 'FUE hair transplant', 25.0700, 55.1420, perGraft: true),
        _s('Elite Hair Dubai', 'Marina', 4.6, 510, 12000, 'AED', 'FUE package from', 25.0800, 55.1400),
        _s('FUE Dubai Clinic', 'Healthcare City', 4.9, 680, 10, 'AED', 'FUE per graft', 25.2330, 55.3210, perGraft: true),
      ],
      'fillers': [
        _s('Dubai Lips Clinic', 'Jumeirah', 4.8, 560, 1800, 'AED', 'Lip filler 1ml', 25.1980, 55.2730),
        _s('Marina Fillers', 'Marina', 4.7, 420, 1600, 'AED', 'Cheek filler', 25.0810, 55.1390),
        _s('JLT Aesthetic', 'JLT', 4.6, 380, 1500, 'AED', 'Jawline filler', 25.0685, 55.1415),
        _s('Couto Fillers', 'Jumeirah', 4.9, 710, 2000, 'AED', 'Lip filler', 25.1975, 55.2740),
      ],
    },
    'new york': {
      'botox': [
        _s('Union Square Laser', 'Union Square', 4.8, 2100, 14, r'$', 'Botox per unit', 40.7359, -73.9911),
        _s('SkinSpirit NYC', 'Upper East Side', 4.7, 980, 15, r'$', 'Botox per unit', 40.7736, -73.9566),
        _s('Maxton NYC', 'SoHo', 4.9, 740, 16, r'$', 'Botox', 40.7233, -74.0030),
        _s('LaserAway NYC', 'Midtown', 4.6, 1800, 12, r'$', 'Botox per unit', 40.7549, -73.9840),
        _s('Chelsea Aesthetics', 'Chelsea', 4.8, 560, 13, r'$', 'Anti-wrinkle', 40.7465, -74.0014),
      ],
      'hair': [
        _s('Bernstein Medical', 'Midtown', 4.9, 1200, 7, r'$', 'FUE per graft', 40.7540, -73.9830, perGraft: true),
        _s('NY Hair Club', 'Upper East Side', 4.7, 890, 6, r'$', 'FUE hair transplant', 40.7720, -73.9550, perGraft: true),
        _s('Bosley NYC', 'Manhattan', 4.6, 1500, 8, r'$', 'FUE per graft', 40.7580, -73.9855, perGraft: true),
        _s('Restore Hair NYC', 'SoHo', 4.8, 620, 6500, r'$', 'FUE package from', 40.7240, -74.0020),
      ],
      'fillers': [
        _s('NYC Lip Lab', 'SoHo', 4.8, 810, 750, r'$', 'Lip filler 1ml', 40.7230, -74.0035),
        _s('Manhattan Dermal', 'UES', 4.7, 640, 850, r'$', 'Cheek filler', 40.7740, -73.9570),
        _s('Chelsea Fillers', 'Chelsea', 4.9, 520, 700, r'$', 'Jawline filler', 40.7460, -74.0010),
        _s('Glow Inject NYC', 'Midtown', 4.6, 480, 800, r'$', 'Lip filler', 40.7550, -73.9845),
      ],
    },
    'miami': {
      'botox': [
        _s('Miami Skin Spa', 'Brickell', 4.8, 920, 12, r'$', 'Botox per unit', 25.7617, -80.1918),
        _s('Coral Gables Aesthetics', 'Coral Gables', 4.7, 680, 13, r'$', 'Botox', 25.7215, -80.2684),
        _s('South Beach Inject', 'South Beach', 4.9, 1100, 14, r'$', '3-area Botox', 25.7907, -80.1300),
        _s('Doral Glow Clinic', 'Doral', 4.6, 410, 11, r'$', 'Anti-wrinkle', 25.8195, -80.3553),
      ],
      'hair': [
        _s('Miami Hair Institute', 'Coral Gables', 4.8, 780, 5, r'$', 'FUE per graft', 25.7220, -80.2690, perGraft: true),
        _s('FUE Miami Clinic', 'Brickell', 4.7, 640, 6, r'$', 'FUE hair transplant', 25.7620, -80.1920, perGraft: true),
        _s('South Florida Hair', 'Aventura', 4.6, 520, 5500, r'$', 'FUE package from', 25.9560, -80.1390),
        _s('Restore Miami', 'South Beach', 4.9, 890, 4.5, r'$', 'FUE per graft', 25.7910, -80.1310, perGraft: true),
      ],
    },
    'los angeles': {
      'botox': [
        _s('Beverly Hills Aesthetics', 'Beverly Hills', 4.9, 1400, 14, r'$', 'Botox per unit', 34.0736, -118.4004),
        _s('Skin Laundry LA', 'West Hollywood', 4.7, 980, 13, r'$', 'Botox', 34.0900, -118.3617),
        _s('LaserAway LA', 'Santa Monica', 4.6, 1600, 12, r'$', 'Botox per unit', 34.0195, -118.4912),
        _s('Glow Beauty LA', 'Culver City', 4.8, 720, 15, r'$', 'Anti-wrinkle', 34.0211, -118.3965),
      ],
      'hair': [
        _s('Bosley LA', 'Beverly Hills', 4.8, 1100, 6, r'$', 'FUE per graft', 34.0740, -118.4010, perGraft: true),
        _s('LA Hair MD', 'West Hollywood', 4.7, 780, 7, r'$', 'FUE hair transplant', 34.0905, -118.3620, perGraft: true),
        _s('FUE Los Angeles', 'Santa Monica', 4.6, 640, 5.5, r'$', 'FUE per graft', 34.0200, -118.4910, perGraft: true),
        _s('Restore Hair LA', 'Culver City', 4.9, 520, 7000, r'$', 'FUE package from', 34.0215, -118.3970),
      ],
    },
    'paris': {
      'botox': [
        _s('Clinique des Champs', '8e', 4.8, 890, 280, '€', 'Botox front', 48.8698, 2.3078),
        _s('Centre Laser Sorbonne', '5e', 4.7, 640, 220, '€', 'Toxine botulique', 48.8490, 2.3450),
        _s('Aesthetic Paris', '16e', 4.9, 720, 300, '€', 'Botox 3 zones', 48.8630, 2.2760),
        _s('Institut du Visage', '1er', 4.6, 410, 250, '€', 'Botox', 48.8606, 2.3376),
      ],
      'fillers': [
        _s('Paris Lips', 'Marais', 4.8, 560, 380, '€', 'Acide hyaluronique lèvres', 48.8560, 2.3620),
        _s('Fillers Champs-Élysées', '8e', 4.9, 680, 420, '€', 'Lip filler', 48.8700, 2.3080),
        _s('Dermal Paris', '16e', 4.7, 390, 350, '€', 'Cheek filler', 48.8625, 2.2750),
        _s('Glow Inject Paris', 'Opéra', 4.6, 320, 320, '€', 'Jawline filler', 48.8710, 2.3320),
      ],
    },
    'istanbul': {
      'hair': [
        _s('Clinicana Hair', 'Şişli', 4.8, 4200, 1.5, '€', 'FUE per graft', 41.0600, 28.9870, perGraft: true),
        _s('Hermes Hair Istanbul', 'Şişli', 4.7, 3100, 1.2, '€', 'FUE hair transplant', 41.0580, 28.9850, perGraft: true),
        _s('Cosmedica', 'Şişli', 4.9, 5600, 1.8, '€', 'FUE per graft', 41.0620, 28.9900, perGraft: true),
        _s('Vera Clinic', 'Şişli', 4.8, 4800, 2, '€', 'DHI hair transplant', 41.0590, 28.9880, perGraft: true),
        _s('Asmed Hair', 'Ataşehir', 4.6, 2900, 2500, '€', 'FUE package from', 40.9920, 29.1250),
      ],
      'botox': [
        _s('Istanbul Aesthetic', 'Nişantaşı', 4.8, 980, 280, r'$', 'Botox', 41.0520, 28.9940),
        _s('Estetik International', 'Levent', 4.7, 1200, 250, r'$', 'Botox 3 areas', 41.0810, 29.0120),
        _s('Acıbadem Aesthetic', 'Kadıköy', 4.6, 860, 320, r'$', 'Anti-wrinkle', 40.9900, 29.0300),
        _s('Glow Istanbul', 'Beşiktaş', 4.8, 640, 220, r'$', 'Botox', 41.0420, 29.0050),
      ],
      'fillers': [
        _s('Nişantaşı Fillers', 'Nişantaşı', 4.8, 720, 9500, 'TRY', 'Lip filler 1ml', 41.0515, 28.9935),
        _s('Lips Istanbul', 'Beşiktaş', 4.7, 540, 8500, 'TRY', 'Russian lip filler', 41.0430, 29.0060),
        _s('Dermal Atelier IST', 'Levent', 4.9, 610, 12000, 'TRY', 'Cheek filler', 41.0805, 29.0115),
        _s('Contour Clinic Kadıköy', 'Kadıköy', 4.6, 380, 11000, 'TRY', 'Jawline filler', 40.9905, 29.0295),
        _s('Injectables Şişli', 'Şişli', 4.8, 450, 8000, 'TRY', 'Dermal filler 1ml', 41.0575, 28.9865),
      ],
      'peels': [
        _s('Peel Lab Istanbul', 'Nişantaşı', 4.7, 310, 2500, 'TRY', 'Glycolic peel', 41.0505, 28.9950),
        _s('Skin Renew Levent', 'Levent', 4.8, 280, 3500, 'TRY', 'TCA peel', 41.0820, 29.0130),
        _s('Medical Peel Kadıköy', 'Kadıköy', 4.6, 220, 1800, 'TRY', 'Jessner peel', 40.9915, 29.0310),
        _s('Dermapeel Beşiktaş', 'Beşiktaş', 4.9, 360, 4000, 'TRY', 'Medical peel', 41.0410, 29.0040),
      ],
      'laser': [
        _s('Laser Istanbul', 'Şişli', 4.7, 640, 1200, 'TRY', 'Laser hair removal underarms', 41.0560, 28.9840),
        _s('Epilasyon Center', 'Kadıköy', 4.6, 510, 900, 'TRY', 'Diode laser legs', 40.9890, 29.0280),
        _s('Skin Laser Levent', 'Levent', 4.8, 420, 1800, 'TRY', 'IPL photofacial', 41.0795, 29.0100),
        _s('Luce Estetik IST', 'Nişantaşı', 4.5, 280, 1500, 'TRY', 'Laser hair removal face', 41.0530, 28.9960),
      ],
      'skin': [
        _s('Profhilo Istanbul', 'Nişantaşı', 4.9, 470, 12000, 'TRY', 'Profhilo face', 41.0525, 28.9945),
        _s('Skin Booster Lab IST', 'Beşiktaş', 4.7, 290, 8500, 'TRY', 'Skin booster', 41.0440, 29.0070),
        _s('Polynucleotides Studio', 'Levent', 4.8, 210, 11000, 'TRY', 'Polynucleotides', 41.0815, 29.0125),
        _s('Bio Remodel Kadıköy', 'Kadıköy', 4.6, 180, 9500, 'TRY', 'Profhilo Structura', 40.9920, 29.0320),
      ],
      'rhinoplasty': [
        _s('Istanbul Nose Clinic', 'Şişli', 4.8, 820, 3200, '€', 'Rhinoplasty', 41.0610, 28.9880),
        _s('Memorial Rhinoplasty', 'Şişli', 4.7, 610, 3800, '€', 'Primary rhinoplasty', 41.0585, 28.9860),
        _s('Esteworld Nose', 'Altunizade', 4.9, 740, 2800, '€', 'Rhinoplasty', 41.0210, 29.0400),
        _s('Face Surgery Istanbul', 'Nişantaşı', 4.6, 340, 4500, '€', 'Ultrasonic rhinoplasty', 41.0540, 28.9970),
      ],
      'boob': [
        _s('Breast Aesthetic Istanbul', 'Şişli', 4.7, 520, 4200, '€', 'Breast augmentation', 41.0595, 28.9890),
        _s('Esteworld Breast', 'Altunizade', 4.8, 680, 3800, '€', 'Breast implants', 41.0205, 29.0395),
        _s('Memorial Breast Unit', 'Şişli', 4.6, 440, 5100, '€', 'Breast augmentation 300cc', 41.0570, 28.9855),
        _s('Istanbul Contour Surgery', 'Levent', 4.9, 310, 4600, '€', 'Fat transfer breasts', 41.0800, 29.0110),
      ],
    },
    'barcelona': {
      'botox': [
        _s('Clínica Planas', 'Sarrià', 4.8, 1100, 220, '€', 'Bótox', 41.4000, 2.1200),
        _s('Instituto de Benito', 'Eixample', 4.9, 890, 250, '€', 'Botox 3 áreas', 41.3910, 2.1650),
        _s('Antiaging Group Barcelona', 'Pedralbes', 4.7, 720, 200, '€', 'Toxina botulínica', 41.3890, 2.1120),
        _s('Barcelona Face Clinic', 'Gràcia', 4.6, 480, 180, '€', 'Botox', 41.4030, 2.1580),
      ],
      'fillers': [
        _s('Lips BCN', 'Eixample', 4.8, 560, 320, '€', 'Relleno labios', 41.3920, 2.1640),
        _s('Dermal Barcelona', 'Sarrià', 4.7, 410, 350, '€', 'Ácido hialurónico', 41.3990, 2.1210),
        _s('Glow BCN', 'Born', 4.6, 340, 280, '€', 'Lip filler', 41.3840, 2.1820),
        _s('Injectables Barcelona', 'Pedralbes', 4.9, 620, 380, '€', 'Cheek filler', 41.3885, 2.1130),
      ],
    },
    'bucharest': {
      'botox': [
        _s('Clinica Estet', 'Floreasca', 4.8, 720, 450, 'RON', 'Botox 3 zone', 44.4680, 26.1030),
        _s('Dermastyle', 'Aviatorilor', 4.7, 580, 400, 'RON', 'Botox frunte', 44.4650, 26.0900),
        _s('Botox Boutique', 'Dorobanți', 4.9, 410, 480, 'RON', 'Botox', 44.4600, 26.1000),
        _s('Glow București', 'Herăstrău', 4.6, 320, 380, 'RON', 'Injectabile botox', 44.4750, 26.0800),
      ],
      'fillers': [
        _s('Lip Clinic București', 'Floreasca', 4.8, 490, 900, 'RON', 'Acid hialuronic buze', 44.4675, 26.1025),
        _s('Fillers RO', 'Aviatorilor', 4.7, 380, 850, 'RON', 'Filler buze 1ml', 44.4645, 26.0895),
        _s('Estetic Contur', 'Dorobanți', 4.6, 290, 950, 'RON', 'Filler pomeți', 44.4595, 26.0995),
        _s('Dermal București', 'Herăstrău', 4.8, 360, 800, 'RON', 'Filler jawline', 44.4745, 26.0795),
      ],
      'laser': [
        _s('Laser Med București', 'Floreasca', 4.7, 640, 80, 'RON', 'Epilare laser axilă', 44.4685, 26.1035),
        _s('Epilare Expert RO', 'Aviatorilor', 4.6, 510, 120, 'RON', 'Laser picioare', 44.4655, 26.0905),
        _s('Skin Laser București', 'Dorobanți', 4.8, 420, 200, 'RON', 'IPL față', 44.4605, 26.1005),
        _s('Luce Estetica RO', 'Herăstrău', 4.5, 280, 90, 'RON', 'Laser facial', 44.4755, 26.0805),
      ],
    },
    'new delhi': {
      'botox': [
        _s('JL Aesthetics', 'Defence Colony', 4.8, 620, 8999, 'INR', 'Botox 50 units', 28.5730, 77.2320),
        _s('Isya Aesthetics', 'Greater Kailash', 4.9, 890, 12000, 'INR', 'Forehead Botox', 28.5480, 77.2420),
        _s('Berkowits Hair & Skin', 'Rajouri Garden', 4.7, 1100, 7500, 'INR', 'Anti-wrinkle Botox', 28.6460, 77.1210),
        _s('SkinKraft Clinic', 'Saket', 4.6, 480, 9999, 'INR', '3-area Botox', 28.5240, 77.2060),
        _s('Clinic Dermatech', 'Punjabi Bagh', 4.8, 720, 8500, 'INR', 'Botox', 28.6680, 77.1320),
      ],
      'fillers': [
        _s('Delhi Lip Studio', 'Hauz Khas', 4.8, 540, 18000, 'INR', 'Lip filler 1ml', 28.5490, 77.2000),
        _s('Isya Contour', 'Greater Kailash', 4.9, 710, 25000, 'INR', 'Cheek filler', 28.5485, 77.2425),
        _s('Fillers India', 'Vasant Kunj', 4.7, 390, 22000, 'INR', 'Jawline filler', 28.5400, 77.1550),
        _s('Glow Inject Delhi', 'South Extension', 4.6, 320, 15000, 'INR', 'Lip filler', 28.5680, 77.2200),
        _s('Aesthetic Hub Delhi', 'Karol Bagh', 4.8, 450, 20000, 'INR', 'Dermal filler 1ml', 28.6510, 77.1900),
      ],
      'laser': [
        _s('Oliva Clinic Delhi', 'Defence Colony', 4.8, 980, 1999, 'INR', 'Laser hair removal underarms', 28.5725, 77.2315),
        _s('Kaya Skin Clinic', 'Saket', 4.7, 1400, 2499, 'INR', 'Laser hair removal face', 28.5245, 77.2065),
        _s('VLCC Delhi', 'Connaught Place', 4.5, 2100, 1499, 'INR', 'Diode laser underarms', 28.6315, 77.2167),
        _s('Enrich Hair & Skin', 'GK-1', 4.6, 560, 3500, 'INR', 'IPL photofacial', 28.5500, 77.2400),
        _s('Laser Clinic Delhi', 'Rohini', 4.7, 640, 2999, 'INR', 'Laser hair removal legs', 28.7400, 77.1200),
      ],
      'rhinoplasty': [
        _s('Medanta Aesthetic', 'Gurugram', 4.8, 820, 95000, 'INR', 'Rhinoplasty', 28.4500, 77.0700),
        _s('Apollo Spectra Nose', 'Karol Bagh', 4.7, 610, 120000, 'INR', 'Primary rhinoplasty', 28.6520, 77.1910),
        _s('Delhi Nose Clinic', 'South Extension', 4.6, 340, 85000, 'INR', 'Rhinoplasty', 28.5685, 77.2205),
        _s('Face Surgery Delhi', 'Saket', 4.9, 480, 150000, 'INR', 'Ultrasonic rhinoplasty', 28.5250, 77.2070),
      ],
      'hair': [
        _s('Berkowits Hair Clinic', 'Rajouri Garden', 4.8, 1500, 80, 'INR', 'FUE per graft', 28.6465, 77.1215, perGraft: true),
        _s('DHI India Delhi', 'Defence Colony', 4.9, 1200, 120, 'INR', 'DHI hair transplant', 28.5735, 77.2325, perGraft: true),
        _s('Hair Transplant Delhi', 'Saket', 4.7, 890, 60, 'INR', 'FUE hair transplant', 28.5255, 77.2075, perGraft: true),
        _s('Restore Hair India', 'GK', 4.6, 720, 55000, 'INR', 'FUE package from', 28.5495, 77.2410),
        _s('AK Clinics Delhi', 'Punjabi Bagh', 4.8, 980, 90, 'INR', 'FUE per graft', 28.6685, 77.1325, perGraft: true),
      ],
      'skin': [
        _s('Profhilo Delhi', 'Greater Kailash', 4.9, 410, 28000, 'INR', 'Profhilo face', 28.5482, 77.2422),
        _s('Skin Booster Delhi', 'Hauz Khas', 4.7, 360, 18000, 'INR', 'Skin booster', 28.5492, 77.2002),
        _s('Polynucleotides Delhi', 'Saket', 4.8, 290, 22000, 'INR', 'Polynucleotides', 28.5242, 77.2062),
        _s('Glow Skin Delhi', 'Defence Colony', 4.6, 250, 15000, 'INR', 'Mesotherapy face', 28.5728, 77.2318),
      ],
      'boob': [
        _s('Medanta Breast Unit', 'Gurugram', 4.8, 540, 180000, 'INR', 'Breast augmentation', 28.4510, 77.0710),
        _s('Apollo Breast Clinic', 'Delhi', 4.7, 420, 220000, 'INR', 'Breast implants', 28.5670, 77.2100),
        _s('Delhi Contour Surgery', 'Saket', 4.6, 280, 160000, 'INR', 'Breast augmentation 300cc', 28.5252, 77.2072),
        _s('Aesthetic Body Delhi', 'Vasant Kunj', 4.8, 310, 200000, 'INR', 'Fat transfer breasts', 28.5405, 77.1555),
      ],
      'peels': [
        _s('Kaya Peel Delhi', 'Saket', 4.7, 780, 3500, 'INR', 'Glycolic peel', 28.5248, 77.2068),
        _s('Oliva Chemical Peel', 'Defence Colony', 4.8, 640, 4500, 'INR', 'TCA peel', 28.5722, 77.2312),
        _s('Skin Peel Hub', 'GK', 4.6, 390, 2999, 'INR', 'Medical peel', 28.5498, 77.2412),
        _s('Dermapeel Delhi', 'South Extension', 4.9, 510, 5500, 'INR', 'Jessner peel', 28.5682, 77.2202),
      ],
    },
  };
}

class _SeedClinic {
  const _SeedClinic({
    required this.name,
    required this.area,
    required this.rating,
    required this.reviews,
    required this.priceMin,
    required this.currency,
    required this.brand,
    required this.lat,
    required this.lng,
    this.perGraft = false,
  });

  final String name;
  final String area;
  final double rating;
  final int reviews;
  final double priceMin;
  final String currency;
  final String brand;
  final double lat;
  final double lng;
  final bool perGraft;

  OpenAIClinic toClinic({
    required int rank,
    required String fallbackCurrency,
  }) {
    final cur = currency.isNotEmpty ? currency : fallbackCurrency;
    final label = perGraft
        ? 'from ${_fmt(priceMin)} $cur/graft'
        : 'from ${_fmt(priceMin)} $cur';
    return OpenAIClinic(
      rank: rank,
      name: name,
      area: area,
      distanceMi: 0.8 + (rank * 0.3),
      rating: rating,
      reviews: reviews,
      priceGbp: priceMin.round(),
      priceMin: priceMin,
      priceMax: priceMin,
      priceLabel: label,
      currency: cur,
      currencyConfirmed: true,
      brand: brand,
      badge: rank == 1 ? 'Top rated' : (rank <= 3 ? 'Highly rated' : 'Popular'),
      badgeVariant: rank == 1 ? 'best' : (rank >= 5 ? 'hi' : 'mid'),
      coord: OpenAICoord(lat, lng),
      hasProcedure: true,
    );
  }

  static String _fmt(double v) {
    if (v >= 10000) return '${(v / 1000).round()}k';
    if (v == v.roundToDouble()) {
      final n = v.round();
      final s = n.toString();
      final buf = StringBuffer();
      for (var i = 0; i < s.length; i++) {
        if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
        buf.write(s[i]);
      }
      return buf.toString();
    }
    return v.toStringAsFixed(1);
  }
}

_SeedClinic _s(
  String name,
  String area,
  double rating,
  int reviews,
  double priceMin,
  String currency,
  String brand,
  double lat,
  double lng, {
  bool perGraft = false,
}) =>
    _SeedClinic(
      name: name,
      area: area,
      rating: rating,
      reviews: reviews,
      priceMin: priceMin,
      currency: currency,
      brand: brand,
      lat: lat,
      lng: lng,
      perGraft: perGraft,
    );
