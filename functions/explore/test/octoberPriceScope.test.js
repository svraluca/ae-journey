'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const {evaluateExtractedPriceCandidate, looksLikeMultiSessionSeriesQuote,
  looksLikePartialRhinoplastyStarting} = require('../priceSanity');

const quote = (overrides = {}) => evaluateExtractedPriceCandidate({
  rawPriceText: '150 EUR', priceMin: 150, currency: 'EUR',
  extractionMethod: 'html_table', rawEvidence: 'Chemical peel 150 EUR',
  procedure: 'Chemical Peel', sourceUrl: 'https://aster.example/precios/',
  logRejects: false, ...overrides,
});

test('body peels cannot be promoted to chemical facial peels', () => {
  for (const label of ['Peeling corporal', 'Peeling Corporal Sales', 'Peeling enzimático']) {
    assert.equal(quote({rawEvidence: `${label} chemical peel 150 EUR`}).accepted, false);
  }
});
test('provider hair identity rejects otherwise bare Botox service', () => {
  assert.equal(quote({procedure: 'Botox', rawEvidence: 'Botox 150 EUR',
    clinicName: 'Peluquería Aster'}).reason, 'noninjectable_botox');
});
test('directory cards and booking category pages are rejected', () => {
  for (const url of ['https://multiestetica.com/precios/peeling',
    'https://gorgeousgetaways.com/price-list-guide/spain/',
    'https://booksy.com/es-es/s/botox/48892_barcelona']) {
    assert.equal(quote({sourceUrl: url}).accepted, false);
  }
});
test('Spanish multipacks and named rhinoplasty subtypes keep their scope', () => {
  assert.equal(looksLikeMultiSessionSeriesQuote('Peeling químico 3 sesiones 330€'), true);
  assert.equal(looksLikeMultiSessionSeriesQuote('Peeling químico 1 sesión 120€'), false);
  assert.equal(looksLikePartialRhinoplastyStarting('Rinoplastia racial 8500 EUR'), true);
  assert.equal(looksLikePartialRhinoplastyStarting('Rinoplastia primaria 6990 EUR'), false);
});
