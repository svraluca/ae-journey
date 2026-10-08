import 'package:flutter_test/flutter_test.dart';
import 'package:glowpass/services/explore_comparison_session.dart';
import 'package:glowpass/services/explore_curated_price_store.dart';
import 'package:glowpass/services/explore_price_sanity.dart';
import 'package:glowpass/services/explore_price_verification.dart';
import 'package:glowpass/services/openai_service.dart';

OpenAIClinic _curated({
  required String name,
  required String procedure,
  required double price,
  DateTime? checkedAt,
  String sourceUrl = 'https://miamiskinspa.com/pricing/',
  String currency = 'USD',
  String priceType = 'per_unit',
  String unit = 'unit',
  String family = 'botox',
}) {
  return OpenAIClinic(
    rank: 1,
    name: name,
    area: 'Miami · src:$sourceUrl',
    distanceMi: 0,
    rating: 4.9,
    reviews: 200,
    priceGbp: 0,
    priceMin: price,
    priceMax: price,
    priceLabel: '\$${price.round()} per $unit',
    currency: currency,
    brand: procedure,
    badge: '',
    badgeVariant: 'mid',
    coord: const OpenAICoord(0, 0),
    hasProcedure: true,
    pricePending: false,
    currencyConfirmed: true,
    priceSourceUrl: sourceUrl,
    priceVerificationStatus: PriceVerificationStatus.curatedPublicSite,
    priceVerificationConfidence: 1,
    lastCheckedAt: checkedAt ?? DateTime.utc(2026, 9, 8),
    rawProcedureText: procedure,
    priceType: priceType,
    priceUnit: unit,
    sourceType: kExploreCuratedSourceType,
    procedureFamily: family,
    procedureCanonical: family,
    procedureRelation: 'exact',
  );
}

OpenAIClinic _official({
  required String name,
  required double price,
  required DateTime verifiedAt,
  String procedure = 'Botox',
  String sourceUrl = 'https://miamiskinspa.com/pricing/',
}) {
  return OpenAIClinic(
    rank: 1,
    name: name,
    area: 'Miami · src:$sourceUrl',
    distanceMi: 1,
    rating: 4.9,
    reviews: 200,
    priceGbp: 0,
    priceMin: price,
    priceMax: price,
    priceLabel: '\$${price.round()} per unit',
    currency: 'USD',
    brand: procedure,
    badge: '',
    badgeVariant: 'mid',
    coord: const OpenAICoord(25.76, -80.19),
    hasProcedure: true,
    pricePending: false,
    currencyConfirmed: true,
    priceSourceUrl: sourceUrl,
    priceEvidenceText: 'Botox \$15 per unit',
    priceVerificationStatus: PriceVerificationStatus.officialWebsite,
    priceVerifiedAt: verifiedAt,
    rawProcedureText: procedure,
    rawPriceText: '\$15 per unit',
    extractionMethod: 'html_table',
    sourceType: 'official_clinic',
    procedureFamily: 'botox',
    priceExtractRevision: kExplorePriceExtractRevision,
    procedureRelation: 'exact',
  );
}

OpenAIClinic _snippet({
  required String name,
  required double price,
}) {
  return OpenAIClinic(
    rank: 1,
    name: name,
    area: 'Miami',
    distanceMi: 1,
    rating: 4.5,
    reviews: 10,
    priceGbp: 0,
    priceMin: price,
    priceMax: price,
    priceLabel: '\$${price.round()}',
    currency: 'USD',
    brand: 'Botox',
    badge: '',
    badgeVariant: 'mid',
    coord: const OpenAICoord(25.76, -80.19),
    hasProcedure: true,
    pricePending: false,
    priceSourceUrl: 'https://example.com/search',
    priceVerificationStatus: PriceVerificationStatus.searchEvidence,
    rawProcedureText: 'Botox',
    rawPriceText: '\$$price',
    extractionMethod: 'text_proximity',
    sourceType: 'search_snippet',
  );
}

