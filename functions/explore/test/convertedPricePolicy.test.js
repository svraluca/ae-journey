'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const {evaluateExtractedPriceCandidate} = require('../priceSanity');
const {sanitizeVerifiedPoolRow} = require('../firestoreStore');
const {EXTRACT_REVISION} = require('../extractRevision');
const {clinicJson} = require('../getExploreProcedurePrices');

const row = (currency = 'EUR') => ({
  name: 'Aster Clinic', priceMin: 150, price_min: 150, priceMax: 200, currency,
  rawPriceText: `150–200 ${currency}`, rawEvidence: `Chemical Peel | 150–200 ${currency}`,
  rawProcedureText: 'Chemical Peel', procedure: 'chemical peel',
  sourceUrl: 'https://www.whatclinic.com/beauty-clinics/spain/madrid/aster-clinic',
  sourceType: 'marketplace', sourceCurrencyBasis: 'platform_converted',
  providerClinic: 'Aster Clinic', sourcePlatform: 'WhatClinic',
  extractionMethod: 'marketplace_menu', price_extract_revision: EXTRACT_REVISION,
});
test('approved conversion keeps literal fee and distinct provenance', () => {
  const result = evaluateExtractedPriceCandidate({...row(), logRejects: false});
  assert.equal(result.accepted, true, JSON.stringify(result));
  const serialized = clinicJson({place: {name: 'Aster Clinic'}, evidence: row(), city: 'Madrid'});
  const saved = sanitizeVerifiedPoolRow(serialized, 'chemical peel');
  assert.equal(saved.source_currency_basis, 'platform_converted');
  assert.equal(saved.price_min, 150);
});
test('uncontrolled RON cannot silently replace the default currency', () => {
  assert.equal(evaluateExtractedPriceCandidate({...row('RON'), logRejects: false}).reason,
      'marketplace_conversion_currency_unstable');
});
