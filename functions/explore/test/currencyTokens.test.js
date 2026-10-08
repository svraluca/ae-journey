'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  detectCurrencyToken,
  hasCurrencySignal,
} = require('../currencyTokens');
const {parsePriceText} = require('../parsePrice');
const {hasCurrencySignal: sanityHasCurrency} = require('../priceSanity');

const MIAMI_SENTENCE =
    'Dysport and Xeomin start at $13 per unit, depending on areas';

test('\$13 per unit depending → 13 USD perUnit, never PEN', () => {
  const parsed = parsePriceText(MIAMI_SENTENCE);
  assert.ok(parsed);
  assert.equal(parsed.priceMin, 13);
  assert.equal(parsed.currency, 'USD');
  assert.equal(parsed.priceType, 'perUnit');
  assert.equal(detectCurrencyToken(MIAMI_SENTENCE), 'USD');
});

test('English prose is not a currency token', () => {
  assert.equal(detectCurrencyToken('depending on treatment'), '');
  assert.equal(hasCurrencySignal('depending on treatment'), false);
  assert.equal(sanityHasCurrency('depending on treatment'), false);

  assert.equal(detectCurrencyToken('try our treatment'), '');
  assert.equal(hasCurrencySignal('try our treatment'), false);

  assert.equal(detectCurrencyToken('country pricing information'), '');
  assert.equal(hasCurrencySignal('country pricing information'), false);

  assert.equal(detectCurrencyToken('copyright notice'), '');
  assert.equal(hasCurrencySignal('copyright notice'), false);

  assert.equal(detectCurrencyToken('audience'), '');
  assert.equal(hasCurrencySignal('audience'), false);
});

test('bounded ISO codes and local symbols still parse', () => {
  const penIso = parsePriceText('Botox 13 PEN');
  assert.ok(penIso);
  assert.equal(penIso.priceMin, 13);
  assert.equal(penIso.currency, 'PEN');

  const sol = parsePriceText('Botox S/ 650');
  assert.ok(sol);
  assert.equal(sol.priceMin, 650);
  assert.equal(sol.currency, 'PEN');

  const tryIso = parsePriceText('Botox TRY 4000');
  assert.ok(tryIso);
  assert.equal(tryIso.priceMin, 4000);
  assert.equal(tryIso.currency, 'TRY');

  const cad = parsePriceText('Botox CAD 12/unit');
  assert.ok(cad);
  assert.equal(cad.priceMin, 12);
  assert.equal(cad.currency, 'CAD');
  assert.equal(cad.priceType, 'perUnit');

  const usd = parsePriceText('Botox $13/unit');
  assert.ok(usd);
  assert.equal(usd.priceMin, 13);
  assert.equal(usd.currency, 'USD');
  assert.equal(usd.priceType, 'perUnit');
});

test('symbol near the amount beats later prose', () => {
  const parsed = parsePriceText(
      'Wrinkle relaxers start at $13 per unit, with the exact total ' +
      'depending on the areas treated');
  assert.equal(parsed.currency, 'USD');
  assert.notEqual(parsed.currency, 'PEN');
});
