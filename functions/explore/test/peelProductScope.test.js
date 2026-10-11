'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const cases = require('../../../test/fixtures/peel_product_scope_cases.json');
const {evaluateExtractedPriceCandidate} = require('../priceSanity');

for (const sample of cases) {
  test(`peel fee scope: ${sample.id}`, () => {
    const result = evaluateExtractedPriceCandidate({
      procedure: 'chemical peel', rawProcedureText: sample.label,
      rawEvidence: sample.price_first ? `${sample.amount} EUR | ${sample.label}` : `${sample.label} | ${sample.amount} EUR`,
      rawPriceText: `${sample.amount} EUR`, priceMin: sample.amount, currency: 'EUR',
      extractionMethod: 'dom_tariff_row', structuredOffer: true,
      clinicName: 'Aster Medical Clinic',
      sourceUrl: sample.url || 'https://aster.example/prices/',
      logRejects: false,
    });
    assert.equal(result.accepted, !sample.reject, JSON.stringify(result));
    if (sample.reject) assert.equal(result.reason, 'peel_product_not_procedure');
  });
}
