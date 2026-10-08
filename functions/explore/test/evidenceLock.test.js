'use strict';

const assert = require('assert');
const {amountLiterallyInSource, lockPriceEvidence} = require('../evidenceLock');

assert.ok(amountLiterallyInSource('Lip Filler — Starting AED 990', 990));
assert.ok(amountLiterallyInSource('AED 30,000', 30000));
assert.ok(!amountLiterallyInSource('no price', 990));

{
  const lock = lockPriceEvidence({
    candidate: {
      rawProcedureText: 'Lip Filler',
      rawPriceText: 'Starting AED 990',
      priceMin: 990,
      currency: 'AED',
      sourceUrl: 'https://c.example/f',
      extractionMethod: 'list_item',
      rawEvidence: 'Lip Filler — Starting AED 990',
    },
    procedure: 'lip filler',
    sourceHtmlOrText: '<p>Lip Filler — Starting AED 990</p>',
  });
  assert.ok(lock.accepted, 'lip filler should accept');
  assert.ok(lock.relation.eligible);
}

{
  const lock = lockPriceEvidence({
    candidate: {
      rawProcedureText: 'Breast Augmentation + Breast Lift',
      rawPriceText: 'AED 45,000',
      priceMin: 45000,
      currency: 'AED',
      sourceUrl: 'https://c.example/p',
      extractionMethod: 'html_table',
      rawEvidence: 'Breast Augmentation + Breast Lift AED 45,000',
    },
    procedure: 'breast augmentation',
    sourceHtmlOrText: '<p>Breast Augmentation + Breast Lift AED 45,000</p>',
  });
  assert.ok(!lock.accepted, 'bundle must reject');
  assert.strictEqual(lock.relation.logToken, 'bundle');
}

{
  const lock = lockPriceEvidence({
    candidate: {
      rawProcedureText: 'Fillers',
      rawPriceText: 'AED 1,000–2,000',
      priceMin: 1000,
      currency: 'AED',
      sourceUrl: 'https://c.example/cost',
      extractionMethod: 'text_proximity',
      rawEvidence: 'Fillers in Dubai generally cost AED 1,000–2,000',
    },
    procedure: 'lip filler',
    sourceHtmlOrText: '<p>Fillers in Dubai generally cost AED 1,000–2,000</p>',
  });
  assert.ok(!lock.accepted, 'market average must reject');
  assert.strictEqual(lock.relation.logToken, 'market_information');
}

console.log('evidenceLock.test.js ok');
