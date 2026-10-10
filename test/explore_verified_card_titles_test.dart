import 'package:flutter_test/flutter_test.dart';

import '../lib/services/openai_service.dart';
import '../lib/services/explore_price_sanity.dart';
import '../lib/services/explore_price_verification.dart';
import '../lib/services/explore_search_locale.dart';
import '../lib/ui/clinic_compare_price_display.dart';

OpenAIClinic clinic({
  String name = 'Aster Medical Clinic',
  String procedure = 'Rhinoplasty',
  String canonical = 'rhinoplasty',
  String rawTitle = 'Rhinoplasty',
  String displayTitle = 'Rhinoplasty',
  double amount = 25000,
  String currency = 'AED',
  String city = 'Abu Dhabi',
}) => OpenAIClinic(
  rank: 0, name: name, area: '$city · aster.example', distanceMi: 0,
  rating: 0, reviews: 0, priceGbp: amount.round(), priceMin: amount,
  priceMax: amount, priceLabel: '$amount $currency', currency: currency,
  brand: procedure, badge: '', badgeVariant: 'mid', coord: const OpenAICoord(0, 0),
  priceSourceUrl: 'https://aster.example/prices/',
  priceEvidenceText: '$rawTitle | $amount $currency', rawProcedureText: rawTitle,
  rawPriceText: '$amount $currency', extractionMethod: 'html_table',
  sourceType: 'discovery_tool', procedureCanonical: canonical,
  procedureDisplayName: displayTitle, providerClinic: name,
  priceVerificationStatus: PriceVerificationStatus.officialWebsite,
  priceVerificationConfidence: 0.95, priceVerifiedAt: DateTime.utc(2026, 10, 6),
  priceExtractRevision: kExplorePriceExtractRevision, procedureRelation: 'exact',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('generic peel cache keeps the named peel from the priced row', () {
    final row = clinic(procedure: 'Chemical peel', canonical: 'chemical_peel',
        rawTitle: 'Light peels', displayTitle: 'Chemical Peel', amount: 300);
    expect(exploreCardProcedureLabel(row, selectedPill: 'Peels'), 'Light peels');
  });

  test('old generic peel with a range recovers the named tariff', () {
    final row = clinic(procedure: 'Chemical peel', canonical: 'chemical_peel',
        rawTitle: 'Chemical Peel', displayTitle: 'Chemical Peel', amount: 400).copyWith(
          priceEvidenceText: 'Light peels | AED 400 to AED 700');
    expect(exploreCardProcedureLabel(row, selectedPill: 'Peels'), 'Light peels');
  });

  test('a one ml syringe cannot acquire the neighbouring Botox per unit suffix', () {
    final row = clinic(procedure: 'Dermal filler', canonical: 'filler',
        rawTitle: 'Juvederm Ultra 3', displayTitle: 'Dermal Filler', amount: 1800).copyWith(
          rawPriceText: 'AED 1800', priceLabel: '1800 AED', priceType: 'perUnit', priceUnit: 'unit',
          priceEvidenceText: 'Juvederm Ultra 3: start from AED 1800 (1 mL syringe)');
    final label = clinicCompareProcedurePriceDisplay(row, procedure: 'Fillers');
    expect(label, contains('1 ml syringe'));
    expect(label, isNot(contains('/unit')));
  });

  test('price amount alone cannot mark a current hair tariff stale', () {
    expect(looksLikeHairStaleLandingQuote(
        sourceUrl: 'https://clinic.example/hair-transplant/',
        blob: 'Our hair transplant starts from 7000 AED', priceMin: 7000), isFalse);
    expect(looksLikeHairStaleLandingQuote(
        sourceUrl: 'https://clinic.example/hair-transplant/',
        blob: 'Hair transplant offer expired', priceMin: 7000), isTrue);
    expect(explorePillAiSearchQuery('Hair'), 'hair transplant');
  });

  test('editorial price guide cannot become a clinic tariff from old flags', () {
    final result = evaluateExtractedPriceCandidate(
        rawPriceText: '1500 AED', priceMin: 1500, currency: 'AED', extractionMethod: 'html_table',
        rawEvidence: 'Dermal filler 1500 AED', procedure: 'dermal filler',
        sourceUrl: 'https://beautyforqueens.com/abu-dhabi/dermal-fillers/', logRejects: false);
    expect(result.accepted, isFalse);
    expect(result.reason, 'directory_or_demo_price');
  });

  test('diamond peel does not fill a chemical peel comparison slot', () {
    final result = evaluateExtractedPriceCandidate(
        rawPriceText: '299 AED', priceMin: 299, currency: 'AED', extractionMethod: 'html_table',
        rawEvidence: 'Diamond peels: 299 AED', procedure: 'chemical peel',
        sourceUrl: 'https://clinic.example/peels/', logRejects: false);
    expect(result.accepted, isFalse);
  });

  test('every visible priced card has a nonempty price using the card formatter', () {
    final accepted = clinic();
    // A $1,500 published rhinoplasty fee is eligible. An unpriced lead has
    // no amount; do not rely on the obsolete $2,500 floor to remove it.
    final bad = clinic(name: 'Unpriced Lead', amount: 0, currency: 'USD');
    final shown = clinicsForCompareDisplay([accepted, bad], procedure: 'Rhinoplasty', city: 'Abu Dhabi');
    expect(shown.map((c) => c.name), ['Aster Medical Clinic']);
    expect(shown.every((c) => clinicCompareProcedurePriceDisplay(c,
        procedure: 'Rhinoplasty').isNotEmpty), isTrue);
  });

  test('a no-public-price marker cannot be revived by a stale numeric amount', () {
    final stale = clinic().copyWith(priceRejectionReason: 'no_public_price');
    expect(explorePriceIsVerified(stale), isFalse);
    expect(clinicsForCompareDisplay([stale], procedure: 'Rhinoplasty'), isEmpty);
  });

  test('English filler title preserves the source subtype and brand', () {
    final row = clinic(procedure: 'Dermal filler', canonical: 'filler',
        rawTitle: 'Mărire buze cu acid hialuronic Amalian', displayTitle: 'Dermal Filler',
        amount: 1497, currency: 'RON', city: 'Brașov');
    expect(exploreCardProcedureLabel(row, selectedPill: 'Fillers'),
        'Lip filler with hyaluronic acid Amalian');
  });

  test('published filler technique and dose remain attached to the card', () {
    final row = clinic(procedure: 'Dermal filler', canonical: 'filler',
        rawTitle: 'Russian Lip Filler 1 ml', displayTitle: 'Dermal Filler', amount: 1200);
    expect(exploreCardProcedureLabel(row, selectedPill: 'Fillers'), 'Russian Lip Filler 1 ml');
  });

  test('old generic cache rows recover the exact title from one priced tariff sentence', () {
    final row = clinic(procedure: 'Dermal filler', canonical: 'filler',
        rawTitle: 'Dermal Filler', displayTitle: 'Dermal Filler',
        amount: 1497, currency: 'RON', city: 'Brașov').copyWith(
          priceEvidenceText: 'Servicii în Brașov | Mărire buze cu acid hialuronic Amalian 1497 lei Cumpără');
    expect(exploreCardProcedureLabel(row, selectedPill: 'Fillers'),
        'Lip filler with hyaluronic acid Amalian');
  });

  test('tear-trough title is English while the source text stays unchanged', () {
    final row = clinic(procedure: 'Dermal filler', canonical: 'filler',
        rawTitle: 'Umplere cearcăne', displayTitle: 'Dermal Filler',
        amount: 1600, currency: 'RON', city: 'Brașov');
    expect(exploreCardProcedureLabel(row, selectedPill: 'Fillers'), 'Tear trough filler');
    final concatenated = clinic(procedure: 'Dermal filler', canonical: 'filler',
        rawTitle: 'Umplere cearcăne Injectare acid hialuronic',
        displayTitle: 'Umplere cearcăne Injectare acid hialuronic',
        amount: 1600, currency: 'RON', city: 'Brașov');
    expect(exploreCardProcedureLabel(concatenated, selectedPill: 'Fillers'),
        'Tear trough filler');
    expect(stripGenericFillerMethodSubtitle(
        'Umplere șanțuri nazo-geniene Injectare acid hialuronic (per ml)'),
        'Umplere șanțuri nazo-geniene Injectare acid hialuronic (per ml)');
  });

  test('intimate filler and intimate peels cannot occupy facial price slots', () {
    for (final canonical in ['filler', 'chemical_peel']) {
      final row = clinic(procedure: canonical == 'filler' ? 'Dermal filler' : 'Chemical peel',
          canonical: canonical, rawTitle: canonical == 'filler'
              ? 'Augmentarea zonei intime cu acid hialuronic 1 ml'
              : 'Peeling chimic zona intimă', amount: 1650, currency: 'RON', city: 'Brașov');
      expect(explorePriceIsVerified(row), isFalse);
    }
  });

  test('an Iran price remains foreign despite an Abu Dhabi area label', () {
    expect(exploreQuotedPriceDestinationConflicts(
        'The cost of rhinoplasty in Iran ranges from 1500 USD to 3500 USD.', 'Abu Dhabi'), isTrue);
    expect(exploreQuotedPriceDestinationConflicts(
        'Our rhinoplasty from 25000 AED; our surgeon trained in Iran.', 'Abu Dhabi'), isFalse);
  });
}
