import 'package:flutter_test/flutter_test.dart';

import '../lib/services/explore_clinic_identity.dart';
import '../lib/services/explore_compare_mix.dart';
import '../lib/services/explore_html_price_extractor.dart';
import '../lib/services/explore_price_binding.dart';
import '../lib/services/explore_search_locale.dart';

void main() {
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

  test('new eligible cards can fill slots five through eight', () {
    final rows = stabilizeExploreCompareRows<int>(shown: [1, 2, 3, 4],
      incoming: [4, 5, 6, 7, 8, 9], stillEligible: (_) => true,
      sameProvider: (a, b) => a == b);
    expect(rows, [1, 2, 3, 4, 5, 6, 7, 8]);
  });
}
