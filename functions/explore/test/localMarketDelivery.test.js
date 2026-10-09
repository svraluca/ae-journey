'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const {classifyExplorePricePageContext, exploreEvidenceIsClinicOwnedPrice} = require('../priceOwnership');
const {evaluateExtractedPriceCandidate} = require('../priceSanity');

test('Turkish article estimates are rejected despite a clinic host and table flags', () => {
  for (const claim of ['Dudak dolgusu fiyatları genellikle 10.000 TL',
    'Dolgu fiyatları ortalama 45.000 TL', 'Botoks fiyatları 2026’da genellikle 6.500 TL',
    'Saç ekimi maliyeti 60.000 TL ile 90.000 TL arasında değişir']) {
    assert.equal(classifyExplorePricePageContext({sourceUrl: 'https://clinic.example/prices/', pageText: claim}), 'market_average');
    assert.equal(exploreEvidenceIsClinicOwnedPrice({pageContext: 'official_price_list', rawEvidence: claim}), false);
    assert.equal(evaluateExtractedPriceCandidate({rawPriceText: '10000 TRY', priceMin: 10000,
      currency: 'TRY', extractionMethod: 'html_table', rawEvidence: claim, procedure: 'dermal filler',
      sourceUrl: 'https://clinic.example/prices/', logRejects: false}).accepted, false);
  }
});
test('an actual local tariff is not mistaken for a market estimate', () => {
  assert.equal(exploreEvidenceIsClinicOwnedPrice({pageContext: 'informational_article',
    rawEvidence: 'Kliniğimizde dudak dolgusu ücreti 10.000 TL'}), true);
});
