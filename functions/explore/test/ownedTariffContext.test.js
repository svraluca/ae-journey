'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  classifyExplorePricePageContext,
  exploreEvidenceIsClinicOwnedPrice,
  looksLikeExplicitClinicOwnPriceLanguage,
} = require('../priceOwnership');

test('dose averages on an official menu do not classify its price as average', () => {
  assert.equal(classifyExplorePricePageContext({
    sourceUrl: 'https://miamiskinandvein.com/pricing/',
    pageText: 'BOTOX Cosmetic $18 per unit. On average, 40-50 units of BOTOX are used to treat the upper face.',
  }), 'official_price_list');
});

test('a dosage sentence containing a monetary claim remains market average', () => {
  for (const claim of ['at a cost of $500', 'at CAD 500', 'for 500 PEN']) {
    const pageContext = classifyExplorePricePageContext({
      sourceUrl: 'https://clinic.example/pricing/',
      pageText: `On average, 40-50 units are used ${claim}.`,
    });
    assert.equal(pageContext, 'market_average');
    assert.equal(exploreEvidenceIsClinicOwnedPrice({
      pageContext,
      rawEvidence: 'Botox $500',
      rawProcedureText: 'Botox',
    }), false);
  }
});

test('English price menus do not bypass city cost-guide rejection', () => {
  assert.equal(classifyExplorePricePageContext({
    sourceUrl: 'https://clinic.example/prices',
    pageText: 'Lip filler 350 EUR',
  }), 'official_price_list');
  assert.equal(classifyExplorePricePageContext({
    sourceUrl: 'https://clinic.example/prices-in-dubai/',
    pageText: 'Lip filler 350 EUR',
  }), 'country_cost_guide');
});

test('explicit Arabic own offer differs from an Arabic market average', () => {
  const offer = 'كل يوم إثنين استغلي عرضنا الحصري على البوتوكس بسعر 999 درهم';
  assert.equal(looksLikeExplicitClinicOwnPriceLanguage(offer), true);
  assert.equal(classifyExplorePricePageContext({
    sourceUrl: 'https://mediclinic.ae/ar/special-offers/botox-mondays.html',
    pageText: offer,
  }), 'official_service_price');
  assert.equal(looksLikeExplicitClinicOwnPriceLanguage('متوسط سعر البوتوكس 999 درهم'), false);
});
