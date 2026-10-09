import 'package:flutter_test/flutter_test.dart';
import 'package:glowpass/services/explore_html_price_extractor.dart';
import 'package:glowpass/services/explore_price_sanity.dart';
import 'package:glowpass/services/explore_procedure_family.dart';
import 'package:glowpass/services/explore_procedure_relation.dart';

void main() {
  test(
    'general rhinoplasty cannot borrow reconstructive or functional fees',
    () {
      for (final label in [
        'Rinoplastia post-traumática',
        'Post traumatic rhinoplasty',
        'Rinoplastia secundaria',
        'Revision rhinoplasty',
        'Functional septorhinoplasty',
        'Rinoplastia funcional',
      ]) {
        final relation = classifyProcedureRelation(
          requestedProcedure: 'rhinoplasty nose job',
          label: label,
          evidence: '$label 10000–20000 EUR',
          sourceUrl: 'https://clinic.example/precios',
        );
        expect(relation.eligibleForFromPrice, isFalse, reason: label);
        expect(relation.reason, 'rhinoplasty_variant_not_requested');
        final result = evaluateExtractedPriceCandidate(
          rawProcedureText: label,
          rawPriceText: '10000–20000 EUR',
          rawEvidence: '$label 10000–20000 EUR',
          procedure: 'rhinoplasty nose job',
          priceMin: 10000,
          priceMax: 20000,
          currency: 'EUR',
          extractionMethod: 'html_table',
          sourceUrl: 'https://clinic.example/precios',
          logRejects: false,
        );
        expect(result.accepted, isFalse, reason: label);
        expect(result.reason, 'rhinoplasty_variant_not_requested');
        expect(
          exploreCachedPriceNeedsReselect(
            rawProcedureText: label,
            brand: 'Rhinoplasty',
            sourceUrl: 'https://clinic.example/precios',
            procedure: 'rhinoplasty nose job',
            rawPriceText: '10000–20000 EUR',
            rawEvidence: '$label 10000–20000 EUR',
            priceMin: 10000,
            priceMax: 20000,
            currency: 'EUR',
            priceExtractRevision: kExplorePriceExtractRevision,
          ),
          isTrue,
          reason: label,
        );
        expect(
          explorePriceIsComparableTypicalStart(
            procedure: 'rhinoplasty nose job',
            rawProcedureText: label,
            rawEvidence: '$label 10000–20000 EUR',
            rawPriceText: '10000–20000 EUR',
            priceMin: 10000,
            priceMax: 20000,
            currency: 'EUR',
          ),
          isFalse,
          reason: label,
        );
      }
    },
  );

  test('requested subtype remains eligible for its own quote', () {
    for (final sample in [
      (request: 'revision rhinoplasty', label: 'Rinoplastia secundaria'),
      (
        request: 'post-traumatic rhinoplasty',
        label: 'Rinoplastia post-traumática',
      ),
      (request: 'functional rhinoplasty', label: 'Functional septorhinoplasty'),
    ]) {
      final relation = classifyProcedureRelation(
        requestedProcedure: sample.request,
        label: sample.label,
        evidence: '${sample.label} 12000 EUR',
        sourceUrl: 'https://clinic.example/precios',
      );
      expect(relation.eligibleForFromPrice, isTrue,
          reason: '${sample.request}: ${relation.reason}');
      expect(
        evaluateExtractedPriceCandidate(
          rawProcedureText: sample.label,
          rawPriceText: '12000 EUR',
          rawEvidence: '${sample.label} 12000 EUR',
          procedure: sample.request,
          priceMin: 12000,
          currency: 'EUR',
          extractionMethod: 'html_table',
          sourceUrl: 'https://clinic.example/precios',
          logRejects: false,
        ).accepted,
        isTrue,
        reason: sample.request,
      );
    }
  });

  test('ultrasound primary tariff wins over post-traumatic table range', () {
    final rows = extractPriceEvidence(
      html: '''<table>
        <tr><td>Rinoplastia ultrasónica</td><td>7500–9000 EUR</td></tr>
        <tr><td>Rinoplastia secundaria</td><td>9000–19000 EUR</td></tr>
        <tr><td>Rinoplastia post-traumática</td><td>10000–20000 EUR</td></tr>
      </table>''',
      sourceUrl: 'https://clinic.example/precios',
    );
    final selected = selectEvidenceForProcedure(
      rows: rows,
      procedure: 'rhinoplasty nose job',
    );
    expect(selected, isNotNull);
    expect(selected!.rawProcedureText, 'Rinoplastia ultrasónica');
    expect(selected.priceMin, 7500);
    expect(selected.priceMax, 9000);
  });
}
