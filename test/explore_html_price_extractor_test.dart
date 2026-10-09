import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glowpass/services/explore_clinic_identity.dart'
    show
        looksLikeCatalogSectionHeading,
        looksLikeGenericInjectableCategoryHeading;
import 'package:glowpass/services/explore_html_price_extractor.dart';
import 'package:glowpass/services/explore_price_evidence.dart';
import 'package:glowpass/services/explore_price_sanity.dart';
import 'package:glowpass/services/explore_procedure_family.dart';
import 'package:glowpass/services/explore_search_locale.dart';
import 'package:glowpass/services/explore_url_discovery.dart';
import 'package:glowpass/services/explore_currency_tokens.dart';

void main() {
  group('parsePriceText', () {
    test('locale and currency forms', () {
      expect(parsePriceText('€350')?.priceMin, 350);
      expect(parsePriceText('350 €')?.currency, 'EUR');
      expect(parsePriceText('350 EUR')?.priceMin, 350);
      expect(parsePriceText('1.600 €')?.priceMin, 1600);
      expect(parsePriceText('1,600 €')?.priceMin, 1600);
      expect(parsePriceText('1.600,00 €')?.priceMin, 1600);
      expect(parsePriceText('1,600.00 €')?.priceMin, 1600);
      expect(parsePriceText('350,00 €')?.priceMin, 350);
      expect(parsePriceText('£250')?.currency, 'GBP');
      expect(parsePriceText('1.200 RON')?.priceMin, 1200);
      expect(parsePriceText('1200 lei')?.currency, 'RON');
      expect(parsePriceText('de la 7000€ (35000 lei)')?.priceMin, 7000);
      expect(parsePriceText('de la 7000€ (35000 lei)')?.priceMax, 7000);
      expect(parsePriceText('de la 7000€ (35000 lei)')?.currency, 'EUR');
      expect(parsePriceText('200 € (1000 lei)')?.priceMin, 200);
      expect(parsePriceText('200 € (1000 lei)')?.currency, 'EUR');
      expect(parsePriceText('154€ / 800 lei')?.priceMin, 154);
      expect(parsePriceText('154€ / 800 lei')?.priceMax, 154);
      expect(parsePriceText('154€ / 800 lei')?.currency, 'EUR');
      expect(parsePriceText('350 € (1840 lei) RON')?.priceMin, 350);
      expect(parsePriceText('350 € (1840 lei) RON')?.currency, 'EUR');
      expect(parsePriceText('între 8100–9300 euro')?.priceMin, 8100);
      expect(parsePriceText('între 8100–9300 euro')?.priceMax, 9300);
      expect(parsePriceText('între 8100–9300 euro')?.currency, 'EUR');
      expect(parsePriceText('porneste de la 2500 euro')?.priceMin, 2500);
      expect(parsePriceText('porneste de la 2500 euro')?.currency, 'EUR');
      expect(parsePriceText('porneste de la 2500 euro')?.priceType, PriceType.from);
      expect(parsePriceText('de la 5.000€')?.priceMin, 5000);
      expect(parsePriceText('499 AED')?.priceMin, 499);
      expect(parsePriceText('499 AED')?.currency, 'AED');
      expect(parsePriceText('AED 999')?.priceMin, 999);
      expect(parsePriceText('AED 999')?.currency, 'AED');
      expect(parsePriceText('AED 1,500')?.priceMin, 1500);
      expect(parsePriceText('AED 1,500')?.currency, 'AED');
      expect(
        parsePriceText('3000 euro pana la +4000 euro')?.priceMin,
        3000,
      );
      expect(
        parsePriceText('3000 euro pana la +4000 euro')?.priceMax,
        4000,
      );
    });

    test('\$13 per unit depending is USD, never PEN', () {
      final parsed = parsePriceText(
        'Dysport and Xeomin start at \$13 per unit, depending on areas',
      );
      expect(parsed?.priceMin, 13);
      expect(parsed?.currency, 'USD');
      expect(parsed?.priceType, PriceType.perUnit);
      expect(
        detectExploreCurrencyToken(
          'Dysport and Xeomin start at \$13 per unit, depending on areas',
        ),
        'USD',
      );
    });

    test('English words are not ISO currency codes', () {
      expect(detectExploreCurrencyToken('depending on treatment'), isEmpty);
      expect(hasCurrencySignal('depending on treatment'), isFalse);
      expect(detectExploreCurrencyToken('try our treatment'), isEmpty);
      expect(detectExploreCurrencyToken('country pricing information'), isEmpty);
      expect(detectExploreCurrencyToken('copyright notice'), isEmpty);
      expect(detectExploreCurrencyToken('audience'), isEmpty);
    });

    test('bounded ISO codes and local symbols still parse', () {
      expect(parsePriceText('Botox 13 PEN')?.currency, 'PEN');
      expect(parsePriceText('Botox 13 PEN')?.priceMin, 13);
      expect(parsePriceText('Botox S/ 650')?.currency, 'PEN');
      expect(parsePriceText('Botox S/ 650')?.priceMin, 650);
      expect(parsePriceText('Botox TRY 4000')?.currency, 'TRY');
      expect(parsePriceText('Botox TRY 4000')?.priceMin, 4000);
      expect(parsePriceText('Botox CAD 12/unit')?.currency, 'CAD');
      expect(parsePriceText('Botox CAD 12/unit')?.priceMin, 12);
      expect(parsePriceText('Botox CAD 12/unit')?.priceType, PriceType.perUnit);
      expect(parsePriceText('Botox \$13/unit')?.currency, 'USD');
      expect(parsePriceText('Botox \$13/unit')?.priceMin, 13);
      expect(parsePriceText('Botox \$13/unit')?.priceType, PriceType.perUnit);
    });

    test('graft counts are not prices; per-graft AED is', () {
      expect(parsePriceText('1,000 grafts'), isNull);
      expect(parsePriceText('1,000 FUE grafts'), isNull);
      expect(parsePriceText('Up to 3.000 Grafts'), isNull);
      expect(parsePriceText('1500 – 2000 بصيلة'), isNull);
      expect(parsePriceText('8 AED per graft')?.priceMin, 8);
      expect(parsePriceText('8 AED per graft')?.currency, 'AED');
      expect(parsePriceText('8 AED per graft')?.priceType, PriceType.perUnit);
      final package = parsePriceText(
        'A 3,000-graft hair transplant in Dubai generally costs between '
        'AED 15,000 and AED 25,000',
      );
      expect(package?.priceMin, 15000);
      expect(package?.priceMax, 25000);
      expect(package?.currency, 'AED');
      final westminster = parsePriceText(
        'Cost of 500 FUE grafts – from £3500',
      );
      expect(westminster?.priceMin, 3500);
      expect(westminster?.currency, 'GBP');
      expect(westminster?.priceType, PriceType.from);
      expect(westminster?.unit, isEmpty);
      expect(westminster?.quantity, 500);
      expect(parsePriceText('Cost of 1,000 FUE grafts – from £5000')?.priceMin, 5000);
      expect(
        parsePriceText('Cost of 1,000 FUE grafts – from £5000')?.priceMin,
        isNot(1000),
      );
    });

    test('from-range does not invent a max', () {
      final p = parsePriceText('from 150 €');
      expect(p?.priceMin, 150);
      expect(p?.priceMax, 150);
      expect(p?.priceType, PriceType.from);
      expect(parsePriceText('desde 150 €')?.priceType, PriceType.from);
      expect(parsePriceText('a partir de 150 €')?.priceMin, 150);
      // WooCommerce BG/EU mangled decimals: "163 61 €" == 163,61.
      expect(parsePriceText('from 163 61 €')?.priceMin, closeTo(163.61, 0.001));
      expect(parsePriceText('from 163 61 €')?.currency, 'EUR');
      expect(parsePriceText('from 40 90 €')?.priceMin, closeTo(40.90, 0.001));
      expect(parsePriceText('from 127 82 €')?.priceMin, closeTo(127.82, 0.001));
      expect(parsePriceText('1 600 €')?.priceMin, 1600);
    });

    test('bare "package" in aftercare copy is not a published unit', () {
      expect(parsePriceText('from £2,500 all-inclusive package')?.unit, isEmpty);
      expect(parsePriceText('from £2,500 per package')?.unit, 'package');
    });

    test('FAQ blobs are not min–max of every figure', () {
      final stitched = parsePriceText(
        'Promo 199 AED. Standard 399 AED. Deep 1299 AED. VIP 1499 AED.',
      );
      expect(stitched?.priceMin, 199);
      expect(stitched?.priceMax, 199);
      final cityRange = parsePriceText(
        'Promo 199 AED. The chemical peel cost Dubai ranges from 399 AED '
        'to 1299 AED, depending on the number of sessions. VIP 1499 AED.',
      );
      expect(cityRange?.priceMin, 399);
      expect(cityRange?.priceMax, 1299);
      expect(cityRange?.priceMax, isNot(1499));
      expect(parsePriceText('AED 750 to AED 1,800')?.priceMin, 750);
      expect(parsePriceText('AED 750 to AED 1,800')?.priceMax, 1800);
    });

    test('SKIN111 brand digits are not a price', () {
      expect(
        parsePriceText(
          'At SKIN111 the price for Juvéderm fillers starts from AED 1500 per ml',
        )?.priceMin,
        1500,
      );
      expect(
        parsePriceText(
          'At SKIN 111 the price for Juvéderm fillers starts from AED 1500 per ml',
        )?.priceMin,
        1500,
      );
      expect(
        parsePriceText(
          'At SKIN 111 the price for Juvéderm fillers starts from per ml',
        ),
        isNull,
      );
      expect(parsePriceText('Cost: 500 AED to 1000 AED')?.priceMin, 500);
      expect(parsePriceText('Cost: 500 AED to 1000 AED')?.priceMax, 1000);
    });
  });

  group('HTML extractor regression', () {
    test('A — Spanish filler table', () {
      const html = '''
        <table><tr>
          <td>Aumento de labios</td>
          <td>150 €</td>
        </tr></table>
      ''';
      final rows = extractPriceEvidence(
        html: html,
        sourceUrl: 'https://clinicasermedbcn.com/precios',
      );
      final picked = selectEvidenceForProcedure(
        rows: rows,
        procedure: 'lip filler',
      );
      expect(picked, isNotNull);
      expect(picked!.procedureCanonical, 'lip_filler');
      expect(picked.priceMin, 150);
      expect(picked.currency, 'EUR');
      expect(picked.extractionMethod, PriceExtractionMethod.htmlTable);
    });

    test('A2 — Dubai AED botox table is extracted', () {
      const html = '''
        <table><tr>
          <td>Botox anti-wrinkle injection</td>
          <td>499 AED</td>
        </tr></table>
      ''';
      final rows = extractPriceEvidence(
        html: html,
        sourceUrl: 'https://biolitedubai.com/botox',
      );
      final picked = selectEvidenceForProcedure(
        rows: rows,
        procedure: 'Botox anti-wrinkle injection',
      );
      expect(picked, isNotNull);
      expect(picked!.priceMin, 499);
      expect(picked.currency, 'AED');
    });

    test('A3 — Arabic Dubai menu rows are extracted in dirhams', () {
      const html = '''
        <table>
          <tr><td>فيلر الشفاه 1 مل</td><td>1500 درهم</td></tr>
          <tr><td>زراعة الشعر بتقنية القص</td><td>12000 درهم</td></tr>
        </table>
      ''';
      final rows = extractPriceEvidence(
        html: html,
        sourceUrl: 'https://biolitedubai.com/ar/prices',
      );
      final filler = selectEvidenceForProcedure(
        rows: rows,
        procedure: 'dermal filler lips cheeks',
      );
      expect(filler, isNotNull);
      expect(filler!.priceMin, 1500);
      expect(filler.currency, 'AED');

      final hair = selectEvidenceForProcedure(
        rows: rows,
        procedure: 'hair transplant FUE',
      );
      expect(hair, isNotNull);
      expect(hair!.priceMin, 12000);
      expect(hair.currency, 'AED');
    });

    test('A3b — Dubai Google-style clinic copy is a menu row, not a snippet', () {
      expect(
        isNonLiteralClinicPriceUrl(
          'https://www.royalclinicdubai.com/en-ae/botox-injection-cost-in-dubai/',
        ),
        isFalse,
      );
      expect(
        isNonLiteralClinicPriceUrl(
          'https://tajmeels.ae/rhinoplasty-cost-in-dubai/',
        ),
        isFalse,
      );
      expect(
        isNonLiteralClinicPriceUrl('https://houseofbratz.com/prices/'),
        isFalse,
      );
      expect(
        isNonLiteralClinicPriceUrl(
          'https://www.biolitedubai.com/botox-injections-in-dubai-how-long-do-results-last/',
        ),
        isTrue,
      );

      const html = '''
        <p>At Novomed, Botox prices start from approximately AED 1,500 per area.</p>
        <li>Prices Botox Treatment - Gummy smile 350 AED</li>
        <li>Botox (3 Areas), 1200 AED</li>
      ''';
      final rows = extractPriceEvidence(
        html: html,
        sourceUrl: 'https://novomed.com/services/cosmetic-dermatology/botox/',
      );
      final picked = selectEvidenceForProcedure(
        rows: rows,
        procedure: 'Botox anti-wrinkle injection',
      );
      expect(picked, isNotNull);
      expect(picked!.currency, 'AED');
      expect(picked.priceMin, anyOf(350, 1200, 1500));
    });

    test('A4 — clinic articles keep single amounts, drop brand ranges', () {
      const url =
          'https://www.edenderma.com/post/best-botox-in-dubai-reviews-and-prices-2025';
      expect(looksLikeClinicArticlePriceUrl(url), isTrue);
      expect(
        looksLikeClinicArticlePriceUrl('https://edenderma.com/prices'),
        isFalse,
      );

      const ranges = '''
        <table>
          <tr><td>Allergan Botox</td><td>AED 1,000 to AED 2,500 per area</td></tr>
          <tr><td>Botulax Botox: AED 750 to AED 1,800 per area</td><td>750 AED</td></tr>
        </table>
      ''';
      expect(
        selectEvidenceForProcedure(
          rows: extractPriceEvidence(html: ranges, sourceUrl: url),
          procedure: 'Botox anti-wrinkle injection',
        ),
        isNull,
      );

      const single = '''
        <table><tr>
          <td>Botox one area</td><td>from 999 AED</td>
        </tr></table>
      ''';
      final picked = selectEvidenceForProcedure(
        rows: extractPriceEvidence(html: single, sourceUrl: url),
        procedure: 'Botox anti-wrinkle injection',
      );
      expect(picked, isNotNull);
      expect(picked!.priceMin, 999);
    });

    test('B — Lip Lift must not become filler', () {
      const html = '''
        <div class="service">
          <h2>Lip Lift Barcelona</h2>
          <div class="price">1.600 €</div>
        </div>
      ''';
      final rows = extractPriceEvidence(
        html: html,
        sourceUrl: 'https://example.com/lift',
      );
      final picked = selectEvidenceForProcedure(
        rows: rows,
        procedure: 'lip filler',
      );
      expect(picked, isNull);
      final match = matchRawProcedureLabel(
        'Lip Lift Barcelona',
        requestedProcedure: 'lip filler',
      );
      expect(match.rejectReason, 'wrong_family_lip_lift');
    });

    test('C — WooCommerce sale uses ins as active price', () {
      const html = '''
        <h1>Aumento de labios</h1>
        <p class="price">
          <del>391 €</del>
          <ins>299 €</ins>
        </p>
      ''';
      final rows = extractPriceEvidence(
        html: html,
        sourceUrl: 'https://tienda.clinicalondres.es/aumento',
      );
      expect(rows, isNotEmpty);
      final sale = rows.firstWhere(
        (r) => r.priceType == PriceType.sale || r.priceMin == 299,
      );
      expect(sale.priceMin, 299);
      // Live FROM amount only — struck-through "was" must not widen priceMax.
      expect(sale.priceMax, 299);
      expect(sale.priceType, PriceType.sale);
      expect(sale.rawPriceText.toLowerCase(), isNot(contains('was')));
    });

    test('C2 — WooCommerce Sale! badge never becomes procedure; prefer current price', () {
      const html = '''
        <div class="title"><h2><span>Breast Augmentation</span></h2></div>
        <span class="onsale">Sale!</span>
        <div class="summary entry-summary">
          <p class="price">
            <del aria-hidden="true"><span class="woocommerce-Price-amount amount"><bdi>25,999.00&nbsp;<span class="woocommerce-Price-currencySymbol">AED</span></bdi></span></del>
            <span class="screen-reader-text">Original price was: 25,999.00 AED.</span>
            <ins aria-hidden="true"><span class="woocommerce-Price-amount amount"><bdi>12,999.00&nbsp;<span class="woocommerce-Price-currencySymbol">AED</span></bdi></span></ins>
            <span class="screen-reader-text">Current price is: 12,999.00 AED.</span>
          </p>
        </div>
      ''';
      final rows = extractPriceEvidence(
        html: html,
        sourceUrl:
            'https://ziamedicalcenter.com/product/breast-augmentation-boob-job-dubai/',
      );
      expect(
        rows.any((r) => r.rawProcedureText.toLowerCase().contains('sale')),
        isFalse,
      );
      expect(rows.any((r) => r.priceMin == 25999), isFalse);
      final picked = selectEvidenceForProcedure(
        rows: rows,
        procedure: 'breast augmentation',
      );
      expect(picked, isNotNull);
      expect(picked!.priceMin, 12999);
      expect(
        picked.rawProcedureText.toLowerCase(),
        contains('breast'),
      );
    });

    test('D — JSON-LD botox', () {
      const html = '''
        <script type="application/ld+json">
        {
          "@type": "Service",
          "name": "Toxina botulínica 1 zona",
          "offers": {
            "@type": "Offer",
            "price": "250",
            "priceCurrency": "EUR"
          }
        }
        </script>
      ''';
      final rows = extractPriceEvidence(
        html: html,
        sourceUrl: 'https://clinic.example/botox',
      );
      final picked = selectEvidenceForProcedure(
        rows: rows,
        procedure: 'Botox',
      );
      expect(picked, isNotNull);
      expect(picked!.procedureFamily, 'botox');
      expect(picked.priceMin, 250);
      expect(picked.currency, 'EUR');
      expect(picked.extractionMethod, PriceExtractionMethod.jsonLd);
    });

    test('E — number elsewhere on page is not Botox', () {
      const html = '''
        <div>
          <h2>Botox</h2>
          <p>Contact us for price</p>
        </div>
        <div>
          <h2>Laser treatment</h2>
          <p>150 €</p>
        </div>
      ''';
      final rows = extractPriceEvidence(
        html: html,
        sourceUrl: 'https://clinic.example/menu',
      );
      final picked = selectEvidenceForProcedure(
        rows: rows,
        procedure: 'Botox',
      );
      expect(picked, isNull);
    });

    test('F — consultation is not the filler price', () {
      const html = '''
        <div class="service">
          <h2>Consulta inicial</h2>
          <span>50 €</span>
        </div>
        <div class="service">
          <h2>Aumento de labios</h2>
          <span>350 €</span>
        </div>
      ''';
      final rows = extractPriceEvidence(
        html: html,
        sourceUrl: 'https://clinicamedicoesteticadimar.es/precios',
      );
      final picked = selectEvidenceForProcedure(
        rows: rows,
        procedure: 'Fillers',
      );
      expect(picked, isNotNull);
      expect(picked!.priceMin, 350);
      expect(picked.priceMin, isNot(50));
    });

    test('G — invalid clinic title', () {
      expect(isInvalidClinicIdentity('hasta un 70% dto.'), isTrue);
      expect(isInvalidClinicIdentity('Clínica Sermed'), isFalse);
    });

    test('H — AI cannot mutate parsed price', () {
      const evidence = ExtractedPriceEvidence(
        rawProcedureText: 'Aumento de labios',
        rawPriceText: '350 €',
        priceMin: 350,
        priceMax: 350,
        currency: 'EUR',
        sourceUrl: 'https://clinic.example/filler',
        extractionMethod: PriceExtractionMethod.htmlTable,
        rawEvidence: 'Aumento de labios 350 €',
        confidence: 0.97,
      );
      final merged = applyLabelClassification(
        evidence: evidence,
        aiJson: const {
          'family': 'filler',
          'price': 999,
        },
      );
      expect(merged.priceMin, 350);
      expect(merged.procedureFamily, 'filler');
    });

    test('I — De Felipe HA 1 vial beats rhinomodelación for Fillers', () {
      const html = '''
        <h3>Ácido hialurónico</h3>
        <ul>
          <li>1 vial <span>305€</span></li>
          <li>2 viales <span>550€</span></li>
          <li>Rinomodelación con ácido hialurónico 1 vial <span>405€</span></li>
        </ul>
      ''';
      final rows = extractPriceEvidence(
        html: html,
        sourceUrl: 'https://www.defelipe.com/precios/',
      );
      final picked = selectEvidenceForProcedure(
        rows: rows,
        procedure: 'Fillers',
      );
      expect(picked, isNotNull);
      expect(picked!.priceMin, 305);
      expect(
        matchRawProcedureLabel(
          'Rinomodelación con ácido hialurónico 1 vial',
          requestedProcedure: 'Fillers',
        ).rejectReason,
        'wrong_family_rhinomodeling',
      );
    });

    test('J — Sermed lip augmentation min is 180, not Radiesse 250', () {
      const html = '''
        <div class="service"><h2>AUMENTO DE LABIOS</h2><span>Desde 180 €</span></div>
        <div class="service"><h2>AUMENTO DE LABIOS: OFERTA ACTUAL</h2><span>Desde 150 €</span></div>
        <div class="service"><h2>RADIESSE</h2><span>Desde 250 €</span></div>
        <div class="service"><h2>RELLENO DE POMULOS</h2><span>Desde 180 €</span></div>
      ''';
      final rows = extractPriceEvidence(
        html: html,
        sourceUrl: 'https://www.clinicasermedbcn.com/book-online',
      );
      final picked = selectEvidenceForProcedure(
        rows: rows,
        procedure: 'Fillers',
      );
      expect(picked, isNotNull);
      expect(picked!.priceMin, 180);
      expect(picked.procedureCanonical, 'lip_filler');
    });

    test('K — Clínica Londres sale is 299, not rounded to 300', () {
      const html = '''
        <h1>Aumento de labios, 1 vial</h1>
        <p class="price">
          <del>332,22 €</del>
          <ins>299 €</ins>
        </p>
      ''';
      final rows = extractPriceEvidence(
        html: html,
        sourceUrl:
            'https://tienda.clinicalondres.es/barcelona-bonanova/productos-rebajados',
      );
      final picked = selectEvidenceForProcedure(
        rows: rows,
        procedure: 'Fillers',
      );
      expect(picked, isNotNull);
      expect(picked!.priceMin, 299);
    });

    test('L — Santé cost-guide blog is not official menu evidence', () {
      expect(
        isNonLiteralClinicPriceUrl(
          'https://santeclinics.com/blog/laser-treatment-cost-barcelona',
        ),
        isTrue,
      );
      expect(
        classifyPriceSourceType(
          'https://santeclinics.com/blog/laser-treatment-cost-barcelona',
        ),
        PriceSourceType.searchSnippet,
      );
        expect(
        isNonLiteralClinicPriceUrl('https://www.defelipe.com/precios/'),
        isFalse,
      );
      expect(
        isNonLiteralClinicPriceUrl(
          'https://clinicapogany.ro/articole/pret-rinoplastie-bucuresti-cat-costa',
        ),
        isTrue,
      );
      expect(
        isNonLiteralClinicPriceUrl(
          'https://clinicaark.ro/preturi/preturi_rinoplastie',
        ),
        isFalse,
      );
    });

    test('M — Santé treatments page lip filler is 400, not blog 300 or Botox 350',
        () {
      const html = '''
        <div class="service"><h2>Expression Lines</h2><span>350€</span></div>
        <div class="service"><h2>Lip Augmentation and Hydration</h2><span>400€</span></div>
        <div class="service"><h2>Rhinomodeling</h2><span>400€</span></div>
      ''';
      final rows = extractPriceEvidence(
        html: html,
        sourceUrl: 'https://santeclinics.com/treatments',
      );
      final picked = selectEvidenceForProcedure(
        rows: rows,
        procedure: 'Fillers',
      );
      expect(picked, isNotNull);
      expect(picked!.priceMin, 400);
      expect(picked.rawProcedureText.toLowerCase(), contains('lip'));
    });

    test('N — BePerfect lip filler is Juvederm 1900, not JSON-LD 600–5200', () {
      const html = '''
        <script type="application/ld+json">
        {
          "@type": "Service",
          "name": "Marire buze cu acid hialuronic",
          "offers": {
            "@type": "AggregateOffer",
            "lowPrice": "600",
            "highPrice": "5200",
            "priceCurrency": "RON"
          }
        }
        </script>
        <table>
          <tr><td>Acid Hialuronic – Juvederm 1 ml (buze, pomeți, jaw line)</td><td>1.900 RON</td></tr>
          <tr><td>Full face Acid Hialuronic – Juvederm 4 ml</td><td>5.200 RON</td></tr>
          <tr><td>Acid hialuronic 1 ml</td><td>1.500 RON</td></tr>
          <tr><td>Hialuronidază (Topirea acidului hialuronic inestetic)</td><td>600 RON</td></tr>
        </table>
      ''';
      final rows = extractPriceEvidence(
        html: html,
        sourceUrl: 'https://beperfect.ro/servicii/marire-buze/',
      );
      final picked = selectEvidenceForProcedure(
        rows: rows,
        procedure: 'dermal filler lips cheeks',
      );
      expect(picked, isNotNull);
      expect(picked!.priceMin, 1900);
      expect(picked.procedureCanonical, 'lip_filler');
      expect(
        matchRawProcedureLabel(
          'Hialuronidază (Topirea acidului hialuronic inestetic)',
          requestedProcedure: 'Fillers',
        ).rejectReason,
        'wrong_family_hyaluronidase',
      );
      expect(
        exploreCachedPriceNeedsReselect(
          rawProcedureText: 'Marire buze cu acid hialuronic',
          brand: 'Lip filler',
          sourceUrl: 'https://beperfect.ro/servicii/marire-buze/',
          procedure: 'Fillers',
          rawPriceText: '600–5200 RON',
          priceMin: 600,
          priceMax: 5200,
        ),
        isTrue,
      );
    });

    test('O — BePerfect Botox 1-zone is 900, not hyaluronidase 600', () {
      const html = '''
        <script type="application/ld+json">
        {
          "@type": "Service",
          "name": "Toxina botulinică",
          "offers": {
            "@type": "AggregateOffer",
            "lowPrice": "600",
            "highPrice": "5200",
            "priceCurrency": "RON"
          }
        }
        </script>
        <table>
          <tr><td>Hialuronidază (Topirea acidului hialuronic inestetic)</td><td>600 RON</td></tr>
          <tr><td>Periocular (coada ochiului/laba gâștii)</td><td>900 RON</td></tr>
          <tr><td>Glabelar (între sprâncene)</td><td>900 RON</td></tr>
          <tr><td>2 Zone:</td><td>1.400 RON</td></tr>
          <tr><td>Toate cele 3 Zone: Periocular + Glabelar + Frontal</td><td>1.900 RON</td></tr>
        </table>
      ''';
      final rows = extractPriceEvidence(
        html: html,
        sourceUrl: 'https://beperfect.ro/tarife/',
      );
      final picked = selectEvidenceForProcedure(
        rows: rows,
        procedure: 'Botox',
      );
      expect(picked, isNotNull);
      expect(picked!.priceMin, 900);
      expect(picked.procedureFamily, 'botox');
    });

    test('P — Dr. Estetix Botox 1 zonă is 800, not lip filler 750', () {
      const html = '''
        <table>
          <tr><td>Tratament toxină botulinică 1 zonă</td><td>800 RON</td></tr>
          <tr><td>Tratament toxină botulinică 2 zone</td><td>1300 RON</td></tr>
          <tr><td>Tratament toxină botulinică 3 zone</td><td>1550 RON</td></tr>
          <tr><td>Baby Botox 3 zone</td><td>1050 RON</td></tr>
          <tr><td>Skin Aura / Elasty 0.5 ml</td><td>750 RON</td></tr>
          <tr><td>Juvederm Ultra 1 ml</td><td>1600 RON</td></tr>
        </table>
      ''';
      final rows = extractPriceEvidence(
        html: html,
        sourceUrl: 'https://drestetix.ro/pages/preturi-injectari',
      );
      final picked = selectEvidenceForProcedure(
        rows: rows,
        procedure: 'Botox',
      );
      expect(picked, isNotNull);
      expect(picked!.priceMin, 800);
      expect(picked.procedureFamily, 'botox');
      final filler = selectEvidenceForProcedure(
        rows: rows,
        procedure: 'Fillers',
      );
      expect(filler, isNotNull);
      expect(filler!.procedureFamily, 'filler');
      expect(filler.priceMin, isNot(800));
    });

    test('Q — Doctor SKiN Botox is 1-zone wrinkle, not laser 429 or gummy 546',
        () {
      const html = '''
        <table>
          <tr><td>Cheratoze actinice [zonă mică]</td><td>429 lei</td></tr>
          <tr><td>Corectarea zâmbetului gingival cu neuromodulator</td><td>546 lei</td></tr>
          <tr><td>Corectie riduri frunte toxina botulinica 1 zona</td><td>390 lei</td></tr>
          <tr><td>Corecție riduri 3 zone</td><td>1190 lei</td></tr>
        </table>
      ''';
      final rows = extractPriceEvidence(
        html: html,
        sourceUrl:
            'https://doctorskin.ro/estetica-medicala/eliminare-riduri-neuromodulator/',
      );
      final picked = selectEvidenceForProcedure(
        rows: rows,
        procedure: 'Botox',
      );
      expect(picked, isNotNull);
      expect(picked!.priceMin, 390);
      expect(picked.procedureFamily, 'botox');
      expect(
        matchRawProcedureLabel(
          'Cheratoze actinice [zonă mică]',
          requestedProcedure: 'Botox',
        ).rejectReason,
        'wrong_family_laser',
      );
      expect(
        matchRawProcedureLabel(
          'Polinucleotide periocular',
          requestedProcedure: 'Botox',
        ).rejectReason,
        'wrong_family_biostim',
      );
      expect(
        exploreCachedPriceNeedsReselect(
          rawProcedureText: 'Cheratoze actinice [zonă mică]',
          brand: 'Botox treatment',
          sourceUrl:
              'https://doctorskin.ro/dermatologie/laser-thulium-lasemd-lutronic/',
          procedure: 'Botox anti-wrinkle injection',
          rawPriceText: '429 lei',
          priceMin: 430,
          priceMax: 430,
        ),
        isTrue,
      );
      expect(
        exploreCachedPriceNeedsReselect(
          rawProcedureText: 'botox',
          brand: 'Botox treatment',
          sourceUrl: 'https://mediclinic.ae/botox',
          procedure: 'Botox anti-wrinkle injection',
          rawPriceText: '999 AED',
          priceMin: 999,
          priceMax: 999,
        ),
        isTrue,
      );
      expect(
        isNonLiteralClinicPriceUrl(
          'https://www.mediclinic.ae/en/airport-road-hospital/emergency.html',
        ),
        isTrue,
      );
    });

    test('R — price menu probes are generic by TLD, not per clinic', () {
      expect(
        explorePriceMenuProbeUrls('any-clinic.ro'),
        containsAll([
          'https://any-clinic.ro/preturi',
          'https://any-clinic.ro/pages/preturi-injectari',
        ]),
      );
      expect(
        explorePriceMenuProbeUrls('drestetix.ro'),
        contains('https://drestetix.ro/pages/preturi-injectari'),
      );
      expect(
        explorePriceMenuProbeUrls('clinica.es'),
        contains('https://clinica.es/precios'),
      );
      expect(
        explorePriceMenuProbeUrls('clinique.fr'),
        contains('https://clinique.fr/tarifs'),
      );
      expect(
        explorePriceMenuProbeUrls('clinic.co.uk'),
        contains('https://clinic.co.uk/prices'),
      );
      expect(looksLikePriceMenuUrl('https://x.ro/preturi'), isTrue);
      expect(
        looksLikePriceMenuUrl('https://x.ro/marire-sani-cu-implant-mamar/'),
        isFalse,
      );
    });

    test('S — JSON-LD catalog span is dropped; HTML surgery range is kept', () {
      const jsonLd = ExtractedPriceEvidence(
        rawProcedureText: 'Servicii',
        rawPriceText: '600–5200 RON',
        priceMin: 600,
        priceMax: 5200,
        currency: 'RON',
        sourceUrl: 'https://beperfect.ro/tarife/',
        extractionMethod: PriceExtractionMethod.jsonLd,
        rawEvidence: '600-5200',
        confidence: 0.4,
      );
      const table = ExtractedPriceEvidence(
        rawProcedureText: 'Implant de par FUE + Sapphire',
        rawPriceText: '1800 – 3500€',
        priceMin: 1800,
        priceMax: 3500,
        currency: 'EUR',
        sourceUrl: 'https://clinicabarbatilor.ro/transplant-de-par',
        extractionMethod: PriceExtractionMethod.htmlTable,
        rawEvidence: 'FUE 1800-3500',
        confidence: 0.9,
      );
      expect(
        explorePriceLooksLikeCatalogAggregate(
          rawPriceText: jsonLd.rawPriceText,
          priceMin: jsonLd.priceMin,
          priceMax: jsonLd.priceMax,
        ),
        isTrue,
      );
      expect(
        explorePriceLooksLikeCatalogAggregate(
          rawPriceText: table.rawPriceText,
          priceMin: table.priceMin,
          priceMax: table.priceMax,
        ),
        isFalse,
      );
      final picked = selectEvidenceForProcedure(
        rows: [jsonLd, table],
        procedure: 'hair transplant FUE',
      );
      expect(picked, isNotNull);
      expect(picked!.priceMin, 1800);
      expect(picked.priceMax, 3500);
      expect(picked.extractionMethod, PriceExtractionMethod.htmlTable);
    });

    test('T — breast HTML rows match Romanian menu labels', () {
      const row = ExtractedPriceEvidence(
        rawProcedureText: 'Mărire de sâni cu implant mamar',
        rawPriceText: '4.200 €',
        priceMin: 4200,
        priceMax: 4200,
        currency: 'EUR',
        sourceUrl: 'https://www.elenamartin.ro/preturi',
        extractionMethod: PriceExtractionMethod.htmlTable,
        rawEvidence: 'Marire de sani 4200',
        confidence: 0.9,
      );
      final picked = selectEvidenceForProcedure(
        rows: [row],
        procedure: 'breast augmentation',
      );
      expect(picked, isNotNull);
      expect(picked!.priceMin, 4200);
    });

    test('U — scalp hair row beats beard when both match', () {
      const beard = ExtractedPriceEvidence(
        rawProcedureText: 'Interventie chirurgicala Transplant de par · Barba de la',
        rawPriceText: '2.000 €',
        priceMin: 2000,
        priceMax: 2000,
        currency: 'EUR',
        sourceUrl: 'https://eloshairclinic.ro/preturi',
        extractionMethod: PriceExtractionMethod.htmlTable,
        rawEvidence: 'barba 2000',
        confidence: 0.9,
      );
      const scalp = ExtractedPriceEvidence(
        rawProcedureText: 'Interventie chirurgicala Transplant de par · Scalp de la',
        rawPriceText: '2.500 €',
        priceMin: 2500,
        priceMax: 2500,
        currency: 'EUR',
        sourceUrl: 'https://eloshairclinic.ro/preturi',
        extractionMethod: PriceExtractionMethod.htmlTable,
        rawEvidence: 'scalp 2500',
        confidence: 0.9,
      );
      final picked = selectEvidenceForProcedure(
        rows: [beard, scalp],
        procedure: 'hair transplant FUE',
      );
      expect(picked, isNotNull);
      expect(picked!.priceMin, 2500);
    });

    test('V — Elena Martin dual EUR (lei) is 7000 EUR, not 35000 RON', () {
      const html = '''
        <table><tr>
          <td>Implant mamar</td>
          <td>de la 7000€ (35000 lei)</td>
        </tr></table>
      ''';
      final rows = extractPriceEvidence(
        html: html,
        sourceUrl: 'https://www.elenamartin.ro/preturi',
      );
      final picked = selectEvidenceForProcedure(
        rows: rows,
        procedure: 'breast augmentation',
      );
      expect(picked, isNotNull);
      expect(picked!.priceMin, 7000);
      expect(picked.currency, 'EUR');
    });

    test('W — Panturu EUR-column bare amount is 5500 EUR', () {
      const html = '''
        <h4>Marirea sanilor (Implant Siliconic Mamar):</h4>
        <table>
          <tr><th>Procedura chirurgicala</th><th>Preturi (EUR)</th></tr>
          <tr>
            <td>– Rotund Mentor / Polytech / Motiva</td>
            <td>5,500</td>
          </tr>
        </table>
      ''';
      final rows = extractPriceEvidence(
        html: html,
        sourceUrl:
            'https://www.drpanturu.ro/preturi-servicii-chirurgicale-si-non-chirurgicale/',
      );
      final picked = selectEvidenceForProcedure(
        rows: rows,
        procedure: 'breast augmentation',
      );
      expect(picked, isNotNull);
      expect(picked!.priceMin, 5500);
      expect(picked.currency, 'EUR');
    });

    test('X — Radu Ionescu heading range is 8100–9300 EUR', () {
      const html = '''
        <h4>Augmentare mamară: între 8100–9300 euro</h4>
        <p>Consult medical sân: 900 lei</p>
      ''';
      final rows = extractPriceEvidence(
        html: html,
        sourceUrl: 'https://raduionescu.doctor/preturi.html',
      );
      final picked = selectEvidenceForProcedure(
        rows: rows,
        procedure: 'breast augmentation',
      );
      expect(picked, isNotNull);
      expect(picked!.priceMin, 8100);
      expect(picked.priceMax, 9300);
      expect(picked.currency, 'EUR');
    });

    test('Y — Romanian starting-from rhinoplasty quotes extract on official pages',
        () {
      const ark = '''
        <p>Pretul pentru operatia de rinoplastie porneste de la 2500 euro,
        in functie de amploarea interventiei si tipul de anestezie practicat.</p>
      ''';
      final arkRows = extractPriceEvidence(
        html: ark,
        sourceUrl: 'https://clinicaark.ro/preturi/preturi_rinoplastie',
      );
      final arkPicked = selectEvidenceForProcedure(
        rows: arkRows,
        procedure: 'rhinoplasty nose job',
      );
      expect(arkPicked, isNotNull);
      expect(arkPicked!.priceMin, 2500);
      expect(arkPicked.currency, 'EUR');

      const diana = '''
        <title>Rinoplastie București — Preț Operație Nas de la 5.000€</title>
        <h1>Rinoplastie în București cu rezultate naturale, de la 5.000€</h1>
      ''';
      final dianaRows = extractPriceEvidence(
        html: diana,
        sourceUrl: 'https://drdiana.ro/chirurgia-fetei/rinoplastie',
      );
      final dianaPicked = selectEvidenceForProcedure(
        rows: dianaRows,
        procedure: 'rhinoplasty nose job',
      );
      expect(dianaPicked, isNotNull);
      expect(dianaPicked!.priceMin, 5000);
      expect(dianaPicked.currency, 'EUR');
    });

    test('Z — Bucharest market-average blog copy is not a clinic menu', () {
      const html = '''
        <p>În general, costul unei rinoplastii în București începe de la
        aproximativ 3000-4000 de euro și poate ajunge la 6000 de euro.</p>
      ''';
      final rows = extractPriceEvidence(
        html: html,
        sourceUrl:
            'https://clinicapogany.ro/articole/pret-rinoplastie-bucuresti-cat-costa',
      );
      expect(rows, isEmpty);
    });

    test('AA — Latin-1 HTTP body of UTF-8 Romanian heading is repaired', () {
      const text = 'Augmentare mamară: între 8100–9300 euro';
      final bytes = utf8.encode(text);
      expect(
        decodeHtmlHttpBody(bodyBytes: bytes, contentType: 'text/html'),
        text,
      );
      final mojibake = latin1.decode(bytes);
      expect(looksLikeUtf8Mojibake(mojibake), isTrue);
      expect(repairUtf8Mojibake(mojibake), text);

      const html = '<h4>$text</h4>';
      final garbledHtml = latin1.decode(utf8.encode(html));
      final rows = extractPriceEvidence(
        html: garbledHtml,
        sourceUrl: 'https://raduionescu.doctor/preturi.html',
      );
      final picked = selectEvidenceForProcedure(
        rows: rows,
        procedure: 'breast augmentation',
      );
      expect(picked, isNotNull);
      expect(picked!.priceMin, 8100);
      expect(picked.priceMax, 9300);
      expect(picked.rawProcedureText.toLowerCase(), contains('augmentare'));
      expect(picked.rawProcedureText, isNot(contains('Ã')));
      expect(picked.rawPriceText.toLowerCase(), contains('8100'));
      expect(picked.rawPriceText.length, lessThan(40));
    });

    test('AB — QSH FAQ keeps hospital range, not Dubai typical', () {
      const html = '''
        <h2>How much does rhinoplasty cost in Dubai?</h2>
        <p>Rhinoplasty costs in Dubai typically range from AED 27,299 to
        AED 50,000, depending on factors like the surgeon’s expertise and
        the complexity of the surgery. At Quttainah Specialized Hospital,
        the price usually ranges from AED 22000 to AED 40,000.</p>
        <p>On average, the price of rhinoplasty ranges from AED 23,299 to
        AED 30,000.</p>
      ''';
      final rows = extractPriceEvidence(
        html: html,
        sourceUrl: 'https://qsh-dubai.com/rhinoplasty-price-in-dubai/',
      );
      final picked = selectEvidenceForProcedure(
        rows: rows,
        procedure: 'rhinoplasty nose job',
      );
      expect(picked, isNotNull);
      expect(picked!.priceMin, 22000);
      expect(picked.priceMax, 40000);
      expect(picked.priceMin, isNot(27299));
      expect(picked.priceMin, isNot(23299));
    });

    test('AC — hair table prefers AED/graft over graft count', () {
      const html = '''
        <h3>FUE Hair Transplant Cost in Dubai (Per Graft)</h3>
        <table>
          <tr>
            <td>Receding hairline or mild-to-moderate hair loss.</td>
            <td>1,000 grafts</td>
            <td>8 AED per graft</td>
          </tr>
          <tr>
            <td>زراعة الشعر بتقنية DHI</td>
            <td>6,999 – 11,999 AED</td>
          </tr>
        </table>
      ''';
      final rows = extractPriceEvidence(
        html: html,
        sourceUrl: 'https://www.glamorousdubai.ae/fue',
      );
      final perGraft = selectEvidenceForProcedure(
        rows: rows,
        procedure: 'hair transplant FUE',
      );
      expect(perGraft, isNotNull);
      expect(perGraft!.priceMin, 8);
      expect(perGraft.priceMin, isNot(1000));
      expect(perGraft.currency, 'AED');
    });

    test('AA — market peel FAQ is rejected; owned menu row wins', () {
      const faq =
          'The chemical peel cost Dubai ranges from 399 AED to 1299 AED, '
          'depending on the number of sessions required, the condition of '
          'the patient. Promo 199 AED. VIP 1499 AED.';
      expect(looksLikeMarketAveragePriceBlurb(faq), isTrue);
      expect(
        clinicOwnPublishedPriceWindow(faq),
        contains('399'),
      );
      expect(
        clinicOwnPublishedPriceWindow(faq),
        contains('1299'),
      );

      const faqOnly = '<p>$faq</p>';
      final faqRows = extractPriceEvidence(
        html: faqOnly,
        sourceUrl: 'https://tajmeels.ae/chemical-peels-in-dubai/',
      );
      final faqPicked = selectEvidenceForProcedure(
        rows: faqRows,
        procedure: 'chemical peel',
      );
      expect(faqPicked, isNull, reason: 'A city-market FAQ does not own its prices');

      const html = '''
        <p>$faq</p>
        <table>
          <tr>
            <td>Our peel treatment — Glycolic chemical peel</td>
            <td>399 AED</td>
          </tr>
        </table>
      ''';
      final rows = extractPriceEvidence(
        html: html,
        sourceUrl: 'https://tajmeels.ae/chemical-peels-in-dubai/',
      );
      final picked = selectEvidenceForProcedure(
        rows: rows,
        procedure: 'chemical peel',
      );
      expect(picked, isNotNull);
      expect(picked!.priceMin, 399);
      expect(picked.priceMax, 399);
      expect(picked.currency, 'AED');
      expect(picked.extractionMethod, PriceExtractionMethod.htmlTable);
    });

    test('AD — city marketing is rejected; clinic tariff ranges stay exact', () {
      const rhino = '''
        <p>The nose job cost Dubai ranges from 12999 AED to 19999 AED,
        depending on several factors that affect the overall cost.</p>
      ''';
      final rhinoPicked = selectEvidenceForProcedure(
        rows: extractPriceEvidence(
          html: rhino,
          sourceUrl: 'https://tajmeels.ae/rhinoplasty-cost-in-dubai/',
        ),
        procedure: 'rhinoplasty',
      );
      expect(rhinoPicked, isNull);

      const hair = '''
        <p>The Hair transplant price UAE ranges from 4,999 AED to 29,999 AED,
        depending on the number of grafts.</p>
      ''';
      final hairPicked = selectEvidenceForProcedure(
        rows: extractPriceEvidence(
          html: hair,
          sourceUrl: 'https://tajmeels.ae/hair-transplant-in-dubai/',
        ),
        procedure: 'hair transplant FUE',
      );
      expect(hairPicked, isNull);

      const tariff = '''
        <h1>Our prices</h1>
        <table>
          <tr><td>Rhinoplasty</td><td>12,999–19,999 AED</td></tr>
          <tr><td>FUE hair transplant</td><td>6,000–8,500 AED</td></tr>
        </table>
      ''';
      final tariffRows = extractPriceEvidence(
        html: tariff,
        sourceUrl: 'https://tajmeels.ae/prices/',
      );
      final ownedRhino = selectEvidenceForProcedure(
        rows: tariffRows,
        procedure: 'rhinoplasty',
      );
      expect(ownedRhino, isNotNull);
      expect(ownedRhino!.priceMin, 12999);
      expect(ownedRhino.priceMax, 19999);
      expect(ownedRhino.currency, 'AED');
      final ownedHair = selectEvidenceForProcedure(
        rows: tariffRows,
        procedure: 'hair transplant FUE',
      );
      expect(ownedHair, isNotNull);
      expect(ownedHair!.priceMin, 6000);
      expect(ownedHair.priceMax, 8500);
      expect(ownedHair.currency, 'AED');
    });

    test('AE — Skin111 starts from AED 490 beats a city typical range', () {
      const html = '''
        <p>Typical chemical peel prices in Dubai range from AED 199 to AED 1,499.</p>
        <p>At SKIN111, our chemical peel treatment starts from AED 490.
        Pricing may vary based on the depth of the peel.</p>
      ''';
      final picked = selectEvidenceForProcedure(
        rows: extractPriceEvidence(
          html: html,
          sourceUrl: 'https://skin111.com/chemical-peel-treatment/',
        ),
        procedure: 'chemical peel',
      );
      expect(picked, isNotNull);
      expect(picked!.priceMin, 490);
      expect(picked.currency, 'AED');
      expect(picked.priceType, PriceType.from);
    });

    test('AF — SEO laser title and gold package are not extracted', () {
      const seo = '''
        <p>Laser Hair Removal Price Abu Dhabi — From AED 100 | Dr Azra.
        Laser hair removal starts at AED 100 per session.</p>
      ''';
      final seoPicked = selectEvidenceForProcedure(
        rows: extractPriceEvidence(
          html: seo,
          sourceUrl: 'https://drazra.com/laser-hair-removal-abu-dhabi/',
        ),
        procedure: 'laser skin treatment hair removal',
      );
      expect(seoPicked, isNull);

      const bundle = '''
        <p>د.إ 999 الباقة الذهبية اختر أي 2 من الخدمات التالية
        ليزر الكربون هايدرا فيشل بوتوكس</p>
      ''';
      final bundlePicked = selectEvidenceForProcedure(
        rows: extractPriceEvidence(
          html: bundle,
          sourceUrl: 'https://clinic.ae/packages',
        ),
        procedure: 'Botox anti-wrinkle injection',
      );
      expect(bundlePicked, isNull);
    });

    test('AG — Tajmeels Quick Facts Cost row is lip filler 500–1000, not peel 399',
        () {
      const html = '''
        <h1>Lip Augmentation Cost in Dubai</h1>
        <h2>Quick Facts:</h2>
        <ul>
          <li><strong>Cost:</strong> 500 AED to 1000 AED</li>
          <li><strong>Target:</strong> Individuals seeking fuller, plumper lips</li>
          <li><strong>Duration of Treatment:</strong> 30 minutes to 1 hour</li>
          <li><strong>Procedure Type:</strong> Non-surgical (dermal fillers)
            or surgical (lip implants)</li>
        </ul>
        <p>The chemical peel cost Dubai ranges from 399 AED to 1299 AED.</p>
        <p>In common, the rate is between 500 AED to 1000 AED. For non-invasive
        and 2500 AED to 5000 AED for surgical implants.</p>
      ''';
      final picked = selectEvidenceForProcedure(
        rows: extractPriceEvidence(
          html: html,
          sourceUrl: 'https://tajmeels.ae/en/lip-augmentation-cost-in-dubai/',
        ),
        procedure: 'dermal filler lips cheeks',
      );
      expect(picked, isNotNull);
      expect(picked!.priceMin, 500);
      expect(picked.priceMax, 1000);
      expect(picked.currency, 'AED');
      expect(picked.priceMin, isNot(399));
      expect(picked.priceMin, isNot(2500));
      expect(
        exploreCachedPriceNeedsReselect(
          rawProcedureText: 'Lip filler',
          brand: 'Lip filler',
          sourceUrl: 'https://tajmeels.ae/chemical-peels-in-dubai/',
          procedure: 'dermal filler lips cheeks',
          rawPriceText: '399 AED',
          rawEvidence: 'The chemical peel cost Dubai ranges from 399 AED',
          priceMin: 399,
          priceMax: 1299,
        ),
        isTrue,
      );
      expect(
        exploreCachedPriceNeedsReselect(
          rawProcedureText: 'Lip filler',
          brand: 'Lip filler',
          sourceUrl: 'https://tajmeels.ae/en/lip-augmentation-cost-in-dubai/',
          procedure: 'dermal filler lips cheeks',
          rawPriceText: 'cost Dubai ranges from 399 AED to 1299 AED',
          rawEvidence: 'cost Dubai ranges from 399 AED to 1299 AED',
          priceMin: 399,
          priceMax: 1299,
        ),
        isTrue,
      );
    });

    test('AH — Skin111 Juvederm is AED 1500 per ml, never brand 111', () {
      const html = '''
        <h1>Juvéderm Fillers in Dubai & Abu Dhabi</h1>
        <p>At SKIN 111 the price for Juvéderm fillers starts from AED 1500 per ml.
        Juvéderm is a dermal filler primarily used to add volume.</p>
      ''';
      final picked = selectEvidenceForProcedure(
        rows: extractPriceEvidence(
          html: html,
          sourceUrl: 'https://skin111.com/juvederm-fillers',
        ),
        procedure: 'dermal filler lips cheeks',
      );
      expect(picked, isNotNull);
      expect(picked!.priceMin, 1500);
      expect(picked.currency, 'AED');
      expect(picked.priceMin, isNot(111));
      expect(
        evaluateExtractedPriceCandidate(
          rawPriceText: '111 AED',
          priceMin: 111,
          currency: 'AED',
          extractionMethod: 'text_proximity',
          rawEvidence:
              'At SKIN 111 the price for Juvéderm fillers starts from per ml',
          procedure: 'dermal filler lips cheeks',
        ).reason,
        'brand_embedded_digits',
      );
      expect(
        exploreCachedPriceNeedsReselect(
          rawProcedureText:
              'At SKIN 111 the price for Juvéderm fillers starts from per ml',
          brand: 'At SKIN 111 the price for Juvéderm fillers starts from per ml',
          sourceUrl: 'https://skin111.com/juvederm-fillers',
          procedure: 'dermal filler lips cheeks',
          rawPriceText: '111 AED',
          priceMin: 111,
        ),
        isTrue,
      );
    });

    test('AH — Enfield laser cost page: published table row wins', () {
      const html = '''
        <h1>Laser Treatments Cost in Abu Dhabi</h1>
        <p>The cost of laser treatment starts as low as 150 AED per session.</p>
        <table>
          <tr><th>Treatment Type</th><th>Cost 1 Session</th></tr>
          <tr><td>Laser For Hair Removal</td><td></td></tr>
          <tr><td>Underarm</td><td>150 AED</td></tr>
          <tr><td>Full Face</td><td>300 AED</td></tr>
          <tr><td>Full Female Body Laser</td><td>500 AED</td></tr>
        </table>
        <h3>Is Laser Tattoo Removal More Expensive?</h3>
        <p>The ink removal takes multiple sessions. Each session can cost you
        between 200 AED and 500 AED for laser tattoo removal.</p>
      ''';
      const url =
          'https://www.enfieldabudhabi.ae/en/laser-treatments-cost-in-abu-dhabi/';
      expect(looksLikeCityCostArticleUrl(url), isTrue);
      expect(isNonLiteralClinicPriceUrl(url), isFalse);
      final picked = selectEvidenceForProcedure(
        rows: extractPriceEvidence(html: html, sourceUrl: url),
        procedure: 'laser skin treatment hair removal',
      );
      expect(picked, isNotNull);
      expect(picked!.extractionMethod, PriceExtractionMethod.htmlTable);
      expect(picked.priceMin, 150);
      expect(picked.currency, 'AED');
      expect(picked.rawProcedureText.toLowerCase(), contains('underarm'));
    });

    test('AH — market prose on a cost page is not a clinic price', () {
      const html = '''
        <h1>Lip Filler Cost in Abu Dhabi</h1>
        <p>Across Abu Dhabi clinics, lip filler treatments generally range from
        AED 1,200 to AED 2,200 per syringe depending on the product used.</p>
      ''';
      final picked = selectEvidenceForProcedure(
        rows: extractPriceEvidence(
          html: html,
          sourceUrl:
              'https://charismamedicalgroup.com/lip-filler-cost-in-abu-dhabi/',
        ),
        procedure: 'dermal filler lips cheeks',
      );
      expect(picked, isNull);
    });

    test('AI — Enfield Botox uses English 799, not Arabic small-area 599', () {
      const arHtml = '''
        <h2>تكلفة حقن البوتوكس في أبو ظبي</h2>
        <table>
          <tr><th>منطقة الحقن</th><th>السعر السابق</th><th>السعر الحالي</th></tr>
          <tr><td>كامل الوجه</td><td>1,200 درهم إماراتي</td>
              <td>699 درهم إماراتي</td></tr>
          <tr><td>مناطق صغيرة</td><td>599 درهم إماراتي</td></tr>
          <tr><td>الحقن في اي منطقة</td><td>699 درهم إماراتي</td></tr>
        </table>
      ''';
      const enHtml = '''
        <h2>Cost of Botox Abu Dhabi</h2>
        <p>Discounted Costs: start from 799 AED</p>
        <p>The average Botox injection Price start from 799 AED.</p>
        <table>
          <tr><th>Botox</th><th>Price Before Discount</th>
              <th>Price After Discount</th></tr>
          <tr><td>Our Botox · Full Face</td><td>1,500 AED</td><td>799 AED</td></tr>
          <tr><td>Small area</td><td>Starting at 799 AED</td></tr>
        </table>
      ''';
      expect(
        exploreEnglishLocaleUrl(
          'https://www.enfieldabudhabi.ae/ar/cosmetic-injectables/botox-injections/',
        ),
        'https://www.enfieldabudhabi.ae/en/cosmetic-injectables/botox-injections/',
      );
      final arOnly = selectEvidenceForProcedure(
        rows: extractPriceEvidence(
          html: arHtml,
          sourceUrl:
              'https://www.enfieldabudhabi.ae/ar/cosmetic-injectables/botox-injections/',
        ),
        procedure: 'Botox anti-wrinkle injection',
      );
      expect(arOnly, isNotNull);
      expect(arOnly!.priceMin, isNot(599));
      expect(arOnly.priceMin, 699);

      final mixed = selectEvidenceForProcedure(
        rows: [
          ...extractPriceEvidence(
            html: arHtml,
            sourceUrl:
                'https://www.enfieldabudhabi.ae/ar/cosmetic-injectables/botox-injections/',
          ),
          ...extractPriceEvidence(
            html: enHtml,
            sourceUrl:
                'https://www.enfieldabudhabi.ae/en/cosmetic-injectables/botox-injections/',
          ),
        ],
        procedure: 'Botox anti-wrinkle injection',
      );
      expect(mixed, isNotNull);
      expect(mixed!.priceMin, 799);
      expect(mixed.currency, 'AED');
      expect(mixed.sourceUrl, contains('/en/'));
    });

    test('AJ — peel URL must not accept GP checkup or Worth promo', () {
      const html = '''
        <h1>Chemical Peel Treatment</h1>
        <table>
          <tr><td>Quick Pricing · GP Checkup</td><td>AED 100</td></tr>
          <tr><td>Dermamelan Chemical Peel</td><td>AED 399</td></tr>
        </table>
        <div class="card">
          <h3>Free Comprehensive Assessment (Worth AED 1,500) Includes:</h3>
          <span class="price">1,500 AED</span>
        </div>
        <p>At SKIN111, our chemical peel treatment starts from AED 490.</p>
      ''';
      final rows = extractPriceEvidence(
        html: html,
        sourceUrl: 'https://skin111.com/chemical-peel',
      );
      final picked = selectEvidenceForProcedure(
        rows: rows,
        procedure: 'chemical peel facial',
      );
      expect(picked, isNotNull);
      expect(picked!.priceMin, 490);
      expect(picked.rawProcedureText.toLowerCase(), isNot(contains('checkup')));
      expect(picked.rawProcedureText.toLowerCase(), isNot(contains('worth')));
    });

    test('AK — city common-price surgery guide is rejected for rhinoplasty', () {
      const commonGuide = '''
        <h1>Plastic Surgery Cost in Dubai</h1>
        <p>Here’s a breakdown of common prices for some famous methods in Dubai:</p>
        <table>
          <tr><th>Treatment Type</th><th>Cost- AED</th></tr>
          <tr><td>Rhinoplasty</td><td>20,000</td></tr>
          <tr><td>Facelift</td><td>36,000</td></tr>
        </table>
      ''';
      final rejected = selectEvidenceForProcedure(
        rows: extractPriceEvidence(
          html: commonGuide,
          sourceUrl: 'https://clinic.example/en/plastic-surgery-cost-in-dubai/',
        ),
        procedure: 'rhinoplasty nose job',
      );
      expect(rejected, isNull);

      const clinicMenu = '''
        <h1>Rhinoplasty</h1>
        <table>
          <tr><td>Primary rhinoplasty</td><td>From AED 28,000</td></tr>
        </table>
      ''';
      final picked = selectEvidenceForProcedure(
        rows: extractPriceEvidence(
          html: clinicMenu,
          sourceUrl: 'https://clinic.example/en/rhinoplasty/',
        ),
        procedure: 'rhinoplasty nose job',
      );
      expect(picked, isNotNull);
      expect(picked!.priceMin, 28000);
      expect(picked.sourceUrl, contains('/rhinoplasty'));
    });

    test('AL — botox prefers per-unit starting price over package', () {
      const html = '''
        <table>
          <tr><td>Botox</td><td>AED 42 / unit</td></tr>
          <tr><td>Full 3-Zone Package</td><td>AED 3,500</td></tr>
        </table>
      ''';
      final picked = selectEvidenceForProcedure(
        rows: extractPriceEvidence(
          html: html,
          sourceUrl: 'https://clinic.example/botox',
        ),
        procedure: 'Botox anti-wrinkle injection',
      );
      expect(picked, isNotNull);
      expect(picked!.priceMin, 42);
      expect(
        picked.priceType == PriceType.perUnit ||
            picked.unit.toLowerCase().contains('unit') ||
            picked.rawPriceText.toLowerCase().contains('unit'),
        isTrue,
      );
    });

    test('AM — market filler range on clinic domain is rejected', () {
      const html = '''
        <h1>Fillers Cost in Dubai</h1>
        <p>The cost of fillers in Dubai can vary significantly, but generally
        falls within a specific range:</p>
        <p>Basic hyaluronic acid fillers: AED 1,000 – AED 2,000 per syringe</p>
        <p>Premium brand fillers: AED 2,000 – AED 3,500 per syringe</p>
      ''';
      final picked = selectEvidenceForProcedure(
        rows: extractPriceEvidence(
          html: html,
          sourceUrl: 'https://clinic.example/fillers-cost-in-dubai/',
        ),
        procedure: 'lip filler',
      );
      expect(picked, isNull);
    });

    test('AN — Skin111-style peel starts from 490; lip from 990', () {
      const peelHtml = '''
        <p>At our clinic, chemical peel treatment starts from AED 490.</p>
      ''';
      final peel = selectEvidenceForProcedure(
        rows: extractPriceEvidence(
          html: peelHtml,
          sourceUrl: 'https://clinic.example/chemical-peel',
        ),
        procedure: 'chemical peel facial',
      );
      expect(peel, isNotNull);
      expect(peel!.priceMin, 490);

      const lipHtml = '''
        <p>Lip fillers start from AED 990.</p>
      ''';
      final lip = selectEvidenceForProcedure(
        rows: extractPriceEvidence(
          html: lipHtml,
          sourceUrl: 'https://clinic.example/fillers',
        ),
        procedure: 'lip filler',
      );
      expect(lip, isNotNull);
      expect(lip!.priceMin, 990);
    });

    test('AO — Premier Laser 1 Area beats Chin Dimpling', () {
      const html = '''
        <h2>Botox Pricing</h2>
        <table>
          <tr><td>Botox 3 Areas</td><td>Price: £999.00</td></tr>
          <tr><td>1 Area</td><td>Price: £175.00</td></tr>
          <tr><td>2 Areas</td><td>Price: £250.00</td></tr>
          <tr><td>3 Areas</td><td>Price: £249.00</td></tr>
          <tr><td>Jawline Lift</td><td>Price: £299.00</td></tr>
          <tr><td>Bunny Lines</td><td>Price: £175.00</td></tr>
          <tr><td>Chin Dimpling</td><td>Price: £299.00</td></tr>
          <tr><td>Masseter (50u)</td><td>Price: £299.00</td></tr>
        </table>
      ''';
      final picked = selectEvidenceForProcedure(
        rows: extractPriceEvidence(
          html: html,
          sourceUrl: 'https://londonpremierlaser.co.uk/prices/injectables/',
        ),
        procedure: 'Botox anti-wrinkle injection',
      );
      expect(picked, isNotNull);
      expect(picked!.priceMin, 175);
      expect(picked.rawProcedureText.toLowerCase(), contains('1 area'));
      expect(
        exploreCachedPriceNeedsReselect(
          rawProcedureText: 'Chin Dimpling',
          brand: 'Botox treatment',
          sourceUrl: 'https://londonpremierlaser.co.uk/treatments/anti-wrinkle-injections/',
          procedure: 'Botox anti-wrinkle injection',
          rawPriceText: 'Price: £ 299.00',
          priceMin: 299,
        ),
        isTrue,
      );
    });

    test('Miami Forma RF is not Botox FROM', () {
      const html = '''
        <h1>Forma</h1>
        <p>Forma starts at \$300 for a single lower-face session, with
        package and area-based pricing for full face and face-and-neck.</p>
        <p>Botox 1 area from \$12 per unit.</p>
      ''';
      expect(
        selectEvidenceForProcedure(
          rows: extractPriceEvidence(
            html: html,
            sourceUrl: 'https://www.miamiskinspa.com/services/forma',
          ),
          procedure: 'Botox anti-wrinkle injection',
        ),
        isNull,
      );
      expect(
        exploreCachedPriceNeedsReselect(
          rawProcedureText: 'Forma',
          brand: 'Botox anti-wrinkle injection',
          sourceUrl: 'https://www.miamiskinspa.com/services/forma',
          procedure: 'Botox anti-wrinkle injection',
          rawPriceText: 'Forma starts at \$300',
          priceMin: 300,
          currency: 'USD',
          priceExtractRevision: kExplorePriceExtractRevision,
        ),
        isTrue,
      );
      expect(
        explorePriceIsComparableTypicalStart(
          procedure: 'Botox anti-wrinkle injection',
          rawProcedureText: 'Forma',
          rawPriceText: 'from 300 USD',
          sourceUrl: 'https://www.miamiskinspa.com/services/forma',
          priceMin: 300,
          currency: 'USD',
        ),
        isFalse,
      );
    });

    test('AP — saving-row Botox loses to 1 Area', () {
      const html = '''
        <table>
          <tr><td>Botox Treatment Areas · Your saving</td><td>£120</td></tr>
          <tr><td>1 Area</td><td>£175</td></tr>
          <tr><td>2 Areas</td><td>£260</td></tr>
        </table>
      ''';
      final picked = selectEvidenceForProcedure(
        rows: extractPriceEvidence(
          html: html,
          sourceUrl: 'https://sw11clinic.example/botox',
        ),
        procedure: 'Botox anti-wrinkle injection',
      );
      expect(picked, isNotNull);
      expect(picked!.priceMin, 175);
    });

    test('AR — generic Botox FROM is 1-area, not Jawline £299 or competitor £120/£99', () {
      const premier = '''
        <h2>Botox Pricing</h2>
        <div class="product-grid justify-content-start">
          <div id="Botox 3 Areas" class="product-item outlined large">
            <h3>Botox 3 Areas</h3>
            <div class="pricing-block">
              <span class="woocommerce-Price-amount amount"><bdi>£999.00</bdi></span>
            </div>
          </div>
          <div id="1 Area" class="product-item outlined large">
            <h3>1 Area</h3>
            <div class="pricing-block">
              <span class="woocommerce-Price-amount amount"><bdi>£175.00</bdi></span>
              <p>Price: <b><span class="woocommerce-Price-amount amount"><bdi>£175.00</bdi></span></b></p>
            </div>
          </div>
          <div id="3 Areas" class="product-item outlined large">
            <h3>3 Areas</h3>
            <div class="pricing-block">
              <del><span class="woocommerce-Price-amount amount">£325.00</span></del>
              <ins><span class="woocommerce-Price-amount amount">£249.00</span></ins>
            </div>
          </div>
          <div id="Jawline Lift" class="product-item outlined large">
            <h3>Jawline Lift</h3>
            <div class="pricing-block">
              <span class="woocommerce-Price-amount amount"><bdi>£299.00</bdi></span>
              <p>Price: <b>£299.00</b></p>
            </div>
          </div>
          <div id="Masseter" class="product-item outlined large">
            <h3>Masseter (50u)</h3>
            <div class="pricing-block">
              <del><span class="woocommerce-Price-amount amount">£399.00</span></del>
              <ins><span class="woocommerce-Price-amount amount">£299.00</span></ins>
            </div>
          </div>
        </div>
      ''';
      final premierPicked = selectEvidenceForProcedure(
        rows: extractPriceEvidence(
          html: premier,
          sourceUrl: 'https://londonpremierlaser.co.uk/prices/injectables/',
        ),
        procedure: 'Botox anti-wrinkle injection',
      );
      expect(premierPicked, isNotNull);
      expect(premierPicked!.priceMin, 175);
      expect(premierPicked.rawProcedureText.toLowerCase(), contains('1 area'));
      expect(
        exploreCachedPriceNeedsReselect(
          rawProcedureText: 'Botox treatment',
          brand: 'Botox treatment',
          sourceUrl: 'https://londonpremierlaser.co.uk/prices/injectables/',
          procedure: 'Botox anti-wrinkle injection',
          rawPriceText: 'from £299',
          priceMin: 299,
        ),
        isTrue,
      );

      const sw11 = '''
        <table>
          <thead>
            <tr>
              <th>Treatment</th>
              <th>SW11 Medical Clinic (Clapham)</th>
              <th>High Street Salons (Non-Medical)</th>
              <th>Harley Street Clinics</th>
            </tr>
          </thead>
          <tbody>
            <tr>
              <td>Botox (1 Area)</td>
              <td>£175</td>
              <td>£120 – £150</td>
              <td>£250 – £350</td>
            </tr>
            <tr>
              <td>Botox (3 Areas)</td>
              <td>£320</td>
              <td>£200 – £250</td>
              <td>£400 – £550</td>
            </tr>
          </tbody>
        </table>
        <table>
          <tr><td>Anti-wrinkle injections – 1 area</td><td>£175</td></tr>
          <tr><td>Anti-wrinkle injections – 2 areas</td><td>£260</td></tr>
          <tr><td>Anti-wrinkle injections – 3 areas</td><td>£320</td></tr>
        </table>
      ''';
      final sw11Picked = selectEvidenceForProcedure(
        rows: extractPriceEvidence(
          html: sw11,
          sourceUrl:
              'https://sw11clinic-clapham.co.uk/aesthetic-medicine-in-clapham-expert-botox-fillers-skin-treatments/',
        ),
        procedure: 'Botox anti-wrinkle injection',
      );
      expect(sw11Picked, isNotNull);
      expect(sw11Picked!.priceMin, 175);
      expect(sw11Picked.priceMin, isNot(120));
      expect(
        exploreCachedPriceNeedsReselect(
          rawProcedureText: 'Botox (1 Area)',
          brand: 'Botox treatment',
          sourceUrl:
              'https://sw11clinic-clapham.co.uk/aesthetic-medicine-in-clapham-expert-botox-fillers-skin-treatments/',
          procedure: 'Botox anti-wrinkle injection',
          rawPriceText: '£120 – £150',
          rawEvidence: 'High Street Salons (Non-Medical) £120 – £150',
          priceMin: 120,
        ),
        isTrue,
      );

      const faceClinicWarning = '''
        <p>There are some clinics that are offering Botox® at ridiculously cheap
        prices, such as “Botox® for £99”, but cheapest is not always best.
        These practitioners may not be registered professionals.</p>
      ''';
      final warningPicked = selectEvidenceForProcedure(
        rows: extractPriceEvidence(
          html: faceClinicWarning,
          sourceUrl: 'https://facecliniclondon.com/botox-cost/',
        ),
        procedure: 'Botox anti-wrinkle injection',
      );
      expect(warningPicked, isNull);
      expect(
        evaluateExtractedPriceCandidate(
          rawPriceText:
              'There are some clinics that are offering Botox® at ridiculously cheap prices, such as “Botox® for £99”',
          priceMin: 99,
          currency: 'GBP',
          extractionMethod: 'text_proximity',
          rawEvidence:
              'There are some clinics that are offering Botox® at ridiculously cheap prices, such as “Botox® for £99”, but cheapest is not always best.',
          procedure: 'botox',
          sourceUrl: 'https://facecliniclondon.com/botox-cost/',
        ).reason,
        'competitor_quote',
      );
      expect(
        exploreCachedPriceNeedsReselect(
          rawProcedureText: 'botox',
          brand: 'Botox treatment',
          sourceUrl: 'https://facecliniclondon.com/botox-cost/',
          procedure: 'Botox anti-wrinkle injection',
          rawPriceText: 'Botox® for £99',
          priceMin: 99,
        ),
        isTrue,
      );
    });

    test('AS — BOTOX 50 unități / Pret 1500 Lei is 1500 RON not 50', () {
      const html = '''
        <div class="service">
          <h3>BOTOX TOXINA BOTULINICA (50 unități - 3 zone)</h3>
          <p>Pret 1500 Lei</p>
        </div>
      ''';
      final rows = extractPriceEvidence(
        html: html,
        sourceUrl: 'https://example-clinic.ro/preturi/',
      );
      expect(rows, isNotEmpty);
      final picked = selectEvidenceForProcedure(
        rows: rows,
        procedure: 'Botox anti-wrinkle injection',
      );
      expect(picked, isNotNull);
      expect(picked!.priceMin, 1500);
      expect(
        picked.currency.toUpperCase(),
        anyOf('RON', 'LEI'),
      );
      expect(picked.priceMin, isNot(anyOf(50, 3)));
    });

    test('AQ — rhinoplasty prefers primary over tip', () {
      const html = '''
        <table>
          <tr><td>Standard primary rhinoplasty:</td><td>£6,500–£9,500</td></tr>
          <tr><td>Tip rhinoplasty:</td><td>£3,500–£5,500</td></tr>
          <tr><td>Revision rhinoplasty:</td><td>£7,000–£12,000</td></tr>
        </table>
      ''';
      final picked = selectEvidenceForProcedure(
        rows: extractPriceEvidence(
          html: html,
          sourceUrl: 'https://londonprivatehospital.uk/rhinoplasty-london-prices/',
        ),
        procedure: 'rhinoplasty nose job',
      );
      expect(picked, isNotNull);
      expect(picked!.priceMin, 6500);
      expect(picked.rawProcedureText.toLowerCase(), contains('primary'));
    });

    test('AR — liquid rhino £550 is not surgical rhinoplasty', () {
      const html = '''
        <p>A male nose job procedure starts from £6,900 at the Cadogan Clinic.</p>
        <p>For a cheaper alternative, non-surgical rhinoplasty starts from £550.</p>
      ''';
      final picked = selectEvidenceForProcedure(
        rows: extractPriceEvidence(
          html: html,
          sourceUrl:
              'https://www.cadoganclinic.com/ask-the-expert/facial-treatments/rhinoplasty-for-men',
        ),
        procedure: 'rhinoplasty nose job',
      );
      expect(picked, isNotNull);
      expect(picked!.priceMin, 6900);
    });

    test('AS — 2Glow 1 AREA £99, not Shopify template \$399.99', () {
      const menu = '''
        <ul>
          <li class="service-list--block">
            <div class="service-list--info">
              <div class="service-list--block-title">
                <p class="service-list--block-title-text">1 AREA</p>
              </div>
              <div class="service-list--price">£99</div>
            </div>
          </li>
          <li class="service-list--block">
            <p class="service-list--block-title-text">2 AREAS</p>
            <div class="service-list--price">£150</div>
          </li>
          <li class="service-list--block">
            <p class="service-list--block-title-text">3 AREAS</p>
            <div class="service-list--price">£190</div>
          </li>
        </ul>
      ''';
      final picked = selectEvidenceForProcedure(
        rows: extractPriceEvidence(
          html: menu,
          sourceUrl: 'https://2glow.co.uk/pages/botox',
        ),
        procedure: 'Botox anti-wrinkle injection',
      );
      expect(picked, isNotNull);
      expect(picked!.priceMin, 99);
      expect(picked.currency, 'GBP');
      expect(picked.rawProcedureText.toLowerCase(), contains('1 area'));

      const dummy = '''
        <p>Page Editor Template</p>
        <p><strong>from \$399.99</strong></p>
      ''';
      expect(
        selectEvidenceForProcedure(
          rows: extractPriceEvidence(
            html: dummy,
            sourceUrl: 'https://2glow.co.uk/pages/botox-template',
          ),
          procedure: 'Botox anti-wrinkle injection',
        ),
        isNull,
      );
      expect(
        isNonLiteralClinicPriceUrl('https://2glow.co.uk/pages/botox-template'),
        isTrue,
      );
      expect(
        isNonLiteralClinicPriceUrl('https://2glow.co.uk/pages/botox'),
        isFalse,
      );
      expect(
        evaluateExtractedPriceCandidate(
          rawPriceText: 'from \$399.99',
          priceMin: 399.99,
          currency: 'USD',
          extractionMethod: 'dom_block',
          sourceUrl: 'https://2glow.co.uk/pages/botox-template',
        ).reason,
        'theme_placeholder',
      );
      expect(
        evaluateExtractedPriceCandidate(
          rawPriceText: 'from 400 USD',
          priceMin: 400,
          currency: 'USD',
          extractionMethod: 'dom_block',
          sourceUrl: 'https://2glow.co.uk/pages/botox',
        ).reason,
        'tld_currency_mismatch',
      );
      expect(
        exploreCachedPriceNeedsReselect(
          rawProcedureText: 'Botox treatment',
          brand: 'Botox treatment',
          sourceUrl: 'https://2glow.co.uk/pages/botox',
          procedure: 'Botox anti-wrinkle injection',
          rawPriceText: 'from 400 USD',
          priceMin: 400,
          currency: 'USD',
        ),
        isTrue,
      );
    });

    test('laser hair vs skin: named rows win, generic Laser treatment skipped', () {
      const html = '''
        <table>
          <tr><td>Laser Hair Removal · peri anal</td><td>£14</td></tr>
          <tr><td>Photo Rejuvenation Face</td><td>£180.00</td></tr>
          <tr><td>Byonik hydrating laser facial</td><td>£197</td></tr>
          <tr><td>Laser treatment</td><td>£60</td></tr>
        </table>
      ''';
      const url = 'https://the-laserclinic.com/pages/prices';
      final rows = extractPriceEvidence(html: html, sourceUrl: url);

      final hair = selectEvidenceForProcedure(
        rows: rows,
        procedure: 'laser hair removal',
      );
      expect(hair, isNotNull);
      expect(hair!.priceMin, 14);
      expect(hair.rawProcedureText.toLowerCase(), contains('peri anal'));

      final skin = selectEvidenceForProcedure(
        rows: rows,
        procedure: 'laser skin rejuvenation IPL',
      );
      expect(skin, isNotNull);
      expect(skin!.rawProcedureText.toLowerCase(), isNot(contains('peri anal')));
      expect(skin.rawProcedureText.toLowerCase(), isNot(equals('laser treatment')));
      expect(
        skin.rawProcedureText.toLowerCase(),
        anyOf(contains('photo rejuvenation'), contains('byonik')),
      );

      expect(
        selectEvidenceForProcedure(
          rows: extractPriceEvidence(
            html: '<table><tr><td>Laser treatment</td><td>£60</td></tr></table>',
            sourceUrl: url,
          ),
          procedure: 'laser hair removal',
        ),
        isNull,
      );

      expect(
        exploreCachedPriceNeedsReselect(
          rawProcedureText: 'Laser treatment',
          brand: 'Laser treatment',
          sourceUrl: url,
          procedure: 'laser hair removal',
          rawPriceText: 'from 60 GBP',
          priceMin: 60,
          currency: 'GBP',
        ),
        isTrue,
      );
      expect(
        exploreLaserRowSubtype('Photo Rejuvenation Face'),
        'skin',
      );
      expect(
        exploreLaserRowFitsRequest(
          label: 'Byonik hydrating laser facial',
          procedure: 'laser hair removal',
        ),
        isFalse,
      );
    });

    test('London breast: financing heading is not the row; £2500 is not full BA', () {
      const enhanceHtml = '''
        <h1>Breast surgery financing</h1>
        <p>We offer monthly finance options from £4,595.</p>
        <table>
          <tr><td>Breast Enlargement (Boob Job)</td><td>from £4,595</td></tr>
          <tr><td>Breast Enlargement with MemoryGel Xtra</td><td>£4,950</td></tr>
          <tr><td>Anatomical Implants with BA</td><td>£4,995</td></tr>
          <tr><td>Inverted Nipple</td><td>£2,500</td></tr>
        </table>
      ''';
      final enhance = selectEvidenceForProcedure(
        rows: extractPriceEvidence(
          html: enhanceHtml,
          sourceUrl: 'https://enhancemedicalgroup.com/boob-job-cost',
        ),
        procedure: 'breast augmentation',
      );
      expect(enhance, isNotNull);
      expect(enhance!.priceMin, 4595);
      expect(enhance.currency, 'GBP');
      expect(enhance.rawProcedureText.toLowerCase(), isNot(contains('financ')));
      expect(
        enhance.rawProcedureText.toLowerCase(),
        anyOf(contains('enlargement'), contains('augmentation'), contains('memorygel')),
      );

      const hsbcGuide = '''
        <h1>Breast Augmentation Cost London: 2026 Price Guide</h1>
        <p>Some clinics advertise from £2,500. London usually costs
        between £6,500 and £9,500 as a single all-inclusive fee.</p>
      ''';
      expect(
        selectEvidenceForProcedure(
          rows: extractPriceEvidence(
            html: hsbcGuide,
            sourceUrl:
                'https://harleystreetbreastcentre.com/breast-augmentation-cost-london/',
          ),
          procedure: 'breast augmentation',
        )?.priceMin,
        isNot(2500),
      );

      const hsbcFees = '''
        <h1>Our fees</h1>
        <table>
          <tr><td>Breast Enlargement</td><td>From £7,500</td></tr>
          <tr><td>Breast Reduction</td><td>From £8,500</td></tr>
        </table>
      ''';
      final fees = selectEvidenceForProcedure(
        rows: extractPriceEvidence(
          html: hsbcFees,
          sourceUrl: 'https://harleystreetbreastcentre.com/our-fees/',
        ),
        procedure: 'breast augmentation',
      );
      expect(fees, isNotNull);
      expect(fees!.priceMin, 7500);

      expect(
        exploreCachedPriceNeedsReselect(
          rawProcedureText: 'Breast surgery financing',
          brand: 'Breast surgery financing',
          sourceUrl: 'https://enhancemedicalgroup.com/pricing',
          procedure: 'breast augmentation',
          rawPriceText: 'from £4,595',
          priceMin: 4595,
          currency: 'GBP',
        ),
        isTrue,
      );
      expect(
        exploreCachedPriceNeedsReselect(
          rawProcedureText: 'Breast augmentation',
          brand: 'Breast augmentation',
          sourceUrl: 'https://harleystreetbreastcentre.com/breast-augmentation/',
          procedure: 'breast augmentation',
          rawPriceText: 'from 2,500 GBP',
          priceMin: 2500,
          currency: 'GBP',
        ),
        isTrue,
      );
    });

    test('London breast: Harley bilateral FROM, Cadogan menu, Nuffield not pain H3', () {
      const harleyHtml = '''
        <h1>Boob job cost</h1>
        <table>
          <tr><td>Breast augmentation</td><td>from £6,995</td></tr>
          <tr><td>Unilateral breast augmentation</td><td>from £6,495</td></tr>
        </table>
      ''';
      final harley = selectEvidenceForProcedure(
        rows: extractPriceEvidence(
          html: harleyHtml,
          sourceUrl: 'https://www.harleymedical.co.uk/boob-job-cost',
        ),
        procedure: 'breast augmentation',
      );
      expect(harley, isNotNull);
      expect(harley!.priceMin, 6995);
      expect(
        harley.rawProcedureText.toLowerCase(),
        isNot(contains('unilateral')),
      );

      const cadoganHtml = '''
        <p>The cost of a good boob job should be no less than £5,000 - £7,000.
        Most reputable clinics in this region given the cost of running a
        medical facility.</p>
        <p>At the Cadogan Clinic in London, a boob job costs from £5,900</p>
        <table>
          <tr><td>Breast Enlargement - Unilateral Implants</td><td>£3,750</td></tr>
          <tr><td>Breast Enlargement - Bilateral Implants</td><td>£5,995</td></tr>
        </table>
      ''';
      final cadogan = selectEvidenceForProcedure(
        rows: extractPriceEvidence(
          html: cadoganHtml,
          sourceUrl:
              'https://www.cadoganclinic.com/cosmetic-surgery/breast-surgery/breast-enlargement/',
        ),
        procedure: 'breast augmentation',
      );
      expect(cadogan, isNotNull);
      expect(cadogan!.priceMin, anyOf(5900, 5995));
      expect(cadogan.priceMin, isNot(5000));
      expect(cadogan.priceMax - cadogan.priceMin, lessThan(1));

      const nuffieldHtml = '''
        <h1>Breast augmentation and enlargement</h1>
        <h3>Pain following breast enlargement surgery</h3>
        <p>The average guide price for breast augmentation at a Nuffield
        Health hospital is £8,579.</p>
        <table>
          <tr><td>Treatment</td><td>from £8,579</td></tr>
        </table>
      ''';
      final nuffield = selectEvidenceForProcedure(
        rows: extractPriceEvidence(
          html: nuffieldHtml,
          sourceUrl:
              'https://www.nuffieldhealth.com/treatments/breast-augmentation-enlargement',
        ),
        procedure: 'breast augmentation',
      );
      expect(nuffield, isNotNull);
      expect(nuffield!.priceMin, 8579);
      expect(
        nuffield.rawProcedureText.toLowerCase(),
        isNot(contains('pain following')),
      );

      expect(
        exploreCachedPriceNeedsReselect(
          rawProcedureText: 'Unilateral breast augmentation',
          brand: 'Unilateral breast augmentation',
          sourceUrl: 'https://www.harleymedical.co.uk/boob-job-cost',
          procedure: 'breast augmentation',
          rawPriceText: 'from £6,495',
          priceMin: 6495,
          currency: 'GBP',
        ),
        isTrue,
      );
      expect(
        exploreCachedPriceNeedsReselect(
          rawProcedureText: 'Breast augmentation',
          brand: 'Breast augmentation',
          sourceUrl: 'https://www.cadoganclinic.com/boob-job-cost',
          procedure: 'breast augmentation',
          rawPriceText: 'from £5,000-£7,000',
          priceMin: 5000,
          priceMax: 7000,
          currency: 'GBP',
        ),
        isTrue,
      );
    });

    test('London peel — Cosmelan kit is not the facial FROM; Face Clinic add-on is not £90', () {
      const peelMenu = '''
        <h2>Medical-Grade Peels</h2>
        <table>
          <tr><td>Cosmelan Peel Starter Kit</td><td>£1000 £900 – Limited Time Offer</td></tr>
          <tr><td>Chemical Peel Juliette Armand</td><td>from £200</td></tr>
          <tr><td>BioRePeel Face 1 Session</td><td>£250</td></tr>
        </table>
      ''';
      final peelPicked = selectEvidenceForProcedure(
        rows: extractPriceEvidence(
          html: peelMenu,
          sourceUrl: 'https://skinlogicaesthetics.co.uk/price-list/',
        ),
        procedure: 'chemical peel facial',
      );
      expect(peelPicked, isNotNull);
      expect(peelPicked!.priceMin, 200);
      expect(peelPicked.priceMin, isNot(850));
      expect(peelPicked.priceMin, isNot(900));
      expect(peelPicked.rawProcedureText.toLowerCase(), contains('chemical peel'));

      const faceClinic = '''
        <table>
          <tr><td>One Area</td><td>from £250</td></tr>
          <tr><td>Two Areas</td><td>from £350</td></tr>
          <tr><td>Three Areas</td><td>from £390</td></tr>
          <tr>
            <td>Targeted Areas (Bunny Lines, Chin, Gummy Smile, Marionette Lines, Smokers Line)</td>
            <td>£90 each when added to another anti-wrinkle treatment, or £180 as a standalone treatment</td>
          </tr>
          <tr><td>Masseter Botox</td><td>from £390</td></tr>
        </table>
      ''';
      final botoxPicked = selectEvidenceForProcedure(
        rows: extractPriceEvidence(
          html: faceClinic,
          sourceUrl: 'https://facecliniclondon.com/prices',
        ),
        procedure: 'Botox anti-wrinkle injection',
      );
      expect(botoxPicked, isNotNull);
      expect(botoxPicked!.priceMin, 250);
      expect(botoxPicked.priceMin, isNot(90));
      expect(botoxPicked.rawProcedureText.toLowerCase(), contains('one area'));

      expect(
        exploreCachedPriceNeedsReselect(
          rawProcedureText: 'Cosmelan Peel Starter Kit',
          brand: 'Cosmelan Peel Starter Kit',
          sourceUrl: 'https://skinlogicaesthetics.co.uk/cosmelan-peel/',
          procedure: 'chemical peel facial',
          rawPriceText: 'Limited Time Offer £1000£850',
          priceMin: 850,
          priceMax: 1000,
          currency: 'GBP',
        ),
        isTrue,
      );
      expect(
        exploreCachedPriceNeedsReselect(
          rawProcedureText: 'botox',
          brand: 'Botox anti-wrinkle injection',
          sourceUrl: 'https://facecliniclondon.com/prices',
          procedure: 'Botox anti-wrinkle injection',
          rawPriceText:
              'Targeted Areas (Bunny Lines) £90 each when added to another anti-wrinkle treatment',
          rawEvidence:
              'Targeted Areas (Bunny Lines) £90 each when added to another anti-wrinkle treatment',
          priceMin: 90,
          currency: 'GBP',
        ),
        isTrue,
      );
    });

    test('London rhinoplasty — Closed FROM not tip market band; dated menu beats male landing', () {
      expect(
        looksLikeCityCostArticleUrl(
          'https://londonprivatehospital.uk/rhinoplasty-london-prices/',
        ),
        isTrue,
      );
      expect(
        isNonLiteralClinicPriceUrl(
          'https://www.cadoganclinic.com/price-guide/',
        ),
        isFalse,
      );
      expect(
        looksLikeOfficialPriceListUrl(
          'https://www.cadoganclinic.com/price-guide/',
        ),
        isTrue,
      );
      expect(
        looksLikeOfficialPriceListUrl(
          'https://www.williamtownley.co.uk/rhinoplasty/cost/',
        ),
        isTrue,
      );

      const lph = '''
        <h2>Typical London Price Ranges</h2>
        <p>Prices vary among surgeons. On average: Tip rhinoplasty £3,500–£5,500.
        This is a helpful reference, not our menu.</p>
        <table>
          <tr><td>Closed Rhinoplasty</td><td>from £6,900</td></tr>
          <tr><td>Open Rhinoplasty</td><td>from £7,999</td></tr>
          <tr><td>Tip Rhinoplasty</td><td>from £4,900</td></tr>
          <tr><td>Secondary / Septo Rhinoplasty</td><td>from £9,900</td></tr>
        </table>
        <p>Start From £6900</p>
      ''';
      final lphPicked = selectEvidenceForProcedure(
        rows: extractPriceEvidence(
          html: lph,
          sourceUrl: 'https://londonprivatehospital.uk/treatments/rhinoplasty/',
        ),
        procedure: 'rhinoplasty nose job',
      );
      expect(lphPicked, isNull, reason: 'A reference table explicitly says it is not a clinic menu');

      const ownedMenu = '''
        <h1>Our prices</h1>
        <table>
          <tr><td>Closed Rhinoplasty</td><td>from £6,900</td></tr>
          <tr><td>Open Rhinoplasty</td><td>from £7,999</td></tr>
          <tr><td>Tip Rhinoplasty</td><td>from £4,900</td></tr>
          <tr><td>Secondary / Septo Rhinoplasty</td><td>from £9,900</td></tr>
        </table>
      ''';
      final ownedPicked = selectEvidenceForProcedure(
        rows: extractPriceEvidence(
          html: ownedMenu,
          sourceUrl: 'https://londonprivatehospital.uk/treatments/rhinoplasty/',
        ),
        procedure: 'rhinoplasty nose job',
      );
      expect(ownedPicked, isNotNull);
      expect(ownedPicked!.priceMin, 6900);
      expect(ownedPicked.priceMin, isNot(4900));
      expect(ownedPicked.rawProcedureText.toLowerCase(), contains('closed'));

      const cadogan = '''
        <p>Price guide revised in June 2026</p>
        <table>
          <tr><td>Rhinoplasty</td><td>£7,995</td></tr>
          <tr><td>Ultrasonic Rhinoplasty</td><td>£8,395</td></tr>
          <tr><td>Revision Rhinoplasty</td><td>£10,995</td></tr>
        </table>
        <p>A male nose job procedure starts from £6,900 at the Cadogan Clinic.</p>
      ''';
      final cadoganPicked = selectEvidenceForProcedure(
        rows: extractPriceEvidence(
          html: cadogan,
          sourceUrl: 'https://www.cadoganclinic.com/price-guide/',
        ),
        procedure: 'rhinoplasty nose job',
      );
      expect(cadoganPicked, isNotNull);
      expect(cadoganPicked!.priceMin, 7995);
      expect(cadoganPicked.priceMin, isNot(6900));

      expect(
        exploreCachedPriceNeedsReselect(
          rawProcedureText: 'Rhinoplasty',
          brand: 'rhinoplasty nose job',
          sourceUrl:
              'https://www.cadoganclinic.com/for-men/rhinoplasty-for-men/',
          procedure: 'rhinoplasty nose job',
          rawPriceText: 'starts from £6,900',
          priceMin: 6900,
          currency: 'GBP',
        ),
        isTrue,
      );
      expect(
        exploreCachedPriceNeedsReselect(
          rawProcedureText: 'Tip rhinoplasty',
          brand: 'rhinoplasty nose job',
          sourceUrl:
              'https://londonprivatehospital.uk/rhinoplasty-london-prices/',
          procedure: 'rhinoplasty nose job',
          rawPriceText: 'from £3,500–£5,500',
          priceMin: 3500,
          priceMax: 5500,
          currency: 'GBP',
        ),
        isTrue,
      );
      expect(
        exploreCachedPriceNeedsReselect(
          rawProcedureText: 'Primary / Closed Rhinoplasty',
          brand: 'rhinoplasty nose job',
          sourceUrl: 'https://nizarhamadeh.com/rhinoplasty/',
          procedure: 'rhinoplasty nose job',
          rawPriceText: 'from £7,998',
          priceMin: 7998,
          currency: 'GBP',
          priceExtractRevision: kExplorePriceExtractRevision,
        ),
        isFalse,
      );
      expect(
        exploreCachedPriceNeedsReselect(
          rawProcedureText: 'Ultrasonic rhinoplasty',
          brand: 'rhinoplasty nose job',
          sourceUrl: 'https://www.williamtownley.co.uk/rhinoplasty/cost/',
          procedure: 'rhinoplasty nose job',
          rawPriceText: 'from £12,500',
          priceMin: 12500,
          currency: 'GBP',
          priceExtractRevision: kExplorePriceExtractRevision,
        ),
        isFalse,
      );
      expect(
        exploreCachedPriceNeedsReselect(
          rawProcedureText: 'Rhinoplasty',
          brand: 'rhinoplasty nose job',
          sourceUrl: 'https://www.williamtownley.co.uk/reviews/',
          procedure: 'rhinoplasty nose job',
          rawPriceText: 'I paid £12,500 in 2023',
          rawEvidence: 'A patient who paid £12,500 reported the surgery in 2023',
          priceMin: 12500,
          currency: 'GBP',
        ),
        isTrue,
      );
    });

    test('London rhinoplasty — clinic FROM vs market guide vs hospital fees only', () {
      const ardaGuide =
          'https://ardakucukguven.com/rhinoplasty-cost-in-london-complete-pricing-guide/';
      expect(isNonLiteralClinicPriceUrl(ardaGuide), isTrue);
      expect(looksLikeCityMarketPricingGuideUrl(ardaGuide), isTrue);
      expect(
        looksLikeRoundedMarketPriceSpread(
          priceMin: 7000,
          priceMax: 15000,
          currency: 'GBP',
          procedure: 'rhinoplasty nose job',
        ),
        isTrue,
      );

      const arda = '''
        <h1>Rhinoplasty Cost in London: Complete Pricing Guide</h1>
        <p>London rhinoplasty prices typically range from £6,000-£15,000,
        reflecting surgeon expertise, procedure complexity, and facility quality.</p>
        <p>Ethnic rhinoplasty £7,000–£15,000</p>
        <p>Revision rhinoplasty £8,000–£18,000</p>
      ''';
      expect(
        selectEvidenceForProcedure(
          rows: extractPriceEvidence(html: arda, sourceUrl: ardaGuide),
          procedure: 'rhinoplasty nose job',
        ),
        isNull,
      );

      const enhance = '''
        <h2>RHINOPLASTY COST</h2>
        <p>Rhinoplasty from £6,295</p>
        <p>Rhinoplasty costs £6,295 with Enhance Medical.</p>
        <table>
          <tr><td>Rhinoplasty (Nose Job)</td><td>£6,295</td></tr>
          <tr><td>Septoplasty</td><td>£6,795</td></tr>
        </table>
      ''';
      final enhancePicked = selectEvidenceForProcedure(
        rows: extractPriceEvidence(
          html: enhance,
          sourceUrl: 'https://enhancemedicalgroup.com/face-surgery/rhinoplasty',
        ),
        procedure: 'rhinoplasty nose job',
      );
      expect(enhancePicked, isNotNull);
      expect(enhancePicked!.priceMin, 6295);

      const hje = '''
        <h2>How much does a private rhinoplasty cost?</h2>
        <p>from £3,000* (guide price)</p>
        <p>The cost of a private rhinoplasty starts from £3,000* (Guide Price)
        at St John &amp; St Elizabeth Hospital.</p>
        <p>*The price shown is an estimated guide to the hospital charges
        associated with your treatment from admission to discharge. This guide
        price excludes consultation fees, diagnostic tests, and professional
        fees charged separately by your surgeon, anaesthetist, and any other
        specialists involved in your care.</p>
      ''';
      final hjePicked = selectEvidenceForProcedure(
        rows: extractPriceEvidence(
          html: hje,
          sourceUrl: 'https://hje.org.uk/treatments/rhinoplasty/',
        ),
        procedure: 'rhinoplasty nose job',
      );
      expect(hjePicked, isNotNull);
      expect(hjePicked!.priceMin, 3000);
      expect(
        looksLikeHospitalFeesOnlyQuote(
          '${hjePicked.rawPriceText}\n${hjePicked.rawEvidence}',
        ),
        isTrue,
      );
      expect(
        explorePriceIsComparableTypicalStart(
          procedure: 'rhinoplasty nose job',
          rawProcedureText: hjePicked.rawProcedureText,
          rawPriceText: hjePicked.rawPriceText,
          rawEvidence: hjePicked.rawEvidence,
          sourceUrl: 'https://hje.org.uk/treatments/rhinoplasty/',
          priceMin: 3000,
          currency: 'GBP',
        ),
        isFalse,
      );

      const townley = '''
        <p>The cost of rhinoplasty in London ranges from approximately
        £12,500 to £15,000.</p>
        <p>At our practice, pricing for ultrasonic rhinoplasty starts at £12,500.</p>
      ''';
      final townleyPicked = selectEvidenceForProcedure(
        rows: extractPriceEvidence(
          html: townley,
          sourceUrl: 'https://www.williamtownley.co.uk/rhinoplasty/cost/',
        ),
        procedure: 'rhinoplasty nose job',
      );
      expect(townleyPicked, isNotNull);
      expect(townleyPicked!.priceMin, 12500);

      expect(
        exploreCachedPriceNeedsReselect(
          rawProcedureText: 'Ethnic Rhinoplasty',
          brand: 'rhinoplasty nose job',
          sourceUrl: ardaGuide,
          procedure: 'rhinoplasty nose job',
          rawPriceText: 'from £7,000–£15,000',
          rawEvidence: 'Ethnic rhinoplasty £7,000–£15,000',
          priceMin: 7000,
          priceMax: 15000,
          currency: 'GBP',
          priceExtractRevision: kExplorePriceExtractRevision,
        ),
        isTrue,
      );
      expect(
        explorePriceIsComparableTypicalStart(
          procedure: 'rhinoplasty nose job',
          rawProcedureText: 'Rhinoplasty',
          rawPriceText: 'from £6,295',
          sourceUrl: 'https://enhancemedicalgroup.com/face-surgery/rhinoplasty',
          priceMin: 6295,
          currency: 'GBP',
        ),
        isTrue,
      );
    });

    test('Harley Medical — official /nose-job-cost, not nav or finance list', () {
      const boobUrl = 'https://www.harleymedical.co.uk/boob-job-cost';
      const noseUrl = 'https://www.harleymedical.co.uk/nose-job-cost';
      const financeUrl = 'https://www.harleymedical.co.uk/nose-job-on-finance';

      expect(exploreUrlConflictsWithProcedure(boobUrl, 'rhinoplasty nose job'), isTrue);
      expect(exploreUrlConflictsWithProcedure(noseUrl, 'rhinoplasty nose job'), isFalse);
      expect(exploreUrlConflictsWithProcedure(financeUrl, 'rhinoplasty nose job'), isTrue);
      expect(exploreUrlConflictsWithProcedure(boobUrl, 'breast augmentation'), isFalse);
      expect(exploreScoreClinicPriceUrl(boobUrl, procedure: 'rhinoplasty nose job'), 0);
      expect(
        exploreScoreClinicPriceUrl(noseUrl, procedure: 'rhinoplasty nose job'),
        greaterThanOrEqualTo(5),
      );
      expect(exploreScoreClinicPriceUrl(financeUrl, procedure: 'rhinoplasty nose job'), 0);

      const withNav = '''
        <header>
          <nav>
            <a href="/boob-job-cost">Breast Surgery</a>
            <a href="/nose-job-cost">Rhinoplasty</a>
            <a href="/tummy-tuck-cost">Abdominoplasty</a>
          </nav>
        </header>
        <h1>How Much is a Boob Job?</h1>
        <h2>Breast Augmentation Guide Prices</h2>
        <table>
          <tr><th>Procedure</th><th>Guide price (from)</th></tr>
          <tr><td>Breast augmentation</td><td>£6,995</td></tr>
          <tr><td>Unilateral breast augmentation</td><td>£6,495</td></tr>
        </table>
      ''';
      expect(
        selectEvidenceForProcedure(
          rows: extractPriceEvidence(html: withNav, sourceUrl: boobUrl),
          procedure: 'rhinoplasty nose job',
        ),
        isNull,
      );
      final breast = selectEvidenceForProcedure(
        rows: extractPriceEvidence(html: withNav, sourceUrl: boobUrl),
        procedure: 'breast augmentation',
      );
      expect(breast, isNotNull);
      expect(breast!.priceMin, 6995);

      const official = '''
        <h2>Our Rhinoplasty Guide Prices</h2>
        <table>
          <tr><th>Procedure</th><th>Guide price (from)</th></tr>
          <tr><td><a href="#book">Rhinoplasty on tip - alar base reduction</a></td><td>£8,995</td></tr>
          <tr><td><a href="#book">Rhinoplasty (closed)</a></td><td>£8,995</td></tr>
          <tr><td><a href="#book">Rhinoplasty - reconstruction/secondary</a></td><td>£12,995</td></tr>
          <tr><td><a href="#book">Septorhinoplasty closed</a></td><td>£8,995</td></tr>
        </table>
      ''';
      final officialPicked = selectEvidenceForProcedure(
        rows: extractPriceEvidence(html: official, sourceUrl: noseUrl),
        procedure: 'rhinoplasty nose job',
      );
      expect(officialPicked, isNotNull);
      expect(officialPicked!.priceMin, 8995);
      expect(officialPicked.rawProcedureText.toLowerCase(), contains('closed'));
      expect(officialPicked.priceMin, isNot(6625));
      expect(officialPicked.priceMin, isNot(6995));

      const finance = '''
        <h1>Nose Job on Finance</h1>
        <table>
          <tr><td>Breast Surgery</td><td>£5,995</td></tr>
          <tr><td>Nose Reshaping (Rhinoplasty)</td><td>£6,625</td></tr>
          <tr><td>Brow Lift</td><td>£6,300</td></tr>
        </table>
      ''';
      expect(
        selectEvidenceForProcedure(
          rows: extractPriceEvidence(html: finance, sourceUrl: financeUrl),
          procedure: 'rhinoplasty nose job',
        ),
        isNull,
      );
      expect(
        exploreCachedPriceNeedsReselect(
          rawProcedureText: 'Nose Reshaping (Rhinoplasty)',
          brand: 'rhinoplasty nose job',
          sourceUrl: financeUrl,
          procedure: 'rhinoplasty nose job',
          rawPriceText: 'from £6,625',
          priceMin: 6625,
          currency: 'GBP',
          priceExtractRevision: kExplorePriceExtractRevision,
        ),
        isTrue,
      );
      expect(
        exploreCachedPriceNeedsReselect(
          rawProcedureText: 'Rhinoplasty',
          brand: 'rhinoplasty nose job',
          sourceUrl: boobUrl,
          procedure: 'rhinoplasty nose job',
          rawPriceText: 'from £6,995',
          priceMin: 6995,
          currency: 'GBP',
          priceExtractRevision: kExplorePriceExtractRevision,
        ),
        isTrue,
      );
    });

    test('London hair — package FROM not graft count or effective £/graft', () {
      const westminster = '''
        <h2>FUE hair transplant technique cost</h2>
        <ul>
          <li>Cost of 500 FUE grafts – from £3500</li>
          <li>Cost of 1,000 FUE grafts – from £5000</li>
          <li>Cost of 1500 FUE grafts – from £6000</li>
          <li>Cost of 2000 FUE grafts – from £7000</li>
          <li>Private consultation with one of our hair surgeons – £75</li>
          <li>Female hair loss specialist package – £1000</li>
        </ul>
        <p>To confirm a date we will require a non-refundable theatre deposit of £1000.</p>
      ''';
      final westminsterPicked = selectEvidenceForProcedure(
        rows: extractPriceEvidence(
          html: westminster,
          sourceUrl:
              'https://westminsterclinic.co.uk/cost-and-prices-for-hair-transplants-in-london/',
        ),
        procedure: 'hair transplant FUE',
      );
      expect(westminsterPicked, isNotNull);
      expect(westminsterPicked!.priceMin, 3500);
      expect(westminsterPicked.priceMin, isNot(1000));
      expect(westminsterPicked.priceMin, isNot(75));
      expect(westminsterPicked.unit.toLowerCase(), isNot(contains('graft')));
      expect(westminsterPicked.quantity, 500);

      const fks = '''
        <h1>Hair Transplant Cost in London</h1>
        <p>Micro Sapphire FUE starts at £2,999 for up to 3,000 grafts.
        A £200 arrangement fee applies to every package, so the total
        payable ranges from £3,199 to £4,999.</p>
        <table>
          <tr><td>Lowest package price</td><td>£2,999</td></tr>
          <tr><td>Highest package price</td><td>£4,799</td></tr>
          <tr><td>Lowest total payable</td>
              <td>£3,199 including the £200 arrangement fee</td></tr>
          <tr><td>Lowest effective cost per graft</td>
              <td>£0.76 with Package 2 at 5,000 grafts</td></tr>
          <tr><td>Maximum grafts</td><td>Up to 5,000 in a single session</td></tr>
          <tr><td>Prices valid</td><td>2026</td></tr>
        </table>
        <div>
          <h3>PACKAGE 1</h3>
          <p>Micro Sapphire FUE in London</p>
          <p>Up to 3.000 Grafts</p>
          <p>£ 2,999</p>
        </div>
        <div>
          <h3>PACKAGE 2</h3>
          <p>Micro Sapphire FUE in London</p>
          <p>Up to 5.000 Grafts</p>
          <p>£ 3,599</p>
        </div>
        <table>
          <tr><th>Fee</th><th>Amount</th><th>When it applies</th></tr>
          <tr><td>Arrangement fee</td><td>£200</td><td>All packages</td></tr>
        </table>
        <table>
          <tr><td>Package 2</td><td>Micro Sapphire FUE</td><td>5,000</td>
              <td>£3,799</td><td>£0.76</td></tr>
          <tr><td>Package 1</td><td>Micro Sapphire FUE</td><td>3,000</td>
              <td>£3,199</td><td>£1.07</td></tr>
        </table>
      ''';
      final fksPicked = selectEvidenceForProcedure(
        rows: extractPriceEvidence(
          html: fks,
          sourceUrl: 'https://www.fksclinic.co.uk/hair-transplant-uk/cost/',
        ),
        procedure: 'hair transplant FUE',
      );
      expect(fksPicked, isNotNull);
      expect(fksPicked!.priceMin, 3199);
      expect(fksPicked.priceMin, isNot(2999));
      expect(fksPicked.priceMin, isNot(3599));
      expect(fksPicked.priceMin, isNot(3799));
      expect(fksPicked.priceMin, isNot(0.76));
      expect(fksPicked.priceMin, isNot(2));
      expect(fksPicked.unit.toLowerCase(), isNot(contains('graft')));

      const harley = '''
        <p>Our FUE hair transplant costs start from £3,000 for very small surgeries
        and can go up to £7,000 for larger cases.</p>
        <table>
          <tr><th>Grafts</th><th>Price</th></tr>
          <tr><td>500 grafts</td><td>£3,000 – £3,500</td></tr>
          <tr><td>3,000 grafts</td><td>£6,500 – £7,000</td></tr>
        </table>
        <p>FUE starts from £3,000 and FUT from £4,000.</p>
      ''';
      final harleyPicked = selectEvidenceForProcedure(
        rows: extractPriceEvidence(
          html: harley,
          sourceUrl:
              'https://www.harleystreethairtransplant.co.uk/hair-transplant-cost/',
        ),
        procedure: 'hair transplant FUE',
      );
      expect(harleyPicked, isNotNull);
      expect(harleyPicked!.priceMin, 3000);
      expect(harleyPicked.priceMin, isNot(3499));
      expect(harleyPicked.unit.toLowerCase(), isNot(contains('graft')));

      expect(
        exploreCachedPriceNeedsReselect(
          rawProcedureText: 'Hair transplant',
          brand: 'hair transplant FUE',
          sourceUrl:
              'https://westminsterclinic.co.uk/cost-and-prices-for-hair-transplants-in-london/',
          procedure: 'hair transplant FUE',
          rawPriceText: '1,000 FUE grafts',
          rawEvidence: 'Cost of 1,000 FUE grafts – from £5000',
          priceMin: 1000,
          currency: 'GBP',
        ),
        isTrue,
      );
      expect(
        exploreCachedPriceNeedsReselect(
          rawProcedureText: 'Lowest effective cost per graft',
          brand: 'hair transplant FUE',
          sourceUrl: 'https://www.fksclinic.co.uk/hair-transplant-uk/cost/',
          procedure: 'hair transplant FUE',
          rawPriceText: 'from 2 GBP/graft',
          rawEvidence: 'Lowest effective cost per graft £0.76',
          priceMin: 2,
          currency: 'GBP',
        ),
        isTrue,
      );
      expect(
        exploreCachedPriceNeedsReselect(
          rawProcedureText: 'FUE starts',
          brand: 'hair transplant FUE',
          sourceUrl:
              'https://www.harleystreethairtransplant.co.uk/hair-transplant-cost/',
          procedure: 'hair transplant FUE',
          rawPriceText: 'from 3499 GBP/graft',
          rawEvidence: 'FUE starts from £3,499 grafts',
          priceMin: 3499,
          currency: 'GBP',
        ),
        isTrue,
      );
      expect(
        explorePriceIsComparableTypicalStart(
          procedure: 'hair transplant FUE',
          rawProcedureText: 'Lowest effective cost per graft',
          rawPriceText: 'from 2 GBP/graft',
          priceMin: 2,
          currency: 'GBP',
        ),
        isFalse,
      );
      expect(
        explorePriceIsComparableTypicalStart(
          procedure: 'hair transplant FUE',
          rawProcedureText: 'Lowest total payable',
          rawPriceText: 'from £3,199',
          sourceUrl: 'https://www.fksclinic.co.uk/hair-transplant-uk/cost/',
          priceMin: 3199,
          currency: 'GBP',
        ),
        isTrue,
      );
      expect(
        explorePriceIsComparableTypicalStart(
          procedure: 'hair transplant FUE',
          rawProcedureText: 'Hair transplant',
          rawPriceText: 'from 3,799 £',
          sourceUrl: 'https://www.fksclinic.co.uk/hair-transplant-uk/cost/',
          priceMin: 3799,
          currency: 'GBP',
        ),
        isFalse,
      );

      const lhtcArticle =
          'https://londonhairtransplantclinic.uk/the-cost-of-hair-transplants-london-a-complete-breakdown/';
      expect(isNonLiteralClinicPriceUrl(lhtcArticle), isTrue);
      expect(looksLikeClinicArticlePriceUrl(lhtcArticle), isTrue);
      const lhtc = '''
        <p>FUE hair transplants in London often cost £2–£3 per graft.</p>
        <p>FUT may be slightly cheaper, starting at £1.50 per graft.</p>
      ''';
      expect(
        selectEvidenceForProcedure(
          rows: extractPriceEvidence(html: lhtc, sourceUrl: lhtcArticle),
          procedure: 'hair transplant FUE',
        ),
        isNull,
      );

      const tamLanding = '''
        <p>Our hair transplant treatment fee starts from £5400 to £7600.</p>
      ''';
      final tamLandingPicked = selectEvidenceForProcedure(
        rows: extractPriceEvidence(
          html: tamLanding,
          sourceUrl: 'https://drmarktam.co.uk/fue-hair-transplant/',
        ),
        procedure: 'hair transplant FUE',
      );
      expect(tamLandingPicked, isNotNull);
      expect(tamLandingPicked!.priceMin, 5400);
      expect(tamLandingPicked.priceMax, 7600);
      expect(tamLandingPicked.currency, 'GBP');

      const expiredLanding = '''
        <p>Our hair transplant treatment fee starts from £5400 to £7600.
        This price has expired and is no longer available.</p>
      ''';
      expect(
        looksLikeHairStaleLandingQuote(
          sourceUrl: 'https://drmarktam.co.uk/fue-hair-transplant/',
          blob: expiredLanding,
          priceMin: 5400,
          priceMax: 7600,
        ),
        isTrue,
      );
      expect(
        selectEvidenceForProcedure(
          rows: extractPriceEvidence(
            html: expiredLanding,
            sourceUrl: 'https://drmarktam.co.uk/fue-hair-transplant/',
          ),
          procedure: 'hair transplant FUE',
        ),
        isNull,
      );

      const tamFees = '''
        <h3>FUE Treatment Prices</h3>
        <p>Consultation/Follow up Appointment cost £250.</p>
        <p>Video consultation – 30 minutes cost £60.</p>
        <table>
          <tr><td>Hair Restoration Surgery 3,500 - 4,200 grafts</td>
              <td>£21,000 - £25,000 (inc 20% VAT)</td></tr>
          <tr><td>3,000 - 3,500 grafts</td>
              <td>£18,000 - £21,000 (inc 20% VAT)</td></tr>
          <tr><td>2,400 - 3,000 grafts</td>
              <td>£14,400 - £18,000 (inc 20% VAT)</td></tr>
          <tr><td>Min fee</td><td>£14,400 inc 20% VAT</td></tr>
          <tr><td>Unshaven Hair Restoration Surgery Up to 1,000 grafts</td>
              <td>£24,000 (inc 20% VAT)</td></tr>
        </table>
      ''';
      final tamPicked = selectEvidenceForProcedure(
        rows: extractPriceEvidence(
          html: tamFees,
          sourceUrl: 'https://drmarktam.co.uk/fees/',
        ),
        procedure: 'hair transplant FUE',
      );
      expect(tamPicked, isNotNull);
      expect(tamPicked!.priceMin, 14400);
      expect(tamPicked.priceMin, isNot(250));
      expect(tamPicked.priceMin, isNot(60));
      expect(tamPicked.priceMin, isNot(5400));
      expect(tamPicked.priceMin, isNot(24000));

      expect(
        exploreCachedPriceNeedsReselect(
          rawProcedureText: 'FUE hair transplant',
          brand: 'hair transplant FUE',
          sourceUrl: 'https://drmarktam.co.uk/fue-hair-transplant/',
          procedure: 'hair transplant FUE',
          rawPriceText: 'starts from £5400 to £7600',
          rawEvidence:
              'Our hair transplant treatment fee starts from £5400 to £7600.',
          priceMin: 5400,
          priceMax: 7600,
          currency: 'GBP',
          priceExtractRevision: kExplorePriceExtractRevision,
        ),
        isFalse,
      );
      expect(
        exploreCachedPriceNeedsReselect(
          rawProcedureText: 'Hair transplant',
          brand: 'hair transplant FUE',
          sourceUrl: 'https://drmarktam.co.uk/fue-hair-transplant/',
          procedure: 'hair transplant FUE',
          rawPriceText: 'from 5400 £',
          rawEvidence: '',
          priceMin: 5400,
          priceMax: 5400,
          currency: 'GBP',
          priceExtractRevision: kExplorePriceExtractRevision,
        ),
        isFalse,
      );
      expect(
        exploreCachedPriceNeedsReselect(
          rawProcedureText: 'FUE hair transplant',
          brand: 'hair transplant FUE',
          sourceUrl: 'https://drmarktam.co.uk/fue-hair-transplant/',
          procedure: 'hair transplant FUE',
          rawPriceText: 'Expired price: from 5400 £',
          rawEvidence: 'This price has expired and is no longer available.',
          priceMin: 5400,
          priceMax: 5400,
          currency: 'GBP',
          priceExtractRevision: kExplorePriceExtractRevision,
        ),
        isTrue,
      );
      expect(
        exploreCachedPriceNeedsReselect(
          rawProcedureText: 'Hair transplant',
          brand: 'hair transplant FUE',
          sourceUrl: 'https://www.fksclinic.co.uk/hair-transplant-uk/cost/',
          procedure: 'hair transplant FUE',
          rawPriceText: 'from 3,799 £',
          rawEvidence: '',
          priceMin: 3799,
          currency: 'GBP',
          priceExtractRevision: kExplorePriceExtractRevision,
        ),
        isTrue,
      );
      expect(
        selectEvidenceForProcedure(
          rows: extractPriceEvidence(
            html: '<p>Our hair transplant treatment fee from £5400.</p>',
            sourceUrl: 'https://drmarktam.co.uk/fue-hair-transplant/',
          ),
          procedure: 'hair transplant FUE',
        ),
        isNotNull,
      );
      expect(
        exploreCachedPriceNeedsReselect(
          rawProcedureText: 'FUE',
          brand: 'hair transplant FUE',
          sourceUrl: lhtcArticle,
          procedure: 'hair transplant FUE',
          rawPriceText: 'from £1.50 per graft',
          rawEvidence: 'FUT starting at £1.50 per graft',
          priceMin: 1.5,
          currency: 'GBP',
          priceExtractRevision: kExplorePriceExtractRevision,
        ),
        isTrue,
      );
      expect(
        exploreCachedPriceNeedsReselect(
          rawProcedureText: 'Cost of 500 FUE grafts',
          brand: 'hair transplant FUE',
          sourceUrl:
              'https://westminsterclinic.co.uk/cost-and-prices-for-hair-transplants-in-london/',
          procedure: 'hair transplant FUE',
          rawPriceText: 'from £3500',
          rawEvidence: 'Cost of 500 FUE grafts – from £3500',
          priceMin: 3500,
          currency: 'GBP',
          priceExtractRevision: kExplorePriceExtractRevision,
        ),
        isFalse,
      );
      expect(
        explorePriceIsComparableTypicalStart(
          procedure: 'hair transplant FUE',
          rawProcedureText: 'FUE hair transplant',
          rawPriceText: 'starts from £5400 to £7600',
          sourceUrl: 'https://drmarktam.co.uk/fue-hair-transplant/',
          priceMin: 5400,
          priceMax: 7600,
          currency: 'GBP',
        ),
        isTrue,
      );
      expect(
        explorePriceIsComparableTypicalStart(
          procedure: 'hair transplant FUE',
          rawProcedureText: 'FUT',
          rawPriceText: 'from £1.50 per graft',
          sourceUrl: lhtcArticle,
          priceMin: 1.5,
          currency: 'GBP',
        ),
        isFalse,
      );
      expect(
        explorePriceIsComparableTypicalStart(
          procedure: 'hair transplant FUE',
          rawProcedureText: 'Cost of 500 FUE grafts',
          rawPriceText: 'from £3500',
          sourceUrl:
              'https://westminsterclinic.co.uk/cost-and-prices-for-hair-transplants-in-london/',
          priceMin: 3500,
          currency: 'GBP',
        ),
        isTrue,
      );
      expect(
        explorePriceIsComparableTypicalStart(
          procedure: 'hair transplant FUE',
          rawProcedureText: '500 grafts FUE',
          rawPriceText: 'from £2,499',
          sourceUrl: 'https://www.myhairuk.com/fue-hair-transplant-cost/',
          priceMin: 2499,
          currency: 'GBP',
        ),
        isTrue,
      );
    });
  });

  group('Miami menu duration copy must not hide Botox unit prices', () {
    test('injectables table \$13/unit is picked for Botox', () {
      const html = '''
        <table>
          <tr><th>Treatment</th><th>Lasts</th><th>Starts at</th></tr>
          <tr><td>Dermal Fillers</td><td>6 mo (lips)</td><td>\$750 lips</td></tr>
          <tr><td>Wrinkle Relaxers</td><td>3–4 months</td><td>\$13/unit</td></tr>
        </table>
      ''';
      final rows = extractPriceEvidence(
        html: html,
        sourceUrl: 'https://www.miamiskinspa.com/services/injectable-services-miami/',
      );
      final picked = selectEvidenceForProcedure(
        rows: rows,
        procedure: 'Botox',
      );
      expect(picked, isNotNull);
      expect(picked!.priceMin, 13);
      expect(picked.currency, 'USD');
      expect(picked.priceType, PriceType.perUnit);
      expect(picked.procedureFamily, 'botox');
    });

    test('mixed menu keeps Restylane \$950, Chemical Peel \$300, not add-on or typical', () {
      const html = '''
        <h2>Injectable Treatments</h2>
        <ul>
          <li>Restylane® \$950 per syringe.</li>
        </ul>
        <p>Results typically last a month. Ask about monthly financing.</p>
        <p>Prices vary depending on the type and amount of filler used, with
        typical sessions ranging from \$500 to \$800 per syringe.</p>
        <div>Full upper face tox + 2 syringes filler \$1500</div>
        <h2>Skin Care</h2>
        <div>Chemical Peel \$300</div>
        <div>PEEL ADD ON \$200</div>
      ''';
      final rows = extractPriceEvidence(
        html: html,
        sourceUrl: 'https://clinic.example/pricing',
      );
      final filler = selectEvidenceForProcedure(
        rows: rows,
        procedure: 'dermal filler lips cheeks',
      );
      expect(filler, isNotNull);
      expect(filler!.priceMin, 950);
      expect(filler.rawProcedureText.toLowerCase(), contains('restylane'));

      final peel = selectEvidenceForProcedure(
        rows: rows,
        procedure: 'chemical peel facial',
      );
      expect(peel, isNotNull);
      expect(peel!.priceMin, 300);
      expect(peel.rawProcedureText.toLowerCase(), contains('chemical peel'));
      expect(peel.rawProcedureText.toLowerCase(), isNot(contains('add on')));
    });

    test('nested spa wrappers still extract a leaf peel price', () {
      const inner = '<div>Chemical Peel \$300</div>';
      final html = '<div>${'<div>' * 40}$inner${'</div>' * 40}</div>';
      final rows = extractPriceEvidence(
        html: html,
        sourceUrl: 'https://spa.example/peels',
      );
      final peel = selectEvidenceForProcedure(
        rows: rows,
        procedure: 'chemical peel facial',
      );
      expect(peel, isNotNull);
      expect(peel!.priceMin, 300);
    });

    test('BOTOX \$18.00 per unit is picked despite 30 days on the same page', () {
      const html = '''
        <ul>
          <li>BOTOX® Cosmetic \$18.00 per unit</li>
        </ul>
        <p>Consultation credited within 30 days of the initial visit.</p>
      ''';
      final rows = extractPriceEvidence(
        html: html,
        sourceUrl: 'https://www.miamiskinandvein.com/pricing/',
      );
      final picked = selectEvidenceForProcedure(
        rows: rows,
        procedure: 'Botox',
      );
      expect(picked, isNotNull);
      expect(picked!.priceMin, 18);
      expect(picked.currency, 'USD');
      expect(picked.priceType, PriceType.perUnit);
    });

    test('average-dose range beside a per-unit fee is not the price', () {
      // Verbatim markup from the live page. The fixture above trims the
      // trailing dose sentence, which is exactly what hid this: "40-50 units"
      // outranked "\$18.00" in parsePriceText and also pushed the blob to
      // three "amounts", so the stitched-catalog guard dropped the row.
      const html = '''
        <h3 class="intro card-feature-individual-subtitle">Injectable Treatments</h3>
        <div class="card-feature-individual-text"><ul>
        <li><a href="/injectables-fillers/botox-cosmetic/"><strong>BOTOX&reg; Cosmetic</strong></a><strong> </strong> \$18.00 per unit. On average, 40-50 units of BOTOX&reg; are used to treat the entire upper face (frown lines, horizontal forehead lines, crow's feet, eyebrow raise).</li>
        <li><a href="/injectables-fillers/restylane/"><strong>Restylane&reg;</strong></a> \$950 per syringe.</li>
        </ul></div>
      ''';
      final rows = extractPriceEvidence(
        html: html,
        sourceUrl: 'https://www.miamiskinandvein.com/pricing/',
      );
      final botox = rows.where(
        (r) => r.rawProcedureText.contains('BOTOX'),
      );
      expect(botox, isNotEmpty, reason: 'dose range must not drop the row');
      expect(botox.first.priceMin, 18);
      expect(botox.first.priceMax, 18);
      expect(botox.first.priceType, PriceType.perUnit);
      expect(botox.first.priceMin, isNot(40));
    });

    test('a Botox search prefers BOTOX over cheaper Dysport units', () {
      // Same clinic, same menu: $18/unit Botox and $6/unit Dysport. Dysport
      // units are not Botox units, so the cheaper row must not win a Botox
      // search — in either DOM order.
      const botox = '<li><strong>BOTOX&reg; Cosmetic</strong> \$18.00 per '
          'unit. On average, 40-50 units are used.</li>';
      const dysport = '<li><strong>Dysport&reg;</strong> \$6.00 per unit. '
          'On average, 120-150 units are used.</li>';
      for (final html in ['<ul>$botox$dysport</ul>', '<ul>$dysport$botox</ul>']) {
        final picked = selectEvidenceForProcedure(
          rows: extractPriceEvidence(
            html: html,
            sourceUrl: 'https://www.miamiskinandvein.com/pricing/',
          ),
          procedure: 'Botox anti-wrinkle injection',
        );
        expect(picked, isNotNull);
        expect(picked!.priceMin, 18);
        expect(picked.rawProcedureText, contains('BOTOX'));
      }

      // A clinic that only lists Dysport still quotes it: this is a
      // preference between rows, not a rejection.
      final only = selectEvidenceForProcedure(
        rows: extractPriceEvidence(
          html: '<ul>$dysport</ul>',
          sourceUrl: 'https://www.miamiskinandvein.com/pricing/',
        ),
        procedure: 'Botox anti-wrinkle injection',
      );
      expect(only, isNotNull);
      expect(only!.priceMin, 6);
    });

    test('dose ranges are stripped, published price ranges are not', () {
      expect(
        parsePriceText(
          r'BOTOX® Cosmetic $18.00 per unit. On average, 40-50 units of '
          'BOTOX® are used to treat the entire upper face.',
        )?.priceMin,
        18,
      );
      expect(
        parsePriceText(r'Dysport® $6.00 per unit. On average, 120-150 units.')
            ?.priceMin,
        6,
      );
      expect(
        parsePriceText(r'BOTOX® $18.00 per unit. On average, 40 to 50 units.')
            ?.priceMin,
        18,
      );
      // "per" between the amount and the unit means this really is a range.
      final session = parsePriceText(r'UltraClear $2,500 - $4,000 per session');
      expect(session?.priceMin, 2500);
      expect(session?.priceMax, 4000);
      final rhino = parsePriceText(r'Rhinoplasty $6,000-$9,000');
      expect(rhino?.priceMin, 6000);
      expect(rhino?.priceMax, 9000);
      // One published price, not three amounts stitched from a catalog.
      expect(
        countPriceLikeAmounts(
          r'BOTOX® Cosmetic $18.00 per unit. On average, 40-50 units used.',
        ),
        1,
      );
    });

    test('SkinLocal frequency copy is not the peel title', () {
      const html = '''
        <div class="peel-block">
          <p>FREQUENCY: Every 4 to 6 weeks, depending on provider discretion</p>
          <h2>PRICING</h2>
          <div>FACE VI PEEL \$375</div>
          <div>SMALL BODY PEEL \$400</div>
        </div>
      ''';
      final rows = extractPriceEvidence(
        html: html,
        sourceUrl: 'https://theskinlocal.com/skin-treatments/peels/',
      );
      final peel = selectEvidenceForProcedure(
        rows: rows,
        procedure: 'chemical peel facial',
      );
      expect(peel, isNotNull);
      expect(peel!.priceMin, 375);
      expect(
        peel.rawProcedureText.toLowerCase(),
        contains('face vi peel'),
      );
      expect(
        peel.rawProcedureText.toLowerCase(),
        isNot(contains('discretion')),
      );
      expect(
        peel.rawProcedureText.toLowerCase(),
        isNot(contains('pricing')),
      );
    });

    test('GetClearBeauty series quote is not a clinic peel FROM', () {
      const html = '''
        <p>A VI Peel nationally typically costs \$250 to \$375 per session.
        A full series nationally typically runs \$600.</p>
      ''';
      final picked = selectEvidenceForProcedure(
        rows: extractPriceEvidence(
          html: html,
          sourceUrl: 'https://getclearbeauty.com/vi-peel/',
        ),
        procedure: 'chemical peel facial',
      );
      expect(picked, isNull);
    });

    test('Dubai DCS table inherits Cost (AED) from the header cell', () {
      const html = '''
        <table>
          <tbody>
            <tr>
              <td><b>Botox treatment</b></td>
              <td><b>Cost (AED)</b></td>
            </tr>
            <tr>
              <td>Unit price of botox 25-40</td>
              <td>25-40</td>
            </tr>
            <tr>
              <td>Forehead starting</td>
              <td>500 &#8211; 1000</td>
            </tr>
            <tr>
              <td>Crows feet starting</td>
              <td>500 &#8211; 1000</td>
            </tr>
            <tr>
              <td>Botox underarms starting</td>
              <td>2500-4000</td>
            </tr>
          </tbody>
        </table>
        <p>The average starting price of Botox treatment in Dubai is AED 42 per unit.</p>
      ''';
      const url =
          'https://www.dubaicosmeticsurgery.com/cosmetic-injectables/injectables-botox-cost/';
      final rows = extractPriceEvidence(html: html, sourceUrl: url);
      expect(rows, isNotEmpty);
      expect(rows.any((r) => r.currency == 'AED' && r.priceMin == 500), isTrue);
      final picked = selectEvidenceForProcedure(
        rows: rows,
        procedure: 'Botox anti-wrinkle injection',
      );
      expect(picked, isNotNull);
      expect(picked!.currency, 'AED');
      expect(picked.priceMin, 500);
    });

    test('Dubai Mediclinic Monday offer is a last-resort FROM, not dropped', () {
      const html = '''
        <h1>Botox Mondays</h1>
        <p>كل يوم إثنين استغلي عرضنا الحصري على البوتوكس بسعر 999 درهمًا إماراتيًا.</p>
      ''';
      const url =
          'https://www.mediclinic.ae/ar/corporate/special-offers/botox-mondays.html';
      final picked = selectEvidenceForProcedure(
        rows: extractPriceEvidence(html: html, sourceUrl: url),
        procedure: 'Botox anti-wrinkle injection',
      );
      expect(picked, isNotNull);
      expect(picked!.priceMin, 999);
      expect(picked.currency, 'AED');
      expect(
        exploreCachedPriceNeedsReselect(
          rawProcedureText: picked.rawProcedureText,
          brand: picked.rawProcedureText,
          sourceUrl: url,
          procedure: 'Botox anti-wrinkle injection',
          rawPriceText: picked.rawPriceText,
          rawEvidence: picked.rawEvidence,
          priceMin: picked.priceMin,
          currency: picked.currency,
          priceExtractRevision: kExplorePriceExtractRevision,
        ),
        isFalse,
      );
    });

    test('hospital menu still keeps Botox after 80 surgical rows', () {
      final surgery = [
        for (var i = 0; i < 90; i++)
          '<li>Reducția mamară ${4500 + i} EUR</li>',
      ].join('\n');
      final html = '''
        <h1>Lista de prețuri</h1>
        <ul>
          $surgery
          <li>Toxina botulinică 1 zonă facial 70 EUR</li>
          <li>Ботокс лица (одна зона) 70 EUR</li>
        </ul>
      ''';
      final rows = extractPriceEvidence(
        html: html,
        sourceUrl: 'https://www.sancos.md/lista-de-preturi',
      );
      expect(rows.length, kExploreMaxEvidenceRowsPerPage);
      final picked = selectEvidenceForProcedure(
        rows: rows,
        procedure: 'Botox anti-wrinkle injection',
      );
      expect(picked, isNotNull);
      expect(picked!.priceMin, 70);
      expect(picked.currency, 'EUR');
    });

    test('Chisinau AMC per-unit lei Botox is kept', () {
      const html = '''
        <h1>Prices</h1>
        <ul>
          <li>Correcting facial wrinkles (1 unit botulinum toxin) 150 lei</li>
        </ul>
      ''';
      final picked = selectEvidenceForProcedure(
        rows: extractPriceEvidence(
          html: html,
          sourceUrl: 'https://amc.md/en/prices/',
        ),
        procedure: 'Botox anti-wrinkle injection',
      );
      expect(picked, isNotNull);
      expect(picked!.priceMin, 150);
      expect(
        exploreCurrencyFitsSearchCity(picked.currency, 'Chisinau'),
        isTrue,
      );
    });

    test('Alter-MED peel heading is not the card name', () {
      expect(
        looksLikePriceMenuHeadingOnly('The price of the procedure'),
        isTrue,
      );
      const html = '''
        <h3>The price of the procedure:</h3>
        <ul>
          <li>Superficial peeling – 850 lei</li>
          <li>Peeling BioRePeel – 1000 lei</li>
          <li>Deep peeling – 2000 lei</li>
        </ul>
      ''';
      final picked = selectEvidenceForProcedure(
        rows: extractPriceEvidence(
          html: html,
          sourceUrl: 'https://altermed.md/en/services/peeling',
        ),
        procedure: 'chemical peel facial',
      );
      expect(picked, isNotNull);
      expect(picked!.priceMin, 850);
      expect(
        looksLikePriceMenuHeadingOnly(picked.rawProcedureText),
        isFalse,
      );
      expect(
        picked.rawProcedureText.toLowerCase(),
        contains('peel'),
      );
    });

    test('chirurgie-estetica BA is implant 4500, not areola 800', () {
      const html = '''
        <table>
          <tr><td>Breast augmentation with anatomical implants Mentor USA</td><td>4500 €</td></tr>
          <tr><td>Correction of areolas (in case of breast augmentation)</td><td>800 €</td></tr>
          <tr><td>Removing breast implants</td><td>2000 €</td></tr>
        </table>
      ''';
      final picked = selectEvidenceForProcedure(
        rows: extractPriceEvidence(
          html: html,
          sourceUrl: 'https://www.chirurgie-estetica.md/en/prices/',
        ),
        procedure: 'breast augmentation',
      );
      expect(picked, isNotNull);
      expect(picked!.priceMin, 4500);
    });

    test('chirurgie-estetica rhinoplasty is multi-zone, not partial tip', () {
      const html = '''
        <table>
          <tr><td>Multi-zone Rhinoplasty</td><td>3700 €</td></tr>
          <tr><td>Partial Rhinoplasty</td><td>2500 €</td></tr>
        </table>
      ''';
      final picked = selectEvidenceForProcedure(
        rows: extractPriceEvidence(
          html: html,
          sourceUrl: 'https://www.chirurgie-estetica.md/en/prices/',
        ),
        procedure: 'rhinoplasty nose job',
      );
      expect(picked, isNotNull);
      expect(picked!.priceMin, 3700);
    });

    test('chirurgie-estetica filler is Stylage M 1 ml, not Hydro heading', () {
      const html = '''
        <table>
          <tr>
            <th>Services</th>
            <th>Description of services</th>
            <th>Price</th>
          </tr>
          <tr>
            <td>Filler dermatological injections</td>
            <td>Stylage Hydro</td>
            <td>140 €</td>
          </tr>
          <tr>
            <td>Filler dermatological injections</td>
            <td>Stylage M – 1,0 ml</td>
            <td>140 €</td>
          </tr>
          <tr>
            <td>Filler dermatological injections</td>
            <td>Stylage L – 1,0 ml</td>
            <td>170 €</td>
          </tr>
          <tr>
            <td>Filler dermatological injections</td>
            <td>Botulinum toxin (neuronox) – 1 unit</td>
            <td>9 €</td>
          </tr>
        </table>
      ''';
      final rows = extractPriceEvidence(
        html: html,
        sourceUrl: 'https://www.chirurgie-estetica.md/en/prices/',
      );
      final picked = selectEvidenceForProcedure(
        rows: rows,
        procedure: 'dermal filler lips cheeks',
      );
      expect(picked, isNotNull);
      expect(picked!.priceMin, 140);
      expect(picked.rawProcedureText.toLowerCase(), contains('stylage m'));
      expect(picked.rawProcedureText.toLowerCase(), isNot(contains('hydro')));
      expect(
        looksLikeGenericInjectableCategoryHeading(picked.rawProcedureText),
        isFalse,
      );
      final botox = selectEvidenceForProcedure(
        rows: rows,
        procedure: 'Botox anti-wrinkle injection',
      );
      expect(botox, isNotNull);
      expect(botox!.priceMin, 9);
      expect(botox.rawProcedureText.toLowerCase(), contains('neuronox'));
    });

    test('Estetic Sana Prețuri heading is not glued onto lip filler', () {
      expect(looksLikePriceMenuHeadingOnly('Prețuri'), isTrue);
      expect(looksLikeCatalogSectionHeading('Prețuri'), isTrue);
      const html = '''
        <h1>Prețuri</h1>
        <p>mărire buze, augmentare riduri, corecție volumetrică pomeți - 3500-5000 lei</p>
      ''';
      final picked = selectEvidenceForProcedure(
        rows: extractPriceEvidence(
          html: html,
          sourceUrl: 'https://estetic-sana.md/prices',
        ),
        procedure: 'dermal filler lips cheeks',
      );
      expect(picked, isNotNull);
      expect(picked!.priceMin, 3500);
      expect(picked.rawProcedureText.toLowerCase(), isNot(contains('prețuri')));
      expect(picked.rawProcedureText.toLowerCase(), isNot(contains('preturi')));
    });
  });
}
