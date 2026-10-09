'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const {marketplaceProviderLocations, providerLocationContext, providerLocationConflicts} = require('../providerLocation');
const {marketplaceLocationStronglyMatches} = require('../identity');
const {sanitizeVerifiedPoolRow} = require('../firestoreStore');
const {comparisonPriceContext, medicalQaPriceContext} = require('../tariffScope');
const {EXTRACT_REVISION} = require('../extractRevision');
const {classifyExplorePricePageContext, exploreEvidenceIsClinicOwnedPrice} = require('../priceOwnership');

const url = 'https://us-uk.bookimed.com/clinic/aster-clinic/';
const html = `<script type="application/ld+json">${JSON.stringify({
  '@type': 'MedicalWebPage', url, mainEntity: {
    '@type': 'Hospital', url, address: {addressLocality: 'Kuala Lumpur'}},
  publisher: {'@type': 'Organization', address: {addressLocality: 'Istanbul'}},
  relatedLink: {'@type': 'Hospital', url: url + 'other/', address: {addressLocality: 'Istanbul'}},
})}</script><footer><address>Platform office Istanbul</address></footer>`;

test('provider metadata excludes publishers and recommended clinics', () => {
  assert.deepEqual(marketplaceProviderLocations(html, url), ['Kuala Lumpur']);
  assert.equal(marketplaceLocationStronglyMatches({city: 'Istanbul', placeAddress: 'Istanbul',
    pageText: 'Istanbul clinic', sourceUrl: url, providerLocation: providerLocationContext(html, url)}), false);
  assert.equal(providerLocationConflicts(providerLocationContext(html, url), 'Kuala Lumpur'), false);
  assert.equal(marketplaceLocationStronglyMatches({city: 'İstanbul', sourceUrl: url,
    providerLocation: 'Provider locality: İstanbul'}), true);
});
test('unknown foreign locality is rejected without needing a city dictionary', () => {
  assert.equal(providerLocationConflicts('Provider locality: Chiang Mai', 'Istanbul'), true);
  assert.equal(providerLocationConflicts('Provider locality: İstanbul', 'Istanbul'), false);
});
test('current cache stamp cannot override foreign provider proof', () => {
  const row = sanitizeVerifiedPoolRow({price_min: 72, currency: 'USD',
    price_extract_revision: EXTRACT_REVISION, source_location_text: 'Provider locality: Kuala Lumpur'}, 'chemical peel', {city: 'Istanbul'});
  assert.equal(row.price_min, 0);
  assert.equal(row.price_rejection_reason, 'foreign_provider_locality');
});
test('regional figures and medical Q&A cannot claim price ownership', () => {
  assert.equal(comparisonPriceContext('Turkey Price: ~€150 – €900 per area/syringe'), true);
  assert.equal(comparisonPriceContext('Our Nose filler fee: €350 per syringe'), false);
  assert.equal(medicalQaPriceContext('https://info.example/s-s-s/fees/', 'Devlet hastanelerinde dudak dolgu fiyatları 1000 TL'), true);
  const pageContext = classifyExplorePricePageContext({
    sourceUrl: 'https://info.example/s-s-s/fees/',
    pageText: '1 ml dudak dolgusu fiyatlarının bazı örnekleri: Teosyal Kiss: 8500–10500 TL',
  });
  assert.equal(exploreEvidenceIsClinicOwnedPrice({pageContext,
    rawProcedureText: 'Teosyal Kiss', rawEvidence: 'Teosyal Kiss: 8500–10500 TL',
    rawPriceText: '8500–10500 TL', extractionMethod: 'html_table'}), false);
});
