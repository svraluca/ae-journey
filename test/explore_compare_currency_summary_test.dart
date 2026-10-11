import 'package:flutter_test/flutter_test.dart';
import 'package:glowpass/services/explore_price_verification.dart';
import 'package:glowpass/services/openai_service.dart';
import 'package:glowpass/ui/clinic_compare_price_display.dart';

OpenAIClinic _listedFiller(String name, double amount, String currency) {
  final url = 'https://${name.toLowerCase()}.example/prices';
  final price = '$amount $currency';
  return OpenAIClinic(
    rank: 1,
    name: name,
    area: 'City · ${name.toLowerCase()}.example',
    distanceMi: 1,
    rating: 4.5,
    reviews: 20,
    priceGbp: amount.round(),
    priceMin: amount,
    priceMax: amount,
    priceLabel: 'from $price',
    currency: currency,
    brand: 'Lip filler',
    badge: '',
    badgeVariant: 'mid',
    coord: const OpenAICoord(41.4, 2.1),
    hasProcedure: true,
    pricePending: false,
    currencyConfirmed: true,
    priceSourceUrl: url,
    priceEvidenceText: 'Lip filler from $price',
    priceVerificationStatus: PriceVerificationStatus.officialWebsite,
    rawProcedureText: 'Lip filler',
    rawPriceText: 'from $price',
    extractionMethod: 'html_table',
    sourceType: 'official_clinic',
  );
}

void main() {
  test('mixed source currencies do not imply one selected summary currency', () {
    final clinics = [
      _listedFiller('A', 1065, 'RON'),
      _listedFiller('B', 1335, 'RON'),
      _listedFiller('C', 360, 'USD'),
      _listedFiller('D', 840, 'USD'),
    ];
    expect(
      clinicComparePricesHaveMixedCurrencies(clinics, procedure: 'Fillers'),
      isTrue,
    );
    expect(
      clinicCompareAggregateRangeDisplay(clinics, procedure: 'Fillers'),
      isEmpty,
    );
    expect(
      clinicCompareAggregateFromDisplay(clinics, procedure: 'Fillers'),
      isEmpty,
    );
    expect(
      clinicCompareProcedurePriceDisplay(clinics.first, procedure: 'Fillers'),
      contains('RON'),
    );
    expect(
      clinicCompareProcedurePriceDisplay(clinics.last, procedure: 'Fillers'),
      contains('USD'),
    );
  });

  test('equivalent currency symbols and codes retain a comparable range', () {
    final clinics = [
      _listedFiller('A', 250, 'EUR'),
      _listedFiller('B', 325, '€'),
    ];
    expect(
      clinicComparePricesHaveMixedCurrencies(clinics, procedure: 'Fillers'),
      isFalse,
    );
    expect(
      clinicCompareAggregateRangeDisplay(clinics, procedure: 'Fillers'),
      'from 250–325 EUR',
    );
  });
}
