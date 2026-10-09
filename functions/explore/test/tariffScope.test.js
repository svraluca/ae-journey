'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const cases = require('../../../verification/fixtures/tariff_scope.json');
const {evaluateExtractedPriceCandidate} = require('../priceSanity');
const {extractPriceEvidence} = require('../priceExtractor');
const {exploreEvidenceIsClinicOwnedPrice} = require('../priceOwnership');

test('shared price-owner cases are enforced independently of plausible amounts', () => {
  for (const c of cases) {
    const verdict = evaluateExtractedPriceCandidate({procedure:c.procedure,
      rawProcedureText:c.procedure, rawPriceText:`${c.amount} ${c.currency}`,
      priceMin:c.amount, currency:c.currency, rawEvidence:c.evidence,
      sourceUrl:'https://aster.example/prices/', extractionMethod:'html_table', logRejects:false});
    assert.equal(verdict.accepted,c.accepted,`${c.name}: ${verdict.reason}`);
    if (!c.accepted) assert.equal(verdict.reason,c.reason,c.name);
  }
});
test('geographic market tables cannot fill any treatment slot through cards or tables', () => {
  for (const procedure of ['Botox','Dermal filler','Chemical peel','Rhinoplasty','Breast augmentation','Hair transplant']) {
    for (const heading of ['Ülkelere Göre Fiyatlar','Şehirlere Göre Fiyatlar','Prices by country',
      'Cost across cities','Precios por países','Prix par pays','Preise nach Land','Prezzi per paese']) {
      const html = `<h1>${procedure}</h1><h2>${heading}</h2><table><tr><th>Country</th><th>Price</th></tr>
        <tr><td>${procedure} Turkey</td><td>€3,000</td></tr><tr><td>${procedure} France</td><td>€6,000</td></tr></table>`;
      assert.deepEqual(extractPriceEvidence({html,sourceUrl:'https://aster.example/prices/'}),[],`${procedure}: ${heading}`);
    }
  }
});
test('parallel-currency owned packages retain technique, base price and graft cap', () => {
  const html = '<div><h2>Aster Clinic Hair Transplant Prices</h2></div><div><table><tr><th>Package</th><th>Price EUR</th><th>Price USD</th></tr>' +
    '<tr><td>Micro Sapphire DHI</td><td>From €3,290 (up to 4,000 grafts) + €700 upgrade</td><td>From $3,800</td></tr></table></div>';
  const rows = extractPriceEvidence({html,sourceUrl:'https://aster.example/prices/'});
  assert.equal(rows.length,1);
  assert.equal(rows[0].priceMin,3290);
  assert.equal(rows[0].currency,'EUR');
  assert.match(rows[0].rawProcedureText,/DHI/);
  assert.match(rows[0].rawEvidence,/4,000 grafts/);
  assert.doesNotMatch(rows[0].rawEvidence,/700|3,800/);
  assert.equal(evaluateExtractedPriceCandidate({...rows[0],procedure:'hair transplant',
    pageContext:'foreign_price_comparison',logRejects:false}).accepted,true);
  assert.equal(exploreEvidenceIsClinicOwnedPrice({...rows[0],pageContext:'foreign_price_comparison',
    sourceUrl:'https://unrelated.example/prices/'}),false);
});
test('before-discount headers cannot leak old amounts through fallback extractors', () => {
  const html = '<h2>Botox</h2><table><tr><th>Treatment</th><th>Price Before Discount</th>' +
    '<th>Price After Discount</th></tr><tr><td>Botox 3 areas</td><td>1500 AED</td><td>799 AED</td></tr></table>';
  const rows = extractPriceEvidence({html,sourceUrl:'https://aster.example/prices/'});
  assert.ok(rows.length);
  assert.ok(rows.every((r) => r.priceMin === 799 && !/1500/.test(r.rawEvidence)));
});
