import 'package:flutter_test/flutter_test.dart';
import 'package:glowpass/services/explore_currency_tokens.dart';
import 'package:glowpass/services/explore_price_evidence.dart';
import 'package:glowpass/services/openai_service.dart';
import 'package:glowpass/services/explore_procedure_relation.dart';
import 'package:glowpass/services/explore_clinic_identity.dart';
import 'package:glowpass/services/explore_search_locale.dart';
import 'package:glowpass/services/filter_currency.dart';

void main() {
  test('BGN detected and justified for Bellissimo crow feet', () {
    expect(detectExploreCurrencyToken('250 BGN'), 'BGN');
    expect(detectExploreCurrencyToken('300 lv.'), 'BGN');
    final p = parsePriceText('250 BGN');
    expect(p, isNotNull);
    expect(p!.currency, 'BGN');
    expect(p.priceMin, 250);
    expect(
      isJustifiedProcedurePriceValue(
        priceMin: 250,
        currency: 'BGN',
        procedure: 'Botox anti-wrinkle injection',
        evidence: "Botox – crow's feet 250 BGN",
      ),
      isTrue,
    );
    expect(CityCurrency.localCode('Sofia'), 'BGN');
  });

  test('Contour 1 zone on our-pricing stays eligible', () {
    expect(
      exploreSourceUrlLooksLikePriceMenu(
        'http://contourclinic.bg/our-pricing/?lang=en',
      ),
      isTrue,
    );
    final rel = classifyProcedureRelation(
      requestedProcedure: 'Botox anti-wrinkle injection',
      label: '1 zone',
      evidence: '€130',
      sourceUrl: 'http://contourclinic.bg/our-pricing/?lang=en',
    );
    expect(rel.eligibleForFromPrice, isTrue);
    expect(rel.reason, 'botox_zone_or_area_variant');
  });

  test('EUR and BGN both fit Sofia city currency gate', () {
    expect(exploreCurrencyFitsSearchCity('EUR', 'Sofia'), isTrue);
    expect(exploreCurrencyFitsSearchCity('€', 'Sofia'), isTrue);
    expect(exploreCurrencyFitsSearchCity('BGN', 'Sofia'), isTrue);
    expect(exploreCurrencyFitsSearchCity('RON', 'Sofia'), isFalse);
  });

  test('CTA titles rejected; host rename works', () {
    expect(clinicIdentityRejectReason('book now'), 'invalid_identity');
    expect(clinicIdentityRejectReason('Our Pricing'), 'invalid_identity');
    expect(
      exploreClinicDisplayNameFromHost('https://contourclinic.bg/our-pricing/'),
      'Contourclinic',
    );
  });
}
