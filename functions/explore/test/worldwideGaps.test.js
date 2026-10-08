'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  buildCityId,
  isResolvedCityId,
  exploreUrlConflictsWithSearchCity,
  urlMatchesSearchCity,
  legacyRecordMatchesResolvedCity,
  normalizeExploreLocality,
} = require('../cityIdentity');
const {
  docIdWithLocality,
  docId,
  REVISION,
  PREV_REVISION,
  sanitizeVerifiedPoolRow,
} = require('../firestoreStore');
const {scorePriceUrl, rankAndPickUrls} = require('../urlRank');
const {EXTRACT_REVISION} = require('../clinicCatalog');
const {useBrightData} = require('../featureFlags');

test('normalizeExploreLocality prefers explicit fields and fills defaults', () => {
  const loc = normalizeExploreLocality({
    city: 'Sofia',
    cityId: 'place_abc',
    countryCode: 'BG',
    countryName: 'Bulgaria',
    adminArea: 'Sofia-City',
    placeId: 'abc',
    latitude: 42.7,
    longitude: 23.3,
    languageCodes: ['bg'],
    currencyCode: 'bgn',
    canonicalName: 'sofia',
    localName: 'София',
  });
  assert.equal(loc.city, 'Sofia');
  assert.equal(loc.cityId, 'place_abc');
  assert.equal(loc.countryCode, 'BG');
  assert.equal(loc.currencyCode, 'BGN');
  assert.equal(loc.localName, 'София');
  assert.deepEqual(loc.languageCodes, ['bg']);
  const empty = normalizeExploreLocality({});
  assert.equal(empty.city, '');
  assert.equal(empty.cityId, '');
  assert.equal(empty.latitude, null);
  assert.equal(empty.longitude, null);
  assert.deepEqual(empty.languageCodes, []);
});

test('normalizeExploreLocality falls back to city→country when cc missing', () => {
  const loc = normalizeExploreLocality({city: 'Barcelona'});
  assert.equal(loc.countryCode, 'ES');
});

test('docIdWithLocality prefers cityId and dual-reads legacy revision', () => {
  const withId = docIdWithLocality({
    city: 'Sofia',
    cityId: 'place_sofia',
    procedure: 'Botox',
  });
  const byCity = docId('Sofia', 'Botox');
  const legacy = docId('Sofia', 'Botox', PREV_REVISION);
  assert.notEqual(withId, byCity);
  assert.notEqual(byCity, legacy);
  assert.equal(REVISION, 'v13');
  assert.equal(PREV_REVISION, 'v12');
  assert.ok(withId.includes('place_sofia'));
  assert.ok(withId.startsWith('v13') || withId.includes('v13'));
  assert.ok(byCity.includes('v13'));
  assert.ok(legacy.includes('v12'));
});

test('Paris FR vs Paris TX cityIds never collide', () => {
  const fr = buildCityId({
    countryCode: 'FR',
    adminArea: 'Ile-de-France',
    canonicalName: 'paris',
    latitude: 48.8566,
    longitude: 2.3522,
  });
  const tx = buildCityId({
    countryCode: 'US',
    adminArea: 'Texas',
    canonicalName: 'paris',
    latitude: 33.6609,
    longitude: -95.5555,
  });
  assert.notEqual(fr, tx);
  assert.ok(isResolvedCityId(fr));
  assert.ok(isResolvedCityId(tx));
});

test('London UK vs London Ontario cityIds never collide', () => {
  const uk = buildCityId({
    countryCode: 'GB',
    adminArea: 'England',
    canonicalName: 'london',
    latitude: 51.5074,
    longitude: -0.1278,
  });
  const on = buildCityId({
    countryCode: 'CA',
    adminArea: 'Ontario',
    canonicalName: 'london',
    latitude: 42.9849,
    longitude: -81.2453,
  });
  assert.notEqual(uk, on);
});

test('multiple Springfield cities stay distinct', () => {
  const il = buildCityId({
    countryCode: 'US',
    adminArea: 'Illinois',
    canonicalName: 'springfield',
    latitude: 39.7817,
    longitude: -89.6501,
  });
  const mo = buildCityId({
    countryCode: 'US',
    adminArea: 'Missouri',
    canonicalName: 'springfield',
    latitude: 37.2090,
    longitude: -93.2923,
  });
  const ma = buildCityId({
    countryCode: 'US',
    adminArea: 'Massachusetts',
    canonicalName: 'springfield',
    latitude: 42.1015,
    longitude: -72.5898,
  });
  assert.notEqual(il, mo);
  assert.notEqual(il, ma);
  assert.notEqual(mo, ma);
});

