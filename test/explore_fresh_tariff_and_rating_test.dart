import 'package:flutter_test/flutter_test.dart';

import '../lib/services/explore_compare_mix.dart';
import '../lib/services/explore_clinic_identity.dart';
import '../lib/services/explore_comparison_session.dart';
import '../lib/services/explore_search_locale.dart';
import '../lib/services/openai_service.dart';
import '../lib/ui/clinic_compare_price_display.dart';
import '../lib/ui/map_price_pin_bitmap.dart';
import 'explore_verified_card_titles_test.dart' as fixtures;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a newer verified tariff updates its slot even when all four are filled', () {
    final old = fixtures.clinic(city: 'Madrid', currency: 'EUR', amount: 4599)
        .copyWith(priceType: 'from', priceVerifiedAt: DateTime.utc(2026, 10, 1));
    final fresh = old.copyWith(priceMin: 4100, priceMax: 4100,
        rawPriceText: 'from 4100 EUR', priceEvidenceText: 'Our Rhinoplasty starts from 4100 EUR',
        priceVerifiedAt: DateTime.utc(2026, 10, 9));
    final shown = [old, for (var i = 0; i < 3; i++) fixtures.clinic(
        name: 'Other Clinic $i', city: 'Madrid', currency: 'EUR', amount: 5000 + i.toDouble())
        .copyWith(area: 'Madrid · other-$i.example', priceSourceUrl: 'https://other-$i.example/prices/')];
    final result = stabilizeExploreCompareRows<OpenAIClinic>(shown: shown,
        incoming: [fresh], stillEligible: explorePriceIsVerified,
        sameProvider: exploreClinicsAreSameProvider, preferIncoming: exploreVerifiedTariffSupersedes);
    expect(result.map((c) => c.name), shown.map((c) => c.name));
    expect(result.first.priceMin, 4100);
    expect(clinicCompareProcedurePriceDisplay(result.first).replaceAll(',', ''), contains('4100'));
    expect(mapPricePinShortLabel(result.first), contains('4100'));
    expect(exploreVerifiedTariffSupersedes(fresh, old), false);
    expect(exploreVerifiedTariffSupersedes(old, fresh.copyWith(pricePending: true)), false);
  });

  test('euro suffixes retain the area of a single scoped Botox tariff', () {
    final row = fixtures.clinic(city: 'Madrid', currency: 'EUR', amount: 190,
        procedure: 'Botox', canonical: 'botox', rawTitle: 'Botox', displayTitle: 'Botox')
        .copyWith(priceType: 'exact', rawPriceText: '190€', priceEvidenceText: 'Bótox 1 zona: 190€');
    expect(exploreCardProcedureLabel(row, selectedPill: 'Botox'), contains('1 zona'));
    expect(clinicCompareProcedurePriceDisplay(row, procedure: 'Botox'), '190€');
    final ambiguous = row.copyWith(priceEvidenceText: 'Bótox 1 zona 190€ Bótox 3 zonas 350€');
    expect(exploreCardProcedureLabel(ambiguous, selectedPill: 'Botox'), 'Botox');
  });

  test('a promotion remains an offer on both the card and map', () {
    final row = fixtures.clinic(city: 'Madrid', currency: 'EUR', amount: 299,
        procedure: 'Botox', canonical: 'botox', rawTitle: 'Botox')
        .copyWith(priceType: 'sale', rawPriceText: '299 EUR',
            priceEvidenceText: 'Botox promoción desde 299 EUR');
    expect(clinicCompareProcedurePriceDisplay(row), 'offer from 299 EUR');
    expect(mapPricePinShortLabel(row), startsWith('offer from '));
  });

  test('city-named streets do not reject the correct Maps locality', () {
    expect(exploreMarketplaceLocationStronglyMatches(city: 'Madrid',
        placeAddress: 'C. de Murcia, 4, Arganzuela, 28045 Madrid, España'), true);
    expect(exploreMarketplaceLocationStronglyMatches(city: 'Madrid',
        placeAddress: 'Calle Madrid, 8, 30001 Murcia, España'), false);
    expect(exploreMarketplaceLocationStronglyMatches(city: 'Dubai',
        placeAddress: '10 London Road, Dubai, United Arab Emirates'), true);
    expect(exploreMarketplaceLocationStronglyMatches(city: 'London',
        placeAddress: '10 London Road, Dubai, United Arab Emirates'), false);
  });

  test('verified flags cannot turn a publisher or editorial guide into a clinic fee', () {
    expect(exploreSourceIsNewsReport('https://clinic.example/price-guide/'), false);
    for (final url in ['https://www.elle.com/es/belleza/a123456/aumento-pecho/',
      'https://clinic.example/precios-cirugia-plastica-madrid-guia-doctor/']) {
      final row = fixtures.clinic(city: 'Madrid', currency: 'EUR', amount: 8000)
          .copyWith(priceSourceUrl: url, area: 'Madrid · ${Uri.parse(url).host}');
      expect(explorePriceIsVerified(row), false);
      expect(clinicsForCompareDisplay([row], city: 'Madrid', procedure: 'Rhinoplasty'), isEmpty);
    }
  });
}
