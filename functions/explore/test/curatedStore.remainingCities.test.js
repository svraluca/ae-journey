'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const {normalizeCuratedDataset} = require('../curatedStore');

const DATA = path.join(__dirname, '..', '..', 'scripts', 'data');

const CITIES = [
  {
    key: 'atlanta',
    file: 'atlanta_clinics_sitewide_all_public_prices_v2_expanded_injectables.json',
    minClinics: 50,
  },
  {key: 'austin', file: 'austin_clinics_public_pricing_seed_v1.json', minClinics: 8},
  {key: 'boston', file: 'boston_clinics_public_pricing_seed_v1.json', minClinics: 5},
  {key: 'charlotte', file: 'charlotte_clinics_public_pricing_seed_v1.json', minClinics: 4},
  {key: 'chicago', file: 'chicago_clinics_public_pricing_seed_v1.json', minClinics: 5},
  {key: 'denver', file: 'denver_clinics_public_pricing_seed_v1.json', minClinics: 4},
  {key: 'las vegas', file: 'las_vegas_clinics_public_pricing_seed_v1.json', minClinics: 2},
  {key: 'nashville', file: 'nashville_clinics_public_pricing_seed_v1.json', minClinics: 3},
  {key: 'orlando', file: 'orlando_clinics_sitewide_all_public_prices_v1.json', minClinics: 30},
  {key: 'phoenix', file: 'phoenix_clinics_public_pricing_seed_v1.json', minClinics: 4},
  {
    key: 'washington dc',
    file: 'washington_dc_clinics_public_pricing_seed_v1.json',
    minClinics: 4,
  },
  {key: 'tampa', file: 'tampa_clinics_sitewide_all_public_prices_v1.json', minClinics: 35},
  {
    key: 'san diego',
    file: 'san_diego_clinics_sitewide_all_public_prices_v1.json',
    minClinics: 35,
  },
];

for (const city of CITIES) {
  test(`${city.key} clinics with public contact import as USD`, () => {
    const dataset = JSON.parse(
        fs.readFileSync(path.join(DATA, city.file), 'utf8'));
    const normalized = normalizeCuratedDataset({
      dataset,
      cityKeyOverride: city.key,
    });
    assert.ok(
        normalized.clinics.length >= city.minClinics,
        `${city.key} imported ${normalized.clinics.length}, expected >= ${city.minClinics}`);
    for (const {doc, rowCount} of normalized.clinics) {
      assert.equal(doc.city_key, city.key, doc.name);
      assert.equal(doc.country_code, 'US', doc.name);
      assert.ok(doc.address.length > 0, doc.name);
      assert.ok(rowCount > 0, doc.name);
    }
    for (const {doc} of normalized.rows) {
      assert.equal(doc.currency, 'USD', `${doc.clinic_name} · ${doc.procedure_name}`);
      assert.ok(doc.price_min > 0);
    }
    for (const invalid of normalized.invalidClinics) {
      assert.equal(invalid.reason, 'missing_name_or_contact', invalid.name);
    }
  });
}
