'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const {
  parsePriceText,
  applyLabelClassification,
  htmlLooksLikeJsShell,
  looksLikeClinicArticlePriceUrl,
  isNonLiteralClinicPriceUrl,
  looksLikeOfficialPriceListUrl,
} = require('../parsePrice');
const {extractPriceEvidence} = require('../priceExtractor');
const {selectEvidenceForProcedure, matchRawProcedureLabel,
  exploreCachedPriceNeedsReselect, laserRowSubtype} = require('../procedureMatch');
const {isInvalidClinicIdentity} = require('../identity');
const {
  evaluateExtractedPriceCandidate,
  looksLikePhoneNumber,
  looksLikeHairMarketPerGraftBlurb,
  looksLikeHairStaleLandingQuote,
} = require('../priceSanity');

test('phone numbers are never prices', () => {
  assert.equal(looksLikePhoneNumber('+34 621 145 099'), true);
  assert.equal(parsePriceText('+34 621 145 099'), null);
  assert.equal(parsePriceText('+34 933 623 707'), null);
  assert.equal(evaluateExtractedPriceCandidate({
    rawPriceText: '+34 621 145 099',
    priceMin: 34621145099,
    currency: 'EUR',
    extractionMethod: 'dom_block',
  }).reason, 'phone_number');
});

test('address, year, duration, reviews rejected; priced rows accepted', () => {
  assert.equal(evaluateExtractedPriceCandidate({
    rawPriceText: '08021 Barcelona',
    priceMin: 8021,
    currency: '',
    extractionMethod: 'text_proximity',
  }).accepted, false);
  assert.equal(evaluateExtractedPriceCandidate({
    rawPriceText: '2026',
    priceMin: 2026,
    currency: '',
    extractionMethod: 'text_proximity',
  }).reason, 'missing_price_semantics');
  assert.equal(evaluateExtractedPriceCandidate({
    rawPriceText: '30min',
    priceMin: 30,
    currency: '',
    extractionMethod: 'dom_block',
  }).reason, 'duration');
  assert.equal(evaluateExtractedPriceCandidate({
    rawPriceText: 'Desde 120 €',
    priceMin: 120,
    currency: 'EUR',
    extractionMethod: 'html_table',
  }).accepted, true);
  assert.equal(evaluateExtractedPriceCandidate({
    rawPriceText: '2026 EUR',
    priceMin: 2026,
    currency: 'EUR',
    extractionMethod: 'schema_offer',
    structuredOffer: true,
  }).accepted, true);
  assert.equal(evaluateExtractedPriceCandidate({
    rawPriceText: '€34621145099',
    priceMin: 34621145099,
    currency: 'EUR',
    extractionMethod: 'dom_block',
    procedure: 'Laser',
  }).accepted, false);
});

test('botox unit price survives duration copy', () => {
  assert.equal(evaluateExtractedPriceCandidate({
    rawPriceText: '$13 per unit',
    priceMin: 13,
    currency: 'USD',
    extractionMethod: 'html_table',
    rawEvidence: 'Wrinkle Relaxers 3-4 months $13 per unit',
    procedure: 'Botox',
  }).accepted, true);
  assert.equal(evaluateExtractedPriceCandidate({
    rawPriceText: '$18.00 per unit',
    priceMin: 18,
    currency: 'USD',
    extractionMethod: 'list_item',
    rawEvidence: 'BOTOX Cosmetic $18.00 per unit. Consultation credited within 30 days.',
    procedure: 'Botox',
  }).accepted, true);
});

test('average-dose range beside a per-unit fee is not the price', () => {
  // Mirrors the Dart regression: "40-50 units" used to outrank "$18.00".
  assert.equal(parsePriceText(
      'BOTOX® Cosmetic $18.00 per unit. On average, 40-50 units of BOTOX® ' +
      'are used to treat the entire upper face.').priceMin, 18);
  assert.equal(parsePriceText(
      'Dysport® $6.00 per unit. On average, 120-150 units.').priceMin, 6);
  assert.equal(parsePriceText(
      'BOTOX® $18.00 per unit. On average, 40 to 50 units.').priceMin, 18);
  // "per" between the amount and the unit means this really is a range.
  const session = parsePriceText('UltraClear $2,500 - $4,000 per session');
  assert.equal(session.priceMin, 2500);
  assert.equal(session.priceMax, 4000);
  const rhino = parsePriceText('Rhinoplasty $6,000-$9,000');
  assert.equal(rhino.priceMin, 6000);
  assert.equal(rhino.priceMax, 9000);
});

test('locale and currency forms', () => {
  assert.equal(parsePriceText('€350').priceMin, 350);
  assert.equal(parsePriceText('350 €').currency, 'EUR');
  assert.equal(parsePriceText('350 EUR').priceMin, 350);
  assert.equal(parsePriceText('1.600 €').priceMin, 1600);
  assert.equal(parsePriceText('1,600 €').priceMin, 1600);
  assert.equal(parsePriceText('1.600,00 €').priceMin, 1600);
  assert.equal(parsePriceText('1,600.00 €').priceMin, 1600);
  assert.equal(parsePriceText('350,00 €').priceMin, 350);
  assert.equal(parsePriceText('£250').currency, 'GBP');
  assert.equal(parsePriceText('1.200 RON').priceMin, 1200);
  assert.equal(parsePriceText('1200 lei').currency, 'RON');
  assert.equal(parsePriceText('AED 900').currency, 'AED');
  const from = parsePriceText('from 150 €');
  assert.equal(from.priceMin, 150);
  assert.equal(from.priceMax, 150);
  assert.equal(from.priceType, 'from');
  const mangled = parsePriceText('from 163 61 €');
  assert.ok(mangled);
  assert.ok(Math.abs(mangled.priceMin - 163.61) < 0.001);
  assert.equal(mangled.currency, 'EUR');
  assert.ok(Math.abs(parsePriceText('from 40 90 €').priceMin - 40.9) < 0.001);
  assert.equal(parsePriceText('1 600 €').priceMin, 1600);
  const stitched = parsePriceText(
      'Promo 199 AED. Standard 399 AED. Deep 1299 AED. VIP 1499 AED.');
  assert.equal(stitched.priceMin, 199);
  assert.equal(stitched.priceMax, 199);
});

test('A — Spanish botox table', () => {
  const html = '<table><tr><td>Toxina botulínica 1 zona</td><td>250 €</td></tr></table>';
  const rows = extractPriceEvidence({html, sourceUrl: 'https://clinic.example/precios'});
  const picked = selectEvidenceForProcedure(rows, 'Botox');
  assert.ok(picked);
  assert.equal(picked.procedureFamily, 'botox');
  assert.equal(picked.priceMin, 250);
  assert.equal(picked.currency, 'EUR');
  assert.equal(picked.extractionMethod, 'html_table');
});

