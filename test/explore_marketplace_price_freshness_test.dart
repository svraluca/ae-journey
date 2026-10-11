import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:glowpass/services/explore_comparison_session.dart';
import 'package:glowpass/services/explore_marketplace_price_freshness.dart';
import 'package:glowpass/services/explore_price_discovery_tool.dart';
import 'package:glowpass/services/explore_price_sanity.dart';
import 'package:glowpass/services/filter_currency.dart';
import 'package:glowpass/services/openai_service.dart';

Map<String, Object?> _clinicJson({
  String date = '',
  String basis = '',
  String currencyBasis = '',
}) => {
  'name': 'Harbor Medical Clinic',
  'rank': 1,
  'area': 'Istanbul · bookimed.com',
  'price_min': 340,
  'price_max': 350,
  'price_gbp': 340,
  'price_label': r'$340–$350',
  'currency': 'USD',
  'currency_confirmed': true,
  'brand': 'Fillers injection',
  'price_source_url': 'https://us-uk.bookimed.com/clinic/harbor-medical/#prices',
  'price_evidence_text': r'Fillers injection | $340–$350',
  'price_verification_status': 'marketplace_menu',
  'price_verified_at': DateTime.now().toUtc().toIso8601String(),
  'raw_procedure_text': 'Fillers injection',
  'raw_price_text': r'$340–$350',
  'extraction_method': 'marketplace_menu',
  'price_type': 'range',
  'source_type': 'marketplace',
  'provider_clinic': 'Harbor Medical Clinic',
  'source_platform': 'Bookimed',
  'price_extract_revision': kExplorePriceExtractRevision,
  'source_price_updated_at': date,
  'source_price_date_text': date.isEmpty ? '' : 'Last price update: $date',
  'source_price_date_basis': basis,
  'source_currency_basis': currencyBasis,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final clock = DateTime.utc(2026, 10, 10, 12);

  test('the freshly checked published peel survives without an age exception', () {
    final receipt = jsonDecode(File('verification/published_peel_e33.json').readAsStringSync()) as Map;
    final raw = (receipt['app_row'] as Map).cast<String, Object?>();
    final clinic = OpenAIClinic.fromJson(raw);
    expect(clinic.priceMin, 2735);
    expect(CityCurrency.normalizeCode(clinic.currency), CityCurrency.normalizeCode('USD'));
    expect(clinic.sourcePriceUpdatedAt, '2025-01-15T13:15:54.000+00:00');
    expect(clinic.sourcePriceDateBasis, 'provider_procedure_price_record');
    final unretained = stripInvalidCachedPriceJson({...raw,
      'source_price_date_basis': 'provider_procedure_price_record'},
      procedure: 'chemical peel', city: 'Istanbul', logRejects: false);
    expect(unretained['price_min'], 2735);
    final oldStamp = stripInvalidCachedPriceJson({...raw, 'price_extract_revision': 'e32'},
      procedure: 'chemical peel', city: 'Istanbul', logRejects: false);
    expect(oldStamp['price_min'], 0);
  });

  test('published source dates have no maximum age', () {
    expect(
      exploreMarketplacePriceDateFailure(
        updatedAt: '2025-10-10T12:00:00Z',
        now: clock,
      ),
      isEmpty,
    );
    expect(
      exploreMarketplacePriceDateFailure(
        updatedAt: '2025-10-10T11:59:59Z',
        now: clock,
      ),
      isEmpty,
    );
    expect(exploreMarketplacePriceDateFailure(updatedAt: '2001-01-01', now: clock), isEmpty);
  });

  test('explicit user retention keeps dated evidence without rewriting its age', () {
    final raw = _clinicJson(date: '2025-01-15', basis: 'user_retained_published_fee');
    final kept = stripInvalidCachedPriceJson(raw, procedure: 'Fillers', logRejects: false);
    expect(kept['price_min'], 340);
    expect(kept['source_price_updated_at'], '2025-01-15');
    final stale = stripInvalidCachedPriceJson({...raw, 'price_extract_revision': 'e17'}, procedure: 'Fillers', logRejects: false);
    expect(stale['price_min'], 0);
  });

  test('unknown stays unknown; invalid, future and ambiguous dates reject', () {
    expect(
      exploreMarketplacePriceDateFailure(updatedAt: '', now: clock),
      isEmpty,
    );
    expect(
      exploreMarketplacePriceDateFailure(
        updatedAt: '2026-02-30', now: clock,
      ),
      'marketplace_price_date_invalid',
    );
    expect(
      exploreMarketplacePriceDateFailure(
        updatedAt: '2026-10-12', now: clock,
      ),
      'marketplace_price_date_future',
    );
    expect(
      exploreMarketplacePriceDateFailure(
        updatedAt: '', dateBasis: 'ambiguous_menu_date', now: clock,
      ),
      'marketplace_price_date_ambiguous',
    );
  });

  test('current cached tariff keeps the published fee and original date', () {
    final raw = _clinicJson(
      date: '2025-03-29', basis: 'provider_tariff_menu',
    );
    final cleaned = stripInvalidCachedPriceJson(raw, procedure: 'Fillers');
    expect(cleaned['price_min'], 340);
    expect(cleaned['source_price_updated_at'], '2025-03-29');
    final clinic = OpenAIClinic.fromJson(raw);
    expect(clinic.priceMin, 340);
    expect(clinic.sourcePriceUpdatedAt, '2025-03-29');
  });

  test('viewer-localized currency cannot pass via a cached clinic', () {
    final raw = _clinicJson(currencyBasis: 'viewer_localized');
    final cleaned = stripInvalidCachedPriceJson(raw, procedure: 'Fillers');
    expect(cleaned['price_min'], 0);
    expect(cleaned['price_rejection_reason'],
        'marketplace_original_currency_unverified');
    final clinic = OpenAIClinic.fromJson(raw);
    expect(clinic.priceMin, 0);
    expect(clinic.sourceCurrencyBasis, 'viewer_localized');
  });

  test('provenance survives DTO mapping, copy and price-record merge', () {
    final date = clock.toIso8601String();
    final raw = _clinicJson(date: date, basis: 'provider_procedure_price_record');
    final clinic = OpenAIClinic.fromJson(raw);
    expect(clinic.priceMin, 340);
    expect(clinic.sourcePriceUpdatedAt, date);
    expect(clinic.copyWith(rating: 4.8).sourcePriceDateBasis,
        'provider_procedure_price_record');
    final merged = mergeExploreClinicRecord(clinic, clinic.copyWith(reviews: 25));
    expect(merged.sourcePriceUpdatedAt, date);
    expect(merged.sourcePriceDateText, 'Last price update: $date');
    final row = ExplorePriceDiscoveryTool.rowFromJson({
      'clinic_name': 'Harbor Medical Clinic',
      'price_min': 340, 'price_max': 350, 'currency': 'USD',
      'source_url': raw['price_source_url'],
      'raw_procedure_text': 'Fillers injection',
      'raw_evidence': raw['price_evidence_text'],
      'raw_price_text': raw['raw_price_text'],
      'city_match': true, 'verified': true,
      'clinic_own_price': false,
      'source_type': 'marketplace', 'evidence_type': 'marketplace_service_menu',
      'source_price_updated_at': date,
      'source_price_date_text': raw['source_price_date_text'],
      'source_price_date_basis': raw['source_price_date_basis'],
      'source_currency_basis': 'viewer_localized',
      'price_extract_revision': kExplorePriceExtractRevision,
    });
    expect(row, isNotNull);
    expect(row!.sourcePriceUpdatedAt, date);
    expect(row.sourceCurrencyBasis, 'viewer_localized');
  });

  test('legacy readers require backend dates and inspect real currency selector', () {
    expect(
      exploreLegacyMarketplaceProvenanceFailure(
        sourceUrl: 'https://us-uk.bookimed.com/clinic/harbor-medical/', html: '',
      ),
      'marketplace_provenance_requires_backend',
    );
    expect(
      exploreLegacyMarketplaceProvenanceFailure(
        sourceUrl: 'https://www.whatclinic.com/beauty-clinics/example',
        html: '<li class="dropdown link-country-selector">Country</li>',
      ),
      'marketplace_original_currency_unverified',
    );
    expect(
      exploreLegacyMarketplaceProvenanceFailure(
        sourceUrl: 'https://clinic.example/prices',
        html: '<li class="link-country-selector">Country</li>',
      ),
      isEmpty,
    );
  });

  test('full worker keeps dated published fees but rejects invalid dates and viewer currencies', () async {
    ExploreDiscoveryToolRow candidate({String date = '', String currencyBasis = ''}) =>
        ExploreDiscoveryToolRow(
          clinicName: 'Harbor Medical Clinic', priceMin: 340, currency: 'USD',
          sourceUrl: 'https://us-uk.bookimed.com/clinic/harbor-medical/#prices',
          rawProcedureText: 'Fillers injection',
          rawEvidence: r'Fillers injection | $340–$350',
          rawPriceText: r'$340–$350', clinicOwnPrice: false, cityMatch: true,
          sourceType: 'marketplace', evidenceType: 'marketplace_service_menu',
          procedureDisplayName: 'Fillers injection', qualifier: 'range',
          sourcePriceUpdatedAt: date, sourceCurrencyBasis: currencyBasis,
          priceExtractRevision: kExplorePriceExtractRevision,
        );
    final dated = candidate(date: '2025-03-29');
    final accepted = await validateExploreDiscoveryCompareRows(
      rows: [dated], city: 'Istanbul', procedure: 'dermal filler', selection: 'Fillers',
    );
    expect(accepted.accepted, hasLength(1));
    expect(accepted.accepted.single.sourcePriceUpdatedAt, '2025-03-29');
    for (final row in [
      candidate(date: 'not a date'),
      candidate(currencyBasis: 'viewer_localized'),
    ]) {
      final result = await validateExploreDiscoveryCompareRows(
        rows: [row], city: 'Istanbul', procedure: 'dermal filler',
        selection: 'Fillers',
      );
      expect(result.accepted, isEmpty);
      expect(result.rejectedUrls, contains(row.sourceUrl));
    }
  });
}