void main() {
  group('curated search aliases', () {
    test('flagship pills resolve without OpenAI', () {
      expect(exploreCuratedFamilyKeys('Botox anti-wrinkle injection'), ['botox']);
      expect(exploreCuratedFamilyKeys('dermal filler lips cheeks'), ['filler']);
      expect(
        exploreCuratedFamilyKeys('dermal filler lips cheeks'),
        isNot(contains('skin')),
      );
      expect(exploreCuratedFamilyKeys('rhinoplasty nose job'), ['rhinoplasty']);
      expect(exploreCuratedFamilyKeys('breast augmentation'), ['breast_augmentation']);
      expect(exploreCuratedFamilyKeys('boob job'), ['breast_augmentation']);
      expect(
        exploreCuratedFamilyKeys('breast augmentation'),
        isNot(contains('surgery')),
      );
      expect(exploreCuratedFamilyKeys('hair transplant FUE').first, 'hair_transplant');
      expect(exploreCuratedFamilyKeys('chemical peel facial'), ['peel']);
    });

    test('common aliases hit the same families', () {
      expect(exploreCuratedFamilyKeys('boob job').first, 'breast_augmentation');
      expect(exploreCuratedFamilyKeys('nose job').first, 'rhinoplasty');
      expect(exploreCuratedFamilyKeys('wrinkle relaxer'), ['botox']);
      expect(exploreCuratedFamilyKeys('lip injections'), ['filler']);
      expect(exploreCuratedFamilyKeys('VI Peel'), ['peel']);
      expect(exploreCuratedFamilyKeys('Morpheus8').first, 'microneedling');
      expect(exploreCuratedFamilyKeys('HydraFacial').first, 'hydrafacial');
    });

    test('London searches the london city key', () {
      expect(ExploreCuratedPriceStore.cityKeyFor('London'), 'london');
      expect(ExploreCuratedPriceStore.cityKeyFor('Westminster'), 'london');
      expect(ExploreCuratedPriceStore.cityKeyFor('Harley Street'), 'london');
    });

    test('New York searches the new york city key', () {
      expect(ExploreCuratedPriceStore.cityKeyFor('New York'), 'new york');
      expect(ExploreCuratedPriceStore.cityKeyFor('NYC'), 'new york');
      expect(ExploreCuratedPriceStore.cityKeyFor('Manhattan'), 'new york');
      expect(ExploreCuratedPriceStore.cityKeyFor('Brooklyn'), 'new york');
    });

    test('Los Angeles searches the los angeles city key', () {
      expect(ExploreCuratedPriceStore.cityKeyFor('Los Angeles'), 'los angeles');
      expect(ExploreCuratedPriceStore.cityKeyFor('LA'), 'los angeles');
      expect(ExploreCuratedPriceStore.cityKeyFor('Beverly Hills'), 'los angeles');
      expect(ExploreCuratedPriceStore.cityKeyFor('Santa Monica'), 'los angeles');
    });

    test('Houston searches the houston city key', () {
      expect(ExploreCuratedPriceStore.cityKeyFor('Houston'), 'houston');
      expect(ExploreCuratedPriceStore.cityKeyFor('The Woodlands'), 'houston');
      expect(ExploreCuratedPriceStore.cityKeyFor('Bellaire'), 'houston');
      expect(ExploreCuratedPriceStore.cityKeyFor('Sugar Land'), 'houston');
    });

    test('Dallas searches the dallas city key', () {
      expect(ExploreCuratedPriceStore.cityKeyFor('Dallas'), 'dallas');
      expect(ExploreCuratedPriceStore.cityKeyFor('DFW'), 'dallas');
      expect(ExploreCuratedPriceStore.cityKeyFor('Plano'), 'dallas');
      expect(ExploreCuratedPriceStore.cityKeyFor('Frisco'), 'dallas');
    });

    test('remaining US metros search their city keys', () {
      expect(ExploreCuratedPriceStore.cityKeyFor('Atlanta'), 'atlanta');
      expect(ExploreCuratedPriceStore.cityKeyFor('Buckhead'), 'atlanta');
      expect(ExploreCuratedPriceStore.cityKeyFor('Austin'), 'austin');
      expect(ExploreCuratedPriceStore.cityKeyFor('Boston'), 'boston');
      expect(ExploreCuratedPriceStore.cityKeyFor('Charlotte'), 'charlotte');
      expect(ExploreCuratedPriceStore.cityKeyFor('Chicago'), 'chicago');
      expect(ExploreCuratedPriceStore.cityKeyFor('Denver'), 'denver');
      expect(ExploreCuratedPriceStore.cityKeyFor('Las Vegas'), 'las vegas');
      expect(ExploreCuratedPriceStore.cityKeyFor('Nashville'), 'nashville');
      expect(ExploreCuratedPriceStore.cityKeyFor('Orlando'), 'orlando');
      expect(ExploreCuratedPriceStore.cityKeyFor('Winter Park'), 'orlando');
      expect(ExploreCuratedPriceStore.cityKeyFor('Phoenix'), 'phoenix');
      expect(ExploreCuratedPriceStore.cityKeyFor('Scottsdale'), 'phoenix');
      expect(ExploreCuratedPriceStore.cityKeyFor('Washington DC'), 'washington dc');
      expect(ExploreCuratedPriceStore.cityKeyFor('Bethesda'), 'washington dc');
      expect(ExploreCuratedPriceStore.cityKeyFor('Tampa'), 'tampa');
      expect(ExploreCuratedPriceStore.cityKeyFor('San Diego'), 'san diego');
      expect(ExploreCuratedPriceStore.cityKeyFor('La Jolla'), 'san diego');
    });

    test('Canadian metros search their city keys', () {
      expect(ExploreCuratedPriceStore.cityKeyFor('Toronto'), 'toronto');
      expect(ExploreCuratedPriceStore.cityKeyFor('Mississauga'), 'toronto');
      expect(ExploreCuratedPriceStore.cityKeyFor('Markham'), 'toronto');
      expect(ExploreCuratedPriceStore.cityKeyFor('Oakville'), 'toronto');
      expect(ExploreCuratedPriceStore.cityKeyFor('Richmond Hill'), 'toronto');
      expect(ExploreCuratedPriceStore.cityKeyFor('Vaughan'), 'toronto');
      expect(ExploreCuratedPriceStore.cityKeyFor('Vancouver'), 'vancouver');
      expect(ExploreCuratedPriceStore.cityKeyFor('Burnaby'), 'vancouver');
      expect(ExploreCuratedPriceStore.cityKeyFor('Surrey'), 'vancouver');
      expect(ExploreCuratedPriceStore.cityKeyFor('Montreal'), 'montreal');
      expect(ExploreCuratedPriceStore.cityKeyFor('Montréal'), 'montreal');
      expect(ExploreCuratedPriceStore.cityKeyFor('Quebec City'), 'quebec city');
      expect(ExploreCuratedPriceStore.cityKeyFor('Québec'), 'quebec city');
      expect(ExploreCuratedPriceStore.cityKeyFor('Hamilton'), 'hamilton');
      expect(ExploreCuratedPriceStore.cityKeyFor('Calgary'), 'calgary');
    });
  });

  group('curated vs live merge', () {
    test('newer official website price replaces curated', () {
      final curated = _curated(
        name: 'Miami Skin Spa',
        procedure: 'Botox',
        price: 14,
        checkedAt: DateTime.utc(2026, 9, 8),
      );
      final live = _official(
        name: 'Miami Skin Spa',
        price: 15,
        verifiedAt: DateTime.utc(2026, 9, 15),
      );
      final kept = explorePreferFresherTrustedPrice(curated, live);
      expect(kept.priceMin, 15);
      expect(
        kept.priceVerificationStatus,
        PriceVerificationStatus.officialWebsite,
      );
    });

    test('older official cache loses to more recent curated', () {
      final live = _official(
        name: 'Miami Skin Spa',
        price: 13,
        verifiedAt: DateTime.utc(2026, 8, 1),
      );
      final curated = _curated(
        name: 'Miami Skin Spa',
        procedure: 'Botox',
        price: 14,
        checkedAt: DateTime.utc(2026, 9, 8),
      );
      expect(
        explorePreferFresherTrustedPrice(live, curated).priceMin,
        14,
      );
    });

    test('unverified search snippet cannot replace curated', () {
      final curated = _curated(
        name: 'Miami Skin Spa',
        procedure: 'Botox',
        price: 14,
      );
      final snippet = _snippet(name: 'Miami Skin Spa', price: 9);
      expect(
        explorePreferFresherTrustedPrice(curated, snippet).priceMin,
        14,
      );
      expect(
        explorePreferFresherTrustedPrice(snippet, curated).priceMin,
        14,
      );
    });

    test('a live official quote that would fail compare cannot replace curated', () {
      final curated = _curated(
        name: 'Careaga Plastic Surgery',
        procedure: 'Breast Augmentation',
        price: 5500,
        family: 'breast_augmentation',
        priceType: 'from',
        unit: '',
        sourceUrl: 'https://www.careagaplasticsurgery.com/pricing-guide/',
      );
      final live = _official(
        name: 'Careaga Plastic Surgery',
        price: 40,
        procedure: 'Breast Augmentation',
        verifiedAt: DateTime.utc(2026, 9, 15),
        sourceUrl: 'https://www.careagaplasticsurgery.com/pricing-guide/',
      );
      expect(
        explorePreferFresherTrustedPrice(
          live,
          curated,
          procedure: 'breast augmentation',
        ).priceMin,
        5500,
      );
      expect(
        explorePreferFresherTrustedPrice(
          curated,
          live,
          procedure: 'breast augmentation',
        ).sourceType,
        kExploreCuratedSourceType,
      );
    });
  });

  group('curated trust is independent of extract revision', () {
    test('a curated row stays eligible without DOM evidence', () {
      final clinic = _curated(
        name: 'Miami Skin Spa - Brickell',
        procedure: 'Botox',
        price: 14,
      );
      expect(exploreCuratedPriceIsTrusted(clinic), isTrue);
      expect(explorePriceIsVerified(clinic), isTrue);
      expect(
        exploreClinicEligibleForVerifiedPool(
          clinic,
          procedure: 'Botox anti-wrinkle injection',
          city: 'Miami',
        ),
        isTrue,
      );
    });

    test('extract-revision strip does not blank a curated price', () {
      final clinic = _curated(
        name: 'Miami Skin Spa - Brickell',
        procedure: 'Botox',
        price: 14,
      ).copyWith(priceExtractRevision: 'e12');
      final kept = stripStaleExtractedClinicPrice(clinic);
      expect(kept.priceMin, 14);
      expect(
        kept.priceVerificationStatus,
        PriceVerificationStatus.curatedPublicSite,
      );
    });

    test('fromJson keeps a curated row that has no extraction method', () {
      final clinic = _curated(
        name: 'Miami Skin Spa - Brickell',
        procedure: 'HydraFacial Platinum',
        price: 299,
        family: 'hydrafacial',
        priceType: 'fixed',
        unit: '',
      );
      final json = <String, Object?>{
        'name': clinic.name,
        'area': clinic.area,
        'price_min': clinic.priceMin,
        'price_max': clinic.priceMax,
        'price_label': clinic.priceLabel,
        'currency': clinic.currency,
        'brand': clinic.brand,
        'has_procedure': true,
        'price_source_url': clinic.priceSourceUrl,
        'price_verification_status': 'curated_public_site',
        'source_type': kExploreCuratedSourceType,
        'raw_procedure_text': clinic.rawProcedureText,
        'last_checked_at': clinic.lastCheckedAt!.toUtc().toIso8601String(),
        'procedure_family': clinic.procedureFamily,
      };
      final restored = OpenAIClinic.fromJson(json);
      expect(restored.priceMin, 299);
      expect(restored.brand, 'HydraFacial Platinum');
      expect(exploreCuratedPriceIsTrusted(restored), isTrue);
    });

    test('cached google-store JSON for a curated row is not zeroed', () {
      final kept = stripInvalidCachedPriceJson(
        {
          'name': 'Miami Skin Spa',
          'price_min': 14,
          'currency': 'USD',
          'source_type': 'curated_public_site',
          'price_verification_status': 'curated_public_site',
          'source_url': 'https://miamiskinspa.com/pricing/',
        },
        procedure: 'Botox',
      );
      expect(kept['price_min'], 14);
    });
  });

  group('All-tab mix with a full curated pool', () {
    test('full pool seeds 2 Firestore and still hunts 2 Google', () {
      final plan = planExplorePoolMix(4, liveVerifiedCount: 4);
      expect(plan.firestoreShow, 2);
      expect(plan.skipLiveGoogle, isFalse);
      expect(plan.googleLiveTarget, 2);
    });

    test('empty live count still seeds 2 verified and leaves Google slots', () {
      final plan = planExplorePoolMix(4, liveVerifiedCount: 0);
      expect(plan.firestoreShow, 2);
      expect(plan.skipLiveGoogle, isFalse);
      expect(plan.googleLiveTarget, 2);
    });
  });

  group('curated breast cards survive compare filters', () {
    OpenAIClinic breastClinic(String name, double price) => _curated(
          name: name,
          procedure: 'Breast Augmentation - Motiva Ergonomix',
          price: price,
          family: 'breast_augmentation',
          priceType: 'from',
          unit: '',
          sourceUrl: 'https://www.careagaplasticsurgery.com/pricing-guide/',
        );

    test('a Motiva row is justified without DOM evidence', () {
      final clinic = breastClinic('Careaga Plastic Surgery', 6000);
      expect(exploreClinicMatchesProcedure(clinic, 'breast augmentation'), isTrue);
      expect(
        isJustifiedProcedurePrice(clinic, procedure: 'breast augmentation'),
        isTrue,
      );
      expect(
        exploreClinicEligibleForVerifiedPool(
          clinic,
          procedure: 'breast augmentation',
          city: 'Miami',
        ),
        isTrue,
      );
    });

    test('compare filter keeps four curated breast clinics', () {
      final kept = filterComparisonClinicsWithJustifiedPrices(
        clinics: [
          breastClinic('Avana Plastic Surgery', 3000),
          breastClinic('Careaga Plastic Surgery', 6000),
          breastClinic('CG Cosmetic Surgery', 2500),
          breastClinic('Svelta Plastic Surgery', 2800),
          _snippet(name: 'Market Average Blog', price: 4000),
        ],
        procedure: 'breast augmentation',
      );
      expect(kept.length, 4);
      expect(
        kept.map((c) => c.name),
        isNot(contains('Market Average Blog')),
      );
    });

    test('paint pool keeps curated first and still exposes pool diversity', () {
      final curated = [
        breastClinic('Avana Plastic Surgery', 3000),
        breastClinic('Careaga Plastic Surgery', 6000),
        breastClinic('CG Cosmetic Surgery', 2500),
        breastClinic('Svelta Plastic Surgery', 2800),
      ];
      final live = _snippet(name: 'Dr. Sean Simon MD', price: 4000);
      final painted = explorePaintPool(
        verifiedPool: [...curated, live],
        curated: curated,
        want: 4,
      );
      expect(painted.take(4).map((c) => c.name), curated.map((c) => c.name));
      expect(painted.map((c) => c.name), contains('Dr. Sean Simon MD'));
    });

    test('paint pool uses the audit list when the pool was overwritten', () {
      final audit = [
        breastClinic('Avana Plastic Surgery', 3000),
        breastClinic('Careaga Plastic Surgery', 6000),
        breastClinic('CG Cosmetic Surgery', 2500),
        breastClinic('Svelta Plastic Surgery', 2800),
      ];
      final overwritten = [
        for (final c in audit)
          _official(
            name: c.name,
            price: c.priceMin,
            procedure: 'Breast Augmentation',
            verifiedAt: DateTime.utc(2026, 9, 15),
            sourceUrl: c.priceSourceUrl,
          ),
      ];
      final painted = explorePaintPool(
        verifiedPool: overwritten,
        curated: audit,
        want: 4,
      );
      expect(painted.every(exploreCuratedPriceIsTrusted), isTrue);
      expect(painted.length, 4);
    });
  });

  group('Fillers pill does not paint dissolving or skin-booster scraps', () {
    OpenAIClinic fillerClinic(String name, String procedure, double price) =>
        _curated(
          name: name,
          procedure: procedure,
          price: price,
          family: 'filler',
          priceType: 'from',
          unit: 'syringe',
          sourceUrl: 'https://www.ammaaesthetics.com/services/',
        );

    test('hyaluronidase is not a Fillers from-price', () {
      final dissolving = fillerClinic(
        'Getplump',
        'Facial Filler Dissolving',
        300,
      );
      expect(
        exploreClinicFitsCompareProcedure(dissolving, 'dermal filler lips cheeks'),
        isFalse,
      );
      expect(
        exploreClinicFitsCompareProcedure(
          fillerClinic('ZDermaEsthetics', 'Lip Filler', 600),
          'dermal filler lips cheeks',
        ),
        isTrue,
      );
    });

    test('compare keeps four real filler clinics after dropping dissolving', () {
      final kept = filterComparisonClinicsWithJustifiedPrices(
        clinics: [
          fillerClinic('Getplump', 'Facial Filler Dissolving', 300),
          fillerClinic('AMMA Aesthetics', 'Lip Filler', 700),
          fillerClinic('ZDermaEsthetics', 'Lip Filler', 600),
          fillerClinic('Hydra Prime Wellness', 'Nasolabial Folds Filler', 750),
          fillerClinic('Arviv Medical Aesthetics', 'Dermal Filler', 650),
        ],
        procedure: 'dermal filler lips cheeks',
      );
      expect(kept.length, 4);
      expect(kept.map((c) => c.name), isNot(contains('Getplump')));
    });
  });
}