test('B — Lip Lift must not become filler', () => {
  const html = '<div class="service"><h2>Lip Lift</h2><span>1600 €</span></div>';
  const rows = extractPriceEvidence({html, sourceUrl: 'https://example.com/lift'});
  const picked = selectEvidenceForProcedure(rows, 'lip filler');
  assert.equal(picked, null);
  const match = matchRawProcedureLabel('Lip Lift', 'lip filler');
  assert.equal(match.rejectReason, 'wrong_family_lip_lift');
});

test('C — WooCommerce sale uses ins as active price', () => {
  const html = '<h1>Aumento de labios</h1><p class="price"><del>391€</del><ins>299€</ins></p>';
  const rows = extractPriceEvidence({html, sourceUrl: 'https://tienda.clinicalondres.es/aumento'});
  assert.ok(rows.length);
  const sale = rows.find((r) => r.priceType === 'sale' || r.priceMin === 299);
  assert.ok(sale);
  assert.equal(sale.priceMin, 299);
  assert.equal(sale.priceMax, 391);
  assert.equal(sale.priceType, 'sale');
});

test('D — number elsewhere is not Botox', () => {
  const html = `
    <div><h2>Botox</h2><p>Contact for price</p></div>
    <div><h2>Laser</h2><p>150€</p></div>`;
  const rows = extractPriceEvidence({html, sourceUrl: 'https://clinic.example/menu'});
  const picked = selectEvidenceForProcedure(rows, 'Botox');
  assert.equal(picked, null);
});

test('E — consultation is not the filler price', () => {
  const html = `
    <div class="service"><h2>Consulta inicial</h2><span>50 €</span></div>
    <div class="service"><h2>Aumento de labios</h2><span>350 €</span></div>`;
  const rows = extractPriceEvidence({html, sourceUrl: 'https://clinic.example/precios'});
  const picked = selectEvidenceForProcedure(rows, 'Fillers');
  assert.ok(picked);
  assert.equal(picked.priceMin, 350);
});

test('F — invalid clinic title', () => {
  assert.equal(isInvalidClinicIdentity('hasta un 70% dto.'), true);
  assert.equal(isInvalidClinicIdentity('Clínica Sermed'), false);
});

test('G — AI cannot mutate parsed price', () => {
  const evidence = {
    rawProcedureText: 'Aumento de labios',
    rawPriceText: '350 €',
    priceMin: 350,
    priceMax: 350,
    currency: 'EUR',
  };
  const merged = applyLabelClassification(evidence, {family: 'filler', price: 999});
  assert.equal(merged.priceMin, 350);
  assert.equal(merged.procedureFamily, 'filler');
});

test('H — JS shell requests renderer, not AI', () => {
  const html = `<!doctype html><html><head>${'<script src="app.js"></script>'.repeat(50)}</head>` +
      '<body><div id="root"></div></body></html>';
  assert.equal(htmlLooksLikeJsShell(html), true);
  const rows = extractPriceEvidence({html, sourceUrl: 'https://spa.example'});
  assert.equal(rows.length, 0);
});

test('I — De Felipe HA 1 vial beats rhinomodelación for Fillers', () => {
  const html = `
    <h3>Ácido hialurónico</h3>
    <ul>
      <li>1 vial <span>305€</span></li>
      <li>2 viales <span>550€</span></li>
      <li>Rinomodelación con ácido hialurónico 1 vial <span>405€</span></li>
    </ul>`;
  const rows = extractPriceEvidence({html, sourceUrl: 'https://www.defelipe.com/precios/'});
  const picked = selectEvidenceForProcedure(rows, 'Fillers');
  assert.ok(picked);
  assert.equal(picked.priceMin, 305);
  const match = matchRawProcedureLabel(
    'Rinomodelación con ácido hialurónico 1 vial', 'Fillers');
  assert.equal(match.rejectReason, 'wrong_family_rhinomodeling');
});

test('J — Sermed lip min is 180 not Radiesse 250', () => {
  const html = `
    <div class="service"><h2>AUMENTO DE LABIOS</h2><span>Desde 180 €</span></div>
    <div class="service"><h2>AUMENTO DE LABIOS: OFERTA ACTUAL</h2><span>Desde 150 €</span></div>
    <div class="service"><h2>RADIESSE</h2><span>Desde 250 €</span></div>
    <div class="service"><h2>RELLENO DE POMULOS</h2><span>Desde 180 €</span></div>`;
  const rows = extractPriceEvidence({html, sourceUrl: 'https://www.clinicasermedbcn.com/book-online'});
  const picked = selectEvidenceForProcedure(rows, 'Fillers');
  assert.ok(picked);
  assert.equal(picked.priceMin, 180);
  assert.equal(picked.procedureCanonical, 'lip_filler');
});

test('K — Londres sale is 299 not 300', () => {
  const html = '<h1>Aumento de labios, 1 vial</h1><p class="price"><del>332,22€</del><ins>299€</ins></p>';
  const rows = extractPriceEvidence({
    html,
    sourceUrl: 'https://tienda.clinicalondres.es/barcelona-bonanova/productos-rebajados',
  });
  const picked = selectEvidenceForProcedure(rows, 'Fillers');
  assert.ok(picked);
  assert.equal(picked.priceMin, 299);
});

test('L — blog cost guide is not official clinic evidence', () => {
  const {classifyPriceSourceType, isNonLiteralClinicPriceUrl} = require('../parsePrice');
  assert.equal(isNonLiteralClinicPriceUrl(
    'https://santeclinics.com/blog/laser-treatment-cost-barcelona'), true);
  assert.equal(classifyPriceSourceType(
    'https://santeclinics.com/blog/laser-treatment-cost-barcelona'), 'search_snippet');
  assert.equal(isNonLiteralClinicPriceUrl(
    'https://clinicapogany.ro/articole/pret-rinoplastie-bucuresti-cat-costa'), true);
  assert.equal(isNonLiteralClinicPriceUrl(
    'https://clinicaark.ro/preturi/preturi_rinoplastie'), false);
  assert.equal(isNonLiteralClinicPriceUrl(
    'https://www.biolitedubai.com/botox-aftercare-in-dubai-how-to-maximize-your-results/'), true);
});

