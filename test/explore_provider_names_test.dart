import 'package:flutter_test/flutter_test.dart';
import '../lib/services/explore_comparison_session.dart';
import '../lib/services/openai_service.dart';

import 'explore_verified_card_titles_test.dart' as fixtures;

OpenAIClinic provider(String name, {double rating = 4.9}) => fixtures
    .clinic(
      name: name,
      city: 'İstanbul',
      procedure: 'Botox',
      canonical: 'botox',
      rawTitle: 'Botoks',
      amount: 5000,
      currency: 'TRY',
    )
    .copyWith(
      area: 'İstanbul · drakinsahin.com',
      priceSourceUrl: 'https://drakinsahin.com/bonta/',
      rating: rating,
      reviews: rating > 0 ? 80 : 0,
    );

void main() {
  test('a packed doctor host does not invent a female title or surname', () {
    expect(exploreClinicBrandFromHost('drakinsahin.com'), 'Drakinsahin');
    expect(exploreClinicBrandFromHost('drazra.com'), 'Drazra');
    expect(
      exploreClinicBrandFromHost('dr-alice-smith.example'),
      'Dr Alice Smith',
    );
  });

  test('official Turkish provider name survives rendering unchanged', () {
    final source = provider('Op. Dr. Akın Şahin');
    expect(exploreClinicDisplayName(source), source.name);
    expect(exploreClinicNameNeedsMapsRefresh(source), isFalse);
    expect(exploreClinicNameNeedsMapsRefresh(provider('Dra Kinsahin')), isTrue);
  });

  test('verified website identity replaces a synthetic cached name', () {
    expect(
      exploreClinicNameFromVerifiedMaps(
        sourceName: 'Dra Kinsahin',
        mapsName: 'Op. Dr. Akın Şahin',
        sourceHost: 'drakinsahin.com',
        mapsHost: 'www.drakinsahin.com',
      ),
      'Op. Dr. Akın Şahin',
    );
    // A provider can change its brand without changing its verified website.
    expect(
      exploreClinicNameFromVerifiedMaps(
        sourceName: 'Oldbrand',
        mapsName: 'Aurora Medical Clinic',
        sourceHost: 'oldbrand.example',
        mapsHost: 'www.oldbrand.example',
      ),
      'Aurora Medical Clinic',
    );
  });

  test('another website and SEO titles do not overwrite provider identity', () {
    expect(
      exploreClinicNameFromVerifiedMaps(
        sourceName: 'Dra Kinsahin',
        mapsName: 'Dr. Ethem Şahin',
        sourceHost: 'drakinsahin.com',
        mapsHost: 'drethemsahin.com',
      ),
      'Dra Kinsahin',
    );
    expect(
      exploreClinicNameFromVerifiedMaps(
        sourceName: 'Aurora Clinic',
        mapsName: 'Botox prices 2026',
        sourceHost: 'aurora.example',
        mapsHost: 'aurora.example',
      ),
      'Aurora Clinic',
    );
  });

  test('name repair applies when rating and verified fee are unchanged', () {
    final old = provider('Dra Kinsahin');
    final corrected = provider('Op. Dr. Akın Şahin');
    final repaired = overlayExploreClinicRatings(
      shown: [old],
      enriched: [corrected],
    );
    expect(repaired.single.name, corrected.name);
    expect(repaired.single.priceMin, old.priceMin);
    expect(repaired.single.priceEvidenceText, old.priceEvidenceText);
    expect(repaired.single.priceSourceUrl, old.priceSourceUrl);
    expect(repaired.single.rating, old.rating);
  });

  test('website name repair does not depend on a Google rating', () {
    final old = provider('Dra Kinsahin');
    final corrected = provider('Op. Dr. Akın Şahin', rating: 0);
    final repaired = overlayExploreClinicRatings(
      shown: [old],
      enriched: [corrected],
    );
    expect(repaired.single.name, corrected.name);
    expect(repaired.single.rating, old.rating);
    expect(repaired.single.reviews, old.reviews);
    expect(repaired.single.priceMin, old.priceMin);
  });

  test('late host fallback cannot regress a corrected public name', () {
    final corrected = provider('Op. Dr. Akın Şahin');
    final stale = provider('Dra Kinsahin');
    expect(
      overlayExploreClinicRatings(
        shown: [corrected],
        enriched: [stale],
      ).single.name,
      corrected.name,
    );
    expect(mergeExploreClinicRecord(corrected, stale).name, corrected.name);
  });
}
