import 'package:flutter_test/flutter_test.dart';
import 'package:glowpass/services/explore_html_price_extractor.dart';
import 'package:glowpass/services/explore_price_binding.dart';
import 'package:glowpass/services/explore_price_ownership.dart';
import 'package:glowpass/services/explore_price_sanity.dart';
import 'package:glowpass/services/explore_procedure_family.dart';

void main() {
  test('credit ceilings reject while owned treatment fees remain valid', () {
    const evidence =
        'Financiación hasta 48 cuotas. Hasta 2.500€ '
        'hasta 2.000€ hasta 4.000€. Pregúntanos por la financiación. '
        'Chin filler ácido hialurónico 350 EUR';
    expect(
      exploreNonTreatmentPriceReason(
        evidence: evidence,
        priceMin: 2500,
        currency: 'EUR',
      ),
      'credit_limit',
    );
    expect(
      exploreNonTreatmentPriceReason(
        evidence: evidence,
        priceMin: 350,
        currency: 'EUR',
      ),
      isNull,
    );
    expect(
      exploreCachedPriceNeedsReselect(
        rawProcedureText: 'Chin filler',
        brand: 'Chin filler',
        sourceUrl: 'https://clinic.example/',
        procedure: 'dermal filler lips cheeks',
        rawPriceText: '2500 EUR',
        rawEvidence: evidence,
        priceMin: 2500,
        currency: 'EUR',
        priceExtractRevision: kExplorePriceExtractRevision,
      ),
      isTrue,
    );
    expect(
      evaluateExtractedPriceCandidate(
        rawPriceText: '350 EUR',
        rawProcedureText: 'Chin filler ácido hialurónico',
        rawEvidence: evidence,
        priceMin: 350,
        currency: 'EUR',
        extractionMethod: 'html_table',
        procedure: 'dermal filler lips cheeks',
        sourceUrl: 'https://clinic.example/precios',
        logRejects: false,
      ).accepted,
      isTrue,
    );
  });

  test('friend pack price cannot set a single-person comparable start', () {
    const label = 'Pack Amigas (Aumento de labios o tratamiento antiarrugas)';
    const evidence =
        '$label Ven con una amiga y disfruten de un precio '
        'especial. 250€ 350€ *Precio para cada persona';
    expect(
      exploreNonTreatmentPriceReason(
        evidence: evidence,
        priceMin: 250,
        currency: 'EUR',
      ),
      'conditional_offer',
    );
    expect(
      explorePriceIsComparableTypicalStart(
        procedure: 'dermal filler lips cheeks',
        rawProcedureText: label,
        rawPriceText: '250 EUR',
        rawEvidence: evidence,
        priceMin: 250,
        currency: 'EUR',
      ),
      isFalse,
    );
    expect(
      exploreNonTreatmentPriceReason(
        evidence: 'Aumento de labios 349 EUR por persona',
        priceMin: 349,
        currency: 'EUR',
      ),
      isNull,
      reason: 'Per-person pricing alone does not make an offer conditional',
    );
  });

  test(
    'ANTES amount rejects without removing current price or neighbor rows',
    () {
      const evidence = 'Relleno de labios ANTES 400€ AHORA 330€';
      expect(
        exploreNonTreatmentPriceReason(
          evidence: evidence,
          priceMin: 400,
          currency: 'EUR',
        ),
        'superseded_price',
      );
      expect(
        exploreNonTreatmentPriceReason(
          evidence: evidence,
          priceMin: 330,
          currency: 'EUR',
        ),
        isNull,
      );
      expect(
        explorePublishedPriceIsSuperseded(
          evidence: 'Relleno de labios 400€\nBotox una zona 180€',
          priceMin: 400,
          currency: 'EUR',
        ),
        isFalse,
      );
    },
  );

  test('current 1-vial tariff survives old and 2-vial price columns', () {
    final selected = selectEvidenceForProcedure(
      rows: extractPriceEvidence(
        html: '''<table>
          <tr><th>TRATAMIENTO</th><th>ANTES</th><th>1 VIAL (AHORA)</th>
            <th>2 VIALES (AHORA)</th></tr>
          <tr><td>Relleno de labios ácido hialurónico</td><td>400€</td>
            <td>330€</td><td>650€</td></tr>
        </table>''',
        sourceUrl: 'https://clinic.example/precios',
      ),
      procedure: 'dermal filler lips cheeks',
    );
    expect(selected, isNotNull);
    expect(selected!.priceMin, 330);
  });

  test(
    'explicit non-clinic disclaimer blocks official URL and own fragments',
    () {
      const disclaimer =
          'Los precios son indicativos de la media en España. '
          'No representan los precios aplicados en la consulta del doctor.';
      final context = classifyExplorePricePageContext(
        sourceUrl: 'https://clinic.example/precios',
        pageText: '$disclaimer Rinoplastia ultrasónica 7500–9000 EUR',
        title: 'Precios Rinoplastia',
      );
      expect(context, ExplorePricePageContext.nonClinicPrices);
      expect(
        exploreEvidenceIsClinicOwnedPrice(
          pageContext: context,
          rawEvidence: 'Rhinoplasty starting from 7500 EUR',
          rawProcedureText: 'Rhinoplasty',
          rawPriceText: '7500 EUR',
        ),
        isFalse,
      );
      expect(
        evaluateExtractedPriceCandidate(
          rawPriceText: '7500 EUR',
          rawEvidence: 'Rhinoplasty starting from 7500 EUR',
          procedure: 'rhinoplasty nose job',
          priceMin: 7500,
          currency: 'EUR',
          extractionMethod: 'html_table',
          sourceUrl: 'https://clinic.example/precios',
          pageContextWire: explorePricePageContextWire(context),
          logRejects: false,
        ).reason,
        'not_clinic_owned_price',
      );
    },
  );

  test('locked semantics preserve approximate price and ignore duration', () {
    expect(
      inferLockedEvidencePriceSemantics(
        '300 EUR Relleno de labios: depende del número de viales; '
        'suele rondar los 300€.',
        priceMin: 300,
      ).priceType,
      'approximate',
    );
    expect(
      inferLockedEvidencePriceSemantics(
        'Relleno de labios 300 EUR. Duración aproximada de 30 minutos.',
        priceMin: 300,
      ).priceType,
      'fixed',
    );
    expect(
      inferLockedEvidencePriceSemantics(
        'Lip filler 300 EUR. A different package is about 900 EUR.',
        priceMin: 300,
      ).priceType,
      'fixed',
    );
  });
}
