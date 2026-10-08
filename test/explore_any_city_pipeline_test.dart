import 'package:flutter_test/flutter_test.dart';
import 'package:glowpass/services/explore_city_identity.dart';
import 'package:glowpass/services/explore_cold_start_session.dart';
import 'package:glowpass/services/explore_comparison_session.dart';
import 'package:glowpass/services/explore_google_price_store.dart';
import 'package:glowpass/services/explore_pipeline_config.dart';
import 'package:glowpass/services/explore_price_evidence.dart';
import 'package:glowpass/services/explore_price_sanity.dart';
import 'package:glowpass/services/explore_price_verification.dart';
import 'package:glowpass/services/explore_procedure_family.dart';
import 'package:glowpass/services/explore_procedure_relation.dart';
import 'package:glowpass/services/explore_search_locale.dart';
import 'package:glowpass/services/openai_service.dart';

OpenAIClinic _card(String name, {required String placeId, double price = 100}) {
  return OpenAIClinic(
    rank: 1,
    name: name,
    area: 'sofia.example · src:https://sofia.example/prices',
    distanceMi: 1,
    rating: 4.5,
    reviews: 20,
    priceGbp: price.round(),
    priceMin: price,
    priceMax: price,
    priceLabel: '${price.round()} EUR',
    currency: 'EUR',
    brand: 'Rhinoplasty',
    badge: '',
    badgeVariant: 'mid',
    coord: const OpenAICoord(42.6977, 23.3219),
    hasProcedure: true,
    pricePending: false,
    currencyConfirmed: true,
    priceSourceUrl: 'https://sofia.example/prices',
    priceEvidenceText: 'Rhinoplasty ${price.round()} EUR',
    priceVerificationStatus: PriceVerificationStatus.officialWebsite,
    rawProcedureText: 'Rhinoplasty',
    rawPriceText: '${price.round()} EUR',
    extractionMethod: 'html_table',
    sourceType: 'official_clinic',
    placeId: placeId,
    priceExtractRevision: kExplorePriceExtractRevision,
  );
}