test('N — BePerfect lip filler is Juvederm 1900, not JSON-LD 600-5200', () => {
  const html = `
    <script type="application/ld+json">
    {"@type":"Service","name":"Marire buze cu acid hialuronic",
     "offers":{"@type":"AggregateOffer","lowPrice":"600","highPrice":"5200","priceCurrency":"RON"}}
    </script>
    <table>
      <tr><td>Acid Hialuronic – Juvederm 1 ml (buze, pomeți, jaw line)</td><td>1.900 RON</td></tr>
      <tr><td>Full face Acid Hialuronic – Juvederm 4 ml</td><td>5.200 RON</td></tr>
      <tr><td>Acid hialuronic 1 ml</td><td>1.500 RON</td></tr>
      <tr><td>Hialuronidază (Topirea acidului hialuronic inestetic)</td><td>600 RON</td></tr>
    </table>`;
  const rows = extractPriceEvidence({
    html,
    sourceUrl: 'https://beperfect.ro/servicii/marire-buze/',
  });
  const picked = selectEvidenceForProcedure(rows, 'dermal filler lips cheeks');
  assert.ok(picked);
  assert.equal(picked.priceMin, 1900);
  assert.equal(picked.procedureCanonical, 'lip_filler');
  assert.equal(
      matchRawProcedureLabel(
          'Hialuronidază (Topirea acidului hialuronic inestetic)', 'Fillers')
          .rejectReason,
      'wrong_family_hyaluronidase');
});

test('O — BePerfect Botox 1-zone is 900, not hyaluronidase 600', () => {
  const html = `
    <script type="application/ld+json">
    {"@type":"Service","name":"Toxina botulinică",
     "offers":{"@type":"AggregateOffer","lowPrice":"600","highPrice":"5200","priceCurrency":"RON"}}
    </script>
    <table>
      <tr><td>Hialuronidază (Topirea acidului hialuronic inestetic)</td><td>600 RON</td></tr>
      <tr><td>Periocular (coada ochiului/laba gâștii)</td><td>900 RON</td></tr>
      <tr><td>Glabelar (între sprâncene)</td><td>900 RON</td></tr>
      <tr><td>2 Zone:</td><td>1.400 RON</td></tr>
      <tr><td>Toate cele 3 Zone: Periocular + Glabelar + Frontal</td><td>1.900 RON</td></tr>
    </table>`;
  const rows = extractPriceEvidence({html, sourceUrl: 'https://beperfect.ro/tarife/'});
  const picked = selectEvidenceForProcedure(rows, 'Botox');
  assert.ok(picked);
  assert.equal(picked.priceMin, 900);
  assert.equal(picked.procedureFamily, 'botox');
});

test('Miami Forma RF is not Botox FROM', () => {
  const {exploreUrlConflictsWithProcedure} = require('../priceSanity');
  const html = `
    <h1>Forma</h1>
    <p>Forma starts at \$300 for a single lower-face session, with
    package and area-based pricing for full face.</p>`;
  assert.equal(selectEvidenceForProcedure(
      extractPriceEvidence({
        html,
        sourceUrl: 'https://www.miamiskinspa.com/services/forma',
      }),
      'Botox anti-wrinkle injection'), null);
  assert.equal(exploreUrlConflictsWithProcedure(
      'https://www.miamiskinspa.com/services/forma',
      'Botox anti-wrinkle injection'), true);
  assert.equal(exploreCachedPriceNeedsReselect({
    rawProcedureText: 'Forma',
    brand: 'Botox anti-wrinkle injection',
    sourceUrl: 'https://www.miamiskinspa.com/services/forma',
    procedure: 'Botox anti-wrinkle injection',
    rawPriceText: 'Forma starts at \$300',
    priceMin: 300,
    currency: 'USD',
  }), true);
  assert.equal(
      matchRawProcedureLabel('Forma', 'Botox anti-wrinkle injection').rejectReason,
      'wrong_family_energy_device');
});

test('P — Dr. Estetix Botox 1 zona is 800, not lip filler', () => {
  const html = `
    <table>
      <tr><td>Tratament toxină botulinică 1 zonă</td><td>800 RON</td></tr>
      <tr><td>Tratament toxină botulinică 2 zone</td><td>1300 RON</td></tr>
      <tr><td>Baby Botox 3 zone</td><td>1050 RON</td></tr>
      <tr><td>Skin Aura / Elasty 0.5 ml</td><td>750 RON</td></tr>
      <tr><td>Juvederm Ultra 1 ml</td><td>1600 RON</td></tr>
    </table>`;
  const rows = extractPriceEvidence({
    html, sourceUrl: 'https://drestetix.ro/pages/preturi-injectari',
  });
  const picked = selectEvidenceForProcedure(rows, 'Botox');
  assert.ok(picked);
  assert.equal(picked.priceMin, 800);
  const filler = selectEvidenceForProcedure(rows, 'Fillers');
  assert.ok(filler);
  assert.notEqual(filler.priceMin, 800);
});

test('Q — Doctor SKiN Botox is 1-zone wrinkle, not laser 429', () => {
  const html = `
    <table>
      <tr><td>Cheratoze actinice [zonă mică]</td><td>429 lei</td></tr>
      <tr><td>Corectarea zâmbetului gingival cu neuromodulator</td><td>546 lei</td></tr>
      <tr><td>Corectie riduri frunte toxina botulinica 1 zona</td><td>390 lei</td></tr>
      <tr><td>Corecție riduri 3 zone</td><td>1190 lei</td></tr>
    </table>`;
  const rows = extractPriceEvidence({
    html,
    sourceUrl: 'https://doctorskin.ro/estetica-medicala/eliminare-riduri-neuromodulator/',
  });
  const picked = selectEvidenceForProcedure(rows, 'Botox');
  assert.ok(picked);
  assert.equal(picked.priceMin, 390);
  assert.equal(
      matchRawProcedureLabel('Cheratoze actinice [zonă mică]', 'Botox').rejectReason,
      'wrong_family_laser');
});

test('R — Arabic Dubai menus match every family and price in dirhams', () => {
  const html = `
    <table>
      <tr><td>بوتوكس منطقة واحدة</td><td>499 درهم</td></tr>
      <tr><td>فيلر الشفاه 1 مل</td><td>1500 درهم</td></tr>
      <tr><td>إزالة الشعر بالليزر</td><td>350 درهم</td></tr>
      <tr><td>تقشير كيميائي للوجه</td><td>600 درهم</td></tr>
      <tr><td>عملية تجميل الانف</td><td>25000 درهم</td></tr>
      <tr><td>تكبير الثدي بالسيليكون</td><td>27000 درهم</td></tr>
      <tr><td>زراعة الشعر بتقنية القص</td><td>12000 درهم</td></tr>
    </table>`;
  const rows = extractPriceEvidence({
    html, sourceUrl: 'https://biolitedubai.com/ar/prices',
  });
  const cases = [
    ['Botox', 499],
    ['Fillers', 1500],
    ['laser hair removal', 350],
    ['chemical peel', 600],
    ['rhinoplasty nose job', 25000],
    ['breast augmentation', 27000],
    ['hair transplant FUE', 12000],
  ];
  for (const [procedure, amount] of cases) {
    const picked = selectEvidenceForProcedure(rows, procedure);
    assert.ok(picked, procedure);
    assert.equal(picked.priceMin, amount, procedure);
    assert.equal(picked.currency, 'AED', procedure);
  }
  assert.equal(parsePriceText('1500 درهم').currency, 'AED');
  assert.equal(parsePriceText('1500 درهم').priceMin, 1500);
});

