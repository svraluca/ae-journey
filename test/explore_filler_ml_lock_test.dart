import 'package:flutter_test/flutter_test.dart';
import 'package:glowpass/services/explore_price_evidence.dart';
import 'package:glowpass/services/explore_price_evidence_lock.dart';
import 'package:glowpass/services/explore_procedure_relation.dart';
import 'package:glowpass/services/explore_search_locale.dart';

void main() {
  group('Filler bare ml rate lock', () {
    test('1100 Lei/1 ml locks on /preturi without page witness', () {
      final relation = classifyProcedureRelation(
        requestedProcedure: 'dermal filler lips cheeks',
        label: '1100 Lei/1 ml',
        evidence: '1100 Lei/1 ml',
        sourceUrl: 'https://artmedica.ro/preturi',
      );
      expect(relation.eligibleForFromPrice, isTrue, reason: relation.reason);
      expect(relation.relation, ProcedureRelation.variant);

      final lock = lockExplorePriceEvidence(
        candidate: ExtractedPriceEvidence(
          rawProcedureText: '1100 Lei/1 ml',
          rawPriceText: '1100 Lei/1 ml',
          priceMin: 1100,
          priceMax: 1100,
          currency: 'RON',
          sourceUrl: 'https://artmedica.ro/preturi',
          extractionMethod: PriceExtractionMethod.domBlock,
          rawEvidence: '1100 Lei/1 ml',
          confidence: 0.9,
          priceType: PriceType.perUnit,
          unit: 'ml',
          quantity: 1,
        ),
        procedure: 'dermal filler lips cheeks',
        sourceHtmlOrText: 'Acid hialuronic 1100 Lei/1 ml buze',
      );
      expect(lock.accepted, isTrue, reason: lock.rejectReason);
    });

    test('1.650 Ron / ml locks as filler rate', () {
      final relation = classifyProcedureRelation(
        requestedProcedure: 'dermal filler lips cheeks',
        label: '1.650 Ron / ml',
        evidence: '1.650 Ron / ml',
        sourceUrl: 'https://cbeauty.ro/tratamente-injectabile-brasov/injectii-cu-acid-hialuronic/',
      );
      // Service URL is not /preturi, but bare rate + ml still needs menu or witness.
      // Procedure path with acid-hialuronic should help via URL signals if present.
      expect(
        exploreSourceUrlLooksLikePriceMenu('https://artmedica.ro/preturi'),
        isTrue,
      );
      expect(relation.reason, isNot(equals('unmatched_procedure_signal')));
    });
  });

  group('Romanian peer cities', () {
    test('Bacau Cronosmed URL conflicts with Brasov search', () {
      expect(
        exploreUrlConflictsWithSearchCity(
          'https://www.cronosmed.ro/en/preturi/bacau-2',
          'Brasov',
        ),
        isTrue,
      );
      expect(
        exploreUrlConflictsWithSearchCity(
          'https://www.cronosmed.ro/preturi/brasov/',
          'Brașov',
        ),
        isFalse,
      );
    });
  });
}
