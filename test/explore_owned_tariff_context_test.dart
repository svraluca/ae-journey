import 'package:flutter_test/flutter_test.dart';
import 'package:glowpass/services/explore_price_ownership.dart';
import 'package:glowpass/services/explore_price_sanity.dart';

void main() {
  test('dose averages beside a unit tariff do not become market prices', () {
    final context = classifyExplorePricePageContext(
      sourceUrl: 'https://miamiskinandvein.com/pricing/',
      pageText: 'BOTOX Cosmetic \$18 per unit. '
          'On average, 40-50 units of BOTOX are used to treat the upper face.',
    );
    expect(context, ExplorePricePageContext.officialPriceList);
  });

  test('an average dose with a monetary claim still blocks menu ownership', () {
    for (final claim in ['at a cost of \$500', 'at CAD 500', 'for 500 PEN']) {
      final context = classifyExplorePricePageContext(
        sourceUrl: 'https://clinic.example/pricing/',
        pageText: 'On average, 40-50 units are used $claim.',
      );
      expect(context, ExplorePricePageContext.marketAverage);
      expect(
        exploreEvidenceIsClinicOwnedPrice(
          pageContext: context,
          rawEvidence: 'Botox \$500',
          rawProcedureText: 'Botox',
        ),
        isFalse,
      );
    }
  });

  test('English prices endpoint is a price list while a city guide is blocked', () {
    expect(
      classifyExplorePricePageContext(
        sourceUrl: 'https://clinic.example/prices',
        pageText: 'Lip filler 350 EUR',
      ),
      ExplorePricePageContext.officialPriceList,
    );
    expect(
      classifyExplorePricePageContext(
        sourceUrl: 'https://clinic.example/prices-in-dubai/',
        pageText: 'Lip filler 350 EUR',
      ),
      ExplorePricePageContext.countryCostGuide,
    );
  });

  test('Arabic own offer is ownership evidence; an average statement is not', () {
    const offer = 'كل يوم إثنين استغلي عرضنا الحصري على البوتوكس بسعر 999 درهم';
    expect(looksLikeExplicitClinicOwnPriceLanguage(offer), isTrue);
    expect(
      classifyExplorePricePageContext(
        sourceUrl: 'https://mediclinic.ae/ar/special-offers/botox-mondays.html',
        pageText: offer,
      ),
      ExplorePricePageContext.officialServicePrice,
    );
    expect(
      looksLikeExplicitClinicOwnPriceLanguage('متوسط سعر البوتوكس 999 درهم'),
      isFalse,
    );
  });

  test('demo path check does not mistake a clinic hostname for a demo path', () {
    PriceSanityResult evaluate(String url) => evaluateExtractedPriceCandidate(
          rawPriceText: '1500 RON',
          priceMin: 1500,
          currency: 'RON',
          extractionMethod: 'html_table',
          rawEvidence: 'Botox 3 zones 1500 RON',
          procedure: 'Botox 3 zones',
          sourceUrl: url,
          logRejects: false,
        );
    expect(evaluate('https://example-clinic.ro/preturi/').accepted, isTrue);
    expect(
      evaluate('https://clinic.ro/demo-prices/').reason,
      'directory_or_demo_price',
    );
    expect(
      evaluate('https://clinic.ro/template/prices/').reason,
      'directory_or_demo_price',
    );
  });

  test('bound tariff table remains owned with a descriptive hair-loss label', () {
    PriceSanityResult evaluate(String context) => evaluateExtractedPriceCandidate(
          rawPriceText: '8 AED per graft',
          priceMin: 8,
          currency: 'AED',
          extractionMethod: 'html_table',
          rawEvidence: 'Receding hairline or mild-to-moderate hair loss. '
              '1,000 grafts 8 AED per graft',
          procedure: 'FUE Hair Transplant Cost in Dubai (Per Graft) · '
              'Receding hairline or mild-to-moderate hair loss.',
          sourceUrl: 'https://clinic.ae/fue/',
          pageContextWire: context,
          logRejects: false,
        );
    expect(evaluate('unknown').accepted, isTrue);
    expect(evaluate('country_cost_guide').reason, 'not_clinic_owned_price');
    expect(evaluate('market_average').reason, 'not_clinic_owned_price');
  });
}