test('S — clinic articles keep single amounts, drop brand ranges', () => {
  const url =
    'https://www.edenderma.com/post/best-botox-in-dubai-reviews-and-prices-2025';
  assert.equal(looksLikeClinicArticlePriceUrl(url), true);
  assert.equal(looksLikeClinicArticlePriceUrl('https://edenderma.com/prices'), false);

  const ranges = `
    <table>
      <tr><td>Allergan Botox</td><td>AED 1,000 to AED 2,500 per area</td></tr>
      <tr><td>Botulax Botox: AED 750 to AED 1,800 per area</td><td>750 AED</td></tr>
    </table>`;
  assert.equal(
      selectEvidenceForProcedure(
          extractPriceEvidence({html: ranges, sourceUrl: url}), 'Botox'),
      null);

  const single = `<table><tr><td>Botox one area</td><td>from 999 AED</td></tr></table>`;
  const picked = selectEvidenceForProcedure(
      extractPriceEvidence({html: single, sourceUrl: url}), 'Botox');
  assert.ok(picked);
  assert.equal(picked.priceMin, 999);
});

test('Premier Laser 1 Area beats Chin Dimpling', () => {
  const html = `
    <h2>Botox Pricing</h2>
    <table>
      <tr><td>Botox 3 Areas</td><td>Price: £999.00</td></tr>
      <tr><td>1 Area</td><td>Price: £175.00</td></tr>
      <tr><td>2 Areas</td><td>Price: £250.00</td></tr>
      <tr><td>Jawline Lift</td><td>Price: £299.00</td></tr>
      <tr><td>Bunny Lines</td><td>Price: £175.00</td></tr>
      <tr><td>Chin Dimpling</td><td>Price: £299.00</td></tr>
    </table>
  `;
  const picked = selectEvidenceForProcedure(
      extractPriceEvidence({
        html,
        sourceUrl: 'https://londonpremierlaser.co.uk/prices/injectables/',
      }),
      'Botox anti-wrinkle injection');
  assert.ok(picked);
  assert.equal(picked.priceMin, 175);
  assert.match(String(picked.rawProcedureText).toLowerCase(), /1 area/);
});

test('generic Botox FROM is 1-area, not Jawline £299 or competitor £120/£99', () => {
  const {looksLikeCityCostArticleUrl, looksLikeOfficialPriceListUrl} = require('../parsePrice');
  const premier = `
    <h2>Botox Pricing</h2>
    <div class="product-grid">
      <div class="product-item"><h3>Botox 3 Areas</h3>
        <span class="woocommerce-Price-amount">£999.00</span></div>
      <div class="product-item"><h3>1 Area</h3>
        <span class="woocommerce-Price-amount">£175.00</span></div>
      <div class="product-item"><h3>3 Areas</h3>
        <del><span class="woocommerce-Price-amount">£325.00</span></del>
        <ins><span class="woocommerce-Price-amount">£249.00</span></ins></div>
      <div class="product-item"><h3>Jawline Lift</h3>
        <span class="woocommerce-Price-amount">£299.00</span></div>
    </div>`;
  const premierPicked = selectEvidenceForProcedure(
      extractPriceEvidence({
        html: premier,
        sourceUrl: 'https://londonpremierlaser.co.uk/prices/injectables/',
      }),
      'Botox anti-wrinkle injection');
  assert.ok(premierPicked);
  assert.equal(premierPicked.priceMin, 175);
  assert.match(String(premierPicked.rawProcedureText).toLowerCase(), /1 area/);
  assert.equal(exploreCachedPriceNeedsReselect({
    rawProcedureText: 'Botox treatment',
    brand: 'Botox treatment',
    sourceUrl: 'https://londonpremierlaser.co.uk/prices/injectables/',
    procedure: 'Botox anti-wrinkle injection',
    rawPriceText: 'from £299',
    priceMin: 299,
  }), true);

  const sw11 = `
    <table>
      <thead><tr>
        <th>Treatment</th>
        <th>SW11 Medical Clinic (Clapham)</th>
        <th>High Street Salons (Non-Medical)</th>
        <th>Harley Street Clinics</th>
      </tr></thead>
      <tbody>
        <tr>
          <td>Botox (1 Area)</td>
          <td>£175</td>
          <td>£120 – £150</td>
          <td>£250 – £350</td>
        </tr>
      </tbody>
    </table>
    <table>
      <tr><td>Anti-wrinkle injections – 1 area</td><td>£175</td></tr>
    </table>`;
  const sw11Picked = selectEvidenceForProcedure(
      extractPriceEvidence({
        html: sw11,
        sourceUrl: 'https://sw11clinic-clapham.co.uk/aesthetic-medicine-in-clapham/',
      }),
      'Botox anti-wrinkle injection');
  assert.ok(sw11Picked);
  assert.equal(sw11Picked.priceMin, 175);
  assert.notEqual(sw11Picked.priceMin, 120);

  const warning = `<p>There are some clinics that are offering Botox® at ridiculously
    cheap prices, such as “Botox® for £99”, but cheapest is not always best.</p>`;
  const warningPicked = selectEvidenceForProcedure(
      extractPriceEvidence({
        html: warning,
        sourceUrl: 'https://facecliniclondon.com/botox-cost/',
      }),
      'Botox anti-wrinkle injection');
  assert.equal(warningPicked, null);
  assert.equal(evaluateExtractedPriceCandidate({
    rawPriceText: 'some clinics that are offering Botox® for £99, but cheapest is not always best',
    priceMin: 99,
    currency: 'GBP',
    extractionMethod: 'text_proximity',
    rawEvidence: 'There are some clinics that are offering Botox® at ridiculously cheap prices, such as “Botox® for £99”',
    procedure: 'botox',
    sourceUrl: 'https://facecliniclondon.com/botox-cost/',
  }).reason, 'competitor_quote');
  assert.equal(looksLikeCityCostArticleUrl('https://facecliniclondon.com/botox-cost/'), true);
  assert.equal(looksLikeOfficialPriceListUrl('https://facecliniclondon.com/botox-cost/'), false);
  assert.equal(exploreCachedPriceNeedsReselect({
    rawProcedureText: 'botox',
    brand: 'Botox treatment',
    sourceUrl: 'https://facecliniclondon.com/botox-cost/',
    procedure: 'Botox anti-wrinkle injection',
    rawPriceText: 'Botox® for £99',
    priceMin: 99,
  }), true);
});

