'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const {evaluateExtractedPriceCandidate, botoxAmountOwnedByFiller} = require('../priceSanity');
const {looksLikeAddressNumber} = require('../priceSanity');

test('Barcelona anti-frizz hair service never fills an injectable Botox slot', () => {
  for (const label of ['Anti-frizz Botox', 'Botox capilar', 'Botox antiencrespado']) {
    const result = evaluateExtractedPriceCandidate({procedure: 'Botox', priceMin: 115,
      currency: 'EUR', rawPriceText: '115 EUR', rawEvidence: `${label} 115 EUR`,
      sourceUrl: 'https://salon.example/services/', extractionMethod: 'html_table'});
    assert.equal(result.reason, 'noninjectable_botox');
  }
});

test('a following Botox label cannot adopt the preceding hyaluronic acid amount', () => {
  const rawEvidence = 'Hyaluronic Acid - Expression Lines 484€ Botox - Expression Lines from 400€';
  assert.equal(botoxAmountOwnedByFiller({rawEvidence, priceMin: 484, currency: 'EUR'}), true);
  assert.equal(botoxAmountOwnedByFiller({rawEvidence, priceMin: 400, currency: 'EUR'}), false);
  assert.equal(evaluateExtractedPriceCandidate({procedure: 'Botox', priceMin: 484,
    currency: 'EUR', rawPriceText: '484 EUR', rawEvidence,
    sourceUrl: 'https://clinic.example/pricing/', extractionMethod: 'html_table'}).reason,
    'neighbouring_filler_amount');
});

test('related shop products never supply breast augmentation fees', () => {
  assert.equal(evaluateExtractedPriceCandidate({procedure: 'Breast augmentation', priceMin: 1598,
    currency: 'AED', rawPriceText: '1598 AED', extractionMethod: 'html_table',
    rawEvidence: 'Breast augmentation | Related products Original price was: 1598 AED'}).reason,
    'non_treatment_label');
});

test('five-digit AED surgery ranges are not postal codes', () => {
  assert.equal(looksLikeAddressNumber('19999–25999 AED'), false);
  assert.equal(looksLikeAddressNumber('50008 Zaragoza'), true);
  assert.equal(looksLikeAddressNumber('Carrer de Mallorca 125, 08036 Barcelona'), true);
  assert.equal(evaluateExtractedPriceCandidate({procedure:'Breast augmentation with implants',
    priceMin:19999,priceMax:25999,currency:'AED',rawPriceText:'19999–25999 AED',
    rawEvidence:'Silicone Breast Augmentation | 150 – 300 cc: 19999 AED – 25999 AED',
    sourceUrl:'https://clinic.example/pricing/',extractionMethod:'html_table'}).accepted,true);
});
