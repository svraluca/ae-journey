import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import '../lib/services/openai_service.dart';
import '../lib/services/explore_provider_location.dart';
import '../lib/services/explore_search_locale.dart';
import '../lib/services/explore_price_sanity.dart';
import '../lib/services/explore_price_ownership.dart';
import '../lib/ui/clinic_compare_price_display.dart';
import 'explore_verified_card_titles_test.dart' as fixture;

void main() {
  const url = 'https://us-uk.bookimed.com/clinic/aster-clinic/';
  final html = '<script type="application/ld+json">${jsonEncode({
    '@type': 'MedicalWebPage', 'url': url, 'mainEntity': {
      '@type': 'Hospital', 'url': url, 'address': {'addressLocality': 'Kuala Lumpur'}},
    'publisher': {'@type': 'Organization', 'address': {'addressLocality': 'Istanbul'}},
    'relatedLink': {'@type': 'Hospital', 'url': '$url/other/', 'address': {'addressLocality': 'Istanbul'}},
  })}</script><footer>Platform office Istanbul</footer>';
  test('provider geography outranks generated labels and platform offices', () {
    expect(exploreMarketplaceProviderLocations(html, url), ['Kuala Lumpur']);
    final context = exploreProviderLocationContext(html, url);
    expect(exploreMarketplaceLocationStronglyMatches(city: 'Istanbul',
      sourceUrl: url, placeAddress: 'Istanbul', pageText: 'Istanbul clinic',
      sourceLocationText: context), false);
    final card = fixture.clinic(city: 'Istanbul', currency: 'USD', amount: 72,
      rawTitle: 'Chemical peel', canonical: 'chemical_peel').copyWith(
        sourceLocationText: context, priceSourceUrl: url);
    expect(exploreClinicFitsSearchCity(card, 'Istanbul'), false);
    expect(exploreProviderLocationConflicts(context, 'Kuala Lumpur'), false);
  });
  test('unknown localities and diacritics use provider proof', () {
    expect(exploreProviderLocationConflicts('Provider locality: Chiang Mai', 'Istanbul'), true);
    expect(exploreProviderLocationConflicts('Provider locality: İstanbul', 'Istanbul'), false);
  });
  test('regional price labels cannot pass as exact official tariffs', () {
    final verdict = evaluateExtractedPriceCandidate(priceMin: 150, priceMax: 900,
      currency: 'EUR', rawPriceText: '€150–€900', procedure: 'Nose filler',
      rawEvidence: 'Nose filler | Turkey Price: ~€150 – €900 per area/syringe',
      sourceUrl: 'https://clinic.example/nose-filler/', extractionMethod: 'html_table',
      logRejects: false);
    expect(verdict.accepted, false);
    expect(verdict.reason, 'market_comparison_table');
  });
  test('price examples on a medical Q&A portal are not a provider tariff', () {
    final context = classifyExplorePricePageContext(
      sourceUrl: 'https://info.example/s-s-s/1-ml-dudak-dolgusu/',
      pageText: '1 ml dudak dolgusu fiyatlarının bazı örnekleri: Teosyal Kiss 8500–10500 TL',
    );
    expect(exploreEvidenceIsClinicOwnedPrice(pageContext: context,
      rawProcedureText: 'Teosyal Kiss', rawEvidence: 'Teosyal Kiss 8500–10500 TL',
      rawPriceText: '8500–10500 TL', extractionMethod: 'html_table'), false);
  });
  test('English card labels retain subtype, brand, dose and original evidence', () {
    const cases = [
      ('Dudak dolgusu Teosyal Kiss 1 ml', 'filler', 'Fillers', 'Lip filler Teosyal Kiss 1 ml'),
      ('Burun dolgusu', 'filler', 'Fillers', 'Nose filler'),
      ('Botoks', 'botox', 'Botox', 'Botox'),
      ('Kimyasal peeling', 'chemical_peel', 'Peels', 'Chemical peel'),
      ('Kapalı rinoplasti', 'rhinoplasty', 'Rhinoplasty', 'Closed rhinoplasty'),
      ('Meme büyütme', 'breast_augmentation', 'Boob job', 'Breast augmentation'),
      ('DHI saç ekimi 3000 grafts', 'hair_transplant', 'Hair', 'DHI Hair transplant 3000 grafts'),
      ('Teosyal Kiss 1 ml', 'filler', 'Fillers', 'Teosyal Kiss 1 ml'),
    ];
    for (final (source, canonical, pill, display) in cases) {
      final card = fixture.clinic(procedure: pill, canonical: canonical,
        rawTitle: source, displayTitle: source);
      expect(exploreCardProcedureLabel(card, selectedPill: pill), display, reason: source);
      expect(card.rawProcedureText, source);
      expect(card.priceEvidenceText, contains(source));
    }
  });
}