test('2Glow 1 AREA is 99 GBP, not Shopify template 399.99 USD', () => {
  const {isNonLiteralClinicPriceUrl} = require('../parsePrice');
  const {exploreCachedPriceNeedsReselect} = require('../procedureMatch');
  const menu = `
    <ul>
      <li class="service-list--block">
        <p class="service-list--block-title-text">1 AREA</p>
        <div class="service-list--price">£99</div>
      </li>
      <li class="service-list--block">
        <p class="service-list--block-title-text">2 AREAS</p>
        <div class="service-list--price">£150</div>
      </li>
    </ul>
  `;
  const picked = selectEvidenceForProcedure(
      extractPriceEvidence({
        html: menu,
        sourceUrl: 'https://2glow.co.uk/pages/botox',
      }),
      'Botox anti-wrinkle injection');
  assert.ok(picked);
  assert.equal(picked.priceMin, 99);
  assert.equal(picked.currency, 'GBP');

  assert.equal(isNonLiteralClinicPriceUrl(
      'https://2glow.co.uk/pages/botox-template'), true);
  assert.equal(isNonLiteralClinicPriceUrl(
      'https://2glow.co.uk/pages/botox'), false);
  assert.equal(evaluateExtractedPriceCandidate({
    rawPriceText: 'from $399.99',
    priceMin: 399.99,
    currency: 'USD',
    extractionMethod: 'dom_block',
    sourceUrl: 'https://2glow.co.uk/pages/botox-template',
  }).reason, 'theme_placeholder');
  assert.equal(evaluateExtractedPriceCandidate({
    rawPriceText: 'from 400 USD',
    priceMin: 400,
    currency: 'USD',
    extractionMethod: 'dom_block',
    sourceUrl: 'https://2glow.co.uk/pages/botox',
  }).reason, 'tld_currency_mismatch');
  assert.equal(exploreCachedPriceNeedsReselect({
    rawProcedureText: 'Botox treatment',
    brand: 'Botox treatment',
    sourceUrl: 'https://2glow.co.uk/pages/botox',
    procedure: 'Botox anti-wrinkle injection',
    rawPriceText: 'from 400 USD',
    priceMin: 400,
    currency: 'USD',
  }), true);
});

test('laser hair vs skin named rows; generic laser treatment skipped', () => {
  const html = `
    <table>
      <tr><td>Laser Hair Removal peri anal</td><td>£14</td></tr>
      <tr><td>Photo Rejuvenation Face</td><td>£180.00</td></tr>
      <tr><td>Byonik hydrating laser facial</td><td>£197</td></tr>
      <tr><td>Laser treatment</td><td>£60</td></tr>
    </table>`;
  const url = 'https://the-laserclinic.com/pages/prices';
  const rows = extractPriceEvidence({html, sourceUrl: url});
  const hair = selectEvidenceForProcedure(rows, 'laser hair removal');
  assert.ok(hair);
  assert.equal(hair.priceMin, 14);
  assert.match(String(hair.rawProcedureText).toLowerCase(), /peri anal/);

  const skin = selectEvidenceForProcedure(rows, 'laser skin rejuvenation IPL');
  assert.ok(skin);
  assert.notEqual(String(skin.rawProcedureText).toLowerCase(), 'laser treatment');
  assert.match(
      String(skin.rawProcedureText).toLowerCase(),
      /photo rejuvenation|byonik/);

  assert.equal(laserRowSubtype('Photo Rejuvenation Face'), 'skin');
  assert.equal(exploreCachedPriceNeedsReselect({
    rawProcedureText: 'Laser treatment',
    brand: 'Laser treatment',
    sourceUrl: url,
    procedure: 'laser hair removal',
    rawPriceText: 'from 60 GBP',
    priceMin: 60,
    currency: 'GBP',
  }), true);
});

test('Enhance BA is 4595 from the menu row, not the financing heading', () => {
  const html = [
    '<h1>Breast surgery financing</h1>',
    '<p>We offer monthly finance options from 4595 GBP.</p>',
    '<table>',
    '<tr><td>Breast Enlargement (Boob Job)</td><td>from 4595 GBP</td></tr>',
    '<tr><td>Inverted Nipple</td><td>2500 GBP</td></tr>',
    '</table>',
  ].join('');
  const picked = selectEvidenceForProcedure(
      extractPriceEvidence({
        html,
        sourceUrl: 'https://enhancemedicalgroup.com/boob-job-cost',
      }),
      'breast augmentation');
  assert.ok(picked);
  assert.equal(picked.priceMin, 4595);
  assert.equal(picked.currency, 'GBP');
  assert.equal(/financ/i.test(String(picked.rawProcedureText)), false);

  assert.equal(evaluateExtractedPriceCandidate({
    rawPriceText: 'from 2500 GBP',
    priceMin: 2500,
    currency: 'GBP',
    extractionMethod: 'html_table',
    procedure: 'breast augmentation',
    sourceUrl: 'https://harleystreetbreastcentre.com/breast-augmentation/',
  }).reason, 'implausible_amount');
  assert.equal(exploreCachedPriceNeedsReselect({
    rawProcedureText: 'Breast augmentation',
    brand: 'Breast augmentation',
    sourceUrl: 'https://harleystreetbreastcentre.com/breast-augmentation/',
    procedure: 'breast augmentation',
    rawPriceText: 'from 2,500 GBP',
    priceMin: 2500,
    currency: 'GBP',
  }), true);
});