void main() {
  group('CASE A — Sofia cold DB bootstrap', () {
    test('resolved BG identity targets 4 and bilingual discovery', () {
      final sofia = ExploreCityIdentity.resolve(
        rawCity: 'Sofia',
        countryCode: 'BG',
        countryName: 'Bulgaria',
        placeId: 'ChIJ_sofia_bg',
        latitude: 42.6977,
        longitude: 23.3219,
        languageCodes: const ['bg', 'en'],
      );
      expect(sofia.cityId, isNotEmpty);
      expect(sofia.countryCode, 'BG');

      expect(
        exploreCoverageNeedsDiscovery(
          status: ExploreCoverageStatus.unknown,
          verifiedVisibleCount: 0,
          coverageDocumentExists: false,
        ),
        isTrue,
      );

      final mix = planExplorePoolMix(0);
      expect(mix.firestoreShow, 0);
      expect(mix.googleLiveTarget, ExplorePipelineConfig.visibleTarget);
      expect(mix.googleLiveTarget, 4);

      final loc = exploreCityPriceSearchTerms(
        'Sofia',
        countryCode: sofia.countryCode,
      );
      expect(loc.lang, 'bg');
      expect(loc.priceWords, contains('цена'));

      final queries = exploreBilingualSearchPair(
        city: 'Sofia',
        procedure: 'Rhinoplasty',
        countryCode: sofia.countryCode,
      );
      expect(queries.length, greaterThanOrEqualTo(2));
      expect(
        queries.any((q) => q.contains('ринопластика')),
        isTrue,
        reason: queries.join(' | '),
      );
      expect(
        queries.any((q) => q.toLowerCase().contains('rhinoplasty')),
        isTrue,
        reason: queries.join(' | '),
      );
      expect(
        exploreGoogleGl(loc.lang, 'Sofia', countryCode: sofia.countryCode),
        'bg',
      );
    });
  });

  group('CASE B — Sofia with 1 verified continues toward 4', () {
    test(
      '1 verified → paint 1, live need 3, coverage still needs discovery',
      () {
        final mix = planExplorePoolMix(1);
        expect(mix.firestoreShow, 1);
        expect(mix.googleLiveTarget, 3);
        expect(mix.skipLiveGoogle, isFalse);
        expect(
          exploreCoverageNeedsDiscovery(
            status: ExploreCoverageStatus.partial,
            candidateCount: 20,
            verifiedVisibleCount: 1,
            coverageDocumentExists: true,
          ),
          isTrue,
        );
        expect(
          exploreCoverageNeedsDiscovery(
            status: ExploreCoverageStatus.complete,
            candidateCount: 40,
            verifiedVisibleCount: 1,
            coverageDocumentExists: true,
          ),
          isTrue,
        );
      },
    );
  });

  group('CASE C–F — Bulgarian procedure labels', () {
    test('химичен пилинг → peel', () {
      final m = matchRawProcedureLabel(
        'химичен пилинг',
        requestedProcedure: 'Peels',
      );
      expect(m.family, 'peel');
      expect(m.rejectReason == null || m.rejectReason!.isEmpty, isTrue);
      final r = classifyProcedureRelation(
        requestedProcedure: 'Peels',
        label: 'химичен пилинг',
        evidence: 'химичен пилинг 120 EUR',
        sourceUrl: 'https://clinic.bg/ceni',
      );
      expect(r.eligibleForFromPrice, isTrue, reason: r.reason);
    });

    test('ринопластика → rhinoplasty', () {
      final m = matchRawProcedureLabel(
        'ринопластика',
        requestedProcedure: 'Rhinoplasty',
      );
      expect(m.family, 'rhinoplasty');
      final r = classifyProcedureRelation(
        requestedProcedure: 'Rhinoplasty',
        label: 'ринопластика',
        evidence: 'ринопластика 2800 EUR',
        sourceUrl: 'https://clinic.bg/rhino',
      );
      expect(r.eligibleForFromPrice, isTrue, reason: r.reason);
    });

    test('уголемяване на бюст → breast augmentation', () {
      final m = matchRawProcedureLabel(
        'уголемяване на бюст',
        requestedProcedure: 'Breast augmentation',
      );
      expect(m.family, 'breast_augmentation');
      final r = classifyProcedureRelation(
        requestedProcedure: 'Breast augmentation',
        label: 'уголемяване на бюст',
        evidence: 'уголемяване на бюст 4500 EUR',
        sourceUrl: 'https://clinic.bg/breast',
      );
      expect(r.eligibleForFromPrice, isTrue, reason: r.reason);
    });

    test('трансплантация на коса → hair transplant', () {
      final m = matchRawProcedureLabel(
        'трансплантация на коса',
        requestedProcedure: 'Hair Transplant',
      );
      expect(m.family, 'hair_transplant');
      final r = classifyProcedureRelation(
        requestedProcedure: 'Hair Transplant',
        label: 'трансплантация на коса',
        evidence: 'трансплантация на коса 2500 EUR',
        sourceUrl: 'https://clinic.bg/hair',
      );
      expect(r.eligibleForFromPrice, isTrue, reason: r.reason);
    });
  });

  group('CASE G — same-name cities stay isolated', () {
    test('Paris FR vs Paris TX have distinct cityIds and store keys', () {
      final fr = ExploreCityIdentity.resolve(
        rawCity: 'Paris',
        countryCode: 'FR',
        placeId: 'ChIJ_paris_fr',
        latitude: 48.8566,
        longitude: 2.3522,
      );
      final tx = ExploreCityIdentity.resolve(
        rawCity: 'Paris',
        countryCode: 'US',
        adminArea: 'Texas',
        placeId: 'ChIJ_paris_tx',
        latitude: 33.6609,
        longitude: -95.5555,
      );
      expect(fr.cityId, isNot(tx.cityId));
      expect(ExploreCityIdentity.sameLocality(fr, tx), isFalse);

      final keyFr = ExploreGooglePriceStore.docId(
        city: 'Paris',
        procedure: 'Botox',
        cityId: fr.cityId,
      );
      final keyTx = ExploreGooglePriceStore.docId(
        city: 'Paris',
        procedure: 'Botox',
        cityId: tx.cityId,
      );
      expect(keyFr, isNot(keyTx));
    });
  });

  group('CASE H — unsupported language aliases still discover via EN + GL', () {
    test('Kenya city uses English discovery with gl=ke', () {
      final nairobi = ExploreCityIdentity.resolve(
        rawCity: 'Nairobi',
        countryCode: 'KE',
        latitude: -1.2921,
        longitude: 36.8219,
        placeId: 'ChIJ_nairobi',
      );
      final loc = exploreCityPriceSearchTerms(
        nairobi.displayName,
        countryCode: nairobi.countryCode,
      );
      expect(loc.lang, anyOf('en', 'sw'));
      final queries = exploreBilingualSearchPair(
        city: nairobi.displayName,
        procedure: 'Rhinoplasty',
        countryCode: nairobi.countryCode,
      );
      expect(
        queries.any((q) => q.toLowerCase().contains('rhinoplasty')),
        isTrue,
      );
      expect(
        exploreGoogleGl(
          loc.lang,
          nairobi.displayName,
          countryCode: nairobi.countryCode,
        ),
        'ke',
      );
      expect(
        exploreCoverageNeedsDiscovery(
          verifiedVisibleCount: 0,
          coverageDocumentExists: false,
        ),
        isTrue,
      );
    });
  });

  group('CASE I — literal foreign currency on official page', () {
    test('2800 EUR accepted in Sofia even when city default is BGN', () {
      const raw = 'Rhinoplasty 2800 EUR';
      final parsed = parsePriceText(raw);
      expect(parsed, isNotNull);
      expect(parsed!.priceMin, 2800);
      expect(parsed.currency.toUpperCase(), anyOf('EUR', '€'));

      final sanity = evaluateExtractedPriceCandidate(
        rawPriceText: raw,
        priceMin: 2800,
        currency: 'EUR',
        extractionMethod: 'html_table',
        procedure: 'rhinoplasty',
        rawEvidence: raw,
        sourceUrl: 'https://clinic.bg/ceni/rhino',
      );
      expect(sanity.accepted, isTrue, reason: sanity.reason);

      expect(exploreCurrencyFitsSearchCity('EUR', 'Sofia'), isTrue);
    });
  });

  group('CASE J — leaving UI does not cancel background discovery', () {
    test(
      'detach keeps backend; reattach loads stored verified cards',
      () async {
        final city = ExploreCityIdentity.resolve(
          rawCity: 'Sofia',
          countryCode: 'BG',
          placeId: 'ChIJ_sofia_bg2',
          latitude: 42.6977,
          longitude: 23.3219,
        );
        final session = ExploreColdStartSession(
          city: city,
          procedure: 'Rhinoplasty',
        );
        final paint = <int>[];
        final sub = session.uiResults.listen((list) => paint.add(list.length));

        final backend = session.runDiscovery(
          verifiedInOrder: [
            for (var i = 1; i <= 4; i++)
              _card('Sofia Clinic $i', placeId: 'sf$i', price: 2000.0 + i),
          ],
          stepDelay: const Duration(milliseconds: 4),
        );

        await Future<void>.delayed(const Duration(milliseconds: 10));
        session.detachUi();
        await backend;
        await session.whenBackendSettled;

        expect(session.backendCancelled, isFalse);
        expect(session.firestoreStore.length, 4);
        expect(paint, contains(1));

        final warm = session.reattachAndLoadStored();
        expect(warm.length, 4);

        await sub.cancel();
        await session.dispose();
      },
    );
  });
}
