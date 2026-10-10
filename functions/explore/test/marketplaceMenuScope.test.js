'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const {extractPriceEvidence} = require('../priceExtractor');

const sourceUrl = 'https://us-uk.bookimed.com/clinic/aster-clinic/procedure=chemical-peel/';
const page = (amount, label = 'Chemical Peel', options = true) =>
  `<title>Aster Clinic</title><h1>Chemical Peel in Aster Clinic</h1>
  <div class="clinic-page__description">${options ?
    'The package costs $800. The standard chemical peel option costs $300. Both options are available.' :
    'The treatment costs $700. Hotel $90. Consultation $50.'}</div>
  <table><tr><th>Treatment</th><th>Price</th></tr><tr><td>${label}</td><td>$${amount}</td></tr></table>`;

test('unexplained generic marketplace amount is not a treatment fee', () => {
  const rows = extractPriceEvidence({html: page(700), sourceUrl});
  assert.ok(!rows.some(r => r.priceMin === 700));
});

test('matching option and an explicitly scoped treatment remain eligible', () => {
  for (const [amount,label] of [[300,'Chemical Peel'], [700,'Glycolic acid Chemical Peel']]) {
    const rows = extractPriceEvidence({html: page(amount,label), sourceUrl});
    assert.ok(rows.some(r => r.priceMin === amount && r.rawProcedureText.endsWith(label)));
  }
});

test('ancillary prices without treatment options do not remove the menu', () => {
  const rows = extractPriceEvidence({html: page(700,'Chemical Peel',false), sourceUrl});
  assert.ok(rows.some(r => r.priceMin === 700 && r.rawProcedureText.endsWith('Chemical Peel')));
});
