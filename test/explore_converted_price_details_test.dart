import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glowpass/services/openai_service.dart';
import 'package:glowpass/services/explore_price_sanity.dart';
import 'package:glowpass/services/explore_price_discovery_tool.dart';
import 'package:glowpass/ui/explore_price_details.dart';

Map<String, Object?> row({String currency = 'EUR', String basis = 'platform_converted'}) => {
  'name': 'Aster Clinic', 'area': 'Madrid · whatclinic.com',
  'price_min': 150, 'price_max': 200, 'currency': currency,
  'brand': 'Chemical Peel', 'raw_procedure_text': 'Chemical Peel',
  'raw_price_text': '150–200 $currency', 'price_evidence_text': 'Chemical Peel | 150–200 $currency',
  'price_source_url': 'https://www.whatclinic.com/beauty-clinics/spain/madrid/aster-clinic',
  'price_verification_status': 'marketplace_menu', 'source_type': 'marketplace',
  'extraction_method': 'marketplace_menu', 'price_extract_revision': kExplorePriceExtractRevision,
  'source_currency_basis': basis,
};

void main() {
  test('actual live provider menus survive full Flutter validation with conversion details', () async {
    final receipt = jsonDecode(File('verification/whatclinic_peel_delivery_0_12_0.json').readAsStringSync()) as Map;
    final rows = (receipt['results'] as List).cast<Map>().map((raw) =>
      ExplorePriceDiscoveryTool.rowFromJson(raw.cast<String, Object?>())).whereType<ExploreDiscoveryToolRow>().toList();
    expect(rows, hasLength(5));
    final verified = await validateExploreDiscoveryCompareRows(
      rows: rows, city: 'Istanbul', procedure: 'chemical peel', selection: 'chemical peel facial');
    expect(verified.rejectedUrls, isEmpty);
    expect(verified.accepted, hasLength(5));
    for (final clinic in verified.accepted) {
      expect(explorePriceConversionNote(clinic), isNotEmpty);
      expect(explorePriceIsVerified(clinic), true);
    }
  });
  test('converted EUR survives model and cache with its provenance intact', () {
    final clinic = OpenAIClinic.fromJson(row());
    expect(clinic.priceMin, 150);
    expect(clinic.sourceCurrencyBasis, 'platform_converted');
    final cleaned = stripInvalidCachedPriceJson(row(), procedure: 'chemical peel', city: 'Madrid');
    expect(cleaned['price_min'], 150);
    expect(cleaned['source_currency_basis'], 'platform_converted');
    expect(explorePriceConversionNote(clinic), contains('original currency has not been confirmed'));
  });

  test('uncontrolled RON and old viewer markers remain ineligible', () {
    expect(OpenAIClinic.fromJson(row(currency: 'RON')).priceMin, 0);
    expect(OpenAIClinic.fromJson(row(basis: 'viewer_localized')).priceMin, 0);
  });

  testWidgets('conversion note opens in details without a subtitle below the amount', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ExplorePriceDetailsButton(
      clinic: OpenAIClinic.fromJson(row()), child: const Text('€150–€200')))));
    expect(find.textContaining('WhatClinic displays'), findsNothing);
    await tester.tap(find.text('€150–€200'));
    await tester.pumpAndSettle();
    expect(find.text('Price details'), findsOneWidget);
    expect(find.textContaining('original currency has not been confirmed'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.text('Price details'), findsNothing);
  });
}