test('Harley bilateral FROM; Cadogan not 5k-7k market band; Nuffield not pain H3', () => {
  const harley = selectEvidenceForProcedure(
      extractPriceEvidence({
        html: [
          '<h1>Boob job cost</h1>',
          '<table>',
          '<tr><td>Breast augmentation</td><td>from £6,995</td></tr>',
          '<tr><td>Unilateral breast augmentation</td><td>from £6,495</td></tr>',
          '</table>',
        ].join(''),
        sourceUrl: 'https://www.harleymedical.co.uk/boob-job-cost',
      }),
      'breast augmentation');
  assert.ok(harley);
  assert.equal(harley.priceMin, 6995);
  assert.equal(/unilateral/i.test(String(harley.rawProcedureText)), false);

  const cadogan = selectEvidenceForProcedure(
      extractPriceEvidence({
        html: [
          '<p>The cost of a good boob job should be no less than £5,000 - £7,000.',
          'Most reputable clinics in this region given the cost.</p>',
          '<p>At the Cadogan Clinic in London, a boob job costs from £5,900</p>',
          '<table>',
          '<tr><td>Breast Enlargement - Unilateral Implants</td><td>£3,750</td></tr>',
          '<tr><td>Breast Enlargement - Bilateral Implants</td><td>£5,995</td></tr>',
          '</table>',
        ].join(''),
        sourceUrl: 'https://www.cadoganclinic.com/cosmetic-surgery/breast-surgery/breast-enlargement/',
      }),
      'breast augmentation');
  assert.ok(cadogan);
  assert.ok(cadogan.priceMin === 5900 || cadogan.priceMin === 5995);
  assert.notEqual(cadogan.priceMin, 5000);
  assert.ok((cadogan.priceMax - cadogan.priceMin) < 1);

  const nuffield = selectEvidenceForProcedure(
      extractPriceEvidence({
        html: [
          '<h1>Breast augmentation and enlargement</h1>',
          '<h3>Pain following breast enlargement surgery</h3>',
          '<p>The average guide price for breast augmentation at a Nuffield',
          'Health hospital is £8,579.</p>',
          '<table><tr><td>Treatment</td><td>from £8,579</td></tr></table>',
        ].join(''),
        sourceUrl: 'https://www.nuffieldhealth.com/treatments/breast-augmentation-enlargement',
      }),
      'breast augmentation');
  assert.ok(nuffield);
  assert.equal(nuffield.priceMin, 8579);
  assert.equal(/pain following/i.test(String(nuffield.rawProcedureText)), false);

  assert.equal(exploreCachedPriceNeedsReselect({
    rawProcedureText: 'Unilateral breast augmentation',
    brand: 'Unilateral breast augmentation',
    sourceUrl: 'https://www.harleymedical.co.uk/boob-job-cost',
    procedure: 'breast augmentation',
    rawPriceText: 'from £6,495',
    priceMin: 6495,
    currency: 'GBP',
  }), true);
  assert.equal(exploreCachedPriceNeedsReselect({
    rawProcedureText: 'Breast augmentation',
    brand: 'Breast augmentation',
    sourceUrl: 'https://www.cadoganclinic.com/boob-job-cost',
    procedure: 'breast augmentation',
    rawPriceText: 'from £5,000-£7,000',
    priceMin: 5000,
    priceMax: 7000,
    currency: 'GBP',
  }), true);
});

test('London peel menu prefers Juliette Armand over Cosmelan kit', () => {
  const html = [
    '<table>',
    '<tr><td>Cosmelan Peel Starter Kit</td><td>£900</td></tr>',
    '<tr><td>Chemical Peel Juliette Armand</td><td>from £200</td></tr>',
    '<tr><td>BioRePeel Face 1 Session</td><td>£250</td></tr>',
    '</table>',
  ].join('');
  const picked = selectEvidenceForProcedure(
    extractPriceEvidence({
      html,
      sourceUrl: 'https://skinlogicaesthetics.co.uk/price-list/',
    }),
    'chemical peel facial',
  );
  assert.ok(picked);
  assert.equal(picked.priceMin, 200);
  assert.notEqual(picked.priceMin, 900);
});

test('Face Clinic targeted add-on is not the Botox FROM', () => {
  const html = [
    '<table>',
    '<tr><td>One Area</td><td>from £250</td></tr>',
    '<tr><td>Targeted Areas (Bunny Lines)</td>',
    '<td>£90 each when added to another anti-wrinkle treatment</td></tr>',
    '</table>',
  ].join('');
  const picked = selectEvidenceForProcedure(
    extractPriceEvidence({
      html,
      sourceUrl: 'https://facecliniclondon.com/prices',
    }),
    'Botox anti-wrinkle injection',
  );
  assert.ok(picked);
  assert.equal(picked.priceMin, 250);
});

test('London rhinoplasty — closed FROM not tip band; price-guide beats male copy', () => {
  const {isNonLiteralClinicPriceUrl, looksLikeOfficialPriceListUrl,
    looksLikeCityCostArticleUrl, looksLikeClinicArticlePriceUrl} = require('../parsePrice');
  assert.equal(looksLikeCityCostArticleUrl(
      'https://londonprivatehospital.uk/rhinoplasty-london-prices/'), true);
  assert.equal(isNonLiteralClinicPriceUrl(
      'https://www.cadoganclinic.com/price-guide/'), false);
  assert.equal(looksLikeOfficialPriceListUrl(
      'https://www.cadoganclinic.com/price-guide/'), true);
  assert.equal(looksLikeClinicArticlePriceUrl(
      'https://www.cadoganclinic.com/for-men/rhinoplasty-for-men/'), true);

  const lph = `
    <h2>Typical London Price Ranges</h2>
    <p>On average: Tip rhinoplasty £3,500–£5,500</p>
    <table>
      <tr><td>Closed Rhinoplasty</td><td>from £6,900</td></tr>
      <tr><td>Open Rhinoplasty</td><td>from £7,999</td></tr>
      <tr><td>Tip Rhinoplasty</td><td>from £4,900</td></tr>
    </table>`;
  const lphPicked = selectEvidenceForProcedure(
    extractPriceEvidence({
      html: lph,
      sourceUrl: 'https://londonprivatehospital.uk/treatments/rhinoplasty/',
    }),
    'rhinoplasty nose job',
  );
  assert.ok(lphPicked);
  assert.equal(lphPicked.priceMin, 6900);

  const cadogan = `
    <p>Price guide revised in June 2026</p>
    <table>
      <tr><td>Rhinoplasty</td><td>£7,995</td></tr>
      <tr><td>Ultrasonic Rhinoplasty</td><td>£8,395</td></tr>
      <tr><td>Revision Rhinoplasty</td><td>£10,995</td></tr>
    </table>
    <p>A male nose job procedure starts from £6,900 at the Cadogan Clinic.</p>`;
  const cadoganPicked = selectEvidenceForProcedure(
    extractPriceEvidence({
      html: cadogan,
      sourceUrl: 'https://www.cadoganclinic.com/price-guide/',
    }),
    'rhinoplasty nose job',
  );
  assert.ok(cadoganPicked);
  assert.equal(cadoganPicked.priceMin, 7995);

  assert.equal(exploreCachedPriceNeedsReselect({
    rawProcedureText: 'Rhinoplasty',
    brand: 'rhinoplasty nose job',
    sourceUrl: 'https://www.cadoganclinic.com/for-men/rhinoplasty-for-men/',
    procedure: 'rhinoplasty nose job',
    rawPriceText: 'starts from £6,900',
    priceMin: 6900,
    currency: 'GBP',
  }), true);
  assert.equal(exploreCachedPriceNeedsReselect({
    rawProcedureText: 'Primary / Closed Rhinoplasty',
    brand: 'rhinoplasty nose job',
    sourceUrl: 'https://nizarhamadeh.com/rhinoplasty/',
    procedure: 'rhinoplasty nose job',
    rawPriceText: 'from £7,998',
    priceMin: 7998,
    currency: 'GBP',
  }), false);
  assert.equal(evaluateExtractedPriceCandidate({
    rawPriceText: 'from £3,500–£5,500',
    priceMin: 3500,
    priceMax: 5500,
    currency: 'GBP',
    extractionMethod: 'html_table',
    procedure: 'rhinoplasty nose job',
  }).accepted, false);
});

