'use strict';

const assert = require('assert');
const {
  scorePriceUrl,
  rankAndPickUrls,
  isPdfUrl,
  parseSitemapLocs,
} = require('../urlRank');
const {parsePriceText} = require('../parsePrice');
const {firecrawlMapSearch} = require('../firecrawlDiscovery');

assert.ok(scorePriceUrl('https://c.ae/ar/أسعار', {city: 'Dubai', procedure: 'botox'}) >= 3);
assert.ok(scorePriceUrl('https://c.ro/preturi', {city: 'Bucharest'}) >= 3);
assert.ok(scorePriceUrl('https://c.kr/가격', {city: 'Seoul'}) >= 3);
assert.ok(isPdfUrl('https://c.com/menu.pdf'));

const ranked = rankAndPickUrls([
  'https://c.com/',
  'https://c.com/prices.pdf',
  'https://other.com/prices',
  'https://c.com/en/botox-fees',
], {procedure: 'botox', host: 'c.com', city: 'London', max: 3});
assert.ok(ranked.every((u) => u.includes('c.com')));

const locs = parseSitemapLocs(
    '<urlset><url><loc>https://www.c.fr/tarifs</loc></url>' +
    '<url><loc>https://x.fr/prices</loc></url></urlset>',
    'c.fr',
);
assert.deepStrictEqual(locs, ['https://www.c.fr/tarifs']);

const ml = parsePriceText('Lip filler 1 ml from 1200 AED');
assert.equal(ml.unit, 'ml');
assert.equal(ml.quantity, 1);
// "1 ml" is package quantity; "from" keeps starting-price semantics — not /ml.
assert.equal(ml.priceType, 'from');
assert.equal(ml.priceMin, 1200);

const exactMl = parsePriceText('Injectare acid hialuronic 1 ml: 1600 RON');
assert.equal(exactMl.priceType, 'fixed');
assert.equal(exactMl.priceMin, 1600);
assert.equal(exactMl.unit, 'ml');

const perMl = parsePriceText('Filler 250 EUR/ml');
assert.equal(perMl.priceType, 'perUnit');
assert.equal(perMl.unit, 'ml');
assert.equal(perMl.priceMin, 250);

const fromAr = parsePriceText('تبدأ من 799 درهم');
assert.equal(fromAr.priceType, 'from');
assert.equal(fromAr.priceMin, 799);

const {shrinkEvidenceToProcedureAndPrice} = require('../parsePrice');
const slim = shrinkEvidenceToProcedureAndPrice({
  block: 'Intro. Botox forehead from 799 AED. Laser 199.',
  procedure: 'Botox forehead',
  priceRaw: '799 AED',
});
assert.ok(slim.toLowerCase().includes('botox'));
assert.ok(slim.includes('799'));
assert.ok(!slim.toLowerCase().includes('laser'));

const {marketplaceLocationStronglyMatches} = require('../identity');
assert.ok(marketplaceLocationStronglyMatches({
  city: 'Paris',
  placeAddress: 'Paris, France',
  sourceUrl: 'https://fresha.com/l/paris-clinic',
  pageText: 'Botox 120 EUR',
}));
assert.ok(!marketplaceLocationStronglyMatches({
  city: 'Abu Dhabi',
  placeAddress: 'Dubai Marina',
  sourceUrl: 'https://fresha.com/l/dubai',
  pageText: 'Botox Dubai',
}));

const search = firecrawlMapSearch({procedure: 'Botox', city: 'Paris'});
assert.ok(/botox/i.test(search));
assert.ok(/prix|price|fees/i.test(search));

console.log('global urlRank + parsePrice unit tests passed');
