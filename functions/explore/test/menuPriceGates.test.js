'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const {
  evaluateExtractedPriceCandidate,
  looksLikeMonthlyFinancingQuotedAsPrice,
  looksLikeTypicalMarketRangeQuotedAsPrice,
} = require('../priceSanity');
const {extractPriceEvidence} = require('../priceExtractor');
const {selectEvidenceForProcedure} = require('../procedureMatch');
const {classifyProcedureRelation} = require('../procedureRelation');

test('syringe price survives results-last-a-month copy', () => {
  assert.equal(looksLikeMonthlyFinancingQuotedAsPrice({
    priceMin: 950,
    rawPriceText: '$950 per syringe',
    blob: 'Restylane $950 per syringe. Results typically last a month.',
  }), false);
  assert.equal(evaluateExtractedPriceCandidate({
    rawPriceText: '$950 per syringe',
    priceMin: 950,
    currency: 'USD',
    extractionMethod: 'list_item',
    rawEvidence: 'Restylane $950 per syringe. Results typically last a month.',
    procedure: 'Restylane',
  }).accepted, true);
});

test('monthly installment is still rejected', () => {
  assert.equal(evaluateExtractedPriceCandidate({
    rawPriceText: "$99/mo",
    priceMin: 99,
    currency: 'USD',
    extractionMethod: 'list_item',
  }).reason, 'monthly_financing');
});

test('typical sessions ranging is not a menu FROM', () => {
  const typical = 'Prices vary depending on the type and amount of filler used, with typical sessions ranging from $500 to $800 per syringe';
  assert.equal(looksLikeTypicalMarketRangeQuotedAsPrice({
    priceMin: 500,
    rawPriceText: typical,
    blob: typical,
  }), true);
  assert.equal(evaluateExtractedPriceCandidate({
    rawPriceText: typical,
    priceMin: 500,
    currency: 'USD',
    extractionMethod: 'text_proximity',
    rawEvidence: typical,
    procedure: 'filler',
  }).accepted, false);
});

test('mixed menu Restylane and Chemical Peel, not add-on or typical', () => {
  const html = `
    <h2>Injectable Treatments</h2>
    <ul><li>Restylane $950 per syringe.</li></ul>
    <p>Results typically last a month. Ask about monthly financing.</p>
    <p>Prices vary depending on the type and amount of filler used, with
    typical sessions ranging from $500 to $800 per syringe.</p>
    <div>Full upper face tox + 2 syringes filler $1500</div>
    <h2>Skin Care</h2>
    <div>Chemical Peel $300</div>
    <div>PEEL ADD ON $200</div>
  `;
  const rows = extractPriceEvidence({
    html,
    sourceUrl: 'https://clinic.example/pricing',
  });
  const filler = selectEvidenceForProcedure(rows, 'dermal filler lips cheeks');
  assert.ok(filler);
  assert.equal(filler.priceMin, 950);
  const peel = selectEvidenceForProcedure(rows, 'chemical peel');
  assert.ok(peel);
  assert.equal(peel.priceMin, 300);
  assert.equal(classifyProcedureRelation({
    requestedProcedure: 'dermal filler lips cheeks',
    label: 'Full upper face tox + 2 syringes filler',
    evidence: '$ 1500',
  }).eligible, false);
  assert.equal(classifyProcedureRelation({
    requestedProcedure: 'dermal filler lips cheeks',
    label: 'Lip Flip Standalone Treatment Session',
    evidence: '$ 100',
    pageHasFamilyWitness: true,
  }).eligible, false);
  assert.equal(classifyProcedureRelation({
    requestedProcedure: 'dermal filler lips cheeks',
    label: '$700 1 syringe filler',
    evidence: '$700 1 syringe filler',
  }).eligible, true);
  assert.equal(classifyProcedureRelation({
    requestedProcedure: 'chemical peel',
    label: 'PEEL ADD ON',
    evidence: '$200',
  }).relation, 'add_on');
});
