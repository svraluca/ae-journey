import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';

import '../lib/services/explore_price_discovery_tool.dart';
import '../lib/services/explore_price_evidence.dart';
import '../lib/services/explore_price_sanity.dart';
import '../lib/services/google_places_service.dart';
import '../lib/services/openai_service.dart';
import '../lib/ui/clinic_compare_price_display.dart';
import '../lib/ui/map_price_pin_bitmap.dart';
import 'explore_verified_card_titles_test.dart' as fixtures;

class _UnexpectedFirestore implements FirebaseFirestore {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('A verified tab return must not read Firestore');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => dotenv.testLoad(fileInput: ''));

  OpenAIService offlineService() {
    final client = MockClient(
      (_) async => throw StateError('A verified tab return must not call HTTP'),
    );
    addTearDown(client.close);
    return OpenAIService(
      client: client,
      apiKey: '',
      placesApiKey: '',
      places: GooglePlacesService(client: client, apiKey: ''),
      firestore: _UnexpectedFirestore(),
    );
  }

  OpenAIComparisonResult comparison(List<OpenAIClinic> clinics) =>
      OpenAIComparisonResult(
        city: 'Madrid',
        topic: 'Botox',
        topicType: OpenAISearchItemType.procedure,
        summary: '',
        rangeLabel: '',
        mapCenter: const OpenAICoord(40.4, -3.7),
        clinics: clinics,
      );

  test('worker snapshot refresh updates a full saved display and keeps its Maps score', () {
    final service = offlineService();
    final old = fixtures.clinic(name: 'Aster Medical Clinic', city: 'Madrid',
        procedure: 'Botox', canonical: 'botox', rawTitle: 'Botox 3 zones',
        amount: 350, currency: 'EUR').copyWith(
          priceVerifiedAt: DateTime.utc(2026, 10, 1),
          rating: 4.8, reviews: 100, placeId: 'aster-place');
    final previous = comparison([old, for (var i = 0; i < 3; i++)
      fixtures.clinic(name: 'Other Clinic $i', city: 'Madrid', procedure: 'Botox',
          canonical: 'botox', rawTitle: 'Botox 3 zones', amount: 400 + i.toDouble(),
          currency: 'EUR').copyWith(area: 'Madrid · other-$i.example',
            priceSourceUrl: 'https://other-$i.example/prices/')]);
    for (final origin in ['live_search', 'firestore']) {
      final refreshed = service.comparisonWithDiscoveryRows(city: 'Madrid',
          procedure: 'Botox', previous: previous, rows: [ExploreDiscoveryToolRow(
            clinicName: old.name, priceMin: 299, currency: 'EUR',
            sourceUrl: old.priceSourceUrl, rawProcedureText: 'Botox 3 zones',
            rawEvidence: 'Botox 3 zones | 299 EUR', rawPriceText: '299 EUR',
            clinicOwnPrice: true, cityMatch: true, sourceType: 'official_clinic',
            evidenceType: 'official_price_menu', procedureDisplayName: 'Botox 3 zones',
            qualifier: 'promo', procedureCanonical: 'botox', origin: origin,
            lastVerifiedAt: DateTime.utc(2026, 10, 9),
          )]);
      expect(refreshed.clinics.map((c) => c.name), previous.clinics.map((c) => c.name));
      expect(refreshed.clinics.first.priceMin, 299, reason: origin);
      expect(refreshed.clinics.first.rating, 4.8);
      expect(refreshed.clinics.first.reviews, 100);
      expect(refreshed.clinics.first.placeId, 'aster-place');
      expect(refreshed.clinics.first.priceType, 'sale');
    }
  });

  test(
    'returning between full verified tabs uses their snapshots without I/O',
    () async {
      final service = offlineService();
      for (final pill in ['Botox', 'Fillers']) {
        final clinics = [
          for (var i = 0; i < 4; i++)
            fixtures
                .clinic(
                  name: '$pill Clinic $i',
                  city: 'Madrid',
                  procedure: pill == 'Botox' ? 'Botox' : 'Dermal filler',
                  canonical: pill == 'Botox' ? 'botox' : 'filler',
                  rawTitle: pill == 'Botox'
                      ? 'Botox 3 zones'
                      : 'Lip filler 1 ml',
                  amount: 300 + i.toDouble(),
                  currency: 'EUR',
                )
                .copyWith(
                  area: 'Madrid · clinic-$pill-$i.example',
                  priceSourceUrl: 'https://clinic-$pill-$i.example/prices/',
                ),
        ];
        service.putCachedComparison(
          'comparison|$kExploreComparisonCacheRevision|$pill|Madrid|procedure',
          comparison(clinics),
        );
      }
      final watch = Stopwatch()..start();
      for (final pill in ['Botox', 'Fillers', 'Botox']) {
        final result = await service.buildComparison(
          queryOrSelection: pill,
          city: 'Madrid',
          mode: 'procedure',
          categoryPill: pill,
        );
        expect(result.clinics.map((c) => c.name), [
          for (var i = 0; i < 4; i++) '$pill Clinic $i',
        ]);
        expect(result.clinics.map((c) => c.priceMin), [300, 301, 302, 303]);
      }
      // Report a measurement without imposing a machine-sensitive frame budget.
      // The mocks above assert the absence of both expensive I/O paths.
      print('Three verified tab restores: ${watch.elapsedMilliseconds}ms');
      final previous = service.getCachedComparison(
        'comparison|$kExploreComparisonCacheRevision|Botox|Madrid|procedure',
      )!;
      final replacement = previous.copyWith(
        clinics: [
          for (final c in previous.clinics)
            c.copyWith(
              priceMin: 400,
              priceMax: 400,
              rawPriceText: '400 EUR',
              priceEvidenceText: 'Botox 3 zones | 400 EUR',
            ),
        ],
      );
      service.putCachedComparison(
        'comparison|$kExploreComparisonCacheRevision|Botox|Madrid|procedure',
        replacement,
      );
      final updated = await service.buildComparison(
        queryOrSelection: 'Botox',
        city: 'Madrid',
        mode: 'procedure',
        categoryPill: 'Botox',
      );
      expect(
        updated.clinics.map((c) => c.priceMin),
        everyElement(400),
        reason: 'a replaced snapshot must invalidate the eligibility memo',
      );
    },
  );

  test(
    'rating backfill without Places configuration performs no I/O',
    () async {
      final service = offlineService();
      final base = comparison([fixtures.clinic(city: 'Madrid')]);
      expect(
        service.hasRetryableUnratedClinics(
          clinics: base.clinics,
          city: 'Madrid',
        ),
        false,
      );
      final result = await service.backfillMissingClinicRatings(
        base: base,
        city: 'Madrid',
        procedure: 'Rhinoplasty',
        pill: 'Rhinoplasty',
      );
      expect(identical(result, base), true);
    },
  );

  test(
    'approximate source quotes retain uncertainty and both range bounds',
    () {
      expect(PriceType.fromWire('approximate'), PriceType.approximate);
      for (final text in [
        'Botox suele rondar los 300€',
        'Botox approximately EUR 300',
      ]) {
        final parsed = parsePriceText(text);
        expect(parsed?.priceMin, 300);
        expect(parsed?.priceType, PriceType.approximate);
      }
      final range = parsePriceText(
        'Rhinoplasty aproximadamente entre 10000–20000 EUR',
      );
      expect(range?.priceMin, 10000);
      expect(range?.priceMax, 20000);
      expect(range?.priceType, PriceType.approximate);
      expect(
        parsePriceText('Botox approximately 20 minutes | 300 EUR')?.priceType,
        isNot(PriceType.approximate),
      );
    },
  );

  test('Python approximate qualifier reaches the card and map intact', () {
    final service = offlineService();
    final result = service.comparisonWithDiscoveryRows(
      city: 'Madrid',
      procedure: 'Botox',
      rows: [
        ExploreDiscoveryToolRow(
          clinicName: 'Olmo Test Clinic',
          priceMin: 300,
          currency: 'EUR',
          sourceUrl: 'https://olmo-test.example/neuromoduladores/',
          rawProcedureText: 'Neuromoduladores',
          rawEvidence:
              'Neuromoduladores: depende del número de viales, suele rondar los 300€',
          rawPriceText: 'suele rondar los 300€',
          clinicOwnPrice: true,
          cityMatch: true,
          sourceType: 'official_clinic',
          evidenceType: 'rendered_html',
          procedureDisplayName: 'Neuromoduladores',
          procedureCanonical: 'botox',
          qualifier: 'approximate',
          lastVerifiedAt: DateTime.utc(2026, 10, 8),
        ),
      ],
    );
    expect(result.clinics, hasLength(1));
    final clinic = result.clinics.single;
    expect(clinic.priceType, 'approximate');
    expect(
      clinicCompareProcedurePriceDisplay(clinic, procedure: 'Botox'),
      allOf(startsWith('approx. '), contains('300'), isNot(contains('from'))),
    );
    expect(mapPricePinShortLabel(clinic), startsWith('approx. '));

    final range = fixtures
        .clinic(city: 'Madrid', currency: 'EUR', amount: 10000)
        .copyWith(
          priceMax: 20000,
          priceType: 'approximate',
          rawPriceText: 'approximately 10000–20000 EUR',
          priceEvidenceText:
              'Our clinic charges approximately 10000–20000 EUR for rhinoplasty',
        );
    expect(
      clinicCompareProcedurePriceDisplay(range, procedure: 'Rhinoplasty'),
      allOf(startsWith('approx. '), contains('10,000'), contains('20,000')),
    );
  });
}
