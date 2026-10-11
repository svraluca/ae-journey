import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:glowpass/services/explore_price_sanity.dart';

void main() {
  final cases = jsonDecode(File('test/fixtures/peel_product_scope_cases.json').readAsStringSync()) as List;
  for (final sample in cases.cast<Map>()) {
    test('peel fee scope: ${sample['id']}', () {
      final result = evaluateExtractedPriceCandidate(
        procedure: 'chemical peel', rawProcedureText: sample['label'] as String,
        rawEvidence: sample['price_first'] == true ? '${sample['amount']} EUR | ${sample['label']}' : '${sample['label']} | ${sample['amount']} EUR',
        rawPriceText: '${sample['amount']} EUR',
        priceMin: (sample['amount'] as num).toDouble(), currency: 'EUR',
        extractionMethod: 'dom_tariff_row', structuredOffer: true,
        clinicName: 'Aster Medical Clinic',
        sourceUrl: sample['url'] as String? ?? 'https://aster.example/prices/',
        logRejects: false,
      );
      expect(result.accepted, sample['reject'] == false, reason: result.reason);
      if (sample['reject'] == true) expect(result.reason, 'peel_product_not_procedure');
    });
  }
}
