'use strict';

const {describe, it} = require('node:test');
const assert = require('node:assert/strict');
const {discoveryQueriesForProcedure} = require('../brightdata/discoveryQueries');
const {parseBrightDataSerpBody, buildGoogleSearchUrl} =
    require('../brightdata/brightDataSerp');
const {normalizeMapsRow} = require('../brightdata/brightDataMaps');
const {detectCurrencyToken} = require('../parsePrice');
const {plausibleAmountBand} = require('../priceSanity');
const {useApifyFresha, useZyteFallback} = require('../featureFlags');

describe('bright data discovery queries', () => {
  it('builds focused Botox queries not generic aesthetic clinic', () => {
    const qs = discoveryQueriesForProcedure('Botox anti-wrinkle injection', 'Dubai');
    assert.ok(qs.length >= 2);
    assert.ok(qs.some((q) => /botox/i.test(q)));
    assert.ok(!qs.every((q) => /^aesthetic clinic$/i.test(q)));
  });

  it('builds rhinoplasty surgeon queries', () => {
    const qs = discoveryQueriesForProcedure('rhinoplasty nose job', 'Dubai');
    assert.ok(qs.some((q) => /rhinoplasty/i.test(q)));
  });
});

describe('bright data serp helpers', () => {
  it('builds google search url with brd_json', () => {
    const u = buildGoogleSearchUrl('site:novomed.com Botox price', {hl: 'en', gl: 'ae'});
    assert.match(u, /google\.com\/search/);
    assert.match(u, /brd_json=1/);
  });

  it('parses organic results without reading prices', () => {
    const hits = parseBrightDataSerpBody('', {
      organic: [
        {link: 'https://clinic.com/botox', title: 'Botox', snippet: 'from AED 999'},
      ],
    });
    assert.equal(hits.length, 1);
    assert.equal(hits[0].url, 'https://clinic.com/botox');
  });
});

describe('bright data maps normalize', () => {
  it('maps dataset rows to clinic candidates', () => {
    const c = normalizeMapsRow({
      name: 'Glow Clinic',
      place_id: 'abc',
      website: 'https://glow.ae',
      rating: 4.8,
      reviews_count: 100,
      latitude: 25.2,
      longitude: 55.3,
      address: 'Dubai Marina',
    });
    assert.equal(c.name, 'Glow Clinic');
    assert.equal(c.discovery_provider, 'brightdata_maps');
    assert.equal(c.website, 'https://glow.ae');
  });
});

describe('worldwide currencies', () => {
  it('detects expanded currencies', () => {
    assert.equal(detectCurrencyToken('AED 990'), 'AED');
    assert.equal(detectCurrencyToken('₩1,500,000'), 'KRW');
    assert.equal(detectCurrencyToken('¥800,000'), 'JPY');
    assert.equal(detectCurrencyToken('Rp 15,000,000'), 'IDR');
    assert.equal(detectCurrencyToken('SAR 500'), 'SAR');
    assert.equal(detectCurrencyToken('₹12,000'), 'INR');
  });

  it('uses currency-aware bands', () => {
    const krw = plausibleAmountBand({currency: 'KRW', procedure: 'botox'});
    assert.ok(krw.max > 100000);
    const idr = plausibleAmountBand({currency: 'IDR', procedure: 'filler'});
    assert.ok(idr.max > 1000000);
  });
});

describe('feature flags defaults', () => {
  it('disables fresha and zyte by default', () => {
    assert.equal(useApifyFresha(), false);
    assert.equal(useZyteFallback(), false);
  });
});
