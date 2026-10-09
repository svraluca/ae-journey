import 'package:flutter_test/flutter_test.dart';
import 'package:glowpass/services/explore_city_identity.dart';
import 'package:glowpass/services/explore_clinic_identity.dart';
import 'package:glowpass/services/explore_comparison_session.dart';
import 'package:glowpass/services/openai_service.dart';
import 'package:glowpass/services/explore_price_verification.dart';
import 'package:glowpass/services/explore_search_locale.dart';
import 'package:glowpass/services/filter_currency.dart';
import 'package:glowpass/services/explore_seed_catalog.dart';
import 'package:glowpass/services/explore_price_evidence.dart';
import 'package:glowpass/services/explore_price_sanity.dart';
import 'package:glowpass/services/explore_procedure_family.dart';
import 'package:glowpass/services/explore_procedure_relation.dart';
import 'package:glowpass/services/explore_html_price_extractor.dart';
import 'package:glowpass/ui/clinic_compare_price_display.dart';

OpenAIClinic _clinic({
  required String name,
  double price = 150,
  String placeId = '',
  String brand = 'Lip filler',
  String sourceType = 'official_clinic',
  String sourceUrl = 'https://clinic.example/precios',
  String host = 'clinic.example',
  String providerClinic = '',
  String sourcePlatform = '',
}) {
  return OpenAIClinic(
    rank: 1,
    name: name,
    area: '$host · src:$sourceUrl',
    distanceMi: 1,
    rating: 4.5,
    reviews: 20,
    priceGbp: price.round(),
    priceMin: price,
    priceMax: price,
    priceLabel: 'from ${price.round()} €',
    currency: 'EUR',
    brand: brand,
    badge: '',
    badgeVariant: 'mid',
    coord: const OpenAICoord(41.4, 2.1),
    hasProcedure: true,
    pricePending: false,
    currencyConfirmed: true,
    priceSourceUrl: sourceUrl,
    priceEvidenceText: 'Aumento de labios $price €',
    priceVerificationStatus: PriceVerificationStatus.officialWebsite,
    rawProcedureText: brand,
    rawPriceText: '$price €',
    extractionMethod: 'html_table',
    sourceType: sourceType,
    placeId: placeId,
    providerClinic: providerClinic,
    sourcePlatform: sourcePlatform,
  );
}

OpenAIComparisonResult _cmp(List<OpenAIClinic> clinics) {
  return OpenAIComparisonResult(
    city: 'Barcelona',
    topic: 'Fillers',
    topicType: OpenAISearchItemType.procedure,
    summary: '',
    rangeLabel: '',
    mapCenter: const OpenAICoord(41.4, 2.1),
    clinics: clinics,
  );
}

