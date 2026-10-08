import 'package:flutter_test/flutter_test.dart';
import 'package:glowpass/services/explore_price_sanity.dart';
import 'package:glowpass/services/explore_procedure_relation.dart';

void main() {
  test('Romanian fire threads are not emergency numbers', () {
    expect(
      looksLikeEmergencyOrHelpNumber('de la 400€ /2 fire', priceMin: 400),
      isFalse,
    );
    expect(
      looksLikeEmergencyOrHelpNumber(
        'Extragere fire sutura 100 RON',
        priceMin: 100,
      ),
      isFalse,
    );
    expect(
      looksLikeEmergencyOrHelpNumber(
        'Emergency fire brigade 999',
        priceMin: 999,
      ),
      isTrue,
    );
  });

  test('rhino 1800 EUR accepted', () {
    final r = evaluateExtractedPriceCandidate(
      rawPriceText: '1.800 € - 4.000 €',
      priceMin: 1800,
      priceMax: 4000,
      currency: 'EUR',
      extractionMethod: 'list_item',
      procedure: 'Rinoplastie',
      rawEvidence: 'Rinoplastie 1.800 € - 4.000 €',
      sourceUrl: 'https://www.cosmedica.ro/rinoplastie/',
    );
    expect(r.accepted, isTrue, reason: r.reason);
  });

  test('nanofat polluted evidence is not botox same_treatment', () {
    final r = classifyProcedureRelation(
      requestedProcedure: 'Botox anti-wrinkle injection',
      label: 'Regenerare cutanata Nanofat - fata',
      evidence:
          'Toxina botulinica 800 RON Regenerare cutanata Nanofat - fata de la 2500 EUR',
      sourceUrl: 'https://cronosmed.ro/preturi/brasov/',
    );
    expect(r.eligibleForFromPrice, isFalse);
    expect(r.relation, ProcedureRelation.differentProcedure);
  });
}
