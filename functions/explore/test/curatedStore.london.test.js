'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const {
  normalizeCuratedDataset,
  tallyFamilies,
  countryCodeOf,
} = require('../curatedStore');

const DATASET_PATH = path.join(
    __dirname, '..', '..', 'scripts', 'data',
    'london_clinics_sitewide_all_public_prices_v1.json');

const dataset = JSON.parse(fs.readFileSync(DATASET_PATH, 'utf8'));
const normalized = normalizeCuratedDataset({
  dataset,
  cityKeyOverride: 'london',
});

test('United Kingdom locations import as GB, not US', () => {
  assert.equal(
      countryCodeOf({
        location: {country: 'United Kingdom'},
        currencyDefault: 'GBP',
      }),
      'GB',
  );
  assert.equal(
      countryCodeOf({location: {state: 'FL', zip: '33134'}}),
      'US',
  );
});

test('every London clinic imports with GBP and a priced procedure', () => {
  assert.equal(normalized.clinics.length, 23);
  assert.equal(normalized.invalidClinics.length, 0);
  for (const {doc, rowCount} of normalized.clinics) {
    assert.equal(doc.city_key, 'london', doc.name);
    assert.equal(doc.country_code, 'GB', doc.name);
    assert.ok(doc.address.length > 0, doc.name);
    assert.ok(rowCount > 0, doc.name);
  }
  for (const {doc} of normalized.rows) {
    assert.equal(doc.currency, 'GBP', `${doc.clinic_name} · ${doc.procedure_name}`);
    assert.ok(doc.price_min > 0);
  }
});

test('London flagship families are populated from public clinic prices', () => {
  const families = tallyFamilies(normalized.rows);
  for (const expected of [
    'botox', 'filler', 'rhinoplasty', 'breast_augmentation',
    'hair_transplant', 'peel',
  ]) {
    assert.ok((families[expected] || 0) > 0, `missing family ${expected}`);
  }
});