test('London rhinoplasty market guide rejected; hospital guide not typical', () => {
  const {isNonLiteralClinicPriceUrl} = require('../parsePrice');
  const {
    looksLikeCityMarketPricingGuideUrl,
    looksLikeHospitalFeesOnlyQuote,
    looksLikeRoundedMarketPriceSpread,
  } = require('../priceSanity');
  const ardaGuide =
      'https://ardakucukguven.com/rhinoplasty-cost-in-london-complete-pricing-guide/';
  assert.equal(isNonLiteralClinicPriceUrl(ardaGuide), true);
  assert.equal(looksLikeCityMarketPricingGuideUrl(ardaGuide), true);
  assert.equal(looksLikeRoundedMarketPriceSpread({
    priceMin: 7000, priceMax: 15000, currency: 'GBP',
    procedure: 'rhinoplasty nose job',
  }), true);

  const arda = `
    <h1>Rhinoplasty Cost in London: Complete Pricing Guide</h1>
    <p>London rhinoplasty prices typically range from £6,000-£15,000.</p>
    <p>Ethnic rhinoplasty £7,000–£15,000</p>`;
  assert.equal(selectEvidenceForProcedure(
      extractPriceEvidence({html: arda, sourceUrl: ardaGuide}),
      'rhinoplasty nose job'), null);

  const enhance = `
    <p>Rhinoplasty from £6,295</p>
    <table><tr><td>Rhinoplasty (Nose Job)</td><td>£6,295</td></tr></table>`;
  const e = selectEvidenceForProcedure(
      extractPriceEvidence({
        html: enhance,
        sourceUrl: 'https://enhancemedicalgroup.com/face-surgery/rhinoplasty',
      }),
      'rhinoplasty nose job');
  assert.ok(e);
  assert.equal(e.priceMin, 6295);

  assert.equal(looksLikeHospitalFeesOnlyQuote(
      'from £3,000* (guide price). Excludes surgeon and anaesthetist fees.'),
      true);
  assert.equal(evaluateExtractedPriceCandidate({
    rawPriceText: 'from £7,000–£15,000',
    priceMin: 7000,
    priceMax: 15000,
    currency: 'GBP',
    extractionMethod: 'dom_block',
    procedure: 'rhinoplasty nose job',
    sourceUrl: ardaGuide,
  }).reason, 'market_information');
  assert.equal(exploreCachedPriceNeedsReselect({
    rawProcedureText: 'Ethnic Rhinoplasty',
    brand: 'rhinoplasty nose job',
    sourceUrl: ardaGuide,
    procedure: 'rhinoplasty nose job',
    rawPriceText: 'from £7,000–£15,000',
    priceMin: 7000,
    priceMax: 15000,
    currency: 'GBP',
  }), true);
});

test('Harley Medical official nose-job-cost, not finance or boob-job-cost', () => {
  const {
    exploreUrlConflictsWithProcedure,
    looksLikeTreatmentFinanceUrl,
  } = require('../priceSanity');
  const {scorePriceUrl} = require('../urlRank');
  const boobUrl = 'https://www.harleymedical.co.uk/boob-job-cost';
  const noseUrl = 'https://www.harleymedical.co.uk/nose-job-cost';
  const financeUrl = 'https://www.harleymedical.co.uk/nose-job-on-finance';
  assert.equal(exploreUrlConflictsWithProcedure(boobUrl, 'rhinoplasty nose job'), true);
  assert.equal(exploreUrlConflictsWithProcedure(noseUrl, 'rhinoplasty nose job'), false);
  assert.equal(looksLikeTreatmentFinanceUrl(financeUrl), true);
  assert.equal(scorePriceUrl(boobUrl, {procedure: 'rhinoplasty nose job'}), 0);
  assert.ok(scorePriceUrl(noseUrl, {procedure: 'rhinoplasty nose job'}) >= 5);

  const withNav = `
    <header><nav><a href="/nose-job-cost">Rhinoplasty</a></nav></header>
    <table>
      <tr><td>Breast augmentation</td><td>£6,995</td></tr>
    </table>`;
  assert.equal(selectEvidenceForProcedure(
      extractPriceEvidence({html: withNav, sourceUrl: boobUrl}),
      'rhinoplasty nose job'), null);

  const official = `
    <table>
      <tr><td>Rhinoplasty on tip - alar base reduction</td><td>£8,995</td></tr>
      <tr><td>Rhinoplasty (closed)</td><td>£8,995</td></tr>
      <tr><td>Rhinoplasty - reconstruction/secondary</td><td>£12,995</td></tr>
    </table>`;
  const picked = selectEvidenceForProcedure(
      extractPriceEvidence({html: official, sourceUrl: noseUrl}),
      'rhinoplasty nose job');
  assert.ok(picked);
  assert.equal(picked.priceMin, 8995);
  assert.match(String(picked.rawProcedureText).toLowerCase(), /closed/);

  const finance = `
    <table>
      <tr><td>Nose Reshaping (Rhinoplasty)</td><td>£6,625</td></tr>
    </table>`;
  assert.equal(selectEvidenceForProcedure(
      extractPriceEvidence({html: finance, sourceUrl: financeUrl}),
      'rhinoplasty nose job'), null);
});