test('missing country/coords is unresolved and does not merge', () => {
  const unresolved = buildCityId({canonicalName: 'paris'});
  assert.ok(unresolved.startsWith('unresolved_'));
  assert.equal(isResolvedCityId(unresolved), false);
});

test('legacy London UK record cannot leak into London Ontario', () => {
  const ok = legacyRecordMatchesResolvedCity(
      {
        countryCode: 'GB',
        city: 'London',
        address: 'Harley Street, London, UK',
        latitude: 51.52,
        longitude: -0.15,
      },
      {
        countryCode: 'CA',
        adminArea: 'Ontario',
        canonicalName: 'london',
        displayName: 'London',
        latitude: 42.98,
        longitude: -81.25,
      });
  assert.equal(ok, false);
});

test('legacy Paris FR record cannot leak into Paris Texas', () => {
  const ok = legacyRecordMatchesResolvedCity(
      {
        countryCode: 'FR',
        city: 'Paris',
        address: 'Paris, France',
        latitude: 48.85,
        longitude: 2.35,
      },
      {
        countryCode: 'US',
        adminArea: 'Texas',
        canonicalName: 'paris',
        displayName: 'Paris',
        latitude: 33.66,
        longitude: -95.55,
      });
  assert.equal(ok, false);
});

test('Cronosmed Timisoara page preferred; Iasi/Brasov rejected', () => {
  const city = 'Timisoara';
  const urls = [
    'https://www.cronosmed.ro/preturi/iasi/',
    'https://www.cronosmed.ro/preturi/brasov/',
    'https://www.cronosmed.ro/preturi/timisoara/',
    'https://www.cronosmed.ro/preturi/',
  ];
  assert.equal(
      exploreUrlConflictsWithSearchCity(
          'https://www.cronosmed.ro/preturi/iasi/', city),
      true);
  assert.equal(
      exploreUrlConflictsWithSearchCity(
          'https://www.cronosmed.ro/preturi/brasov/', city),
      true);
  assert.equal(
      exploreUrlConflictsWithSearchCity(
          'https://www.cronosmed.ro/preturi/timisoara/', city),
      false);
  assert.ok(urlMatchesSearchCity(
      'https://www.cronosmed.ro/preturi/timisoara/', city));
  assert.equal(
      scorePriceUrl('https://www.cronosmed.ro/preturi/iasi/', {city}),
      0);
  assert.equal(
      scorePriceUrl('https://www.cronosmed.ro/preturi/brasov/', {city}),
      0);
  const ranked = rankAndPickUrls(urls, {
    city,
    procedure: 'lip filler',
    host: 'cronosmed.ro',
    max: 3,
  });
  assert.equal(ranked[0], 'https://www.cronosmed.ro/preturi/timisoara/');
  assert.ok(!ranked.some((u) => /\/iasi|\/brasov/.test(u)));
});

test('contaminated Iasi cache row invalidated for Timisoara search', () => {
  const row = {
    name: 'Cronosmed',
    price_min: 1600,
    price_max: 1600,
    currency: 'RON',
    raw_procedure_text: 'Buze contur si volum – Teosyal RHA Kiss (0.7 ml)',
    raw_price_text: '1600 RON',
    price_evidence_text:
        'Buze contur si volum – Teosyal RHA Kiss (0.7 ml) 1600 RON',
    price_source_url: 'https://www.cronosmed.ro/preturi/iasi/',
    extraction_method: 'html_table',
    price_verification_status: 'official_website',
    price_verified: true,
    price_extract_revision: EXTRACT_REVISION,
  };
  const cleaned = sanitizeVerifiedPoolRow(row, 'lip filler', {city: 'Timisoara'});
  assert.equal(cleaned.needs_reverification, true);
  assert.match(
      String(cleaned.price_rejection_reason || ''),
      /other_city_source_url/);
});

test('Bright Data is optional via feature flag', () => {
  const prevFlag = process.env.USE_BRIGHTDATA;
  const prevKey = process.env.BRIGHTDATA_API_KEY;
  process.env.USE_BRIGHTDATA = 'false';
  process.env.BRIGHTDATA_API_KEY = 'dummy';
  assert.equal(useBrightData(), false);
  process.env.USE_BRIGHTDATA = 'true';
  delete process.env.BRIGHTDATA_API_KEY;
  assert.equal(useBrightData(), false);
  process.env.USE_BRIGHTDATA = prevFlag || '';
  if (prevKey == null) delete process.env.BRIGHTDATA_API_KEY;
  else process.env.BRIGHTDATA_API_KEY = prevKey;
});
