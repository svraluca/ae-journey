'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const {
  normalizeCuratedDataset,
  tallyFamilies,
} = require('../curatedStore');

const DATASET_PATH = path.join(
    __dirname, '..', '..', 'scripts', 'data',
    'dallas_clinics_sitewide_all_public_prices_v1.json');

const dataset = JSON.parse(fs.readFileSync(DATASET_PATH, 'utf8'));
const normalized = normalizeCuratedDataset({
  dataset,
  cityKeyOverride: 'dallas',
});

const REJECTED = [
  'Dallas Aesthetic Center',
  'Dallas Rhinoplasty Directory Listing',
  'Frisco Med Spa',
  'Legacy Dermatology - Plano',
  'Preston Center MedSpa',
];

test('every Dallas clinic with public contact imports with USD', () => {
  assert.equal(normalized.clinics.length, 38);
  assert.deepEqual(
      normalized.invalidClinics.map((c) => c.name).sort(),
      REJECTED.slice().sort(),
  );
  for (const {doc, rowCount} of normalized.clinics) {
    assert.equal(doc.city_key, 'dallas', doc.name);
    assert.equal(doc.country_code, 'US', doc.name);
    assert.ok(doc.address.length > 0, doc.name);
    assert.ok(rowCount > 0, doc.name);
  }
  for (const {doc} of normalized.rows) {
    assert.equal(doc.currency, 'USD', `${doc.clinic_name} · ${doc.procedure_name}`);
    assert.ok(doc.price_min > 0);
  }
});

test('Dallas flagship families are populated from public clinic prices', () => {
  const families = tallyFamilies(normalized.rows);
  for (const expected of [
    'botox', 'filler', 'rhinoplasty', 'breast_augmentation',
    'hair_transplant', 'peel',
  ]) {
    assert.ok((families[expected] || 0) > 0, `missing family ${expected}`);
  }
});