test('London hair package FROM not graft count or effective per-graft', () => {
  const {looksLikeGraftOrFollicleQuantity, looksLikeEffectivePerGraftMarketing} =
      require('../priceSanity');
  assert.equal(looksLikeGraftOrFollicleQuantity('1,000 FUE grafts'), true);
  assert.equal(looksLikeEffectivePerGraftMarketing(
      'Lowest effective cost per graft £0.76'), true);

  const westminster = `
    <ul>
      <li>Cost of 500 FUE grafts – from £3500</li>
      <li>Cost of 1,000 FUE grafts – from £5000</li>
      <li>Private consultation – £75</li>
    </ul>`;
  const w = selectEvidenceForProcedure(
      extractPriceEvidence({
        html: westminster,
        sourceUrl: 'https://westminsterclinic.co.uk/cost-and-prices-for-hair-transplants-in-london/',
      }),
      'hair transplant FUE');
  assert.ok(w);
  assert.equal(w.priceMin, 3500);
  assert.notEqual(w.priceMin, 1000);

  const fks = `
    <p>Micro Sapphire FUE starts at £2,999 for up to 3,000 grafts.
    A £200 arrangement fee applies to every package, so the total
    payable ranges from £3,199 to £4,999.</p>
    <table>
      <tr><td>Lowest package price</td><td>£2,999</td></tr>
      <tr><td>Lowest total payable</td>
          <td>£3,199 including the £200 arrangement fee</td></tr>
    </table>
    <div><h3>PACKAGE 1</h3><p>Micro Sapphire FUE</p>
         <p>Up to 3.000 Grafts</p><p>£ 2,999</p></div>
    <div><h3>PACKAGE 2</h3><p>Up to 5.000 Grafts</p><p>£ 3,599</p></div>
    <table>
      <tr><td>Arrangement fee</td><td>£200</td><td>All packages</td></tr>
      <tr><td>Package 2</td><td>5,000</td><td>£3,799</td></tr>
    </table>`;
  const f = selectEvidenceForProcedure(
      extractPriceEvidence({
        html: fks,
        sourceUrl: 'https://www.fksclinic.co.uk/hair-transplant-uk/cost/',
      }),
      'hair transplant FUE');
  assert.ok(f);
  assert.equal(f.priceMin, 3199);
  assert.notEqual(f.priceMin, 2999);
  assert.notEqual(f.priceMin, 3799);

  const harley = `
    <p>FUE hair transplant costs start from £3,000 for small cases.</p>
    <table>
      <tr><td>500 grafts</td><td>£3,000 – £3,500</td></tr>
    </table>`;
  const h = selectEvidenceForProcedure(
      extractPriceEvidence({
        html: harley,
        sourceUrl: 'https://www.harleystreethairtransplant.co.uk/hair-transplant-cost/',
      }),
      'hair transplant FUE');
  assert.ok(h);
  assert.equal(h.priceMin, 3000);
  assert.notEqual(h.priceMin, 3499);

  assert.equal(exploreCachedPriceNeedsReselect({
    rawProcedureText: 'Hair transplant',
    brand: 'hair transplant FUE',
    sourceUrl: 'https://westminsterclinic.co.uk/cost-and-prices-for-hair-transplants-in-london/',
    procedure: 'hair transplant FUE',
    rawPriceText: '1,000 FUE grafts',
    priceMin: 1000,
    currency: 'GBP',
  }), true);

  const lhtcArticle =
      'https://londonhairtransplantclinic.uk/the-cost-of-hair-transplants-london-a-complete-breakdown/';
  assert.equal(isNonLiteralClinicPriceUrl(lhtcArticle), true);
  assert.equal(looksLikeClinicArticlePriceUrl(lhtcArticle), true);
  assert.equal(looksLikeHairMarketPerGraftBlurb(
      'FUE hair transplants in London often cost £2–£3 per graft'), true);
  assert.equal(looksLikeOfficialPriceListUrl('https://drmarktam.co.uk/fees/'), true);
  assert.equal(looksLikeHairStaleLandingQuote({
    sourceUrl: 'https://drmarktam.co.uk/fue-hair-transplant/',
    blob: 'Our hair transplant treatment fee starts from £5400 to £7600.',
    priceMin: 5400,
    priceMax: 7600,
  }), false);

  const lhtc = `
    <p>FUE hair transplants in London often cost £2–£3 per graft.</p>
    <p>FUT may be slightly cheaper, starting at £1.50 per graft.</p>`;
  assert.equal(selectEvidenceForProcedure(
      extractPriceEvidence({html: lhtc, sourceUrl: lhtcArticle}),
      'hair transplant FUE'), null);

  const tamLanding = `
    <p>Our hair transplant treatment fee starts from £5400 to £7600.</p>`;
  const freshLanding = selectEvidenceForProcedure(
      extractPriceEvidence({
        html: tamLanding,
        sourceUrl: 'https://drmarktam.co.uk/fue-hair-transplant/',
      }),
      'hair transplant FUE');
  assert.ok(freshLanding);
  assert.equal(freshLanding.priceMin, 5400);
  assert.equal(freshLanding.priceMax, 7600);
  assert.equal(freshLanding.currency, 'GBP');

  const expiredLanding = `
    <p>Our hair transplant treatment fee starts from £5400 to £7600.
    This price has expired and is no longer available.</p>`;
  assert.equal(looksLikeHairStaleLandingQuote({
    sourceUrl: 'https://drmarktam.co.uk/fue-hair-transplant/',
    blob: expiredLanding,
    priceMin: 5400,
    priceMax: 7600,
  }), true);
  assert.equal(selectEvidenceForProcedure(
      extractPriceEvidence({
        html: expiredLanding,
        sourceUrl: 'https://drmarktam.co.uk/fue-hair-transplant/',
      }),
      'hair transplant FUE'), null);

  const tamFees = `
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
    </table>`;
  const tam = selectEvidenceForProcedure(
      extractPriceEvidence({
        html: tamFees,
        sourceUrl: 'https://drmarktam.co.uk/fees/',
      }),
      'hair transplant FUE');
  assert.ok(tam);
  assert.equal(tam.priceMin, 14400);
  assert.notEqual(tam.priceMin, 250);
  assert.notEqual(tam.priceMin, 5400);
  assert.notEqual(tam.priceMin, 24000);

  assert.equal(exploreCachedPriceNeedsReselect({
    rawProcedureText: 'FUE hair transplant',
    brand: 'hair transplant FUE',
    sourceUrl: 'https://drmarktam.co.uk/fue-hair-transplant/',
    procedure: 'hair transplant FUE',
    rawPriceText: 'starts from £5400 to £7600',
    priceMin: 5400,
    priceMax: 7600,
    currency: 'GBP',
  }), false);
  assert.equal(exploreCachedPriceNeedsReselect({
    rawProcedureText: 'Hair transplant',
    brand: 'hair transplant FUE',
    sourceUrl: 'https://drmarktam.co.uk/fue-hair-transplant/',
    procedure: 'hair transplant FUE',
    rawPriceText: 'from 5400 £',
    priceMin: 5400,
    priceMax: 5400,
    currency: 'GBP',
  }), false);
  assert.equal(exploreCachedPriceNeedsReselect({
    rawProcedureText: 'Hair transplant',
    brand: 'hair transplant FUE',
    sourceUrl: 'https://drmarktam.co.uk/fue-hair-transplant/',
    procedure: 'hair transplant FUE',
    rawPriceText: 'Expired price: from 5400 £',
    priceMin: 5400,
    priceMax: 5400,
    currency: 'GBP',
  }), true);
  assert.equal(exploreCachedPriceNeedsReselect({
    rawProcedureText: 'Hair transplant',
    brand: 'hair transplant FUE',
    sourceUrl: 'https://www.fksclinic.co.uk/hair-transplant-uk/cost/',
    procedure: 'hair transplant FUE',
    rawPriceText: 'from 3,799 £',
    priceMin: 3799,
    currency: 'GBP',
  }), true);
  assert.equal(exploreCachedPriceNeedsReselect({
    rawProcedureText: 'FUE',
    brand: 'hair transplant FUE',
    sourceUrl: lhtcArticle,
    procedure: 'hair transplant FUE',
    rawPriceText: 'from £1.50 per graft',
    priceMin: 1.5,
    currency: 'GBP',
  }), true);
});

