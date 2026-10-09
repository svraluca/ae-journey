import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import '../lib/services/explore_price_sanity.dart';
import '../lib/services/explore_price_binding.dart';
import '../lib/services/explore_price_ownership.dart';
import '../lib/ui/clinic_compare_price_display.dart';
import 'explore_verified_card_titles_test.dart' as fixture;

void main() {
  final cases =
      jsonDecode(
            File('verification/fixtures/tariff_scope.json').readAsStringSync(),
          )
          as List;
  for (final raw in cases) {
    final c = raw as Map<String, dynamic>;
    test(c['name'] as String, () {
      final verdict = evaluateExtractedPriceCandidate(
        rawPriceText: '${c['amount']} ${c['currency']}',
        priceMin: (c['amount'] as num).toDouble(),
        currency: c['currency'] as String,
        rawEvidence: c['evidence'] as String,
        rawProcedureText: c['procedure'] as String,
        procedure: c['procedure'] as String,
        extractionMethod: 'html_table',
        sourceUrl: 'https://aster.example/prices/',
        logRejects: false,
      );
      expect(verdict.accepted, c['accepted'], reason: verdict.reason);
      if (c['accepted'] == false) expect(verdict.reason, c['reason']);
    });
  }
  test(
    'cached geographic price comparisons fail despite official menu flags',
    () {
      for (final heading in [
        'Ülkelere Göre Fiyatlar',
        'Şehirlere Göre Fiyatlar',
        'Prices by country',
        'Cost across cities',
        'Precios por países',
        'Prix par pays',
        'Preise nach Land',
        'Prezzi per paese',
      ]) {
        final evidence = '$heading | Hair transplant Turkey: €3000';
        expect(
          exploreNonTreatmentPriceReason(
            evidence: evidence,
            priceMin: 3000,
            currency: 'EUR',
          ),
          'market_comparison_table',
        );
        expect(
          exploreEvidenceIsClinicOwnedPrice(
            pageContext: ExplorePricePageContext.officialPriceList,
            rawEvidence: evidence,
            rawProcedureText: 'Hair transplant',
            rawPriceText: '€3000',
          ),
          false,
        );
      }
    },
  );
  test('a treatment average is not a provider tariff in another language', () {
    final verdict = evaluateExtractedPriceCandidate(
      rawPriceText: '799 AED',
      priceMin: 799,
      currency: 'AED',
      procedure: 'Botox',
      rawEvidence: 'The average Botox injection Price start from 799 AED.',
      sourceUrl: 'https://aster.example/en/botox/',
      extractionMethod: 'dom_block',
      logRejects: false,
    );
    expect(verdict.accepted, false);
    expect(verdict.reason, 'market_comparison_table');
  });
  test('branded menu proof cannot transfer to an unrelated source', () {
    const evidence =
        'Aster Clinic Hair Transplant Prices | DHI: From €3290 (up to 4000 grafts)';
    for (final host in ['aster.example', 'unrelated.example']) {
      expect(
        exploreEvidenceIsClinicOwnedPrice(
          pageContext: ExplorePricePageContext.foreignPriceComparison,
          rawEvidence: evidence,
          rawProcedureText: 'Hair Transplant · DHI',
          extractionMethod: 'owned_currency_tariff_table',
          sourceUrl: 'https://$host/prices/',
        ),
        host == 'aster.example',
      );
    }
  });
  test('package total retains the graft cap on its card', () {
    final row = fixture
        .clinic(
          procedure: 'Hair transplant',
          canonical: 'hair_transplant',
          rawTitle: 'Hair Transplant · Micro Sapphire DHI',
          displayTitle: 'Micro Sapphire DHI',
          amount: 3290,
          currency: 'EUR',
          city: 'Istanbul',
        )
        .copyWith(
          priceEvidenceText:
              'Our hair transplant package starts from €3290 (up to 4000 grafts)',
          procedureDetail: 'DHI · up to 4,000 grafts',
          priceType: 'from',
          priceUnit: 'procedure',
        );
    expect(
      clinicCompareProcedurePriceDisplay(row, procedure: 'Hair'),
      contains('/ up to 4,000 grafts'),
    );
    expect(
      clinicCompareProcedurePriceDisplay(row, procedure: 'Hair'),
      isNot(contains('/graft')),
    );
  });
}
