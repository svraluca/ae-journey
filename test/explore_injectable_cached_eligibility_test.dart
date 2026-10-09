import 'package:flutter_test/flutter_test.dart';
import 'package:glowpass/services/explore_html_price_extractor.dart';
import 'package:glowpass/services/explore_price_evidence.dart';
import 'package:glowpass/services/explore_price_sanity.dart';
import 'package:glowpass/services/explore_procedure_family.dart';
import 'package:glowpass/services/explore_procedure_relation.dart';

Map<String, Object?> _cachedQuote({
  required String label,
  required String procedure,
  required double amount,
  String evidence = '',
  String sourceUrl = 'https://clinic.example/precios',
}) => {
  'name': 'Example Clinic',
  'brand': procedure,
  'raw_procedure_text': label,
  'raw_price_text': '$amount EUR',
  'price_min': amount,
  'price_max': amount,
  'price_label': '$amount EUR',
  'currency': 'EUR',
  'price_evidence_text': evidence,
  'price_source_url': sourceUrl,
  'extraction_method': 'html_table',
  'price_extract_revision': kExplorePriceExtractRevision,
  'price_verification_status': 'official_website',
  'price_verified': true,
  'rating': 4.8,
};

void main() {
  group('mixed skin-booster and neurotoxin quote', () {
    test('stored service label rejects cached amount-only evidence', () {
      const label = 'NeuroSkin (Skinbooster + Neuromoduladores)';
      final cached = _cachedQuote(
        label: label,
        procedure: 'Botox',
        amount: 510,
      );
      final cleaned = stripInvalidCachedPriceJson(
        cached,
        procedure: 'Botox anti-wrinkle injection',
        logRejects: false,
      );
      expect(cleaned['price_min'], 0);
      expect(cleaned['price_verified'], isFalse);
      expect(cleaned['price_rejection_reason'], 'mixed_service_bundle');
      expect(cleaned['rating'], 4.8);
      expect(cached['price_min'], 510, reason: 'Do not mutate the stored row');
      expect(
        exploreCachedPriceNeedsReselect(
          rawProcedureText: label,
          brand: 'Botox',
          sourceUrl: 'https://clinic.example/precios',
          procedure: 'Botox anti-wrinkle injection',
          rawPriceText: '510 EUR',
          priceMin: 510,
          currency: 'EUR',
          priceExtractRevision: kExplorePriceExtractRevision,
        ),
        isTrue,
      );
      expect(
        explorePriceIsComparableTypicalStart(
          procedure: 'Botox anti-wrinkle injection',
          rawProcedureText: label,
          rawPriceText: '510 EUR',
          priceMin: 510,
          currency: 'EUR',
        ),
        isFalse,
      );
    });

    test(
      'reverse-order bundles reject, clean same-family packages survive',
      () {
        for (final label in [
          'Skinbooster + Neuromoduladores',
          'Botox + Skin Booster',
          'Neuromoduladores y Skinbooster',
          'Profhilo with Botox',
        ]) {
          final relation = classifyProcedureRelation(
            requestedProcedure: 'Botox',
            label: label,
            evidence: '$label 510 EUR',
          );
          expect(relation.relation, ProcedureRelation.bundle, reason: label);
          expect(relation.eligibleForFromPrice, isFalse, reason: label);
        }
        final singleFamily = classifyProcedureRelation(
          requestedProcedure: 'Botox',
          label: 'Botox 3 areas package',
          evidence: 'Botox 3 areas package 350 EUR',
        );
        expect(singleFamily.eligibleForFromPrice, isTrue);
        expect(
          looksLikeMixedServiceBundle('Skinbooster 250 EUR\nBotox 300 EUR'),
          isFalse,
        );
      },
    );

    test('selection takes a standalone quote from a mixed service menu', () {
      final rows = extractPriceEvidence(
        html: '''<table>
          <tr><td>NeuroSkin (Skinbooster + Neuromoduladores)</td><td>510 EUR</td></tr>
          <tr><td>Neuromoduladores 1 zona</td><td>180 EUR</td></tr>
        </table>''',
        sourceUrl: 'https://clinic.example/precios',
      );
      final selected = selectEvidenceForProcedure(
        rows: rows,
        procedure: 'Botox anti-wrinkle injection',
      );
      expect(selected, isNotNull);
      expect(selected!.priceMin, 180);
      expect(selected.rawProcedureText, contains('1 zona'));
    });
  });

  group('surgical chin does not become injectable filler', () {
    test('surgical label, evidence and path reject cached filler quotes', () {
      for (final sample in [
        (
          label: 'Mentoplastia con implante',
          evidence: 'Mentoplastia con implante 2500 EUR',
          url: 'https://clinic.example/precios',
        ),
        (
          label: 'Chin filler',
          evidence: 'Genioplasty: chin implant 2500 EUR',
          url: 'https://clinic.example/precios',
        ),
        (
          label: 'Chin filler',
          evidence: '2500 EUR',
          url: 'https://clinic.example/cirugia/mentoplastia/',
        ),
        (
          label: 'Chin filler',
          evidence: 'Reducción del mentón desde 2500 EUR',
          url: 'https://clinic.example/precios',
        ),
      ]) {
        final relation = classifyProcedureRelation(
          requestedProcedure: 'dermal filler lips cheeks',
          label: sample.label,
          evidence: sample.evidence,
          sourceUrl: sample.url,
        );
        expect(relation.eligibleForFromPrice, isFalse, reason: sample.label);
        expect(relation.reason, 'surgical_chin_not_filler');
        final cleaned = stripInvalidCachedPriceJson(
          _cachedQuote(
            label: sample.label,
            procedure: 'Chin filler',
            amount: 2500,
            evidence: sample.evidence,
            sourceUrl: sample.url,
          ),
          procedure: 'dermal filler lips cheeks',
          logRejects: false,
        );
        expect(cleaned['price_min'], 0);
        expect(cleaned['price_rejection_reason'], 'surgical_chin_not_filler');
        expect(
          exploreCachedPriceNeedsReselect(
            rawProcedureText: sample.label,
            brand: 'Chin filler',
            sourceUrl: sample.url,
            procedure: 'dermal filler lips cheeks',
            rawPriceText: '2500 EUR',
            rawEvidence: sample.evidence,
            priceMin: 2500,
            currency: 'EUR',
            priceExtractRevision: kExplorePriceExtractRevision,
          ),
          isTrue,
        );
        expect(
          explorePriceIsComparableTypicalStart(
            procedure: 'dermal filler lips cheeks',
            rawProcedureText: sample.label,
            rawEvidence: sample.evidence,
            sourceUrl: sample.url,
            rawPriceText: '2500 EUR',
            priceMin: 2500,
            currency: 'EUR',
          ),
          isFalse,
        );
      }
    });

    test(
      'legitimate HA chin filler survives at any supported clinic price',
      () {
        for (final sample in [
          (
            label: 'Chin filler',
            evidence: 'Chin filler 2500 EUR',
            url: 'https://clinic.example/precios',
            amount: 2500.0,
          ),
          (
            label: 'Chin filler ácido hialurónico',
            evidence: 'Chin filler ácido hialurónico 350 EUR',
            url: 'https://clinic.example/mentoplastia/',
            amount: 350.0,
          ),
          (
            label: 'Mentoplastia no quirúrgica con ácido hialurónico',
            evidence:
                'Mentoplastia no quirúrgica con ácido hialurónico 350 EUR',
            url: 'https://clinic.example/mentoplastia/',
            amount: 350.0,
          ),
        ]) {
          expect(
            classifyProcedureRelation(
              requestedProcedure: 'dermal filler lips cheeks',
              label: sample.label,
              evidence: sample.evidence,
              sourceUrl: sample.url,
            ).eligibleForFromPrice,
            isTrue,
            reason: sample.label,
          );
          final cleaned = stripInvalidCachedPriceJson(
            _cachedQuote(
              label: sample.label,
              procedure: 'Chin filler',
              amount: sample.amount,
              evidence: sample.evidence,
              sourceUrl: sample.url,
            ),
            procedure: 'dermal filler lips cheeks',
            logRejects: false,
          );
          expect(cleaned['price_min'], sample.amount, reason: sample.label);
          expect(
            exploreCachedPriceNeedsReselect(
              rawProcedureText: sample.label,
              brand: 'Chin filler',
              sourceUrl: sample.url,
              procedure: 'dermal filler lips cheeks',
              rawPriceText: '${sample.amount} EUR',
              rawEvidence: sample.evidence,
              priceMin: sample.amount,
              currency: 'EUR',
              priceExtractRevision: kExplorePriceExtractRevision,
            ),
            isFalse,
            reason: sample.label,
          );
        }
      },
    );

    test('surgical label cannot borrow HA from a different procedure', () {
      expect(
        classifyProcedureRelation(
          requestedProcedure: 'dermal filler lips cheeks',
          label: 'Chin implant',
          evidence: 'Chin implant 2500 EUR\nLip filler hyaluronic acid 300 EUR',
          sourceUrl: 'https://clinic.example/precios',
        ).eligibleForFromPrice,
        isFalse,
      );
    });

    test(
      'selection retains the actual injectable quote beside chin surgery',
      () {
        final selected = selectEvidenceForProcedure(
          rows: const [
            ExtractedPriceEvidence(
              rawProcedureText: 'Chin filler',
              rawPriceText: '2500 EUR',
              priceMin: 2500,
              priceMax: 2500,
              currency: 'EUR',
              sourceUrl: 'https://clinic.example/mentoplastia/',
              extractionMethod: PriceExtractionMethod.htmlTable,
              rawEvidence: 'Mentoplastia con implante 2500 EUR',
              confidence: 0.99,
            ),
            ExtractedPriceEvidence(
              rawProcedureText: 'Chin filler ácido hialurónico',
              rawPriceText: '350 EUR',
              priceMin: 350,
              priceMax: 350,
              currency: 'EUR',
              sourceUrl: 'https://clinic.example/precios',
              extractionMethod: PriceExtractionMethod.htmlTable,
              rawEvidence: 'Chin filler ácido hialurónico 350 EUR',
              confidence: 0.9,
            ),
          ],
          procedure: 'dermal filler lips cheeks',
        );
        expect(selected, isNotNull);
        expect(selected!.priceMin, 350);
        expect(selected.rawProcedureText, contains('hialurónico'));
      },
    );
  });
}