void main() {
  OpenAIClinic verified(String name, {String placeId = '', String host = ''}) {
    return _clinic(
      name: name,
      placeId: placeId,
      host: host.isEmpty ? '${packedCanonicalClinicName(name)}.example' : host,
      sourceUrl: host.isEmpty
          ? 'https://${packedCanonicalClinicName(name)}.example/precios'
          : 'https://$host/precios',
    );
  }

  group('pool mix plan', () {
    test('empty pool is all live Google', () {
      expect(planExplorePoolMix(0).firestoreShow, 0);
      expect(planExplorePoolMix(0).googleLiveTarget, 4);
      expect(planExplorePoolMix(0).skipLiveGoogle, isFalse);
    });

    test('single trusted card paints 1 Firestore and fills 3 live', () {
      expect(planExplorePoolMix(1).firestoreShow, 1);
      expect(planExplorePoolMix(1).googleLiveTarget, 3);
      expect(planExplorePoolMix(1).skipLiveGoogle, isFalse);
    });

    test('2+ pool paints 2 Firestore seeds and still hunts 2 Google', () {
      for (final n in [2, 3, 4, 10, 19, 20]) {
        final p = planExplorePoolMix(n);
        expect(p.firestoreShow, 2, reason: 'n=$n');
        expect(p.googleLiveTarget, 2, reason: 'n=$n');
        expect(p.skipLiveGoogle, isFalse, reason: 'n=$n');
      }
      expect(planExplorePoolMix(20).backgroundDiscoverMax, 1);
      expect(planExplorePoolMix(4).backgroundDiscoverMax, 0);
      expect(planExplorePoolMix(25).skipLiveGoogle, isTrue);
      expect(planExplorePoolMix(25).googleLiveTarget, 0);
    });

    test('curated-heavy pools still leave two Google slots', () {
      final p = planExplorePoolMix(5, liveVerifiedCount: 0);
      expect(p.firestoreShow, 2);
      expect(p.skipLiveGoogle, isFalse);
      expect(p.googleLiveTarget, 2);
      final half = planExplorePoolMix(6, liveVerifiedCount: 2);
      expect(half.firestoreShow, 2);
      expect(half.skipLiveGoogle, isFalse);
      expect(half.googleLiveTarget, 2);
    });
  });

  group('All preview vs focused pill fill', () {
    test('focused pill does not join an under-filled All preview', () {
      expect(
        exploreShouldJoinInFlightTopUp(
          joinInFlight: true,
          googleLiveTargetOverride: null,
          pricedOnScreen: 1,
        ),
        isFalse,
      );
      expect(
        exploreShouldJoinInFlightTopUp(
          joinInFlight: true,
          googleLiveTargetOverride: null,
          pricedOnScreen: 2,
        ),
        isFalse,
      );
    });

    test('All preview still joins its own target=1 search', () {
      expect(
        exploreShouldJoinInFlightTopUp(
          joinInFlight: true,
          googleLiveTargetOverride: 1,
          pricedOnScreen: 1,
        ),
        isTrue,
      );
    });

    test('joinInFlight false never joins', () {
      expect(
        exploreShouldJoinInFlightTopUp(joinInFlight: false, pricedOnScreen: 1),
        isFalse,
      );
    });

    test('focused pill joins once 4 cards are already on screen', () {
      expect(
        exploreShouldJoinInFlightTopUp(joinInFlight: true, pricedOnScreen: 4),
        isTrue,
      );
    });

    test(
      'All preview verifies a few sites; focused pill inspects verify budget',
      () {
        expect(exploreLiveDiscoveryCandidateCap(1), 3);
        expect(exploreLiveDiscoveryCandidateCap(2), 6);
        expect(exploreLiveDiscoveryCandidateCap(3), 9);
        expect(exploreLiveDiscoveryCandidateCap(4), 16);
        expect(exploreLiveDiscoveryCandidateCap(0), 0);
      },
    );

    test('All preview does not spend Places quota', () {
      expect(
        exploreLiveSearchUsesPlaces(
          liveGoogleTarget: 1,
          googleLiveTargetOverride: 1,
        ),
        isFalse,
      );
      expect(
        exploreLiveSearchUsesPlaces(
          liveGoogleTarget: 4,
          googleLiveTargetOverride: null,
        ),
        isTrue,
      );
      expect(
        exploreLiveSearchUsesPlaces(
          liveGoogleTarget: 1,
          googleLiveTargetOverride: null,
        ),
        isTrue,
      );
    });
  });

  group('visible mix from Firestore + Google', () {
    test('1. after search, 2 Firestore + 1 Google pads the leftover slot', () {
      final pool = [
        for (var i = 1; i <= 6; i++) verified('Clinic $i', host: 'c$i.example'),
      ];
      final visible = mixExploreVisibleClinics(
        cachedShown: pool.take(2).toList(),
        googleShown: [verified('Fresh 1', host: 'fresh1.example')],
        poolForPad: pool.skip(2).toList(),
      );
      expect(visible.length, 4);
      expect(visible.map((c) => c.name), [
        'Clinic 1',
        'Clinic 2',
        'Fresh 1',
        'Clinic 3',
      ]);
    });

    test('2. after search finds 0, leftover cards may come from the pool', () {
      final pool = [
        for (var i = 1; i <= 6; i++) verified('Clinic $i', host: 'c$i.example'),
      ];
      final visible = mixExploreVisibleClinics(
        cachedShown: pool.take(2).toList(),
        googleShown: const [],
        poolForPad: pool.skip(2).toList(),
      );
      expect(visible.length, 4);
      expect(visible.map((c) => c.name), [
        'Clinic 1',
        'Clinic 2',
        'Clinic 3',
        'Clinic 4',
      ]);
    });

    test(
      '2c. 1 Firestore seed plus live-confirmed pool clinics fill slots',
      () {
        final seed = verified('Clinic 1', host: 'c1.example');
        final live = [
          verified('Clinic 3', host: 'c3.example'),
          verified('Clinic 4', host: 'c4.example'),
        ];
        final visible = mixExploreVisibleClinics(
          cachedShown: [seed],
          googleShown: live,
          poolForPad: const [],
        );
        expect(visible.map((c) => c.name), [
          'Clinic 1',
          'Clinic 3',
          'Clinic 4',
        ]);
      },
    );

    test('2b. while Google is in flight, 4 verified cache paints 4', () {
      final pool = [
        for (var i = 1; i <= 6; i++) verified('Clinic $i', host: 'c$i.example'),
      ];
      final visible = mixExploreVisibleClinics(
        cachedShown: pool.take(4).toList(),
        googleShown: const [],
        poolForPad: const [],
      );
      expect(visible.length, 4);
      expect(visible.map((c) => c.name), [
        'Clinic 1',
        'Clinic 2',
        'Clinic 3',
        'Clinic 4',
      ]);
    });

    test('2b-legacy. two cached seeds stay at 2 when that is all we have', () {
      final pool = [
        for (var i = 1; i <= 6; i++) verified('Clinic $i', host: 'c$i.example'),
      ];
      final visible = mixExploreVisibleClinics(
        cachedShown: pool.take(2).toList(),
        googleShown: const [],
        poolForPad: const [],
      );
      expect(visible.length, 2);
      expect(visible.map((c) => c.name), ['Clinic 1', 'Clinic 2']);
    });

    test(
      '2d. extra cached pool rows still pad leftover slots after Google 0',
      () {
        final pool = [
          for (var i = 1; i <= 6; i++)
            verified('Clinic $i', host: 'c$i.example'),
        ];
        final visible = mixExploreVisibleClinics(
          cachedShown: pool.take(5).toList(),
          googleShown: const [],
          poolForPad: pool.skip(2).toList(),
          preferredCachedWithFresh: 2,
        );
        expect(visible.length, 4);
        expect(visible.map((c) => c.name).take(2), ['Clinic 1', 'Clinic 2']);
        expect(
          visible.map((c) => c.name).skip(2).toSet(),
          isNot(containsAll(['Clinic 1', 'Clinic 2'])),
        );
      },
    );

    test('3. 2 Firestore + 2 Google is exactly those 4', () {
      final pool = [
        for (var i = 1; i <= 6; i++) verified('Clinic $i', host: 'c$i.example'),
      ];
      final visible = mixExploreVisibleClinics(
        cachedShown: pool.take(2).toList(),
        googleShown: [
          verified('Fresh 1', host: 'fresh1.example'),
          verified('Fresh 2', host: 'fresh2.example'),
        ],
        poolForPad: pool.skip(2).toList(),
      );
      expect(visible.length, 4);
      expect(visible.map((c) => c.name), [
        'Clinic 1',
        'Clinic 2',
        'Fresh 1',
        'Fresh 2',
      ]);
    });
  });

  group('monotonic comparison memory', () {
    test('4+5. remembered 4 survives preload 2 and tab return', () {
      final four = _cmp([
        for (var i = 1; i <= 4; i++) verified('Clinic $i', host: 'c$i.example'),
      ]);
      final preload2 = _cmp([
        verified('Clinic 1', host: 'c1.example'),
        verified('Clinic 2', host: 'c2.example'),
      ]);
      final kept = putBestComparison(previous: four, incoming: preload2);
      expect(kept.clinics.length, 4);
      final returned = putBestComparison(previous: kept, incoming: preload2);
      expect(returned.clinics.length, 4);
    });

    test('merge keeps extract revision so Firestore pool does not strip', () {
      final stale = verified(
        'House',
        host: 'house.example',
      ).copyWith(priceMin: 0, priceLabel: '', priceExtractRevision: '');
      final fresh = verified('House', host: 'house.example').copyWith(
        priceMin: 1400,
        priceLabel: 'from 1400 AED',
        priceExtractRevision: kExplorePriceExtractRevision,
        rawPriceText: '1400 AED',
        extractionMethod: 'dom_block',
        priceSourceUrl: 'https://house.example/prices',
        priceVerifiedAt: DateTime.utc(2026, 8, 20),
      );
      final merged = mergeExploreClinicRecord(stale, fresh);
      expect(merged.priceMin, 1400);
      expect(merged.priceExtractRevision, kExplorePriceExtractRevision);
    });
  });

  group('identity', () {
    test('6. ClinicPoint as provider is rejected', () {
      expect(
        clinicIdentityRejectReason('ClinicPoint'),
        'marketplace_without_provider',
      );
      expect(isUsableExploreClinicIdentity(name: 'ClinicPoint'), isFalse);
    });

    test('7. marketplace price with provider Clínica Londres is accepted', () {
      expect(
        clinicIdentityRejectReason(
          'Clínica Londres Rosselló',
          websiteHost: 'clinicpoint.com',
          providerClinic: 'Clínica Londres Rosselló',
          sourceType: 'marketplace',
        ),
        isNull,
      );
      final html =
          '{"clinicName":"Clínica Londres Rosselló"} '
          '<h2>Clínica Londres Rosselló</h2><p>Lip filler 330 €</p>';
      expect(
        extractMarketplaceProviderName(
          html,
          sourceUrl: 'https://clinicpoint.com/barcelona/lip',
          marketplaceName: 'ClinicPoint',
        ),
        contains('Londres'),
      );
    });

    test('7b. Booksy barber must not keep another clinic\'s filler price', () {
      expect(
        clinicIdentityRejectReason('Flyy City Barbershop'),
        'wrong_business_type',
      );
      expect(
        isUsableExploreClinicIdentity(name: 'Flyy City Barbershop'),
        isFalse,
      );
      expect(isMarketplaceOrDirectoryHost('booksy.com'), isTrue);
      expect(isMarketplaceBrandName('Booksy'), isTrue);
      const booksyBarber =
          'https://booksy.com/en-us/111_flyy-city-barbershop_barber-shop_miami';
      const booksyAesthetics =
          'https://booksy.com/en-us/222_endless-beauty-aesthetics_medical-spa_miami';
      expect(
        marketplaceListingBusinessNameFromUrl(booksyBarber),
        'Flyy City Barbershop',
      );
      expect(
        extractMarketplaceProviderName(
          '{"businessName":"Endless Beauty Aesthetics"} '
          '{"businessName":"Flyy City Barbershop"} '
          '<p>Lip Augmentation \$330+</p>',
          sourceUrl: booksyBarber,
          marketplaceName: 'Flyy City Barbershop',
        ),
        isEmpty,
      );
      expect(
        extractMarketplaceProviderName(
          '{"businessName":"Flyy City Barbershop"} '
          '<p>Lip Augmentation \$330+</p>',
          sourceUrl: booksyAesthetics,
          marketplaceName: 'Flyy City Barbershop',
        ),
        'Endless Beauty Aesthetics',
      );
      expect(
        clinicIdentityRejectReason(
          'Endless Beauty Aesthetics',
          websiteHost: 'booksy.com',
          providerClinic: 'Endless Beauty Aesthetics',
          sourceType: 'marketplace',
        ),
        isNull,
      );
      final flyy =
          _clinic(
            name: 'Flyy City Barbershop',
            brand: 'Lip Augmentation',
            host: 'booksy.com',
            sourceUrl: booksyBarber,
            sourceType: 'marketplace',
            providerClinic: '',
          ).copyWith(
            rawProcedureText: 'Lip Augmentation',
            rawPriceText: r'$330+',
            priceLabel: 'from 330 USD',
            priceMin: 330,
            currency: r'$',
            procedureFamily: 'filler',
          );
      expect(
        exploreClinicEligibleForVerifiedPool(
          flyy,
          procedure: 'dermal filler lips cheeks',
          city: 'Miami',
        ),
        isFalse,
      );
    });

    test(
      '7c. rhinoplasty min–max is \$5,000–\$15,000, not from 5,000–15k \$',
      () {
        final ary =
            _clinic(
              name: 'Ary Krau, MD',
              brand: 'Rhinoplasty',
              host: 'arykraumd.com',
              sourceUrl: 'https://arykraumd.com/procedures/rhinoplasty/',
            ).copyWith(
              rawProcedureText: 'Rhinoplasty',
              rawPriceText: r'$5,000–$15,000',
              priceLabel: r'from 5,000–15k $',
              priceEvidenceText: r'Rhinoplasty $5,000–$15,000',
              priceMin: 5000,
              priceMax: 15000,
              currency: r'$',
              procedureCanonical: 'rhinoplasty',
              procedureFamily: 'rhinoplasty',
            );
        expect(
          clinicCompareProcedurePriceDisplay(
            ary,
            procedure: 'rhinoplasty nose job',
          ),
          r'$5,000–$15,000',
        );
        expect(
          clinicCompareProcedurePriceDisplay(
            ary,
            procedure: 'rhinoplasty nose job',
          ),
          isNot(contains('from')),
        );
      },
    );

    test(
      '7d. GetClearBeauty market estimate is not a verified peel clinic',
      () {
        OpenAIClinic peelCard({
          required String name,
          required double price,
          required String host,
          String brand = 'Chemical peel',
          String evidence = '',
          String sourceType = 'official_clinic',
        }) {
          return _clinic(
            name: name,
            price: price,
            host: host,
            brand: brand,
            sourceUrl: 'https://$host/peels',
            sourceType: sourceType,
          ).copyWith(
            currency: r'$',
            priceLabel: 'from ${price.round()} \$',
            rawProcedureText: brand,
            rawPriceText: '\$${price.round()}',
            priceEvidenceText: evidence.isEmpty
                ? '$brand \$${price.round()}'
                : evidence,
            procedureFamily: 'peel',
            procedureCanonical: 'chemical_peel',
          );
        }

        final amma = peelCard(
          name: 'AMMA Aesthetics',
          price: 125,
          host: 'amma.example',
        );
        final spa = peelCard(
          name: 'Miami Skin Spa',
          price: 350,
          host: 'miamiskinspa.example',
        );
        final skin = peelCard(
          name: 'SkinLocal',
          price: 375,
          host: 'theskinlocal.com',
          brand: 'Face VI Peel',
        );
        final gcb = peelCard(
          name: 'GetClearBeauty',
          price: 600,
          host: 'getclearbeauty.com',
          brand: 'Light chemical peel',
          evidence: r'A full series nationally typically runs $600',
          sourceType: 'marketplace',
        );

        expect(
          exploreClinicEligibleForVerifiedPool(
            gcb,
            procedure: 'chemical peel facial',
            city: 'Barcelona',
          ),
          isFalse,
        );
        expect(looksLikeMultiSessionSeriesQuote(gcb.priceEvidenceText), isTrue);
        expect(
          explorePriceIsComparableTypicalStart(
            procedure: 'chemical peel facial',
            rawProcedureText: gcb.rawProcedureText,
            rawPriceText: gcb.rawPriceText,
            rawEvidence: gcb.priceEvidenceText,
            sourceUrl: gcb.priceSourceUrl,
            priceMin: gcb.priceMin,
            currency: r'$',
          ),
          isFalse,
        );

        final kept = filterComparisonClinicsWithJustifiedPrices(
          clinics: [amma, spa, skin, gcb],
          procedure: 'chemical peel facial',
        );
        expect(kept.map((c) => c.name), isNot(contains('GetClearBeauty')));
        expect(kept.length, 3);
        expect(
          clinicCompareAggregateRangeDisplay(
            kept,
            procedure: 'chemical peel facial',
          ),
          r'from 125–375 $',
        );
      },
    );

    test('8. Tienda is rejected as clinic identity', () {
      expect(clinicIdentityRejectReason('Tienda'), 'generic_business_name');
      expect(isGenericShopIdentity('Shop'), isTrue);
      expect(isGenericShopIdentity('Boutique'), isTrue);
    });

    test('9. Turó Park naming variants dedup to one provider', () {
      expect(
        namesLookLikeSameProvider(
          'Turó Park Aesthetic Clinic',
          'Turoparkaesthetic',
        ),
        isTrue,
      );
      expect(
        namesLookLikeSameProvider(
          'Turó Park Aesthetic Clinic',
          'Turó Park Clinics | Medical & Aesthetic international clinics in Barcelona',
        ),
        isTrue,
      );
      final merged = mergeExploreClinicIdentities([
        verified('Turó Park Aesthetic Clinic', host: 'turopark.com'),
        verified('Turoparkaesthetic', host: 'turopark.com'),
        verified(
          'Turó Park Clinics | Medical & Aesthetic international clinics in Barcelona',
          host: 'turopark.com',
        ),
      ]);
      expect(merged.length, 1);
    });
  });

  group('persistence fingerprint', () {
    test('10. unchanged payload is detected', () {
      final a = [
        verified('Clinic 1', host: 'c1.example'),
        verified('Clinic 2', host: 'c2.example'),
      ];
      final fp1 = explorePersistFingerprint(a);
      final fp2 = explorePersistFingerprint(a);
      expect(explorePersistPayloadUnchanged(fp1, fp2), isTrue);
      final b = [...a, verified('Clinic 3', host: 'c3.example')];
      expect(
        explorePersistPayloadUnchanged(fp1, explorePersistFingerprint(b)),
        isFalse,
      );
    });

    test('11. invalid dead cached row does not consume pool capacity', () {
      final dead = <String, Object?>{
        'name': 'Laserum',
        'price_min': 0,
        'raw_price_text': '+34 621 145 099',
        'price_verification_status': 'legacy_unverified',
        'extraction_method': 'dom_block',
        'price_source_url': 'https://laserum.com',
      };
      final live = <String, Object?>{
        'name': 'Sermed',
        'price_min': 150,
        'raw_price_text': '150 €',
        'raw_procedure_text': 'Aumento de labios',
        'price_verification_status': 'official_website',
        'extraction_method': 'html_table',
        'price_source_url': 'https://sermed.example/precios',
        'verified': true,
        'price_verified': true,
        'price_extract_revision': kExplorePriceExtractRevision,
      };
      expect(cachedRowHasUsablePrice(dead), isFalse);
      expect(cachedRowHasUsablePrice(live), isTrue);
      final usable = [dead, live].where(cachedRowHasUsablePrice).toList();
      expect(usable.length, 1);
      expect(usable.single['name'], 'Sermed');
    });
  });

  group('procedure display title', () {
    test('12. raw comment/date text never becomes procedure display title', () {
      expect(
        looksLikeRawScrapedProcedureTitle(
          'Luis Fajardo noviembre 13, 2022 opinión',
        ),
        isTrue,
      );
      expect(
        looksLikeRawScrapedProcedureTitle('Magia en cinco pinchazos'),
        isTrue,
      );
      expect(looksLikeRawScrapedProcedureTitle('Aumento de labios'), isFalse);
      expect(
        looksLikeRawScrapedProcedureTitle(
          'Botox one area (Forehead, Between eyebrows or Both eyes)',
        ),
        isFalse,
      );
      expect(
        looksLikeRawScrapedProcedureTitle(
          'Achieve Subtle Rejuvenation with Microtox/Baby Botox Treatments',
        ),
        isTrue,
      );
      expect(
        looksLikeRawScrapedProcedureTitle(
          "Anti-Wrinkle Injections London | Botox | Dr L&#39;Art Clinic",
        ),
        isTrue,
      );
      expect(
        looksLikeRawScrapedProcedureTitle(
          'Wrinkle relaxers are priced per unit — Dysport and Xeomin',
        ),
        isTrue,
      );
      expect(
        looksLikeRawScrapedProcedureTitle(
          'Our Botox pricing is competitive and transparent. Treatments',
        ),
        isTrue,
      );
      expect(
        looksLikePricingProseProcedureTitle(
          'Wrinkle relaxers are priced per unit — Dysport and Xeomin',
        ),
        isTrue,
      );
      expect(
        looksLikePricingProseProcedureTitle(
          'depending on provider discretion PRICING FACE VI PEEL',
        ),
        isTrue,
      );
      expect(
        exploreWebsiteProcedureTitle(
          'depending on provider discretion PRICING FACE VI PEEL',
        ),
        'Face VI Peel',
      );
      expect(
        exploreCardProcedureLabel(
          _clinic(
            name: 'SkinLocal',
            brand: 'depending on provider discretion PRICING FACE VI PEEL',
            host: 'theskinlocal.com',
            sourceUrl: 'https://theskinlocal.com/skin-treatments/peels/',
          ).copyWith(
            rawProcedureText:
                'depending on provider discretion PRICING FACE VI PEEL',
            rawPriceText: r'$375',
            priceMin: 375,
            currency: r'$',
            procedureFamily: 'peel',
            procedureCanonical: 'chemical_peel',
          ),
          selectedPill: 'Peels',
        ),
        'Face VI Peel',
      );
      expect(
        exploreCardProcedureLabel(
          _clinic(
            name: 'Miami Skin Spa',
            brand: 'Wrinkle relaxers are priced per unit — Dysport and Xeomin',
            host: 'miamiskinspa.com',
          ).copyWith(
            rawProcedureText:
                'Wrinkle relaxers are priced per unit — Dysport and Xeomin',
            procedureFamily: 'botox',
            procedureCanonical: 'botox',
          ),
          selectedPill: 'Botox',
        ),
        'Botox treatment',
      );
      expect(
        exploreCardProcedureLabel(
          _clinic(
            name: 'Alexislauren',
            brand:
                'Our Botox pricing is competitive and transparent. Treatments',
            host: 'alexislauren.com',
          ).copyWith(
            rawProcedureText:
                'Our Botox pricing is competitive and transparent. Treatments',
            procedureFamily: 'botox',
            procedureCanonical: 'botox',
          ),
          selectedPill: 'Botox',
        ),
        'Botox treatment',
      );
      final clinic = _clinic(
        name: 'Sermed',
        brand: 'Luis Fajardo noviembre 13, 2022 opinión',
        host: 'sermed.example',
      );
      expect(
        exploreCardProcedureLabel(clinic, selectedPill: 'Fillers'),
        'Lip filler',
      );
      expect(
        exploreCardProcedureLabel(
          _clinic(
            name: 'Sermed',
            brand: 'Magia en cinco pinchazos',
            host: 'sermed.example',
          ),
          selectedPill: 'Botox',
        ),
        'Botox treatment',
      );
    });

    test('12e. page <title> SEO is not a Botox card heading', () {
      final harley =
          _clinic(
            name: 'Harleystreetinjectables',
            brand:
                'Achieve Subtle Rejuvenation with Microtox/Baby Botox Treatments',
            host: 'harleystreetinjectables.com',
            sourceUrl: 'https://www.harleystreetinjectables.com/baby-botox',
          ).copyWith(
            rawProcedureText:
                'Achieve Subtle Rejuvenation with Microtox/Baby Botox Treatments',
            procedureFamily: 'botox',
          );
      expect(
        exploreCardProcedureLabel(harley, selectedPill: 'Botox'),
        'Baby Botox',
      );
      expect(
        exploreClinicMatchesProcedure(harley, 'Botox anti-wrinkle injection'),
        isTrue,
      );

      final lart =
          _clinic(
            name: "Dr L'Art Aesthetic Clinic London",
            brand:
                "Anti-Wrinkle Injections London | Botox | Dr L&#39;Art Clinic",
            host: 'drlart.co.uk',
            sourceUrl: 'https://drlart.co.uk/anti-wrinkle-treatment',
          ).copyWith(
            rawProcedureText:
                "Anti-Wrinkle Injections London | Botox | Dr L&#39;Art Clinic",
            procedureFamily: 'botox',
          );
      expect(
        exploreWebsiteProcedureTitle(lart.brand),
        "Anti-Wrinkle Injections London | Botox | Dr L'Art Clinic",
      );
      expect(
        exploreCardProcedureLabel(lart, selectedPill: 'Botox'),
        'Botox treatment',
      );
    });

    test('12g. inherited / chrome labels still match the Botox pill', () {
      final areaOnly =
          _clinic(
            name: 'Dr Joney De Souza',
            brand: '1 area (Face OR Neck OR Décolletage)',
            host: 'drjoneydesouza.com',
          ).copyWith(
            rawProcedureText: '1 area (Face OR Neck OR Décolletage)',
            procedureFamily: 'botox',
            procedureRelation: 'variant',
          );
      expect(
        exploreClinicMatchesProcedure(areaOnly, 'Botox anti-wrinkle injection'),
        isTrue,
      );

      final antiWrinkle = _clinic(
        name: 'Define Clinic',
        brand: 'Anti-Wrinkle Injections',
        host: 'defineclinic.com',
      ).copyWith(rawProcedureText: 'Anti-Wrinkle Injections');
      expect(
        exploreClinicMatchesProcedure(
          antiWrinkle,
          'Botox anti-wrinkle injection',
        ),
        isTrue,
      );

      final priceChrome =
          _clinic(
            name: 'London Lip Clinic',
            brand: 'Price From £350',
            host: 'londonlipclinic.co.uk',
          ).copyWith(
            rawProcedureText: 'Price From £350',
            procedureFamily: 'filler',
            procedureRelation: 'variant',
          );
      expect(
        exploreClinicMatchesProcedure(priceChrome, 'dermal filler lips cheeks'),
        isTrue,
      );
      expect(
        exploreClinicMatchesProcedure(
          priceChrome,
          'Botox anti-wrinkle injection',
        ),
        isFalse,
      );
    });

    test(
      '12b. FAQ price questions are not card titles and keep filler quotes',
      () {
        const faq = 'How much does lip augmentation cost?';
        expect(looksLikeRawScrapedProcedureTitle(faq), isTrue);
        expect(
          looksLikeRawScrapedProcedureTitle('Cât costă mărirea buzelor?'),
          isTrue,
        );
        expect(isHighTicketExploreProcedure('lip augmentation'), isFalse);
        expect(isHighTicketExploreProcedure(faq), isFalse);
        expect(isHighTicketExploreProcedure('breast augmentation'), isTrue);

        final tajmeel =
            _clinic(
              name: 'Tajmeel Clinic Dubai',
              brand: faq,
              host: 'tajmeels.ae',
              sourceUrl: 'https://tajmeels.ae/lip-augmentation',
            ).copyWith(
              priceMin: 2500,
              priceMax: 2500,
              priceGbp: 2500,
              currency: 'AED',
              priceLabel: 'from 2500 AED',
              rawPriceText: '2500 AED',
              rawProcedureText: faq,
              priceEvidenceText: 'Lip augmentation 2500 AED',
            );
        expect(
          exploreCardProcedureLabel(tajmeel, selectedPill: 'Fillers'),
          'Lip filler',
        );
        expect(
          exploreCardProcedureLabel(tajmeel, selectedPill: 'All'),
          'Lip filler',
        );
        expect(
          clinicCompareProcedurePriceDisplay(tajmeel, procedure: faq),
          isNot(isEmpty),
        );
        expect(
          clinicHasListedComparePrice(
            tajmeel,
            procedure: 'dermal filler lips cheeks',
          ),
          isTrue,
        );
      },
    );

    test('12f. FAQ sentences never render in the price cell', () {
      const faq = 'How much does lip augmentation cost in Dubai in 2025?';
      final tajmeel =
          _clinic(
            name: 'Tajmeel Clinic Dubai',
            brand: faq,
            host: 'tajmeels.ae',
            sourceUrl: 'https://tajmeels.ae/lip-augmentation',
          ).copyWith(
            priceMin: 1500,
            priceMax: 1500,
            priceGbp: 1500,
            currency: 'AED',
            priceLabel: faq,
            rawPriceText: '$faq 1500 AED',
            rawProcedureText: faq,
          );
      final shown = clinicCompareProcedurePriceDisplay(
        tajmeel,
        procedure: 'dermal filler lips cheeks',
      );
      expect(shown, 'from 1,500 AED');
      expect(shown, isNot(contains('How much')));

      // Real listed quotes still show exactly as the clinic wrote them.
      final listed = tajmeel.copyWith(
        priceLabel: 'from 1500 AED',
        rawPriceText: 'from 1,500 AED per session',
      );
      expect(
        clinicCompareProcedurePriceDisplay(
          listed,
          procedure: 'dermal filler lips cheeks',
        ),
        'from 1,500 AED',
      );
    });

    test('12c. Botox FAQ headings keep only the listed area', () {
      const glued = 'What Is Botox Injection? · Crows Feet';
      expect(
        looksLikeCatalogSectionHeading('What Is Botox Injection?'),
        isTrue,
      );
      expect(exploreWebsiteProcedureTitle(glued), 'Crows Feet');
      final euromed =
          _clinic(
            name: 'Euromed Clinic Dubai',
            brand: glued,
            host: 'euromedclinicdubai.com',
            sourceUrl: 'https://euromedclinicdubai.com/botox',
          ).copyWith(
            priceMin: 499,
            priceMax: 499,
            priceGbp: 499,
            currency: 'AED',
            priceLabel: '499 AED',
            rawPriceText: '499 AED',
            rawProcedureText: glued,
          );
      expect(
        exploreCardProcedureLabel(euromed, selectedPill: 'Botox'),
        'Crows Feet',
      );
    });

    test('12d. City-average filler blogs are not card titles', () {
      const avg = 'Average Price Range for Fillers in Dubai · Basic HA';
      expect(looksLikeMarketAveragePriceBlurb(avg), isTrue);
      expect(
        isNonLiteralClinicPriceUrl(
          'https://axonmedica.com/blog/fillers-cost-in-dubai/',
        ),
        isTrue,
      );
      expect(
        isNonLiteralClinicPriceUrl(
          'https://axonmedica.com/fillers-cost-in-dubai/',
        ),
        isFalse,
      );
      final axon = _clinic(
        name: 'Axonmedica',
        brand: avg,
        host: 'axonmedica.com',
        sourceUrl: 'https://axonmedica.com/fillers-cost-in-dubai/',
      );
      expect(
        exploreCardProcedureLabel(axon, selectedPill: 'Fillers'),
        'Lip filler',
      );
    });

    test('13. snake_case canonical ids are never card titles', () {
      expect(looksLikeInternalProcedureId('chemical_peel'), isTrue);
      expect(
        humanizeExploreProcedureCanonical('chemical_peel'),
        'Chemical peel',
      );
      expect(humanizeExploreProcedureCanonical('lip_filler'), 'Lip filler');
      final peel = _clinic(
        name: 'Bloome by Egos',
        brand: 'chemical_peel',
        host: 'bloome.example',
      ).copyWith(procedureCanonical: 'chemical_peel');
      expect(
        exploreCardProcedureLabel(peel, selectedPill: 'All'),
        'Chemical peel',
      );
      expect(
        exploreCardProcedureLabel(peel, selectedPill: 'Peels'),
        'Chemical peel',
      );
    });

    test('14. price-quote copy is not a clinic name', () {
      expect(clinicIdentityRejectReason(r'Cost $3500'), 'invalid_identity');
      expect(
        clinicIdentityRejectReason(r'Starts at $3000'),
        'invalid_identity',
      );
      expect(looksLikePriceQuotedClinicName(r'Cost $3500'), isTrue);
      expect(looksLikePriceQuotedClinicName(r'Starts at $3000'), isTrue);
      expect(looksLikePriceQuotedClinicName('Miami Skin Spa'), isFalse);
      expect(
        exploreClinicDisplayName(
          _clinic(
            name: r'Cost $3500',
            host: 'miamiplastics.example',
            sourceUrl: 'https://miamiplastics.example/rhinoplasty',
          ),
        ),
        'Miamiplastics',
      );
    });

    test('14. Serp page titles are not clinic names', () {
      expect(clinicIdentityRejectReason('preț 2026'), 'invalid_identity');
      expect(clinicIdentityRejectReason('599 درهم'), 'invalid_identity');
      expect(clinicIdentityRejectReason('56% OFF'), 'invalid_identity');
      expect(looksLikeBarePriceLabel('599 درهم'), isTrue);
      expect(
        clinicIdentityRejectReason(
          'Mărire buze cu acid hialuronic de la 659 lei',
        ),
        'invalid_identity',
      );
      expect(exploreClinicNameLooksLikeSeoHeadline('preț 2026'), isTrue);
      expect(exploreClinicNameLooksLikeSeoHeadline('Beperfect'), isFalse);
      expect(
        exploreClinicNameLooksLikeSeoHeadline(
          'Mărire buze cu acid hialuronic de la 659 lei',
        ),
        isTrue,
      );
      expect(
        exploreClinicDisplayName(
          _clinic(
            name: 'preț 2026',
            host: 'beperfect.ro',
            sourceUrl: 'https://beperfect.ro/servicii/marire-buze/',
          ),
        ),
        'Beperfect',
      );
      expect(
        exploreClinicDisplayName(
          _clinic(
            name: 'Mărire buze cu acid hialuronic de la 659 lei',
            host: 'doctorskin.ro',
            sourceUrl:
                'https://doctorskin.ro/estetica-medicala/marire-buze-cu-acid-hialuronic/',
          ),
        ),
        'Doctor SKiN',
      );
      expect(
        clinicIdentityRejectReason('Tarife epilare definitiva laser'),
        'invalid_identity',
      );
      expect(
        exploreClinicNameLooksLikeSeoHeadline(
          'Tarife epilare definitiva laser',
        ),
        isTrue,
      );
      expect(
        exploreClinicDisplayName(
          _clinic(
            name: 'Tarife epilare definitiva laser',
            host: 'evasalon.ro',
            sourceUrl: 'https://evasalon.ro/tarife/',
          ),
        ),
        'Evasalon',
      );
      expect(
        exploreClinicNameLooksLikeCategoryOrServiceTitle('Cosmetologie'),
        isTrue,
      );
      expect(
        exploreClinicNameLooksLikeCategoryOrServiceTitle(
          'Aesthetic cosmetology procedures',
        ),
        isTrue,
      );
      expect(
        exploreClinicNameFromSerpTitle('Cosmetologie', 'doctorlica.md'),
        'Doctor Lica',
      );
      expect(
        exploreClinicNameFromSerpTitle(
          'Aesthetic cosmetology procedures',
          'beautysphera.md',
        ),
        'Beauty Sphera',
      );
      expect(
        looksLikeCatalogSectionHeading('Chirurgia zonei genitale'),
        isTrue,
      );
      expect(
        exploreWebsiteProcedureTitle(
          'Chirurgia zonei genitale · Fast botox o zonă',
        ),
        'Fast botox o zonă',
      );
      expect(
        exploreClinicBrandFromHost('elenamartin.ro'),
        'Doctor Elena Martin',
      );
    });

    test('16. lip augmentation is never a Botox card', () {
      final lips = _clinic(
        name: 'DermaBeauty Clinique Nord',
        brand: 'lip augmentation',
        host: 'dermabeauty.ro',
        sourceUrl: 'https://dermabeauty.ro/preturi',
      );
      expect(
        exploreClinicMatchesProcedure(lips, 'Botox anti-wrinkle injection'),
        isFalse,
      );
      expect(
        exploreClinicMatchesProcedure(lips, 'dermal filler lips cheeks'),
        isTrue,
      );
      expect(
        exploreCardProcedureLabel(lips, selectedPill: 'Botox'),
        'Botox treatment',
      );
      final hiddenRaw = _clinic(
        name: 'DermaBeauty Clinique Nord',
        brand: 'Botox treatment',
        host: 'dermabeauty.ro',
      ).copyWith(rawProcedureText: 'lip augmentation');
      expect(
        exploreClinicMatchesProcedure(
          hiddenRaw,
          'Botox anti-wrinkle injection',
        ),
        isFalse,
      );
    });

    test('17. glued scrape titles and hydration rows are not Botox', () {
      expect(
        exploreWebsiteProcedureTitle('Rehydra310 RONhidratare intensă'),
        'Rehydra hidratare intensă',
      );
      final statera = _clinic(
        name: 'Clinica STATERA',
        brand: 'Rehydra310 RONhidratare intensă',
        host: 'clinicastatera.ro',
      );
      expect(
        exploreClinicMatchesProcedure(statera, 'Botox anti-wrinkle injection'),
        isFalse,
      );
    });

    test('18. compare cards keep the listed website price', () {
      final clinic =
          _clinic(
            name: 'Doctor SKiN',
            brand: 'Botox treatment',
            host: 'doctorskin.ro',
            sourceUrl:
                'https://doctorskin.ro/estetica-medicala/eliminare-riduri-neuromodulator/',
          ).copyWith(
            rawProcedureText: 'Corecție riduri frunte 1 zonă',
            rawPriceText: '390 lei',
            priceLabel: 'from 430 RON',
            priceMin: 390,
            currency: 'RON',
          );
      expect(
        clinicCompareProcedurePriceDisplay(
          clinic,
          procedure: 'Botox anti-wrinkle injection',
        ),
        'from 390 RON',
      );
      expect(
        clinicCompareProcedurePriceDisplay(
          _clinic(
            name: 'Endless Beauty Aesthetics',
            brand: 'Lip Augmentation',
            host: 'endlessbeautyaesthetics.com',
            sourceUrl: 'https://endlessbeautyaesthetics.com/pricing',
          ).copyWith(
            rawProcedureText: 'Lip Augmentation',
            rawPriceText: r'$330.00+',
            priceLabel: 'from 330 USD',
            priceMin: 330,
            currency: r'$',
            procedureFamily: 'filler',
          ),
          procedure: 'dermal filler lips cheeks',
        ),
        r'from 330 $',
      );
      expect(priceLabelCurrencyAfter(r'from $330.00+'), r'from 330 $');
    });

    test('19. Places placeId upgrade still matches the host-only card', () {
      final unrated = _clinic(
        name: 'R1clinic',
        host: 'r1clinic.ro',
        sourceUrl: 'https://r1clinic.ro/servicii-si-preturi/',
        placeId: '',
      ).copyWith(rating: 0, reviews: 0);
      final rated = unrated.copyWith(
        name: 'Dr. Raluca Harnagea',
        placeId: 'ChIJTRwRjLwDskARBOwAfoHuWr0',
        rating: 4.9,
        reviews: 1090,
      );
      expect(
        exploreClinicHitsKeys(rated, exploreClinicIdentityKeys(unrated)),
        isTrue,
      );
      expect(exploreClinicsAreSameProvider(unrated, rated), isTrue);
      final overlaid = overlayExploreClinicRatings(
        shown: [unrated],
        enriched: [rated],
      );
      expect(overlaid.single.rating, 4.9);
      expect(overlaid.single.reviews, 1090);
    });

    test('21. Fillers cards use the website treatment name', () {
      expect(looksLikeInternalProcedureId('filler'), isTrue);
      expect(looksLikeInternalProcedureId('Lip filler'), isFalse);
      final listed =
          _clinic(
            name: 'Dr.Estetix',
            brand: 'filler',
            host: 'drestetix.ro',
            sourceUrl: 'https://drestetix.ro/pages/preturi-injectari',
          ).copyWith(
            procedureCanonical: 'filler',
            rawProcedureText: 'Juvederm Ultra 1 ml',
          );
      expect(
        exploreCardProcedureLabel(listed, selectedPill: 'Fillers'),
        'Juvederm Ultra 1 ml',
      );

      final sectioned = listed.copyWith(
        rawProcedureText:
            'DERMATOLOGIE ESTETICĂ · Augmentare buze 1 ml (Lip Augmentation)',
      );
      expect(
        exploreCardProcedureLabel(sectioned, selectedPill: 'Fillers'),
        'Augmentare buze 1 ml (Lip Augmentation)',
      );

      final elenamartin = listed.copyWith(
        name: 'Elenamartin',
        rawProcedureText: 'Procedee estetice non-invazive · Fast botox o zonă',
        procedureCanonical: 'botox',
        brand: 'Botox',
      );
      expect(
        exploreCardProcedureLabel(elenamartin, selectedPill: 'Botox'),
        'Fast botox o zonă',
      );

      final simple = _clinic(
        name: 'Illuma Clinique',
        brand: 'filler',
        host: 'illumaclinique.ro',
      ).copyWith(procedureCanonical: 'filler', rawProcedureText: '');
      expect(
        exploreCardProcedureLabel(simple, selectedPill: 'Fillers'),
        'Lip filler',
      );
    });

    test('Chisinau Fillers cards are not Prețuri headings or Hydro categories', () {
      expect(looksLikePriceMenuHeadingOnly('Prețuri'), isTrue);
      expect(
        looksLikeGenericInjectableCategoryHeading(
          'Filler dermatological injections',
        ),
        isTrue,
      );
      expect(
        firstTreatmentClauseFromLaundryList(
          'mărire buze, augmentare riduri, corecție volumetrică pomeți',
        ),
        'mărire buze',
      );

      final heading =
          _clinic(
            name: 'Aesthetic Surgery Clinic',
            brand: 'Filler dermatological injections',
            host: 'chirurgie-estetica.md',
            sourceUrl: 'https://www.chirurgie-estetica.md/en/prices/',
          ).copyWith(
            rawProcedureText: 'Filler dermatological injections',
            procedureCanonical: 'filler',
          );
      expect(
        exploreCardProcedureLabel(heading, selectedPill: 'Fillers'),
        'Lip filler',
      );

      final bundle =
          _clinic(
            name: 'Estetic Sana',
            brand:
                'Prețuri · mărire buze, augmentare riduri, corecție volumetrică pomeți',
            host: 'estetic-sana.md',
            sourceUrl: 'https://estetic-sana.md/prices',
          ).copyWith(
            rawProcedureText:
                'Prețuri · mărire buze, augmentare riduri, corecție volumetrică pomeți',
            procedureCanonical: 'filler',
          );
      expect(
        exploreCardProcedureLabel(bundle, selectedPill: 'Fillers'),
        'mărire buze',
      );

      final sancos =
          _clinic(
            name: 'Clinica SANCOS Chișinău',
            brand: 'Medic dermatocosmetolog · Toxina botulinică 1 zonă facial',
            host: 'sancos.md',
            sourceUrl: 'https://www.sancos.md/lista-de-preturi',
          ).copyWith(
            rawProcedureText:
                'Medic dermatocosmetolog · Toxina botulinică 1 zonă facial',
            procedureCanonical: 'botox',
          );
      expect(
        exploreCardProcedureLabel(sancos, selectedPill: 'Botox'),
        'Toxina botulinică 1 zonă facial',
      );
    });

    test('20. compare cards hide former sale prices and bare currency', () {
      final sale =
          _clinic(
            name: 'The Clinique Herastrau',
            brand: 'Tratarea Ridurilor Botox – 3 Zone',
            host: 'theclinique.ro',
            sourceUrl: 'https://theclinique.ro/preturi/',
          ).copyWith(
            rawPriceText: '1,200.00 lei (was 2,000.00 lei)',
            priceLabel: 'from 1200 RON',
            priceMin: 1200,
            priceMax: 2000,
            currency: 'RON',
          );
      expect(
        clinicCompareProcedurePriceDisplay(
          sale,
          procedure: 'Botox anti-wrinkle injection',
        ),
        'from 1,200 RON',
      );

      final bare =
          _clinic(
            name: 'Injectare toxină botulinică',
            brand: 'Botox treatment',
            host: 'skina.ro',
            sourceUrl:
                'https://skina.ro/dermato-estetica/injectare-toxina-botulinica/',
          ).copyWith(
            rawPriceText: '900',
            priceLabel: '',
            priceMin: 900,
            currency: 'RON',
          );
      expect(
        clinicCompareProcedurePriceDisplay(
          bare,
          procedure: 'Botox anti-wrinkle injection',
        ),
        'from 900 RON',
      );
    });

    test('22. Romanian slogans fall back to the website brand', () {
      expect(
        exploreClinicNameLooksLikeMarketingSlogan('Nasul Potrivit Fetei Tale'),
        isTrue,
      );
      expect(
        exploreClinicDisplayName(
          _clinic(
            name: 'Nasul Potrivit Fetei Tale',
            host: 'clinicabarbatilor.ro',
            sourceUrl: 'https://clinicabarbatilor.ro/rinoplastie',
          ),
        ),
        'Clinica Barbatilor',
      );
      expect(
        exploreClinicNameLooksLikeMarketingSlogan(
          'Piele Strălucitoare & Sănătoasă',
        ),
        isTrue,
      );
      expect(
        exploreClinicDisplayName(
          _clinic(
            name: 'Piele Strălucitoare & Sănătoasă',
            host: 'doctorskin.ro',
            sourceUrl: 'https://doctorskin.ro/lista-de-preturi-doctor-skin/',
          ),
        ),
        'Doctor SKiN',
      );
    });

    test('23. listed peel prices stay compact', () {
      final dual =
          _clinic(
            name: 'Doctor SKiN',
            brand: 'Chemical peel',
            host: 'doctorskin.ro',
            sourceUrl: 'https://doctorskin.ro/lista-de-preturi-doctor-skin/',
          ).copyWith(
            rawPriceText: '1.210 lei 1.009 lei',
            priceLabel: '1.210 lei 1.009 lei',
            priceMin: 1009,
            priceMax: 1210,
            currency: 'RON',
          );
      expect(
        clinicCompareProcedurePriceDisplay(
          dual,
          procedure: 'chemical peel facial',
        ),
        'from 1.009 RON',
      );

      final range =
          _clinic(
            name: 'Skin Experience Clinic',
            brand: 'Chemical peel',
            host: 'skinexperience.ro',
            sourceUrl: 'https://skinexperience.ro/preturi',
          ).copyWith(
            rawPriceText:
                '500 lei – 950 lei Interval de prețuri pentru peeling',
            priceLabel: '500 lei – 950 lei Interval de prețuri',
            priceMin: 500,
            priceMax: 950,
            currency: 'RON',
          );
      expect(
        clinicCompareProcedurePriceDisplay(
          range,
          procedure: 'chemical peel facial',
        ),
        'from 500 RON – 950 RON',
      );
    });
  });

  group('Places name looks medical', () {
    test('keeps named plastic clinics Google may type as gym/lodging', () {
      expect(placesNameLooksLikeMedicalClinic('Clinica STATERA'), isTrue);
      expect(placesNameLooksLikeMedicalClinic('Cronos Med Herăstrău'), isTrue);
      expect(
        placesNameLooksLikeMedicalClinic(
          'Clinica Dr. Iosif - Chirurgie Estetica Bucuresti',
        ),
        isTrue,
      );
      expect(placesNameLooksLikeMedicalClinic('Dr. Elena Martin'), isTrue);
      expect(placesNameLooksLikeMedicalClinic('aBeauty București Tei'), isTrue);
      expect(placesNameLooksLikeMedicalClinic('Natural Aesthetics'), isTrue);
      expect(
        placesNameLooksLikeMedicalClinic('Premium Cosmetic Laser Center'),
        isTrue,
      );
      expect(
        placesNameLooksLikeMedicalClinic('Beautify Me Medical Center'),
        isTrue,
      );
      expect(
        placesNameLooksLikeMedicalClinic(
          'SnB Aesthetic Clinic l Botox l Filler l DENTAL Implants',
        ),
        isTrue,
      );
      expect(placesNameLooksLikeMedicalClinic('Nail Art Studio'), isFalse);
      expect(placesNameLooksLikeMedicalClinic('Flyy City Barbershop'), isFalse);
      expect(isMarketplaceOrDirectoryHost('fresha.com'), isTrue);
      expect(isMarketplaceOrDirectoryHost('medigence.com'), isTrue);
      expect(isMarketplaceOrDirectoryHost('injectablesbooking.ae'), isTrue);
      expect(isMarketplaceOrDirectoryHost('www.zavis.ai'), isTrue);
      expect(isMarketplaceOrDirectoryHost('medifinder.ae'), isTrue);
      expect(
        isMarketplaceOrDirectoryHost('reuterplasticsurgery.com'),
        isFalse,
      );
      expect(isMarketplaceOrDirectoryHost('www.salonsindubai.ae'), isTrue);
      expect(isMarketplaceBrandName('MediGence'), isTrue);
      expect(isMarketplaceBrandName('Salons in Dubai'), isTrue);
      expect(isMarketplaceOrDirectoryHost('mediglobus.com'), isTrue);
      expect(isMarketplaceBrandName('Mediglobus'), isTrue);
      expect(isMarketplaceBrandName('MediGlobus'), isTrue);
      expect(
        clinicIdentityRejectReason('Mediglobus'),
        'marketplace_without_provider',
      );
      expect(
        clinicIdentityRejectReason(
          'Mediglobus',
          websiteHost:
              'https://mediglobus.com/how-much-breast-augmentation-cost/',
        ),
        anyOf('marketplace_without_provider', 'non_clinic_content_host'),
      );
      expect(isMarketplaceOrDirectoryHost('getclearbeauty.com'), isTrue);
      expect(isMarketplaceBrandName('GetClearBeauty'), isTrue);
      expect(isMarketplaceBrandName('Get Clear Beauty'), isTrue);
      expect(
        looksLikeMarketEstimateDirectoryUrl(
          'https://getclearbeauty.com/light-chemical-peel/',
        ),
        isTrue,
      );
      expect(
        clinicIdentityRejectReason('GetClearBeauty'),
        'marketplace_without_provider',
      );
      for (final host in [
        'turkeymedicals.com',
        'turkeybeautyguide.com',
        'healthyturkiye.com',
        'medicaltravelcost.com',
        'clinicbooking.com',
        'medifyr.com',
        'trendyol.com',
      ]) {
        expect(isMarketplaceOrDirectoryHost(host), isTrue, reason: host);
        expect(
          looksLikeMarketEstimateDirectoryUrl('https://$host/botox'),
          isTrue,
          reason: host,
        );
      }
      expect(isMarketplaceOrDirectoryHost('studio24.bg'), isTrue);
      expect(isMarketplaceBrandName('Studio24'), isTrue);
      expect(marketplacePlatformLabel('studio24.bg'), 'Studio24');
      expect(isMarketplaceBrandName('Turkeymedicals'), isTrue);
      expect(isMarketplaceBrandName('Turkeybeautyguide'), isTrue);
      expect(isMarketplaceBrandName('Medifyr'), isTrue);
      expect(isMarketplaceBrandName('Trendyol'), isTrue);
      expect(
        clinicIdentityRejectReason('Turkeymedicals'),
        'marketplace_without_provider',
      );
      expect(
        clinicIdentityRejectReason(
          'Turkeybeautyguide',
          websiteHost: 'https://turkeybeautyguide.com/en/treatments',
        ),
        anyOf('marketplace_without_provider', 'non_clinic_content_host'),
      );
      expect(
        clinicIdentityRejectReason(
          'Medifyr',
          websiteHost: 'https://medifyr.com/',
        ),
        'marketplace_without_provider',
      );
      expect(
        isNonLiteralClinicPriceUrl('https://turkeymedicals.com/pricing'),
        isTrue,
      );
      expect(
        clinicIdentityRejectReason(
          'Miami Skin Spa',
          websiteHost: 'https://getclearbeauty.com/vi-peel/',
          providerClinic: 'Miami Skin Spa',
          sourceType: 'marketplace',
        ),
        'market_estimate',
      );
      expect(
        isNonLiteralClinicPriceUrl(
          'https://getclearbeauty.com/light-chemical-peel/',
        ),
        isTrue,
      );
      expect(
        classifyPriceSourceType('https://getclearbeauty.com/vi-peel/'),
        PriceSourceType.searchSnippet,
      );
      expect(
        classifyProcedureRelation(
          requestedProcedure: 'chemical peel facial',
          label: 'Light chemical peel',
          evidence: 'from \$600',
          sourceUrl: 'https://getclearbeauty.com/light-chemical-peel/',
        ).logToken,
        'market_information',
      );
      expect(
        isNonLiteralClinicPriceUrl(
          'https://www.biolitedubai.com/botox-aftercare-in-dubai-how-to-maximize-your-results/',
        ),
        isTrue,
      );
      expect(
        isNonLiteralClinicPriceUrl(
          'https://bionixclinic.com/female-balance-iv-drip/',
        ),
        isTrue,
      );
    });

    test(
      '25. Google rhinoplasty titles become clinic hosts, not SEO rejects',
      () {
        expect(
          exploreClinicNameFromSerpTitle(
            'Rinoplastie București — Preț Operație Nas de la 5.000€',
            'drdiana.ro',
          ),
          'Dr Diana',
        );
        expect(
          exploreClinicNameFromSerpTitle(
            'Rinoplastie - Pret Operatie Estetica la Nas | Cosmedica',
            'cosmedica.ro',
          ),
          'Cosmedica',
        );
        expect(
          exploreSerpProcedureMatchTokens('rhinoplasty nose job', lang: 'ro'),
          contains('rinoplastie'),
        );
        final queries = exploreLocalizedSearchQueries(
          procedure: 'rhinoplasty nose job',
          city: 'București',
          pill: 'Rhinoplasty',
        );
        expect(
          queries.any(
            (q) =>
                q.toLowerCase().contains('rinoplastie') &&
                q.toLowerCase().contains('pret'),
          ),
          isTrue,
        );
      },
    );

    test('25b. Google search is worldwide, not Romania-only', () {
      bool hasBoth(List<String> qs, String a, String b) => qs.any(
        (q) => q.toLowerCase().contains(a) && q.toLowerCase().contains(b),
      );

      expect(
        hasBoth(
          exploreLocalizedSearchQueries(
            procedure: 'rhinoplasty',
            city: 'Barcelona',
            pill: 'Rhinoplasty',
          ),
          'rinoplastia',
          'precio',
        ),
        isTrue,
      );
      expect(
        hasBoth(
          exploreLocalizedSearchQueries(
            procedure: 'rhinoplasty',
            city: 'Paris',
            pill: 'Rhinoplasty',
          ),
          'rhinoplastie',
          'prix',
        ),
        isTrue,
      );
      expect(
        exploreLocalizedSearchQueries(
          procedure: 'rhinoplasty',
          city: 'London',
          pill: 'Rhinoplasty',
        ).any((q) => q.toLowerCase().contains('rhinoplasty prices')),
        isTrue,
      );
      expect(
        hasBoth(
          exploreLocalizedSearchQueries(
            procedure: 'rhinoplasty',
            city: 'Istanbul',
            pill: 'Rhinoplasty',
          ),
          'rinoplasti',
          'fiyat',
        ),
        isTrue,
      );
      expect(
        exploreLocalizedSearchQueries(
          procedure: 'rhinoplasty',
          city: 'Nairobi',
          pill: 'Rhinoplasty',
        ).any((q) => q.toLowerCase().contains('rhinoplasty prices in nairobi')),
        isTrue,
      );
      expect(
        hasBoth(
          exploreLocalizedSearchQueries(
            procedure: 'rhinoplasty',
            city: 'Faro',
            pill: 'Rhinoplasty',
            countryCode: 'PT',
          ),
          'rinoplastia',
          'preco',
        ),
        isTrue,
      );

      final tokens = exploreSerpProcedureMatchTokens('rhinoplasty');
      expect(tokens, contains('rinoplastie'));
      expect(tokens, contains('rinoplastia'));
      expect(tokens, contains('rhinoplastie'));
      expect(tokens, contains('nasenkorrektur'));
      expect(tokens, contains('rinoplasti'));

      expect(exploreGoogleGl('es', 'Barcelona'), 'es');
      expect(exploreGoogleGl('ro', 'București'), 'ro');
      expect(exploreGoogleGl('en', 'London'), 'uk');
      expect(exploreGoogleGl('en', 'Nairobi'), '');
      expect(exploreCountryCodeForCity('Worldwide'), '');
      expect(exploreCountryCodeForCity('Seoul'), 'KR');
      expect(exploreCountryCodeForCity('Dubai'), 'AE');
      expect(exploreCountryCodeForCity('Chisinau'), 'MD');
      expect(exploreCountryCodeForCity('Tiranë'), 'AL');
      expect(exploreCountryCodeForCity('Tirana'), 'AL');
      expect(exploreGoogleGl('sq', 'Tiranë'), 'al');
      expect(exploreCityPriceSearchTerms('Tiranë').lang, 'sq');
      expect(ExploreCityIdentity.approxCoordinatesForCity('Tiranë'), isNotNull);
      final tiranaFallback = ExploreCityIdentity.resolve(
        rawCity: 'Tiranë',
        countryCode: exploreCountryCodeForCity('Tiranë'),
        latitude: ExploreCityIdentity.approxCoordinatesForCity('Tiranë')?.$1,
        longitude: ExploreCityIdentity.approxCoordinatesForCity('Tiranë')?.$2,
      );
      expect(tiranaFallback.isResolved, isTrue);
      expect(tiranaFallback.cityId, startsWith('geo_AL_'));
      expect(exploreGoogleGl('ro', 'Chisinau'), 'md');
      expect(exploreCityPriceSearchTerms('Chisinau').lang, 'ro');
      expect(CityCurrency.localCode('Chisinau'), 'MDL');
      expect(exploreCurrencyFitsSearchCity('MDL', 'Chisinau'), isTrue);
      expect(exploreCurrencyFitsSearchCity('EUR', 'Chisinau'), isTrue);
      expect(exploreCurrencyFitsSearchCity('RON', 'Chisinau'), isTrue);
      expect(exploreCurrencyFitsSearchCity('lei', 'Chisinau'), isTrue);
      expect(
        exploreBilingualPlacesPair(
          procedure: 'dermal filler lips cheeks',
          city: 'Chisinau',
          pill: 'Fillers',
        ),
        isNotEmpty,
      );

      expect(
        explorePriceMenuProbeUrls('clinic.co.uk'),
        contains('https://clinic.co.uk/prices'),
      );
      expect(
        explorePriceMenuProbeUrls('klinik.de'),
        contains('https://klinik.de/preise'),
      );
      expect(
        explorePriceMenuProbeUrls('clinic.ae'),
        contains('https://clinic.ae/prices'),
      );
    });

    test('25c. Every search is local language + English', () {
      final hairRo = exploreBilingualSearchPair(
        procedure: 'hair transplant FUE',
        city: 'București',
        pill: 'Hair',
      );
      expect(hairRo.length, 2);
      expect(
        hairRo.any(
          (q) =>
              q.toLowerCase().contains('transplant par') &&
              q.toLowerCase().contains('pret'),
        ),
        isTrue,
      );
      expect(
        hairRo.any((q) => q.toLowerCase().contains('hair transplant prices')),
        isTrue,
      );

      final hairPlaces = exploreBilingualPlacesPair(
        procedure: 'hair transplant FUE',
        city: 'București',
        pill: 'Hair',
      );
      expect(hairPlaces.length, 2);
      expect(hairPlaces[0].toLowerCase(), contains('transplant par'));
      expect(hairPlaces[1].toLowerCase(), contains('hair transplant clinic'));

      final paris = exploreBilingualSearchPair(
        procedure: 'hair transplant FUE',
        city: 'Paris',
        pill: 'Hair',
      );
      expect(paris.any((q) => q.toLowerCase().contains('greffe')), isTrue);
      expect(
        paris.any((q) => q.toLowerCase().contains('hair transplant prices')),
        isTrue,
      );

      final london = exploreBilingualSearchPair(
        procedure: 'rhinoplasty',
        city: 'London',
        pill: 'Rhinoplasty',
      );
      expect(
        london.any((q) => q.toLowerCase().contains('rhinoplasty prices')),
        isTrue,
      );

      expect(
        exploreSerpProcedureMatchTokens('hair transplant FUE'),
        containsAll(['transplant par', 'implant de par']),
      );
      expect(
        matchRawProcedureLabel(
          'Implant de par FUE',
          requestedProcedure: 'hair transplant FUE',
        ).family,
        'hair_transplant',
      );
      expect(
        matchRawProcedureLabel(
          '2000 grafturi FUE',
          requestedProcedure: 'hair transplant FUE',
        ).family,
        'hair_transplant',
      );
      expect(
        matchRawProcedureLabel(
          'fir cu fir',
          requestedProcedure: 'hair transplant FUE',
        ).family,
        'hair_transplant',
      );
    });

    test('25e. Dubai searches Arabic procedure names plus English', () {
      const pills = <({String pill, String procedure, String arabic})>[
        (
          pill: 'Botox',
          procedure: 'Botox anti-wrinkle injection',
          arabic: 'بوتوكس',
        ),
        (
          pill: 'Fillers',
          procedure: 'dermal filler lips cheeks',
          arabic: 'فيلر',
        ),
        (pill: 'Peels', procedure: 'chemical peel facial', arabic: 'تقشير'),
        (
          pill: 'Rhinoplasty',
          procedure: 'rhinoplasty nose job',
          arabic: 'تجميل الانف',
        ),
        (
          pill: 'Boob job',
          procedure: 'breast augmentation',
          arabic: 'تكبير الثدي',
        ),
        (pill: 'Hair', procedure: 'hair transplant FUE', arabic: 'زراعة الشعر'),
      ];
      for (final row in pills) {
        final web = exploreBilingualSearchPair(
          procedure: row.procedure,
          city: 'Dubai',
          pill: row.pill,
        );
        expect(web.length, 2, reason: row.pill);
        expect(
          web.any((q) => q.contains(row.arabic)),
          isTrue,
          reason: row.pill,
        );
        expect(
          web.any((q) => q.toLowerCase().contains('prices in dubai')),
          isTrue,
          reason: row.pill,
        );
        final places = exploreBilingualPlacesPair(
          procedure: row.procedure,
          city: 'Dubai',
          pill: row.pill,
        );
        expect(places.length, 2, reason: row.pill);
        expect(places[0], contains('عيادة'));
        expect(places[0], contains(row.arabic));
        expect(places[0], isNot(contains('dermal filler')));
        expect(places[1].toLowerCase(), contains('clinic dubai'));
      }
    });

    test('12e. Brand-range blog rows do not title the card with a price', () {
      expect(
        exploreWebsiteProcedureTitle(
          'Botulax Botox: AED 750 to AED 1,800 per area',
        ),
        'Botulax Botox',
      );
      expect(
        exploreWebsiteProcedureTitle(
          'Allergan Botox : AED 1,000 to AED 2,500 per area',
        ),
        'Allergan Botox',
      );
      // A listed unit stays part of the row.
      expect(
        exploreWebsiteProcedureTitle('Lip filler 1 ml'),
        'Lip filler 1 ml',
      );
      expect(
        exploreWebsiteProcedureTitle('Botox: 3 areas full face'),
        'Botox: 3 areas full face',
      );
      expect(
        exploreWebsiteProcedureTitle(
          'lip filler kiss lips teoxane 0.7 ml Book Now',
        ),
        'lip filler kiss lips teoxane 0.7 ml',
      );
      expect(
        exploreWebsiteProcedureTitle('Botox Treatment Areas · Your saving'),
        'Botox Treatment Areas',
      );
      expect(exploreWebsiteProcedureTitle(r'$13 to $18 per unit'), '');
      expect(exploreWebsiteProcedureTitle('per unit'), '');
      expect(exploreWebsiteProcedureTitle(r'$11 Per Unit Botox'), 'Botox');
      expect(looksLikeBarePriceLabel(r'$13 per unit'), isTrue);
      expect(looksLikeBarePriceLabel(r'$13 to $18 per unit'), isTrue);
      expect(looksLikePublishedPriceUnitLabel('per unit'), isTrue);
      expect(looksLikePublishedPriceUnitLabel('/unit'), isTrue);
      final unitOnly =
          _clinic(
            name: 'Expert Anti-Wrinkle Treatment',
            brand: 'Botox',
            host: 'southfloridafaceandbody.com',
            sourceUrl:
                'https://www.southfloridafaceandbody.com/miami-beach/crows-feet-treatment',
          ).copyWith(
            rawProcedureText: 'per unit',
            procedureCanonical: 'botox',
            procedureFamily: 'botox',
            priceLabel: r'from 13 $/unit',
            priceUnit: 'unit',
          );
      expect(
        exploreCardProcedureLabel(unitOnly, selectedPill: 'All'),
        'Botox treatment',
      );
      expect(
        exploreCardProcedureLabel(unitOnly, selectedPill: 'Botox'),
        'Botox treatment',
      );
      expect(
        exploreCardProcedureLabel(
          _clinic(
            name: 'The Beauty Clinic',
            brand: r'$11 Per Unit Botox',
            host: 'thebeautyclinic.com',
          ).copyWith(
            rawProcedureText: r'$11 Per Unit Botox',
            procedureFamily: 'botox',
            procedureCanonical: 'botox',
          ),
          selectedPill: 'Botox',
        ),
        'Botox treatment',
      );
      final eden =
          _clinic(
            name: 'EDEN Aesthetics Clinic',
            brand: 'Botulax Botox: AED 750 to AED 1,800 per area',
            host: 'edenderma.com',
            sourceUrl:
                'https://www.edenderma.com/post/best-botox-in-dubai-prices',
          ).copyWith(
            priceMin: 750,
            priceMax: 750,
            priceGbp: 750,
            currency: 'AED',
            priceLabel: '750 AED',
            rawPriceText: '750 AED',
            rawProcedureText: 'Botulax Botox: AED 750 to AED 1,800 per area',
          );
      expect(
        exploreCardProcedureLabel(eden, selectedPill: 'Botox'),
        'Botulax Botox',
      );
    });

    test('25f. Arabic menu rows match every pill and price in dirhams', () {
      const rows = <({String procedure, String label, String family})>[
        (
          procedure: 'Botox anti-wrinkle injection',
          label: 'بوتوكس منطقة واحدة',
          family: 'botox',
        ),
        (
          procedure: 'dermal filler lips cheeks',
          label: 'فيلر الشفاه 1 مل',
          family: 'filler',
        ),
        (
          procedure: 'laser hair removal',
          label: 'إزالة الشعر بالليزر',
          family: 'laser',
        ),
        (
          procedure: 'chemical peel facial',
          label: 'تقشير كيميائي للوجه',
          family: 'peel',
        ),
        (
          procedure: 'rhinoplasty nose job',
          label: 'عملية تجميل الانف',
          family: 'rhinoplasty',
        ),
        (
          procedure: 'breast augmentation',
          label: 'تكبير الثدي بالسيليكون',
          family: 'breast_augmentation',
        ),
        (
          procedure: 'hair transplant FUE',
          label: 'زراعة الشعر بتقنية القص',
          family: 'hair_transplant',
        ),
      ];
      for (final row in rows) {
        final match = matchRawProcedureLabel(
          row.label,
          requestedProcedure: row.procedure,
        );
        expect(match.rejectReason, '', reason: row.label);
        expect(match.family, row.family, reason: row.label);
      }

      expect(parsePriceText('1500 درهم')?.priceMin, 1500);
      expect(parsePriceText('1500 درهم')?.currency, 'AED');

      // Arabic FAQ questions are still rejected as card titles.
      expect(
        looksLikeRawScrapedProcedureTitle('كم تكلفة الفيلر في دبي؟'),
        isTrue,
      );

      // Keep a usable source-language tariff name on the card.
      final arabic =
          _clinic(
            name: 'Biolite Dubai',
            brand: 'فيلر الشفاه 1 مل',
            host: 'biolitedubai.com',
            sourceUrl: 'https://biolitedubai.com/fillers',
          ).copyWith(
            priceMin: 1500,
            priceMax: 1500,
            priceGbp: 1500,
            currency: 'AED',
            priceLabel: '1500 درهم',
            rawPriceText: '1500 درهم',
            rawProcedureText: 'فيلر الشفاه 1 مل',
          );
      expect(
        exploreCardProcedureLabel(arabic, selectedPill: 'Fillers'),
        'فيلر الشفاه 1 مل',
      );
    });

    test('25d. Dubai All does not show Romania or Netherlands menus', () {
      expect(
        exploreListingFitsSearchCity(
          city: 'Dubai',
          host: 'danabratu.ro',
          currency: 'EUR',
          procedureText: 'Peeling chimic superficial · Fata',
        ),
        isFalse,
      );
      expect(
        exploreListingFitsSearchCity(
          city: 'Dubai',
          host: 'houseofbratz.com',
          currency: '€',
          priceLabel: '€150',
          procedureText: 'Oplossen filler',
        ),
        isFalse,
      );
      expect(
        exploreListingFitsSearchCity(
          city: 'Dubai',
          host: 'drazra.com',
          currency: 'AED',
          procedureText: 'Botox treatment',
        ),
        isTrue,
      );
      expect(
        exploreListingFitsSearchCity(
          city: 'Dubai',
          host: 'adnan-tahir.com',
          currency: 'AED',
          procedureText: 'Rhinoplasty',
        ),
        isTrue,
      );
      expect(
        exploreListingFitsSearchCity(
          city: 'București',
          host: 'danabratu.ro',
          currency: 'EUR',
          procedureText: 'Peeling chimic superficial',
        ),
        isTrue,
      );
      expect(
        matchRawProcedureLabel(
          'Oplossen filler',
          requestedProcedure: 'dermal filler',
        ).rejectReason,
        'wrong_family_hyaluronidase',
      );
      expect(
        matchRawProcedureLabel(
          'Hair Filler',
          requestedProcedure: 'dermal filler lips cheeks',
        ).rejectReason,
        'wrong_family_hair_filler',
      );
      expect(
        matchRawProcedureLabel(
          'DR.CYJ Hair Filler',
          requestedProcedure: 'dermal filler',
        ).rejectReason,
        'wrong_family_hair_filler',
      );
      expect(
        matchRawProcedureLabel(
          'Hair mesotherapy',
          requestedProcedure: 'dermal filler lips cheeks',
        ).rejectReason,
        'wrong_family_hair_filler',
      );
    });

    test('25g. Abu Dhabi keeps verified quotes and skips Dubai-only URLs', () {
      expect(ExploreSeedCatalog.hasCityCoverage('Abu Dhabi'), isFalse);
      expect(ExploreSeedCatalog.hasCityCoverage('Dubai'), isTrue);
      expect(
        ExploreSeedCatalog.shouldHoldUnverifiedPrice(
          cityHasCatalog: false,
          hasPrice: true,
          alreadyPending: false,
          verified: true,
        ),
        isFalse,
      );
      expect(
        ExploreSeedCatalog.shouldHoldUnverifiedPrice(
          cityHasCatalog: false,
          hasPrice: true,
          alreadyPending: false,
          verified: false,
        ),
        isTrue,
      );
      expect(
        exploreUrlConflictsWithSearchCity(
          'https://elithair.com/ar/hair-transplant-blog/hair-transplant-in-dubai/',
          'Abu Dhabi',
        ),
        isTrue,
      );
      expect(
        exploreUrlConflictsWithSearchCity(
          'https://www.enfieldabudhabi.ae/ar/hair-transplant/',
          'Abu Dhabi',
        ),
        isFalse,
      );
      expect(
        exploreUrlConflictsWithSearchCity(
          'https://www.enfieldabudhabi.ae/ar/hair-transplant/',
          'Dubai',
        ),
        isTrue,
      );
      expect(
        exploreQuotedPriceConflictsWithSearchCity(
          city: 'Dubai',
          evidence:
              'يبلغ متوسط تكلفة حقن البوتوكس تحت الإبط في دبي وأبوظبي حوالي 2500 درهم',
        ),
        isFalse,
      );
      expect(
        exploreQuotedPriceConflictsWithSearchCity(
          city: 'Dubai',
          evidence: 'تتراوح تكلفة تجميل الأنف في أبوظبي بين 17,999 و 29,999',
        ),
        isTrue,
      );
    });

    test(
      '26. Radu Ionescu mojibake heading is a price range, not the title',
      () {
        final clinic =
            _clinic(
              name: 'DRR Dr Radu Ionescu',
              brand: 'Augmentare mamarÄ: Ã®ntre 8100â9300 euro',
              host: 'raduionescu.doctor',
              sourceUrl: 'https://raduionescu.doctor/preturi.html',
            ).copyWith(
              rawProcedureText:
                  'Augmentare mamarÄ\u0083: Ã®ntre 8100â\u0080\u00939300 euro',
              rawPriceText:
                  'Augmentare mamarÄ\u0083: Ã®ntre 8100â\u0080\u00939300 euro',
              priceLabel: 'from 8100 EUR',
              priceMin: 8100,
              priceMax: 9300,
              currency: 'EUR',
              procedureCanonical: 'breast_augmentation',
            );
        expect(
          exploreCardProcedureLabel(clinic, selectedPill: 'Boob job'),
          isNot(contains('Ã')),
        );
        expect(
          clinicCompareProcedurePriceDisplay(
            clinic,
            procedure: 'breast augmentation',
          ),
          '€8,100–€9,300',
        );
      },
    );
  });

  group('SERP fetch uses any listed price, not a snippet amount', () {
    test(
      'price-page URL is worth fetching without 499 / 1500 in the snippet',
      () {
        expect(
          exploreSerpHitWorthFetching(
            url: 'https://houseofbratz.com/prices',
            title: 'Prices Dubai',
            snippet: 'Botox treatment menu',
            procedure: 'Botox',
          ),
          isTrue,
        );
      },
    );

    test('monthly offers page mentioning botox is worth fetching', () {
      expect(
        exploreSerpHitWorthFetching(
          url: 'https://marinamedical.ae/monthly-offers-2/',
          title: 'Monthly Offers 2',
          snippet: 'Botox and fillers this month',
          procedure: 'Botox',
        ),
        isTrue,
      );
    });

    test('best-clinics ranking article is not worth fetching', () {
      expect(
        exploreSerpHitWorthFetching(
          url: 'https://blog.example/best-clinics-dubai',
          title: 'Best clinics in Dubai',
          snippet: 'Top 10 ranking of Botox prices',
          procedure: 'Botox',
        ),
        isFalse,
      );
    });

    test(
      'does not prefer a Google snippet amount over another listed botox price',
      () {
        const page = 'Botox from 700 AED. Crow feet botox 499 AED.';
        final result = verifyPriceDeterministically(
          pageText: page,
          procedure: 'Botox',
          candidateAmount: 499,
          candidateCurrency: 'AED',
        );
        expect(result.isVerified, isTrue);
        expect(result.priceMin, 700);
      },
    );

    test('every Explore pill fetches a price page without a snippet amount', () {
      const pills = [
        'Botox',
        'Fillers',
        'Peels',
        'Rhinoplasty',
        'Boob job',
        'Hair',
      ];
      for (final pill in pills) {
        expect(
          exploreSerpHitWorthFetching(
            url: 'https://exampleclinic.ae/prices',
            title: 'Prices Dubai',
            snippet: '',
            procedure: pill,
          ),
          isTrue,
          reason:
              '$pill should fetch /prices even with no 499 / 1500 in the snippet',
        );
      }
    });

    test(
      'procedure pages are worth fetching for fillers laser peels rhino breast hair',
      () {
        expect(
          exploreSerpHitWorthFetching(
            url: 'https://clinic.ae/lip-fillers',
            title: 'Lip fillers',
            snippet: 'Menu',
            procedure: 'Fillers',
          ),
          isTrue,
        );
        expect(
          exploreSerpHitWorthFetching(
            url: 'https://clinic.ae/laser-hair-removal',
            title: 'Laser hair removal',
            snippet: 'Packages',
            procedure: 'Laser',
          ),
          isTrue,
        );
        expect(
          exploreSerpHitWorthFetching(
            url: 'https://clinic.ae/chemical-peel',
            title: 'Chemical peel',
            snippet: '',
            procedure: 'Peels',
          ),
          isTrue,
        );
        expect(
          exploreSerpHitWorthFetching(
            url: 'https://clinic.ae/rhinoplasty',
            title: 'Rhinoplasty',
            snippet: '',
            procedure: 'Rhinoplasty',
          ),
          isTrue,
        );
        expect(
          exploreSerpHitWorthFetching(
            url: 'https://clinic.ae/breast-augmentation',
            title: 'Breast augmentation',
            snippet: '',
            procedure: 'Boob job',
          ),
          isTrue,
        );
        expect(
          exploreSerpHitWorthFetching(
            url: 'https://clinic.ae/hair-transplant',
            title: 'Hair transplant',
            snippet: '',
            procedure: 'Hair',
          ),
          isTrue,
        );
      },
    );

    test('27. Abu Dhabi does not keep Dubai clinics or snippet names', () {
      expect(
        explorePlacesAddressConflictsWithSearchCity(
          'Sheikh Zayed Road, Dubai, United Arab Emirates',
          'Abu Dhabi',
        ),
        isTrue,
      );
      expect(
        explorePlacesAddressConflictsWithSearchCity(
          'Marina village Villa A5 - أبو ظبي - United Arab Emirates',
          'Abu Dhabi',
        ),
        isFalse,
      );
      expect(
        exploreListingFitsSearchCity(
          city: 'Abu Dhabi',
          host: 'drazra.com',
          currency: 'AED',
          procedureText: 'Laser Hair Removal Price Abu Dhabi',
          area: 'Sheikh Zayed Road, Dubai',
        ),
        isFalse,
      );
      expect(
        exploreTextConflictsWithSearchCity(
          'تتراوح تكلفة تجميل الأنف في دبي بين 17,999 و 29,999',
          'Abu Dhabi',
        ),
        isTrue,
      );
      expect(
        exploreClinicNameFromSerpTitle(
          'Laser Hair Removal Price Abu Dhabi — From AED 100 | Dr Azra',
          'drazra.com',
        ),
        'Dr Azra',
      );
      expect(
        exploreClinicDisplayName(
          _clinic(
            name: 'From AED 100',
            host: 'drazra.com',
            sourceUrl: 'https://drazra.com/laser',
          ),
        ),
        'Dra Zra',
      );
      expect(
        looksLikeRawScrapedProcedureTitle(
          'Laser Hair Removal Price Abu Dhabi — From | Dr Azra',
        ),
        isTrue,
      );
      expect(
        exploreCardProcedureLabel(
          _clinic(
            name: 'Dr Azra',
            brand:
                'Laser Hair Removal Price Abu Dhabi — From AED 100 | Dr Azra',
            host: 'drazra.com',
            sourceUrl: 'https://drazra.com/laser',
          ),
          selectedPill: 'Laser',
        ),
        'Laser skin treatment',
      );
    });

    test(
      'London breast: financing SEO is not the card title; £2500 is not verified',
      () {
        expect(
          looksLikeFinancingOrPaymentHeading('Breast surgery financing'),
          isTrue,
        );
        expect(
          looksLikeRawScrapedProcedureTitle('Breast surgery financing'),
          isTrue,
        );
        expect(
          looksLikeCommerceChromeLabel('Breast surgery financing'),
          isTrue,
        );

        final enhance =
            _clinic(
              name: 'Enhance Medical Group',
              brand: 'Breast surgery financing',
              host: 'enhancemedicalgroup.com',
              sourceUrl: 'https://enhancemedicalgroup.com/boob-job-cost',
            ).copyWith(
              rawProcedureText: 'Breast surgery financing',
              priceMin: 4595,
              priceMax: 4595,
              priceGbp: 4595,
              currency: 'GBP',
              priceLabel: 'from 4595 GBP',
              rawPriceText: 'from £4,595',
              procedureCanonical: 'breast_augmentation',
              procedureFamily: 'breast',
            );
        expect(
          exploreCardProcedureLabel(enhance, selectedPill: 'Boob job'),
          'Breast augmentation',
        );
        expect(
          clinicCompareProcedurePriceDisplay(
            enhance,
            procedure: 'breast augmentation',
          ),
          'from 4,595 £',
        );

        final harleyUnilateral =
            _clinic(
              name: 'Harley Medical',
              brand: 'Unilateral breast augmentation',
              host: 'harleymedical.co.uk',
              sourceUrl: 'https://www.harleymedical.co.uk/boob-job-cost',
            ).copyWith(
              rawProcedureText: 'Unilateral breast augmentation',
              priceMin: 6495,
              priceMax: 6495,
              priceGbp: 6495,
              currency: 'GBP',
              priceLabel: 'from 6495 GBP',
              rawPriceText: 'from £6,495',
              procedureCanonical: 'breast_augmentation',
            );
        expect(
          exploreCardProcedureLabel(harleyUnilateral, selectedPill: 'Boob job'),
          'Breast augmentation',
        );
        expect(
          isJustifiedProcedurePrice(
            harleyUnilateral,
            procedure: 'breast augmentation',
          ),
          isFalse,
        );
        expect(
          clinicCompareProcedurePriceDisplay(
            harleyUnilateral,
            procedure: 'breast augmentation',
          ),
          isEmpty,
        );

        final harley =
            _clinic(
              name: 'Harley Medical',
              brand: 'Breast augmentation',
              host: 'harleymedical.co.uk',
              sourceUrl: 'https://www.harleymedical.co.uk/boob-job-cost',
            ).copyWith(
              rawProcedureText: 'Breast augmentation',
              priceMin: 6995,
              priceMax: 6995,
              priceGbp: 6995,
              currency: 'GBP',
              priceLabel: 'from 6995 GBP',
              rawPriceText: 'from £6,995',
              procedureCanonical: 'breast_augmentation',
            );

        final cadoganMarket =
            _clinic(
              name: 'Cadogan Clinic',
              brand: 'Breast augmentation',
              host: 'cadoganclinic.com',
              sourceUrl:
                  'https://www.cadoganclinic.com/cosmetic-surgery/breast-surgery/breast-enlargement/',
            ).copyWith(
              rawProcedureText: 'Breast augmentation',
              priceMin: 5000,
              priceMax: 7000,
              priceGbp: 5000,
              currency: 'GBP',
              priceLabel: 'from 5,000-7,000 GBP',
              rawPriceText: 'from £5,000-£7,000',
              procedureCanonical: 'breast_augmentation',
            );
        expect(
          looksLikeRoundedMarketPriceSpread(
            priceMin: 5000,
            priceMax: 7000,
            currency: 'GBP',
            procedure: 'breast augmentation',
          ),
          isTrue,
        );
        expect(
          isJustifiedProcedurePrice(
            cadoganMarket,
            procedure: 'breast augmentation',
          ),
          isFalse,
        );
        expect(
          clinicCompareProcedurePriceDisplay(
            cadoganMarket,
            procedure: 'breast augmentation',
          ),
          isEmpty,
        );

        final nuffield =
            _clinic(
              name: 'Nuffield Health',
              brand: 'Pain following breast enlargement surgery · Treatment',
              host: 'nuffieldhealth.com',
              sourceUrl:
                  'https://www.nuffieldhealth.com/treatments/breast-augmentation-enlargement',
            ).copyWith(
              rawProcedureText:
                  'Pain following breast enlargement surgery · Treatment',
              priceMin: 8579,
              priceMax: 8579,
              priceGbp: 8579,
              currency: 'GBP',
              priceLabel: 'from 8579 GBP',
              rawPriceText: 'from £8,579',
              procedureCanonical: 'breast_augmentation',
              procedureFamily: 'breast',
            );
        expect(
          looksLikeComplicationOrAftercareHeading(
            'Pain following breast enlargement surgery',
          ),
          isTrue,
        );
        expect(
          exploreCardProcedureLabel(nuffield, selectedPill: 'Boob job'),
          'Breast augmentation',
        );
        expect(
          clinicCompareProcedurePriceDisplay(
            nuffield,
            procedure: 'breast augmentation',
          ),
          'from 8,579 £',
        );

        final mya =
            _clinic(
              name: 'MYA',
              brand: 'Breast Enlargement Cost',
              host: 'mya.co.uk',
              sourceUrl:
                  'https://www.mya.co.uk/breast-procedures/breast-enlargement/cost',
            ).copyWith(
              rawProcedureText: 'Breast Enlargement Cost',
              priceMin: 6000,
              priceMax: 6000,
              priceGbp: 6000,
              currency: 'GBP',
              priceLabel: 'from 6000 GBP',
              rawPriceText: 'from £6,000',
              procedureCanonical: 'breast_augmentation',
              procedureFamily: 'breast',
            );
        expect(looksLikeSeoCostPageHeading('Breast Enlargement Cost'), isTrue);
        expect(
          looksLikeRawScrapedProcedureTitle('Breast Enlargement Cost'),
          isTrue,
        );
        expect(
          looksLikeRawScrapedProcedureTitle('Breast Enlargement'),
          isFalse,
        );
        expect(
          exploreCardProcedureLabel(mya, selectedPill: 'Boob job'),
          'Breast augmentation',
        );
        expect(
          clinicCompareProcedurePriceDisplay(
            mya,
            procedure: 'breast augmentation',
          ),
          'from 6,000 £',
        );

        final hsbc =
            _clinic(
              name: 'Harley Street Breast Centre',
              brand: 'Breast augmentation',
              host: 'harleystreetbreastcentre.com',
              sourceUrl:
                  'https://harleystreetbreastcentre.com/breast-augmentation-cost-london/',
            ).copyWith(
              rawProcedureText: 'Breast augmentation',
              priceMin: 2500,
              priceMax: 2500,
              priceGbp: 2500,
              currency: 'GBP',
              priceLabel: 'from 2,500 GBP',
              rawPriceText: 'from 2,500 GBP',
              priceUnit: 'package',
              procedureCanonical: 'breast_augmentation',
            );
        expect(
          isValidExtractedPriceCandidate(
            rawPriceText: hsbc.rawPriceText,
            priceMin: hsbc.priceMin,
            currency: 'GBP',
            extractionMethod: 'html_table',
            procedure: 'breast augmentation',
            sourceUrl: hsbc.priceSourceUrl,
          ),
          isFalse,
        );
        expect(explorePriceIsVerified(hsbc), isFalse);
        expect(
          clinicCompareProcedurePriceDisplay(
            hsbc,
            procedure: 'breast augmentation',
          ),
          isEmpty,
        );
        expect(
          clinicCompareProcedurePriceDisplay(
            hsbc,
            procedure: 'breast augmentation',
          ),
          isNot(contains('package')),
        );
        expect(
          clinicCompareAggregateRangeDisplay([
            enhance,
            harley,
            hsbc,
            harleyUnilateral,
            cadoganMarket,
          ], procedure: 'breast augmentation'),
          'from 4,595–6,995 GBP',
        );
      },
    );

    test('pool-verified skip does not hide wrong-family or help-number rows', () {
      final botoxShowable =
          _clinic(
            name: 'Airport Road Hospital',
            brand: 'Botox treatment',
            host: 'mediclinic.ae',
            sourceUrl: 'https://mediclinic.ae/botox',
          ).copyWith(
            priceMin: 1500,
            priceMax: 1500,
            priceGbp: 1500,
            currency: 'AED',
            priceLabel: 'from 1500 AED',
            rawPriceText: 'from 1500 AED',
            rawProcedureText: 'Botox treatment',
            priceEvidenceText: 'Botox treatment from 1500 AED',
            extractionMethod: 'html_table',
          );
      expect(
        exploreDiscoveryShouldSkipPoolVerified(
          botoxShowable,
          procedure: 'Botox anti-wrinkle injection',
          city: 'Abu Dhabi',
        ),
        isTrue,
      );

      final peelOnBotoxSearch =
          _clinic(
            name: 'Enfield Royal Clinic Abu Dhabi',
            brand: 'Chemical peel',
            host: 'enfieldabudhabi.ae',
            sourceUrl: 'https://www.enfieldabudhabi.ae/peels',
          ).copyWith(
            priceMin: 399,
            priceMax: 399,
            priceGbp: 399,
            currency: 'AED',
            priceLabel: '399 AED',
            rawPriceText: '399 AED',
            rawProcedureText: 'Chemical peel',
          );
      expect(
        exploreClinicMatchesProcedure(
          peelOnBotoxSearch,
          'Botox anti-wrinkle injection',
        ),
        isFalse,
      );
      expect(
        exploreDiscoveryShouldSkipPoolVerified(
          peelOnBotoxSearch,
          procedure: 'Botox anti-wrinkle injection',
          city: 'Abu Dhabi',
        ),
        isFalse,
      );

      final helpNumber =
          _clinic(
            name: 'Mediclinic',
            brand: 'Botox treatment',
            host: 'mediclinic.ae',
            sourceUrl:
                'https://www.mediclinic.ae/en/airport-road-hospital/emergency.html',
          ).copyWith(
            priceMin: 999,
            priceMax: 999,
            priceGbp: 999,
            currency: 'AED',
            priceLabel: '999 AED',
            rawPriceText: '999 AED',
            rawProcedureText: 'Botox treatment',
            priceEvidenceText:
                'In urgent cases, ring 999; this is the emergency number for the UAE',
            extractionMethod: 'text_proximity',
          );
      expect(
        isJustifiedProcedurePrice(
          helpNumber,
          procedure: 'Botox anti-wrinkle injection',
        ),
        isFalse,
      );
      expect(
        exploreDiscoveryShouldSkipPoolVerified(
          helpNumber,
          procedure: 'Botox anti-wrinkle injection',
          city: 'Abu Dhabi',
        ),
        isFalse,
      );
    });

    test('verified Botox row is never both skipped and dropped', () {
      final procedure = explorePillAiSearchQuery('Botox');
      expect(procedure, 'Botox anti-wrinkle injection');

      OpenAIClinic spa({required String label, String storedRelation = ''}) {
        return _clinic(
          name: 'Miami Skin Spa',
          brand: label,
          host: 'miamiskinspa.example',
          sourceUrl: 'https://miamiskinspa.example/botox',
        ).copyWith(
          priceMin: 350,
          priceMax: 350,
          priceGbp: 350,
          currency: 'USD',
          priceLabel: 'from 350 USD',
          rawPriceText: r'$350',
          rawProcedureText: label,
          priceEvidenceText: '$label \$350',
          extractionMethod: 'html_table',
          procedureRelation: storedRelation,
        );
      }

      void expectAligned(OpenAIClinic clinic, {required bool showable}) {
        final eligible = exploreClinicEligibleForVerifiedPool(
          clinic,
          procedure: procedure,
          city: 'Miami',
        );
        final skip = exploreDiscoveryShouldSkipPoolVerified(
          clinic,
          procedure: procedure,
          city: 'Miami',
        );
        expect(skip, eligible);
        expect(eligible, showable);
        expect(skip && !eligible, isFalse);
      }

      final current = spa(label: 'Botox anti-wrinkle injection');
      final currentRel = exploreCurrentProcedureRelation(
        current,
        procedure: procedure,
      );
      expect(currentRel.eligibleForFromPrice, isTrue);
      expect(
        currentRel.relation,
        anyOf(ProcedureRelation.exact, ProcedureRelation.variant),
      );
      expectAligned(current, showable: true);

      final staleLegacy = spa(
        label: 'Botox anti-wrinkle injection',
        storedRelation: 'same_treatment',
      );
      expect(
        exploreCurrentProcedureRelation(
          staleLegacy,
          procedure: procedure,
        ).eligibleForFromPrice,
        isTrue,
      );
      expectAligned(staleLegacy, showable: true);
      expect(
        withCanonicalExploreProcedureRelation(
          staleLegacy,
          procedure: procedure,
        ).procedureRelation,
        anyOf('exact', 'variant'),
      );

      final staleHard = spa(
        label: 'Botox anti-wrinkle injection',
        storedRelation: 'ambiguous',
      );
      expectAligned(staleHard, showable: true);

      final ambiguous = spa(label: 'Injectables');
      final ambRel = exploreCurrentProcedureRelation(
        ambiguous,
        procedure: procedure,
      );
      expect(ambRel.eligibleForFromPrice, isFalse);
      expectAligned(ambiguous, showable: false);

      final endolift = spa(label: 'Endolift JawLine (Under Chin)');
      final endoRel = exploreCurrentProcedureRelation(
        endolift,
        procedure: procedure,
      );
      expect(endoRel.eligibleForFromPrice, isFalse);
      expect(endoRel.relation, ProcedureRelation.differentProcedure);
      expectAligned(endolift, showable: false);
    });

    test('London laser: keep named rows, drop Ripley Lazer Lounge', () {
      expect(
        exploreTreatmentFamily('Photo Rejuvenation Face'),
        ExploreTreatmentFamily.laser,
      );
      expect(
        exploreCardProcedureLabel(
          _clinic(
            name: 'The Laser Clinic',
            brand: 'Photo Rejuvenation Face',
            host: 'the-laserclinic.com',
            sourceUrl: 'https://the-laserclinic.com/pages/prices',
          ).copyWith(
            rawProcedureText: 'Photo Rejuvenation Face',
            priceMin: 180,
            currency: 'GBP',
            priceLabel: 'from 180 GBP',
          ),
          selectedPill: 'Laser',
        ),
        'Photo Rejuvenation Face',
      );
      expect(
        exploreLaserRowFitsRequest(
          label: 'Laser Hair Removal · peri anal',
          procedure: explorePillAiSearchQuery('Laser'),
        ),
        isFalse,
      );
      expect(
        exploreListingFitsSearchCity(
          city: 'London',
          host: 'lazerlounge.co.uk',
          currency: 'GBP',
          procedureText: 'Laser hair removal in Ripley, Derbyshire',
          area: 'Ripley, Derbyshire',
        ),
        isFalse,
      );
      expect(
        explorePlacesAddressConflictsWithSearchCity(
          'Ripley, Derbyshire DE5',
          'London',
        ),
        isTrue,
      );
      expect(
        exploreTextConflictsWithSearchCity(
          'Lazer Lounge, Ripley, Derbyshire, serving Nottingham and Derby.',
          'London',
        ),
        isTrue,
      );
      expect(exploreVisibleComparePill('Laser'), 'Hair');
      expect(exploreVisibleComparePill('Hair removal'), 'Hair');
      expect(exploreVisibleComparePill('Skin laser'), 'Hair');
      expect(exploreVisibleComparePill('All'), 'Botox');
      expect(exploreVisibleComparePill(''), 'Botox');
      expect(explorePillAiSearchQuery('Laser'), 'laser skin rejuvenation IPL');
      expect(
        explorePillAiSearchQuery('Hair removal'),
        'laser skin rejuvenation IPL',
      );
      expect(
        explorePillAiSearchQuery('Skin laser'),
        'laser skin rejuvenation IPL',
      );
    });

    test('London peel typical range ignores Cosmelan starter kit', () {
      OpenAIClinic peelCard({
        required String name,
        required String brand,
        required String host,
        required String path,
        required double price,
      }) {
        return _clinic(
          name: name,
          brand: brand,
          host: host,
          sourceUrl: 'https://$host$path',
        ).copyWith(
          rawProcedureText: brand,
          priceMin: price,
          priceMax: price,
          priceGbp: price.round(),
          currency: 'GBP',
          priceLabel: 'from $price GBP',
          rawPriceText: 'from £$price',
          procedureCanonical: 'chemical_peel',
          procedureFamily: 'peel',
        );
      }

      final cards = [
        peelCard(
          name: 'sk:n London Wall',
          brand: 'Epionce Light Refresh peel',
          host: 'sknclinics.co.uk',
          path: '/prices',
          price: 110,
        ),
        peelCard(
          name: 'Dr Pradnya',
          brand: 'Mandelic Acid Peels',
          host: 'drpradnyalondon.com',
          path: '/price-list',
          price: 105,
        ),
        peelCard(
          name: 'Skin Logic Aesthetics',
          brand: 'Cosmelan Peel Starter Kit',
          host: 'skinlogicaesthetics.co.uk',
          path: '/cosmelan-peel/',
          price: 850,
        ).copyWith(
          priceMax: 1000,
          priceLabel: 'from 850–1,000 £',
          rawPriceText: 'Limited Time Offer £1000£850',
          priceEvidenceText:
              'Cosmelan Peel Starter Kit homecare kit with 3 products £850',
        ),
        peelCard(
          name: 'Aesthetics of London',
          brand: 'Skin Peel',
          host: 'aestheticsoflondon.com',
          path: '/prices',
          price: 59,
        ),
      ];
      expect(
        looksLikeDepigmentationPeelPackage('Cosmelan Peel Starter Kit'),
        isTrue,
      );
      expect(
        explorePriceIsComparableTypicalStart(
          procedure: 'chemical peel facial',
          rawProcedureText: 'Cosmelan Peel Starter Kit',
          rawPriceText: 'from 850–1,000 £',
        ),
        isFalse,
      );
      expect(
        clinicCompareAggregateRangeDisplay(
          cards,
          procedure: 'chemical peel facial',
        ),
        'from 59–110 GBP',
      );
    });

    test(
      'London rhinoplasty typical range ignores tip market band and stale male landing',
      () {
        OpenAIClinic rhinoCard({
          required String name,
          required String brand,
          required String host,
          required String path,
          required double price,
          double priceMax = 0,
          String rawPriceText = '',
          String evidence = '',
        }) {
          return _clinic(
            name: name,
            brand: brand,
            host: host,
            sourceUrl: 'https://$host$path',
          ).copyWith(
            rawProcedureText: brand,
            priceMin: price,
            priceMax: priceMax > 0 ? priceMax : price,
            priceGbp: price.round(),
            currency: 'GBP',
            priceLabel: 'from $price GBP',
            rawPriceText: rawPriceText.isEmpty ? 'from £$price' : rawPriceText,
            priceEvidenceText: evidence.isEmpty ? 'from £$price' : evidence,
            procedureCanonical: 'rhinoplasty',
            procedureFamily: 'rhinoplasty',
          );
        }

        final cards = [
          rhinoCard(
            name: 'London Private Hospital',
            brand: 'Tip rhinoplasty',
            host: 'londonprivatehospital.uk',
            path: '/rhinoplasty-london-prices/',
            price: 3500,
            priceMax: 5500,
            rawPriceText: 'from £3,500–£5,500',
            evidence:
                'Typical London Price Ranges on average: Tip rhinoplasty £3,500–£5,500',
          ),
          rhinoCard(
            name: 'Cadogan Clinic',
            brand: 'Rhinoplasty for men',
            host: 'cadoganclinic.com',
            path: '/for-men/rhinoplasty-for-men/',
            price: 6900,
            rawPriceText: 'starts from £6,900',
            evidence: 'A male nose job procedure starts from £6,900',
          ),
          rhinoCard(
            name: 'Dr Nizar Hamadeh',
            brand: 'Primary / Closed Rhinoplasty',
            host: 'nizarhamadeh.com',
            path: '/rhinoplasty/',
            price: 7998,
            rawPriceText: 'from £7,998',
          ),
          rhinoCard(
            name: 'William Townley',
            brand: 'Ultrasonic rhinoplasty',
            host: 'williamtownley.co.uk',
            path: '/rhinoplasty/cost/',
            price: 12500,
            rawPriceText: 'from £12,500',
          ),
        ];
        expect(
          explorePriceIsComparableTypicalStart(
            procedure: 'rhinoplasty nose job',
            rawProcedureText: 'Tip rhinoplasty',
            rawPriceText: 'from £3,500–£5,500',
            sourceUrl:
                'https://londonprivatehospital.uk/rhinoplasty-london-prices/',
            priceMin: 3500,
            priceMax: 5500,
            currency: 'GBP',
          ),
          isFalse,
        );
        expect(
          explorePriceIsComparableTypicalStart(
            procedure: 'rhinoplasty nose job',
            rawProcedureText: 'Rhinoplasty for men',
            rawPriceText: 'starts from £6,900',
            sourceUrl:
                'https://www.cadoganclinic.com/for-men/rhinoplasty-for-men/',
            priceMin: 6900,
            currency: 'GBP',
          ),
          isFalse,
        );
        expect(
          clinicCompareAggregateRangeDisplay(
            cards,
            procedure: 'rhinoplasty nose job',
          ),
          'from 7,998–13k GBP',
        );
      },
    );

    test('London rhinoplasty typical range is complete clinic FROM only', () {
      OpenAIClinic rhinoCard({
        required String name,
        required String host,
        required String sourceUrl,
        required double price,
        required String rawProcedureText,
        required String rawPriceText,
        double priceMax = 0,
        String evidence = '',
      }) {
        return _clinic(
          name: name,
          brand: 'rhinoplasty nose job',
          host: host,
          sourceUrl: sourceUrl,
        ).copyWith(
          rawProcedureText: rawProcedureText,
          priceMin: price,
          priceMax: priceMax > 0 ? priceMax : price,
          priceGbp: price.round(),
          currency: 'GBP',
          priceLabel: 'from $price GBP',
          rawPriceText: rawPriceText,
          priceEvidenceText: evidence.isEmpty ? rawPriceText : evidence,
          procedureCanonical: 'rhinoplasty',
          procedureFamily: 'rhinoplasty',
          priceExtractRevision: kExplorePriceExtractRevision,
        );
      }

      final enhance = rhinoCard(
        name: 'Enhance Medical Group',
        host: 'enhancemedicalgroup.com',
        sourceUrl: 'https://enhancemedicalgroup.com/face-surgery/rhinoplasty',
        price: 6295,
        rawProcedureText: 'Rhinoplasty',
        rawPriceText: 'from £6,295',
      );
      final townley = rhinoCard(
        name: 'William Townley',
        host: 'williamtownley.co.uk',
        sourceUrl: 'https://www.williamtownley.co.uk/rhinoplasty/cost/',
        price: 12500,
        rawProcedureText: 'Ultrasonic rhinoplasty',
        rawPriceText: 'starts at £12,500',
      );
      final hje = rhinoCard(
        name: 'Hje',
        host: 'hje.org.uk',
        sourceUrl: 'https://hje.org.uk/treatments/rhinoplasty/',
        price: 3000,
        rawProcedureText: 'Rhinoplasty',
        rawPriceText: 'starts from £3,000* (guide price)',
        evidence:
            'The cost of a private rhinoplasty starts from £3,000* (Guide Price). '
            'This guide price excludes consultation fees and professional fees '
            'charged separately by your surgeon and anaesthetist.',
      );
      final arda = rhinoCard(
        name: 'Assoc. Prof. Dr. Arda Kucukguven',
        host: 'ardakucukguven.com',
        sourceUrl:
            'https://ardakucukguven.com/rhinoplasty-cost-in-london-complete-pricing-guide/',
        price: 7000,
        priceMax: 15000,
        rawProcedureText: 'Ethnic Rhinoplasty',
        rawPriceText: 'from £7,000–£15,000',
        evidence:
            'London rhinoplasty prices typically range from £6,000-£15,000',
      );

      expect(
        clinicCompareProcedurePriceDisplay(
          enhance,
          procedure: 'rhinoplasty nose job',
        ),
        contains('6,295'),
      );
      expect(
        clinicCompareProcedurePriceDisplay(
          townley,
          procedure: 'rhinoplasty nose job',
        ),
        contains('12500'),
      );
      expect(
        clinicCompareProcedurePriceDisplay(
          hje,
          procedure: 'rhinoplasty nose job',
        ),
        contains('hospital fees only'),
      );
      expect(
        clinicCompareProcedurePriceDisplay(
          arda,
          procedure: 'rhinoplasty nose job',
        ),
        isEmpty,
      );
      expect(
        clinicCompareAggregateRangeDisplay([
          enhance,
          townley,
          hje,
          arda,
        ], procedure: 'rhinoplasty nose job'),
        'from 6,295–13k GBP',
      );
    });

    test('London hair cards show package FROM, not /graft on graft counts', () {
      final westminster =
          _clinic(
            name: 'Westminster Clinic',
            price: 3500,
            brand: 'hair transplant FUE',
            host: 'westminsterclinic.co.uk',
            sourceUrl:
                'https://westminsterclinic.co.uk/cost-and-prices-for-hair-transplants-in-london/',
          ).copyWith(
            rawProcedureText: 'Cost of 500 FUE grafts',
            priceMin: 3500,
            priceMax: 3500,
            priceGbp: 3500,
            currency: 'GBP',
            priceLabel: 'from 3,500 GBP',
            rawPriceText: 'Cost of 500 FUE grafts – from £3500',
            priceUnit: '',
            priceQuantity: 500,
            procedureCanonical: 'hair_transplant',
            priceExtractRevision: kExplorePriceExtractRevision,
          );
      expect(
        clinicCompareProcedurePriceDisplay(
          westminster,
          procedure: 'hair transplant FUE',
        ),
        contains('3,500'),
      );
      expect(
        clinicCompareProcedurePriceDisplay(
          westminster,
          procedure: 'hair transplant FUE',
        ),
        isNot(contains('/graft')),
      );
      expect(
        clinicCompareProcedurePriceDisplay(
          westminster,
          procedure: 'hair transplant FUE',
        ),
        contains('500 grafts'),
      );

      final bogusGraft = westminster.copyWith(
        priceMin: 1000,
        priceMax: 1000,
        priceGbp: 1000,
        priceLabel: 'from 1000 GBP/graft',
        rawPriceText: '1,000 FUE grafts',
        priceUnit: 'grafts',
        priceQuantity: 1000,
      );
      expect(
        isJustifiedProcedurePrice(bogusGraft, procedure: 'hair transplant FUE'),
        isFalse,
      );

      OpenAIClinic hairCard({
        required String name,
        required String host,
        required String sourceUrl,
        required double price,
        required String rawProcedureText,
        required String rawPriceText,
        double priceMax = 0,
        String priceUnit = '',
        double priceQuantity = 0,
      }) {
        return _clinic(
          name: name,
          price: price,
          brand: 'hair transplant FUE',
          host: host,
          sourceUrl: sourceUrl,
        ).copyWith(
          rawProcedureText: rawProcedureText,
          priceMin: price,
          priceMax: priceMax > 0 ? priceMax : price,
          priceGbp: price.round(),
          currency: 'GBP',
          priceLabel: 'from $price GBP',
          rawPriceText: rawPriceText,
          priceEvidenceText: rawPriceText,
          priceUnit: priceUnit,
          priceQuantity: priceQuantity,
          procedureCanonical: 'hair_transplant',
          priceExtractRevision: kExplorePriceExtractRevision,
        );
      }

      final myHair = hairCard(
        name: 'My Hair UK',
        host: 'myhairuk.com',
        sourceUrl: 'https://www.myhairuk.com/fue-hair-transplant-cost/',
        price: 2499,
        rawProcedureText: '500 grafts FUE',
        rawPriceText: '500 grafts = £2,499',
        priceQuantity: 500,
      );
      final westminsterRange = hairCard(
        name: 'Westminster Clinic',
        host: 'westminsterclinic.co.uk',
        sourceUrl:
            'https://westminsterclinic.co.uk/cost-and-prices-for-hair-transplants-in-london/',
        price: 3500,
        rawProcedureText: 'Cost of 500 FUE grafts',
        rawPriceText: 'Cost of 500 FUE grafts – from £3500',
        priceQuantity: 500,
      );
      final tamStale = hairCard(
        name: 'Dr Mark Tam',
        host: 'drmarktam.co.uk',
        sourceUrl: 'https://drmarktam.co.uk/fue-hair-transplant/',
        price: 5400,
        priceMax: 7600,
        rawProcedureText: 'FUE hair transplant',
        rawPriceText: 'starts from £5400 to £7600',
      );
      final lhtcMarket = hairCard(
        name: 'London Hair Transplant Clinic',
        host: 'londonhairtransplantclinic.uk',
        sourceUrl:
            'https://londonhairtransplantclinic.uk/the-cost-of-hair-transplants-london-a-complete-breakdown/',
        price: 1.5,
        rawProcedureText: 'FUT',
        rawPriceText: 'starting at £1.50 per graft',
        priceUnit: 'graft',
      );
      expect(
        explorePriceIsComparableTypicalStart(
          procedure: 'hair transplant FUE',
          rawProcedureText: myHair.rawProcedureText,
          rawPriceText: myHair.rawPriceText,
          sourceUrl: myHair.priceSourceUrl,
          priceMin: myHair.priceMin,
          currency: 'GBP',
        ),
        isTrue,
      );
      expect(
        explorePriceIsComparableTypicalStart(
          procedure: 'hair transplant FUE',
          rawProcedureText: tamStale.rawProcedureText,
          rawPriceText: tamStale.rawPriceText,
          sourceUrl: tamStale.priceSourceUrl,
          priceMin: tamStale.priceMin,
          priceMax: tamStale.priceMax,
          currency: 'GBP',
        ),
        isFalse,
      );
      expect(
        explorePriceIsComparableTypicalStart(
          procedure: 'hair transplant FUE',
          rawProcedureText: lhtcMarket.rawProcedureText,
          rawPriceText: lhtcMarket.rawPriceText,
          sourceUrl: lhtcMarket.priceSourceUrl,
          priceMin: lhtcMarket.priceMin,
          currency: 'GBP',
        ),
        isFalse,
      );
      expect(
        clinicCompareAggregateRangeDisplay([
          myHair,
          westminsterRange,
          tamStale,
          lhtcMarket,
        ], procedure: 'hair transplant FUE'),
        'from 2,499–3,500 GBP',
      );
    });
  });

  group('canonical city + early discovery rejects', () {
    test('Timisoara and Timișoara share one canonical key', () {
      expect(exploreCanonicalCityKey('Timisoara'), 'timisoara');
      expect(exploreCanonicalCityKey('Timișoara'), 'timisoara');
      expect(exploreCanonicalCityKey('Chișinău'), 'chisinau');
      expect(exploreCanonicalCityKey('Chisinau'), 'chisinau');
      expect(exploreCanonicalCityKey('Iași'), 'iasi');
      expect(exploreCanonicalCityKey('București'), 'bucharest');
      expect(exploreCanonicalCityKey('Tiranë'), 'tirane');
      expect(exploreCanonicalCityKey('Tirana'), 'tirane');
      expect(exploreCanonicalCityKey('Budapest'), 'budapest');
    });

    test('Budapest Botox does not keep a Tiranë clinic', () {
      expect(
        exploreDisplayedLocalityConflictsWithSearchCity(
          'Tiranë · botoxtirana.com',
          'Budapest',
        ),
        isTrue,
      );
      expect(
        exploreUrlConflictsWithSearchCity(
          'https://botoxtirana.com/cost-of-procedures/',
          'Budapest',
        ),
        isTrue,
      );
      expect(
        exploreUrlConflictsWithSearchCity(
          'https://goldentirana.com/price-list/',
          'Budapest',
        ),
        isTrue,
      );
      expect(
        exploreListingFitsSearchCity(
          city: 'Budapest',
          host: 'botoxtirana.com',
          currency: 'EUR',
          procedureText: 'Botox',
          area: 'Tiranë · botoxtirana.com',
          url: 'https://botoxtirana.com/cost-of-procedures/',
        ),
        isFalse,
      );
      expect(
        exploreListingFitsSearchCity(
          city: 'Budapest',
          host: 'koc.hu',
          currency: 'HUF',
          procedureText: 'Botox',
          area: 'Budapest · koc.hu',
          url: 'https://koc.hu/en/arlista',
        ),
        isTrue,
      );
      expect(
        exploreListingFitsSearchCity(
          city: 'Tiranë',
          host: 'botoxtirana.com',
          currency: 'EUR',
          procedureText: 'Botox',
          area: 'Tiranë · botoxtirana.com',
          url: 'https://botoxtirana.com/cost-of-procedures/',
        ),
        isTrue,
      );
      expect(
        explorePlacesAddressConflictsWithSearchCity(
          'Rruga Ismail Qemali, Tiranë, Albania',
          'Budapest',
        ),
        isTrue,
      );
    });

    test('Iasi/Brasov price paths conflict with Timisoara search', () {
      expect(
        exploreUrlConflictsWithSearchCity(
          'https://clinic.ro/preturi/iasi',
          'Timisoara',
        ),
        isTrue,
      );
      expect(
        exploreUrlConflictsWithSearchCity(
          'https://clinic.ro/preturi/brasov',
          'Timișoara',
        ),
        isTrue,
      );
      expect(
        exploreUrlConflictsWithSearchCity(
          'https://clinic.ro/preturi/timisoara',
          'Timisoara',
        ),
        isFalse,
      );
    });

    test('Dermal Fillers + Veeva clinical-trial host is rejected', () {
      expect(
        clinicIdentityRejectReason('Dermal Fillers'),
        'procedure_name_not_clinic',
      );
      expect(
        clinicIdentityRejectReason(
          'Clinical trial listing',
          websiteHost: 'ctv.veeva.com',
        ),
        'non_clinic_content_host',
      );
      expect(
        isUsableExploreClinicIdentity(
          name: 'Dermal Fillers',
          websiteHost: 'ctv.veeva.com/...clinical-trial...',
        ),
        isFalse,
      );
    });

    test(
      'Tirana breast SERP junk is rejected (Wolt/Merrjep/procedure titles)',
      () {
        expect(looksLikeNonClinicContentHost('wolt.com'), isTrue);
        expect(looksLikeNonClinicContentHost('merrjep.al'), isTrue);
        expect(looksLikeNonClinicContentHost('versus.al'), isTrue);
        expect(
          exploreSourceIsNewsReport(
            'https://versus.al/unpublished/zbardhen-pergjimet-e-operacionit-botoksi',
          ),
          isTrue,
        );
        expect(
          exploreListedPriceIsNonClinicContent(
            sourceUrl: 'https://example-clinic.al/prices',
            website: 'example-clinic.al',
          ),
          isFalse,
        );
        expect(isMarketplaceOrDirectoryHost('wolt.com'), isTrue);
        expect(
          looksLikeProcedureNameAsClinicIdentity('Breast Implants'),
          isTrue,
        );
        expect(
          looksLikeProcedureNameAsClinicIdentity('Procedures in Tirana'),
          isTrue,
        );
        expect(
          looksLikeProcedureNameAsClinicIdentity(
            'Breast prosthesis at Family Hospital partner of Albania Doctor',
          ),
          isTrue,
        );
        expect(
          looksLikeProcedureNameAsClinicIdentity(
            'Në shitje, Kërkohet, Me qera ...',
          ),
          isTrue,
        );
        expect(
          clinicIdentityRejectReason(
            'Farmaci Ristopharma Tiranë',
            websiteHost: 'wolt.com',
          ),
          'non_clinic_content_host',
        );
        expect(
          isUsableExploreClinicIdentity(
            name: 'DaVINCI Clinic',
            websiteHost: 'davinci.al',
          ),
          isTrue,
        );
      },
    );
  });
}
