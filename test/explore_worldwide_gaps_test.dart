import 'package:flutter_test/flutter_test.dart';
import 'package:glowpass/services/explore_city_identity.dart';
import 'package:glowpass/services/explore_cold_start_session.dart';
import 'package:glowpass/services/explore_html_price_extractor.dart';
import 'package:glowpass/services/explore_price_evidence.dart';
import 'package:glowpass/services/explore_price_sanity.dart';
import 'package:glowpass/services/explore_search_locale.dart';
import 'package:glowpass/services/openai_service.dart';
import 'package:glowpass/services/explore_price_verification.dart';
import 'package:glowpass/ui/clinic_compare_price_display.dart';

OpenAIClinic _card(String name, {required String placeId, double price = 100}) {
  return OpenAIClinic(
    rank: 1,
    name: name,
    area: 'clinic.example · src:https://clinic.example/prices',
    distanceMi: 1,
    rating: 0,
    reviews: 0,
    priceGbp: price.round(),
    priceMin: price,
    priceMax: price,
    priceLabel: '${price.round()} EUR',
    currency: 'EUR',
    brand: 'Lip filler',
    badge: '',
    badgeVariant: 'mid',
    coord: const OpenAICoord(45.75, 21.22),
    hasProcedure: true,
    pricePending: false,
    currencyConfirmed: true,
    priceSourceUrl: 'https://clinic.example/prices',
    priceEvidenceText: 'Lip filler ${price.round()} EUR',
    priceVerificationStatus: PriceVerificationStatus.officialWebsite,
    rawProcedureText: 'Lip filler',
    rawPriceText: '${price.round()} EUR',
    extractionMethod: 'html_table',
    sourceType: 'official_clinic',
    placeId: placeId,
  );
}

