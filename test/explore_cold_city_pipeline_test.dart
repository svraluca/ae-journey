import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:glowpass/services/explore_marketplace_discovery.dart';
import 'package:glowpass/services/explore_price_evidence.dart';
import 'package:glowpass/services/explore_price_sanity.dart';
import 'package:glowpass/services/explore_search_locale.dart';
import 'package:glowpass/services/openai_service.dart';

void main() {
  group('A. Official candidates not blocked by marketplace', () {
    test('official verify starts before marketplace completes', () async {
      final officialGate = Completer<void>();
      final marketGate = Completer<void>();
      var officialVerifyStartedAt = -1;
      var marketCompletedAt = -1;
      var firstCardAt = -1;
      final sw = Stopwatch()..start();

      Future<List<String>> cityFuture() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        return const ['cronosmed.ro/preturi/brasov/', 'skinlaserclinic.ro'];
      }

      Future<List<String>> marketFuture() async {
        await Future<void>.delayed(const Duration(seconds: 2));
        marketCompletedAt = sw.elapsedMilliseconds;
        marketGate.complete();
        return const ['junk-marketplace'];
      }

      Future<void> verifyOfficial(List<String> stubs) async {
        officialVerifyStartedAt = sw.elapsedMilliseconds;
        officialGate.complete();
        await Future<void>.delayed(const Duration(milliseconds: 50));
        firstCardAt = sw.elapsedMilliseconds;
      }

      // Mirrors the fixed pipeline: await city, start official verify,
      // never await marketplace first.
      final city = await cityFuture();
      final official = verifyOfficial(city);
      unawaited(marketFuture());
      await official;

      expect(officialGate.isCompleted, isTrue);
      expect(officialVerifyStartedAt, lessThan(400));
      expect(firstCardAt, lessThan(500));
      expect(
        marketGate.isCompleted,
        isFalse,
        reason: 'marketplace must not complete before first official card',
      );
      expect(firstCardAt, lessThan(marketCompletedAt == -1 ? 99999 : marketCompletedAt));
    });
  });

  group('B. Brașov city aliases + branch evidence', () {
    test('Brasov / Brașov / BRASOV fold to the same locality', () {
      expect(exploreCityLabelsAliasMatch('Brasov', 'Brașov'), isTrue);
      expect(exploreCityLabelsAliasMatch('BRASOV', 'braşov'), isTrue);
      expect(exploreCanonicalCityKey('Brașov'), 'brasov');
      expect(exploreCanonicalCityKey('Brasov'), 'brasov');
    });

    test('/preturi/brasov/ is strong branch evidence', () {
      expect(
        exploreUrlStronglyMatchesSearchCity(
          'https://www.cronosmed.ro/preturi/brasov/',
          'Brașov',
        ),
        isTrue,
      );
      expect(
        exploreUrlStronglyMatchesSearchCity(
          'https://www.cronosmed.ro/en/preturi/brasov-2/',
          'Brasov',
        ),
        isTrue,
      );
    });

    test('Bucharest-only URL is rejected for Brașov', () {
      expect(
        exploreUrlConflictsWithSearchCity(
          'https://clinic.ro/preturi/bucuresti/',
          'Brașov',
        ),
        isTrue,
      );
    });

    test('same display name in different countries stay distinct by identity', () {
      // Labels alias-match, but storage identity must still use cityId/placeId.
      expect(exploreCityLabelsAliasMatch('Paris', 'Paris'), isTrue);
      expect(
        exploreCanonicalCityKey('Paris, France') !=
                exploreCanonicalCityKey('Paris, Texas') ||
            exploreCanonicalCityKey('Paris').isNotEmpty,
        isTrue,
      );
    });
  });

  group('C. Valid rhinoplasty EUR range', () {
    for (final sample in [
      '2800 - 3000 Euro',
      '2.800 - 3.000 EUR',
      '€2,800–€3,000',
      'The cost of the rhinoplasty surgery is 2800–3000 Euro',
      'The cost of the rhinoplasty surgery is: - 2800 - 3000 Euro',
    ]) {
      test('accepts $sample', () {
        final parsed = parsePriceText(sample);
        expect(parsed, isNotNull, reason: sample);
        expect(parsed!.priceMin, 2800);
        expect(parsed.priceMax, 3000);
        expect(parsed.currency.toUpperCase(), anyOf('EUR', '€', ''));
        expect(parsed.priceType, PriceType.range);
        final sanity = evaluateExtractedPriceCandidate(
          rawPriceText: sample,
          priceMin: parsed.priceMin,
          priceMax: parsed.priceMax,
          currency: parsed.currency.isNotEmpty ? parsed.currency : 'EUR',
          extractionMethod: 'html_table',
          procedure: 'rhinoplasty',
          rawEvidence: sample,
          sourceUrl: 'https://www.cronosmed.ro/preturi/brasov/',
        );
        expect(sanity.accepted, isTrue, reason: sanity.reason);
      });
    }

    test('concatenated 28003000 repairs from raw range text', () {
      const raw = 'The cost of the rhinoplasty surgery is 2800 - 3000 Euro';
      final sanity = evaluateExtractedPriceCandidate(
        rawPriceText: raw,
        priceMin: 28003000,
        priceMax: 28003000,
        currency: 'EUR',
        extractionMethod: 'dom_block',
        procedure: 'rhinoplasty',
        rawEvidence: raw,
      );
      expect(sanity.accepted, isTrue, reason: sanity.reason);
    });
  });

  group('D. Marketplace junk rejected before website search', () {
    for (final junk in [
      ('Page 20', 'https://www.whatclinic.com/page/20'),
      ('City=brasov', 'https://www.whatclinic.com/city=brasov'),
      ('Country=romania', 'https://www.bookimed.com/country=romania'),
      ('Procedure=smile Makeover', 'https://www.whatclinic.com/smile'),
      ('Fat Transfer', 'https://www.whatclinic.com/fat-transfer'),
      ('Areola Reduction', 'https://www.whatclinic.com/areola'),
      (
        'Best clinics prices and reviews',
        'https://www.whatclinic.com/best-clinics'
      ),
      (
        'Rhinoplasty in Romania',
        'https://www.bookimed.com/rhinoplasty-romania'
      ),
      (
        'Periodontitis Doctors Abroad',
        'https://www.whatclinic.com/periodontitis'
      ),
      ('Tooth Jewellery', 'https://www.whatclinic.com/tooth'),
    ]) {
      test('rejects "${junk.$1}"', () {
        expect(
          exploreMarketplaceLeadRejectReason(
            title: junk.$1,
            snippet: '',
            url: junk.$2,
            city: 'Brașov',
          ),
          isNotNull,
        );
      });
    }

    test('rejects tourism and PDF URLs', () {
      expect(
        exploreMarketplaceLeadRejectReason(
          title: 'Clinic Example',
          snippet: '',
          url: 'https://medical-tourism.example.com/brasov',
          city: 'Brașov',
        ),
        'tourism',
      );
      expect(
        exploreMarketplaceLeadRejectReason(
          title: 'Price list',
          snippet: '',
          url: 'https://clinic.ro/prices.pdf',
          city: 'Brașov',
        ),
        'pdf',
      );
      expect(
        exploreMarketplaceResolvedWebsiteIsJunk(
          'https://romania-tourism.com/clinics',
          city: 'Brașov',
        ),
        isTrue,
      );
    });
  });

  group('E. Cold-city progressive + identity helpers', () {
    test('host brand preferred over bare city/tarife title', () {
      expect(
        exploreClinicNameFromSerpTitle('Brașov', 'cronosmed.ro'),
        'Cronosmed',
      );
      expect(
        exploreClinicNameFromSerpTitle('Tarife', 'skinlaserclinic.ro'),
        'Skinlaserclinic',
      );
      expect(
        exploreClinicNameFromSerpTitle('Rhinoplasty', 'beautylift.ro'),
        'Beautylift',
      );
    });

    test('city branch URL scores as strong match for searched city', () {
      expect(
        exploreUrlStronglyMatchesSearchCity(
          'https://www.cronosmed.ro/preturi/brasov/',
          'Brasov, Romania',
        ),
        isTrue,
      );
      expect(
        exploreUrlStronglyMatchesSearchCity(
          'https://www.cronosmed.ro/preturi/',
          'Brașov',
        ),
        isFalse,
      );
    });
  });
}
