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
    'new_york_clinics_sitewide_all_public_prices_v1.json');

const dataset = JSON.parse(fs.readFileSync(DATASET_PATH, 'utf8'));
const normalized = normalizeCuratedDataset({
  dataset,
  cityKeyOverride: 'new york',
});

test('USA locations import as US', () => {
  assert.equal(
      countryCodeOf({
        location: {country: 'USA', state: 'NY'},
        currencyDefault: 'USD',
      }),
      'US',
  );
});

test('every New York clinic imports with USD and a priced procedure', () => {
  assert.equal(normalized.clinics.length, 26);
  assert.equal(normalized.invalidClinics.length, 0);
  for (const {doc, rowCount} of normalized.clinics) {
    assert.equal(doc.city_key, 'new york', doc.name);
    assert.equal(doc.country_code, 'US', doc.name);
    assert.ok(doc.address.length > 0, doc.name);
    assert.ok(rowCount > 0, doc.name);
  }
  for (const {doc} of normalized.rows) {
    assert.equal(doc.currency, 'USD', `${doc.clinic_name} · ${doc.procedure_name}`);
    assert.ok(doc.price_min > 0);
  }
});

test('New York flagship families are populated from public clinic prices', () => {
  const families = tallyFamilies(normalized.rows);
  for (const expected of [
    'botox', 'filler', 'rhinoplasty', 'breast_augmentation',
    'hair_transplant', 'peel',
  ]) {
    assert.ok((families[expected] || 0) > 0, `missing family ${expected}`);
  }
});