void main() {
  group('name-only identity forbidden', () {
    test('unresolved city without country/coords is not mergeable', () {
      final a = ExploreCityIdentity.resolve(rawCity: 'Paris');
      final b = ExploreCityIdentity.resolve(
        rawCity: 'Paris',
        countryCode: 'FR',
        latitude: 48.85,
        longitude: 2.35,
      );
      expect(a.needsLocationResolution, isTrue);
      expect(a.cityId, startsWith('unresolved_'));
      expect(ExploreCityIdentity.sameLocality(a, b), isFalse);
      expect(a.storageKey, isNot(equals('paris')));
      expect(a.storageKey, a.cityId);
    });

    test('Paris FR / Paris TX / Springfields collide-proof', () {
      final fr = ExploreCityIdentity.resolve(
        rawCity: 'Paris',
        countryCode: 'FR',
        adminArea: 'Île-de-France',
        latitude: 48.8566,
        longitude: 2.3522,
      );
      final tx = ExploreCityIdentity.resolve(
        rawCity: 'Paris',
        countryCode: 'US',
        adminArea: 'Texas',
        latitude: 33.6609,
        longitude: -95.5555,
      );
      final il = ExploreCityIdentity.resolve(
        rawCity: 'Springfield',
        countryCode: 'US',
        adminArea: 'Illinois',
        latitude: 39.7817,
        longitude: -89.6501,
      );
      final mo = ExploreCityIdentity.resolve(
        rawCity: 'Springfield',
        countryCode: 'US',
        adminArea: 'Missouri',
        latitude: 37.2090,
        longitude: -93.2923,
      );
      expect(fr.cityId, isNot(tx.cityId));
      expect(il.cityId, isNot(mo.cityId));
      expect(fr.isResolved, isTrue);
      expect(tx.isResolved, isTrue);
    });

    test('transliterated same-city aliases share resolved id via placeId', () {
      final a = ExploreCityIdentity.resolve(
        rawCity: 'München',
        countryCode: 'DE',
        placeId: 'ChIJ_munich',
        aliases: const ['Munich'],
      );
      final b = ExploreCityIdentity.resolve(
        rawCity: 'Munich',
        countryCode: 'DE',
        placeId: 'ChIJ_munich',
        aliases: const ['München'],
      );
      expect(a.cityId, b.cityId);
      expect(ExploreCityIdentity.sameLocality(a, b), isTrue);
    });
  });

  group('legacy geo gate', () {
    test('legacy London UK cannot feed London Ontario', () {
      final on = ExploreCityIdentity.resolve(
        rawCity: 'London',
        countryCode: 'CA',
        adminArea: 'Ontario',
        latitude: 42.98,
        longitude: -81.25,
      );
      expect(
        exploreLegacyRecordMatchesResolvedCity(
          resolved: on,
          legacyCountryCode: 'GB',
          legacyCity: 'London',
          legacyAddress: 'Harley Street, London',
          legacyLatitude: 51.52,
          legacyLongitude: -0.15,
        ),
        isFalse,
      );
    });

    test('legacy Paris FR cannot feed Paris Texas', () {
      final tx = ExploreCityIdentity.resolve(
        rawCity: 'Paris',
        countryCode: 'US',
        adminArea: 'Texas',
        latitude: 33.66,
        longitude: -95.55,
      );
      expect(
        exploreLegacyRecordMatchesResolvedCity(
          resolved: tx,
          legacyCountryCode: 'FR',
          legacyCity: 'Paris',
          legacyLatitude: 48.85,
          legacyLongitude: 2.35,
        ),
        isFalse,
      );
    });
  });

  group('Cronosmed Timisoara branch', () {
    const timisoaraUrl = 'https://www.cronosmed.ro/preturi/timisoara/';
    const iasiUrl = 'https://www.cronosmed.ro/preturi/iasi/';
    const brasovUrl = 'https://www.cronosmed.ro/preturi/brasov/';

    test('selects Timisoara page and rejects Iasi/Brasov paths', () {
      expect(exploreUrlConflictsWithSearchCity(iasiUrl, 'Timisoara'), isTrue);
      expect(exploreUrlConflictsWithSearchCity(brasovUrl, 'Timișoara'), isTrue);
      expect(
        exploreUrlConflictsWithSearchCity(timisoaraUrl, 'Timisoara'),
        isFalse,
      );
    });

    test('same-row Restylane 1700 RON exact; not Teosyal 1600 from other branch', () {
      const html = '''
      <table>
        <tr><td>Buze contur si volum – Teosyal RHA Kiss (0.7 ml)</td><td>1600 RON</td></tr>
        <tr><td>Buze contur si volum – Restylane (1 ml)</td><td>1700 RON</td></tr>
      </table>
      ''';
      final rows = extractPriceEvidence(
        html: html,
        sourceUrl: timisoaraUrl,
      );
      final restylane = rows.where((r) =>
          r.rawProcedureText.toLowerCase().contains('restylane') &&
          r.priceMin == 1700);
      expect(restylane, isNotEmpty);
      final picked = restylane.first;
      expect(picked.currency.toUpperCase(), 'RON');
      // "exact" in product language maps to PriceType.fixed (not from/range).
      expect(picked.priceType, PriceType.fixed);
      expect(picked.priceMin, picked.priceMax);
      expect(
        exploreUrlConflictsWithSearchCity(iasiUrl, 'Timisoara'),
        isTrue,
      );
    });

    test('exact price is not labelled from', () {
      final c = _card('Cronosmed', placeId: 'cronos_tm', price: 1700).copyWith(
        priceType: 'fixed',
        priceLabel: '1700 RON',
        rawPriceText: '1700 RON',
        priceEvidenceText: 'Buze contur si volum – Restylane (1 ml) 1700 RON',
        currency: 'RON',
      );
      expect(exploreClinicShowsExactPrice(c), isTrue);
      expect(c.priceLabel.toLowerCase().contains('from'), isFalse);
      expect(
        clinicCompareProcedurePriceDisplay(c, procedure: 'lip filler')
            .toLowerCase()
            .contains('from'),
        isFalse,
      );
    });

    test('1 ml package quantity is exact, not from /ml', () {
      final parsed = parsePriceText('Injectare acid hialuronic 1 ml: 1600 RON');
      expect(parsed?.priceType, PriceType.fixed);
      expect(parsed?.priceMin, 1600);
      expect(parsed?.unit, 'ml');

      final c = _card('Exact Fill', placeId: 'ef1', price: 1600).copyWith(
        priceType: 'fixed',
        priceLabel: '1600 RON',
        rawPriceText: '1600 RON',
        priceUnit: 'ml',
        priceQuantity: 1,
        priceEvidenceText: 'Injectare acid hialuronic 1 ml: 1600 RON',
        currency: 'RON',
      );
      final label = clinicCompareProcedurePriceDisplay(
        c,
        procedure: 'acid hialuronic',
      ).toLowerCase();
      expect(label.contains('from'), isFalse);
      expect(label.contains('/ml'), isFalse);
      expect(label.contains('1600'), isTrue);
    });

    test('Fillmed Lips 250 EUR is exact, not from', () {
      final parsed = parsePriceText('Fillmed Lips: 250 EUR');
      expect(parsed?.priceType, PriceType.fixed);
      expect(parsed?.priceMin, 250);
      final c = _card('Fillmed Clinic', placeId: 'fm1', price: 250).copyWith(
        priceType: 'fixed',
        priceLabel: '250 EUR',
        rawPriceText: '250 EUR',
        priceEvidenceText: 'Fillmed Lips: 250 EUR',
        currency: 'EUR',
        brand: 'Fillmed Lips',
        rawProcedureText: 'Fillmed Lips',
      );
      expect(exploreClinicShowsExactPrice(c), isTrue);
      expect(
        clinicCompareProcedurePriceDisplay(c, procedure: 'lip filler')
            .toLowerCase()
            .contains('from'),
        isFalse,
      );
    });

    test('raw=4 with one cross-city reject → 3 visible → discovery needed', () {
      const target = 4;
      final raw = [
        _card('A', placeId: 'a'),
        _card('B', placeId: 'b'),
        _card('C', placeId: 'c'),
        _card('Cronosmed', placeId: 'cronos_buc').copyWith(
          priceSourceUrl: 'https://cronosmed.ro/preturi/bucuresti',
          area: 'cronosmed.ro · src:https://cronosmed.ro/preturi/bucuresti',
        ),
      ];
      expect(raw.length, 4);
      final valid = [
        for (final c in raw)
          if (exploreClinicFitsSearchCity(c, 'Timisoara')) c,
      ];
      // Cronosmed București URL conflicts with Timișoara.
      expect(valid.length, lessThan(raw.length));
      expect(valid.length, 3);
      expect(valid.length >= target, isFalse);
      // Mirror backend poolHealthy gate.
      final poolHealthy = valid.length >= target;
      expect(poolHealthy, isFalse);
    });
  });

  group('progressive cold-city integration', () {
    test('zero cache → discovery → progressive UI → detach keeps backend', () async {
      final city = ExploreCityIdentity.resolve(
        rawCity: 'Nairobi',
        countryCode: 'KE',
        latitude: -1.2921,
        longitude: 36.8219,
      );
      final session = ExploreColdStartSession(
        city: city,
        procedure: 'lip filler',
      );
      expect(session.firestoreStore, isEmpty);

      final paint = <int>[];
      final sub = session.uiResults.listen((list) {
        paint.add(list.length);
      });

      final backend = session.runDiscovery(
        verifiedInOrder: [
          for (var i = 1; i <= 4; i++)
            _card('Clinic $i', placeId: 'p$i', price: 100.0 + i),
        ],
        stepDelay: const Duration(milliseconds: 5),
      );

      // Leave the screen after first paint.
      await Future<void>.delayed(const Duration(milliseconds: 12));
      session.detachUi();
      await backend;
      await session.whenBackendSettled;

      expect(session.discoveryStarted, isTrue);
      expect(session.backendCancelled, isFalse);
      expect(session.firestoreStore.length, 4);
      expect(paint.first, 1);
      expect(paint, contains(1));

      final warm = session.reattachAndLoadStored();
      expect(warm.length, 4);
      expect(warm.first.name, 'Clinic 1');

      await sub.cancel();
      await session.dispose();
    });
  });

  group('peer-city tariff paths', () {
    test('manchester and dubai paths are not the searched city', () {
      expect(
        exploreUrlConflictsWithSearchCity(
          'https://clinic.example/prices/manchester/',
          'London',
        ),
        isTrue,
      );
      expect(
        exploreUrlConflictsWithSearchCity(
          'https://clinic.example/prices/london/',
          'London',
        ),
        isFalse,
      );
      expect(
        exploreUrlConflictsWithSearchCity(
          'https://clinic.example/prices/dubai/',
          'Abu Dhabi',
        ),
        isTrue,
      );
      expect(
        exploreUrlConflictsWithSearchCity(
          'https://clinic.example/tr/istanbul/',
          'London',
        ),
        isTrue,
      );
      expect(
        exploreTextConflictsWithSearchCity(
          'Package available at Emirates Hospital Day Surgery – Motor City',
          'Abu Dhabi',
        ),
        isTrue,
      );
      expect(
        exploreTextConflictsWithSearchCity(
          'Botox Abu Dhabi start from 799 AED',
          'Abu Dhabi',
        ),
        isFalse,
      );
      expect(
        exploreUrlConflictsWithSearchCity(
          'https://www.enfieldabudhabi.ae/en/skincare-treatments/chemical-peel-in-al-ain/',
          'Abu Dhabi',
        ),
        isTrue,
      );
    });

    test('România in a Timișoara address is not Rome', () {
      const address =
          'Strada Samuil Micu 9, 300125 Timișoara, România';
      expect(
        explorePlacesAddressConflictsWithSearchCity(address, 'Timișoara'),
        isFalse,
      );
      expect(
        exploreUrlConflictsWithSearchCity(
          'https://hi-doctor.ai/fr/treatments/hair-transplant/romania',
          'Timișoara',
        ),
        isFalse,
      );
      expect(
        exploreUrlConflictsWithSearchCity(
          'https://clinic.example/preturi/iasi/',
          'Timișoara',
        ),
        isTrue,
      );
      expect(
        explorePlacesAddressConflictsWithSearchCity(
          'Via del Corso 1, Roma, Italia',
          'Timișoara',
        ),
        isTrue,
      );
    });

    test('generic peel row is kept and the kit row is not', () {
      const menu = 'Peeling chimic 850 lei Cosmelan + home kit 2600 lei';
      expect(
        explorePricedLineIsIncomparablePackage(
          procedure: 'chemical peel',
          evidence: menu,
          priceMin: 850,
        ),
        isFalse,
      );
      expect(
        explorePricedLineIsIncomparablePackage(
          procedure: 'chemical peel',
          evidence: menu,
          priceMin: 2600,
        ),
        isTrue,
      );
    });
  });
}
