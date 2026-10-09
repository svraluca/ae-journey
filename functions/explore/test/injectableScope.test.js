'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const cases = require('../../../test/fixtures/injectable_scope_cases.json');
const {injectableScopeRejection} = require('../injectableScope');
const {evaluateExtractedPriceCandidate} = require('../priceSanity');
const {stripInvalidCachedPrice} = require('../priceSanity');
const {extractPriceEvidence} = require('../priceExtractor');
const {buildFreshaPoolRow} = require('../marketplaces/importCity');

for (const c of cases) {
  test(`worldwide injectable scope: ${c.id}`, () => {
    const args = {procedure: c.procedure, label: c.label, evidence: c.evidence,
      provider: c.provider, sourceUrl: c.source_url};
    assert.equal(injectableScopeRejection(args), c.expected);
    if (c.expected) {
      const verdict = evaluateExtractedPriceCandidate({procedure: c.procedure,
        rawProcedureText: c.label, rawEvidence: `${c.evidence} | 350 EUR`,
        clinicName: c.provider, sourceUrl: c.source_url, priceMin: 350,
        rawPriceText: '350 EUR', currency: 'EUR', extractionMethod: 'html_table', logRejects: false});
      assert.equal(verdict.accepted, false);
      assert.equal(verdict.reason, c.expected);
      const cached = stripInvalidCachedPrice({name: c.provider,
        raw_procedure_text: c.label, price_evidence_text: `${c.evidence} | 350 EUR`,
        price_source_url: c.source_url, raw_price_text: '350 EUR', price_min: 350,
        currency: 'EUR', extraction_method: 'html_table', verified: true}, c.procedure,
      {logRejects: false});
      assert.equal(cached.price_min, 0);
      assert.equal(cached.price_rejection_reason, c.expected);
    }
  });
}

test('schema service description and category survive offer extraction', () => {
  const html = `<html><title>Aster Medical Clinic</title><script type="application/ld+json">${JSON.stringify({
    '@type': 'Service', name: 'Dermal filler', description: 'Crema cosmética',
    offers: {'@type': 'Offer', price: 350, priceCurrency: 'EUR'},
  })}</script></html>`;
  assert.deepEqual(extractPriceEvidence({html, sourceUrl: 'https://aster.example/prices/'}), []);
});

test('captured public Fresha pen and unqualified nail-venue offers cannot become medical fillers', () => {
  const html = fs.readFileSync(path.join(__dirname, '../../../test/fixtures/cleopatra_fresha_offers.html'), 'utf8');
  const rows = extractPriceEvidence({html,
    sourceUrl: 'https://www.fresha.com/a/cleopatra-nails-madrid-calle-arroyo-21-wmsg3rrr'});
  assert.ok(rows.every((row) => ![150, 199].includes(row.priceMin)));
  const fillers = rows.filter((row) => evaluateExtractedPriceCandidate({...row,
    procedure: 'dermal filler', logRejects: false}).accepted);
  assert.deepEqual(fillers, []);
});

test('Fresha import rejects pens and ambiguous nail-venue augmentation but keeps injections', () => {
  const base = {venue: {name: 'Aster Nails', venueUrl: 'https://www.fresha.com/a/aster-nails-madrid',
    currency: 'EUR', freshaVenueId: 'aster-nails-madrid'}, place: {name: 'Aster Nails'},
    exploreProcedure: 'Dermal filler', relation: {logToken: 'exact'}};
  const service = {name: 'Aumento de labios', price: 199, currency: 'EUR', rawPriceText: '199 EUR',
    description: 'INCLUYE 1 VIAL', category: 'HYALURON PEN'};
  assert.equal(buildFreshaPoolRow({...base, service}), null);
  assert.equal(buildFreshaPoolRow({...base, service: {...service, category: 'OFERTAS', price: 150,
    rawPriceText: '150 EUR'}}), null);
  const row = buildFreshaPoolRow({...base, service: {...service, category: 'MEDICINA ESTÉTICA',
    description: 'Inyecciones de ácido hialurónico. INCLUYE 1 VIAL'}});
  assert.ok(row);
  assert.match(row.rawEvidence, /Inyecciones/);
  assert.match(row.rawEvidence, /MEDICINA ESTÉTICA/);
});
