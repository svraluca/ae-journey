import 'package:flutter_test/flutter_test.dart';
import 'package:glowpass/services/explore_comparison_session.dart';
import 'package:glowpass/services/explore_html_price_extractor.dart';
import 'package:glowpass/services/explore_price_evidence.dart';
import 'package:glowpass/services/explore_price_sanity.dart';
import 'package:glowpass/services/explore_procedure_family.dart';
import 'package:glowpass/services/explore_procedure_relation.dart';
import 'package:glowpass/services/openai_service.dart';
import 'package:glowpass/ui/clinic_compare_price_display.dart';

const _page =
    'Wrinkle relaxers are priced per unit — Dysport and Xeomin start at \$13 per unit, '
    'with the exact total depending on the areas treated and the dose your plan calls for.';
const _url = 'https://www.miamiskinspa.com/botox';
const _procedure = 'Botox anti-wrinkle injection';

Map<String, Object?> _trustedBotoxJson({
  String extractRevision = kExplorePriceExtractRevision,
  String rawProcedure = 'Dysport and Xeomin',
  String sourceUrl = _url,
  double price = 13,
  String currency = 'USD',
}) {
  return {
    'name': 'Miami Skin Spa',
    'rank': 1,
    'area': 'miamiskinspa.com · src:$sourceUrl',
    'rating': 4.8,
    'reviews': 200,
    'price_min': price,
    'price_max': price,
    'price_gbp': price.round(),
    'price_label': 'from ${price.round()} USD',
    'currency': currency,
    'currency_confirmed': true,
    'brand': rawProcedure,
    'has_procedure': true,
    'price_pending': false,
    'price_source_url': sourceUrl,
    'price_evidence_text': _page,
    'price_verification_status': 'official_website',
    'raw_procedure_text': rawProcedure,
    'raw_price_text': '\$13 per unit',
    'extraction_method': 'dom_block',
    'price_type': 'perUnit',
    'price_unit': 'unit',
    'source_type': 'official_clinic',
    'procedure_family': 'botox',
    'procedure_relation': 'variant',
    'place_id': 'ChIJMiamiSkinSpa',
    'price_extract_revision': extractRevision,
    'verified': true,
    'price_verified': true,
    'lat': 25.76,
    'lng': -80.19,
  };
}

void main() {
  // Pinned on purpose: bumping the revision invalidates every cached price,
  // so the bump has to be a deliberate edit here too.
  // e18: exact prices stay exact (no auto /ml from "1 ml"); cross-city cache purge.
  test('extract revision is e18', () {
    expect(kExplorePriceExtractRevision, 'e18');
  });

  test('Miami Skin Spa paragraph extracts as 13 USD perUnit variant', () {
    final parsed = parsePriceText(_page);
    expect(parsed?.priceMin, 13);
    expect(parsed?.currency, 'USD');
    expect(parsed?.priceType, PriceType.perUnit);

    final rows = extractPriceEvidence(
      html: '<div class="treatment"><p>$_page</p></div>',
      sourceUrl: _url,
    );
    expect(rows, isNotEmpty);
    final picked = selectEvidenceForProcedure(
      rows: rows,
      procedure: _procedure,
    );
    expect(picked, isNotNull);
    expect(picked!.priceMin, 13);
    expect(picked.currency, 'USD');
    expect(picked.priceType, PriceType.perUnit);
    expect(picked.procedureFamily, 'botox');

    final relation = classifyProcedureRelation(
      requestedProcedure: _procedure,
      label: picked.rawProcedureText,
      evidence: picked.rawEvidence,
      sourceUrl: _url,
      clinicOwnQuoted: true,
    );
    expect(relation.eligibleForFromPrice, isTrue);
    expect(relation.logToken, 'variant');

    expect(
      evaluateExtractedPriceCandidate(
        rawPriceText: picked.rawPriceText,
        priceMin: picked.priceMin,
        currency: picked.currency,
        extractionMethod: picked.extractionMethod.wire,
        rawEvidence: picked.rawEvidence,
        procedure: picked.rawProcedureText,
        sourceUrl: picked.sourceUrl,
      ).accepted,
      isTrue,
    );
  });

  test('current-revision clinic deserializes to a from-13-USD/unit card', () {
    final clinic = OpenAIClinic.fromJson(_trustedBotoxJson());
    expect(clinic.priceMin, 13);
    expect(clinic.priceExtractRevision, kExplorePriceExtractRevision);
    expect(explorePriceIsVerified(clinic), isTrue);
    expect(
      exploreClinicEligibleForVerifiedPool(
        clinic,
        procedure: _procedure,
        city: 'Miami',
      ),
      isTrue,
    );
    final display = clinicCompareProcedurePriceDisplay(
      clinic,
      procedure: _procedure,
    );
    expect(display, formatBotoxPerUnitPriceLabel(13, clinic.currency));
    expect(display.toLowerCase(), contains('13'));
    expect(display.toLowerCase(), contains('unit'));
    expect(display.toUpperCase(), isNot(contains('PEN')));
    expect(clinic.name, 'Miami Skin Spa');
  });

  test('stale e11 JSON is not a verified card', () {
    final clinic = OpenAIClinic.fromJson(
      _trustedBotoxJson(extractRevision: 'e11'),
    );
    expect(clinic.priceMin, 0);
    expect(explorePriceIsVerified(clinic), isFalse);
    expect(
      exploreClinicEligibleForVerifiedPool(
        clinic,
        procedure: _procedure,
        city: 'Miami',
      ),
      isFalse,
    );
  });

  test('backend.cached-only paints a valid Botox card', () {
    final consumed = consumeExploreBackendRows(
      cached: [_trustedBotoxJson()],
      fresh: const [],
      procedure: _procedure,
      city: 'Miami',
    );
    expect(consumed.length, 1);
    expect(consumed.single.source, ExploreClinicSource.googleCache);
    expect(consumed.single.clinic.priceMin, 13);
    expect(explorePriceIsVerified(consumed.single.clinic), isTrue);
  });

  test('backend.cached stale e11 or wrong family is not shown', () {
    final stale = consumeExploreBackendRows(
      cached: [_trustedBotoxJson(extractRevision: 'e11')],
      fresh: const [],
      procedure: _procedure,
      city: 'Miami',
    );
    expect(stale, isEmpty);

    final wrongFamily = consumeExploreBackendRows(
      cached: [
        _trustedBotoxJson(
          rawProcedure: 'Endolift JawLine (Under Chin)',
          sourceUrl: 'https://www.miamiskinspa.com/endolift-jawline',
        ),
      ],
      fresh: const [],
      procedure: _procedure,
      city: 'Miami',
    );
    expect(wrongFamily, isEmpty);
  });

  test('backend.fresh still paints a valid Botox card', () {
    final consumed = consumeExploreBackendRows(
      cached: const [],
      fresh: [_trustedBotoxJson()],
      procedure: _procedure,
      city: 'Miami',
    );
    expect(consumed.length, 1);
    expect(consumed.single.source, ExploreClinicSource.googleLive);
    expect(consumed.single.clinic.priceMin, 13);
  });

  test('cached and fresh of the same clinic dedupe to one card', () {
    final consumed = consumeExploreBackendRows(
      cached: [_trustedBotoxJson()],
      fresh: [_trustedBotoxJson()],
      procedure: _procedure,
      city: 'Miami',
    );
    expect(consumed.length, 1);
    expect(consumed.single.source, ExploreClinicSource.googleCache);
  });
}
