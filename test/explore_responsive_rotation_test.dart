import 'dart:async';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../lib/services/explore_compare_mix.dart';
import '../lib/services/explore_city_identity.dart';
import '../lib/services/explore_provider_interfaces.dart';
import '../lib/services/session_prefs.dart';
import '../lib/services/explore_comparison_session.dart';
import '../lib/services/explore_price_discovery_tool.dart';
import '../lib/services/google_places_service.dart';
import '../lib/services/openai_service.dart';
import '../lib/ui/clinic_compare_price_display.dart';
import '../lib/ui/widgets/explore_clinic_loading.dart';
import 'explore_verified_card_titles_test.dart' as fixtures;

class _NoFirestore implements FirebaseFirestore {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected Firestore read');
}

class _ProbeCityResolver implements CityResolver {
  int calls = 0;
  @override
  Future<ExploreCityIdentity?> resolve({
    required String rawCity,
    String countryHint = '',
  }) async {
    calls++;
    return ExploreCityIdentity.resolve(
      rawCity: rawCity,
      countryCode: countryHint,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => dotenv.testLoad(fileInput: ''));

  test(
    'reselecting a resolved city reuses its place ID before any Places request',
    () async {
      SharedPreferences.setMockInitialValues({});
      final madrid = ExploreCityIdentity.resolve(
        rawCity: 'Madrid',
        countryCode: 'ES',
        placeId: 'madrid-place',
        latitude: 40.4,
        longitude: -3.7,
      );
      await SessionPrefs.setCompareSearchCityIdentity(madrid);
      final resolver = _ProbeCityResolver();
      final selected = await resolveExploreCitySelection(
        rawCity: 'Madrid',
        resolver: resolver,
      );
      expect(selected!.placeId, 'madrid-place');
      expect(resolver.calls, 0);
      await resolveExploreCitySelection(rawCity: 'Paris', resolver: resolver);
      expect(resolver.calls, 1);
    },
  );

  OpenAIClinic clinic(int i) => fixtures
      .clinic(
        name: 'Medical Clinic $i',
        city: 'Madrid',
        currency: 'EUR',
        amount: 350,
        procedure: 'Botox',
        canonical: 'botox',
        rawTitle: 'Botox 3 zones',
        displayTitle: 'Botox',
      )
      .copyWith(
        area: 'Madrid · medical-$i.example',
        priceSourceUrl: 'https://medical-$i.example/prices/',
        rating: 4.7,
        reviews: 120,
      );

  test(
    'rotation visits every eligible provider before repeating its exposure',
    () {
      final rotation = ExploreCompareRotation(random: Random(42));
      final visits = [
        for (var i = 0; i < 3; i++)
          rotation.select<int>(
            city: 'Madrid',
            procedure: 'Botox',
            eligible: List.generate(10, (i) => i),
            providerKey: (i) => '$i',
          ),
      ];
      expect(visits.every((rows) => rows.length == 4), true);
      expect(visits.expand((rows) => rows).toSet().length, 10);
      expect(visits[0].toSet().intersection(visits[1].toSet()), isEmpty);
    },
  );

  test(
    'sibling procedures prefer other clinics when enough eligible alternatives exist',
    () {
      final rotation = ExploreCompareRotation(random: Random(7));
      final pool = List.generate(8, (i) => i);
      final botox = rotation.select<int>(
        city: 'Madrid',
        procedure: 'Botox',
        eligible: pool,
        providerKey: (i) => '$i',
      );
      final fillers = rotation.select<int>(
        city: 'Madrid',
        procedure: 'Fillers',
        eligible: pool,
        providerKey: (i) => '$i',
      );
      expect(botox.toSet().intersection(fillers.toSet()), isEmpty);
      final limited = rotation.select<int>(
        city: 'Madrid',
        procedure: 'Hair',
        eligible: [1, 2],
        providerKey: (i) => '$i',
      );
      expect(limited.toSet(), {1, 2});
    },
  );

  test(
    'memory rotation retains the full pool and cannot perform network reads',
    () {
      final client = MockClient(
        (_) async => throw StateError('Unexpected HTTP'),
      );
      addTearDown(client.close);
      final service = OpenAIService(
        client: client,
        apiKey: '',
        placesApiKey: '',
        places: GooglePlacesService(client: client, apiKey: ''),
        firestore: _NoFirestore(),
      );
      final pool = [for (var i = 0; i < 8; i++) clinic(i)];
      final bad = clinic(9).copyWith(
        priceSourceUrl: 'https://www.elle.com/es/belleza/',
        area: 'Madrid · elle.com',
      );
      service.putCachedComparison(
        'rotation',
        OpenAIComparisonResult(
          city: 'Madrid',
          topic: 'Botox',
          topicType: OpenAISearchItemType.procedure,
          summary: '',
          rangeLabel: '',
          mapCenter: const OpenAICoord(40.4, -3.7),
          clinics: [...pool, bad],
        ),
      );
      final first = service.rotateCachedExploreComparison('rotation')!;
      final second = service.rotateCachedExploreComparison('rotation')!;
      expect(first.clinics, hasLength(4));
      expect(second.clinics, hasLength(4));
      expect(
        first.clinics
            .map((c) => c.name)
            .toSet()
            .intersection(second.clinics.map((c) => c.name).toSet()),
        isEmpty,
      );
      expect(
        second.clinics.every(
          (c) => c.rating == 4.7 && c.badge == 'Verified price',
        ),
        true,
      );
      expect(
        [...first.clinics, ...second.clinics].any((c) => c.name == bad.name),
        false,
      );
    },
  );

  test(
    'cache validation rejects wrong city and publisher without blocking the event loop',
    () async {
      final pool = [for (var i = 0; i < 40; i++) clinic(i)];
      final bad = clinic(41).copyWith(
        priceSourceUrl: 'https://www.elle.com/es/belleza/',
        area: 'Madrid · elle.com',
      );
      final foreign = clinic(42).copyWith(
        area: 'Paris · foreign.example',
        currency: 'EUR',
        priceEvidenceText: 'Our Botox 3 zones in Paris: 350 EUR',
        priceSourceUrl: 'https://foreign.example/paris/prices/',
      );
      var responded = false;
      Timer.run(() => responded = true);
      final cold = Stopwatch()..start();
      final accepted = await validateExploreSavedComparisonClinics(
        rows: [...pool, bad, foreign],
        city: 'Madrid',
        procedure: 'Botox',
      );
      cold.stop();
      expect(responded, true);
      expect(accepted, hasLength(40));
      expect(
        cold.elapsedMilliseconds,
        lessThan(4000),
        reason:
            'a 40-provider cache batch took over 30 seconds when validators recompiled patterns',
      );
      final sw = Stopwatch()..start();
      for (var frame = 0; frame < 100; frame++) {
        for (final row in accepted) {
          expect(
            exploreClinicEligibleForVerifiedPool(
              row,
              city: 'Madrid',
              procedure: 'Botox',
            ),
            true,
          );
        }
      }
      expect(
        sw.elapsedMilliseconds,
        lessThan(400),
        reason: '100 cached pool repaints must not repeat cold validation',
      );
      debugPrint(
        'CACHE_VALIDATION cold_ms=${cold.elapsedMilliseconds} '
        'cached_100_repaints_ms=${sw.elapsedMilliseconds}',
      );
    },
  );

  test('discovery worker preserves the same price safety checks', () async {
    ExploreDiscoveryToolRow row(String host, {String path = 'prices'}) =>
        ExploreDiscoveryToolRow(
          clinicName: 'Aster Medical Clinic',
          priceMin: 350,
          currency: 'EUR',
          sourceUrl: 'https://$host/$path/',
          rawProcedureText: 'Cosmetic Botox',
          rawEvidence: 'Our cosmetic Botox injections 350 EUR',
          rawPriceText: '350 EUR',
          clinicOwnPrice: true,
          cityMatch: true,
          sourceType: 'official_clinic',
          evidenceType: 'official_price_menu',
          procedureDisplayName: 'Botox',
          procedureCanonical: 'botox',
          qualifier: 'exact',
          origin: 'firestore',
          lastVerifiedAt: DateTime.now().toUtc(),
        );
    final validated = await validateExploreDiscoveryCompareRows(
      rows: [row('aster.example'), row('elle.com')],
      city: 'Madrid',
      procedure: 'botox',
      selection: 'Botox',
    );
    expect(validated.accepted, hasLength(1));
    expect(validated.accepted.single.priceMin, 350);
    expect(validated.rejectedUrls, contains('https://elle.com/prices/'));
    final ownedGuide = await validateExploreDiscoveryCompareRows(
      rows: [row('aster.example', path: 'price-guide')],
      city: 'Madrid',
      procedure: 'botox',
      selection: 'Botox',
    );
    expect(
      ownedGuide.accepted,
      hasLength(1),
      reason:
          'a clinic-owned tariff is validated by evidence rather than banned by its URL label',
    );
  });

  test(
    'follicular unit brackets stay attached to the published package price',
    () {
      final hair = fixtures
          .clinic(
            city: 'Madrid',
            currency: 'EUR',
            amount: 2900,
            procedure: 'Hair transplant',
            canonical: 'hair_transplant',
            rawTitle: 'Trasplante capilar FUE Zafiro < 1.000UF',
            displayTitle: 'Hair transplant',
          )
          .copyWith(rawPriceText: '2900€', priceType: 'exact');
      expect(
        clinicCompareProcedurePriceDisplay(hair, procedure: 'Hair transplant'),
        contains('/ < 1,000 grafts'),
      );
      final larger = hair.copyWith(
        rawProcedureText: 'Trasplante capilar FUE Zafiro 1.000-2.000UF',
        priceMin: 3400,
        priceMax: 3400,
        rawPriceText: '3400€',
        priceLabel: '3400 EUR',
        priceEvidenceText: 'Trasplante capilar FUE Zafiro 1.000-2.000UF 3400€',
      );
      expect(
        clinicCompareProcedurePriceDisplay(
          larger,
          procedure: 'Hair transplant',
        ),
        contains('/ 1,000–2,000 grafts'),
      );
      expect(
        clinicCompareProcedurePriceDisplay(clinic(1), procedure: 'Botox'),
        isNot(contains('grafts')),
      );
    },
  );

  testWidgets(
    'loading has one caption and animation does not rebuild its parent',
    (tester) async {
      var builds = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              builds++;
              return const Scaffold(body: ExploreClinicLoading(city: 'Madrid'));
            },
          ),
        ),
      );
      expect(find.text('Finding clinics in Madrid'), findsOneWidget);
      expect(
        find.text('Matching treatments with published prices'),
        findsOneWidget,
      );
      final before = builds;
      for (var i = 0; i < 10; i++)
        await tester.pump(const Duration(milliseconds: 16));
      expect(builds, before);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('loading respects reduced motion and settles', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: true),
          child: Scaffold(body: ExploreClinicLoading(city: 'Madrid')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, false);
    expect(find.text('Finding clinics in Madrid'), findsOneWidget);
  });
}
