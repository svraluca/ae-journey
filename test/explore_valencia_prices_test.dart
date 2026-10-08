import 'package:flutter_test/flutter_test.dart';

import '../lib/services/explore_clinic_identity.dart';
import '../lib/services/explore_compare_mix.dart';
import '../lib/services/explore_html_price_extractor.dart';
import '../lib/services/explore_price_binding.dart';
import '../lib/services/explore_price_ownership.dart';
import '../lib/services/explore_search_locale.dart';
import '../lib/ui/clinic_compare_price_display.dart';

void main() {
  test('root tariff guide is owned while market average stays excluded', () {
    expect(classifyExplorePricePageContext(
      sourceUrl: 'https://clinic.example/price-guide/',
      pageText: 'Rhinoplasty £7,995'), ExplorePricePageContext.officialPriceList);
    expect(classifyExplorePricePageContext(
      sourceUrl: 'https://clinic.example/price-guide/',
      pageText: 'On average Rhinoplasty costs £7,995.'), ExplorePricePageContext.marketAverage);
  });

  test('market average and consultation fee cannot be cached treatment prices', () {
    expect(exploreNonTreatmentPriceReason(evidence:
      'El precio promedio de un aumento de labios entre los 200 € y 400 €',
      priceMin: 200, currency: 'EUR'), isNotNull);
    expect(exploreNonTreatmentPriceReason(evidence:
      'Aesthetic Medicine Appointment 70€ (redeemable against any of the treatments)',
      priceMin: 70, currency: 'EUR'), isNotNull);
    expect(exploreNonTreatmentPriceReason(evidence: 'Lip filler 300€ (1 vial)',
      priceMin: 300, currency: 'EUR'), isNull);
  });

  test('pricing prose does not become the card treatment name', () {
    expect(looksLikePricingProseProcedureTitle('Aumento de labios: precio desde'), isTrue);
    expect(looksLikePricingProseProcedureTitle('Lip filler'), isFalse);
  });

  test('branch price overrides a local SEO URL', () {
    expect(exploreQuotedPriceConflictsWithSearchCity(city: 'Valencia',
      url: 'https://clinic.example/valencia',
      evidence: 'Precio del injerto capilar en Oviedo | Nuestro trasplante capilar entre 3090€ y 3690€'), isTrue);
    expect(exploreQuotedPriceConflictsWithSearchCity(city: 'Valencia',
      evidence: 'Precio del injerto capilar en Valencia | desde 3090€'), isFalse);
  });

  test('Booksy markup is compacted before truncating the service menu', () {
    final shell = List.filled(400, '<div class="${List.filled(600, 'x').join()}"></div>').join();
    final html = '<html><body>$shell'
      '<div data-testid="services-list-item-root"><h4 data-testid="service-name">Botox 3 zonas</h4>'
      '<span data-testid="service-variant-price">230,00 €+</span></div>'
      '<div data-testid="services-list-item-root"><h4 data-testid="service-name">Aumento labial</h4>'
      '<span data-testid="service-variant-price">260,00 €+</span></div></body></html>';
    final compact = explorePrepareHtmlForPriceParse(html);
    expect(compact, contains('Botox 3 zonas'));
    expect(compact, contains('Aumento labial'));
    expect(compact.length, lessThan(kExploreMaxHtmlParseChars));
  });

  test('background newcomers cannot add a fifth visible card', () {
    final rows = stabilizeExploreCompareRows<int>(shown: [1, 2, 3, 4],
      incoming: [4, 5, 6, 7, 8, 9], stillEligible: (_) => true,
      sameProvider: (a, b) => a == b);
    expect(rows, [1, 2, 3, 4]);
  });

  test('invalid and duplicate providers do not consume the four slots', () {
    final rows = stabilizeExploreCompareRows<int>(shown: [1, 2],
      incoming: [2, -1, 3, 4, 5], stillEligible: (row) => row > 0,
      sameProvider: (a, b) => a == b);
    expect(rows, [1, 2, 3, 4]);
  });

  test('pending and running searches cannot report a completed empty market', () {
    for (final status in ['pending', 'queued', 'running', 'searching',
      'discovering', 'verifying', 'in_progress', 'accepted']) {
      final message = exploreInsufficientDataMessage(
        'Valencia', procedure: 'Botox', coverageStatus: status,
      );
      expect(message, contains('Searching verified clinic prices in Valencia'));
      expect(message, isNot(contains('No verified')));
    }
  });

  test('an explicit lookup failure overrides stale pending coverage', () {
    for (final status in ['pending', 'running', 'failed']) {
      final message = exploreInsufficientDataMessage(
        'Valencia', procedure: 'Botox', coverageStatus: status,
        technicalFailure: true,
      );
      expect(message, contains('temporary lookup issue'));
      expect(message, isNot(contains('Searching')));
      expect(message, isNot(contains('No verified')));
    }
  });
}
