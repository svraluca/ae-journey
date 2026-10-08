'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const {
  normalizeCuratedDataset,
  countryCodeOf,
} = require('../curatedStore');

const DATA = path.join(__dirname, '..', '..', 'scripts', 'data');

const CITIES = [
  {
    key: 'toronto',
    files: [
      'toronto_aesthetic_clinics_public_prices_v1.json',
      'markham_aesthetic_clinics_public_prices_v1.json',
      'mississauga_aesthetic_clinics_public_prices_v1.json',
      'oakville_aesthetic_clinics_public_prices_v1.json',
      'richmond_hill_aesthetic_clinics_public_prices_v1.json',
      'vaughan_aesthetic_clinics_public_prices_v1.json',
    ],
    minClinics: 28,
  },
  {
    key: 'vancouver',
    files: [
      'vancouver_aesthetic_clinics_public_prices_v1.json',
      'burnaby_aesthetic_clinics_public_prices_v1.json',
      'surrey_aesthetic_clinics_public_prices_v1.json',
    ],
    minClinics: 5,
  },
  {key: 'calgary', files: ['calgary_aesthetic_clinics_public_prices_v1.json'], minClinics: 10},
  {key: 'edmonton', files: ['edmonton_aesthetic_clinics_public_prices_v1.json'], minClinics: 7},
  {key: 'halifax', files: ['halifax_aesthetic_clinics_public_prices_v1.json'], minClinics: 2},
  {key: 'hamilton', files: ['hamilton_aesthetic_clinics_public_prices_v1.json'], minClinics: 3},
  {key: 'kelowna', files: ['kelowna_aesthetic_clinics_public_prices_v1.json'], minClinics: 4},
  {key: 'montreal', files: ['montreal_aesthetic_clinics_public_prices_v1.json'], minClinics: 6},
  {key: 'ottawa', files: ['ottawa_aesthetic_clinics_public_prices_v1.json'], minClinics: 7},
  {
    key: 'quebec city',
    files: ['quebec_city_aesthetic_clinics_public_prices_v1.json'],
    minClinics: 4,
  },
  {key: 'saskatoon', files: ['saskatoon_aesthetic_clinics_public_prices_v1.json'], minClinics: 1},
  {key: 'victoria', files: ['victoria_aesthetic_clinics_public_prices_v1.json'], minClinics: 3},
  {key: 'winnipeg', files: ['winnipeg_aesthetic_clinics_public_prices_v1.json'], minClinics: 4},
];

const DIRECTORY_LISTINGS = new Set([
  'Monarchy Medispa Halifax',
  'Ronen Avram, MD - Hamilton Listing',
  'Okanagan Health Surgical Centre - Public Listing',
  'Cory Goldberg, MD - Mississauga Listing',
  'Ian Sunderland, MD - Saskatoon Listing',
]);

test('Canada locations import as CA when country or CAD is set', () => {
  assert.equal(
      countryCodeOf({
        location: {country: 'Canada', province: 'Ontario'},
        currencyDefault: 'CAD',
      }),
      'CA',
  );
  assert.equal(
      countryCodeOf({location: {country_code: 'ca'}, currencyDefault: 'CAD'}),
      'CA',
  );
  assert.equal(countryCodeOf({currencyDefault: 'CAD'}), 'CA');
});

for (const city of CITIES) {
  test(`${city.key} clinics with public contact import as CAD`, () => {
    let clinics = 0;
    let rows = 0;
    const invalid = [];
    for (const file of city.files) {
      const dataset = JSON.parse(fs.readFileSync(path.join(DATA, file), 'utf8'));
      const normalized = normalizeCuratedDataset({
        dataset,
        cityKeyOverride: city.key,
      });
      clinics += normalized.clinics.length;
      rows += normalized.rows.length;
      invalid.push(...normalized.invalidClinics);
      for (const {doc, rowCount} of normalized.clinics) {
        assert.equal(doc.city_key, city.key, doc.name);
        assert.equal(doc.country_code, 'CA', doc.name);
        assert.ok(doc.state.length > 0, `${doc.name} missing province`);
        assert.ok(doc.address.length > 0, doc.name);
        assert.ok(rowCount > 0, doc.name);
      }
      for (const {doc} of normalized.rows) {
        assert.equal(doc.currency, 'CAD', `${doc.clinic_name} · ${doc.procedure_name}`);
        assert.ok(doc.price_min > 0);
      }
    }
    assert.ok(
        clinics >= city.minClinics,
        `${city.key} imported ${clinics}, expected >= ${city.minClinics}`,
    );
    assert.ok(rows > 0, `${city.key} has no priced rows`);
    for (const clinic of invalid) {
      assert.equal(clinic.reason, 'missing_name_or_contact', clinic.name);
      assert.ok(
          DIRECTORY_LISTINGS.has(clinic.name),
          `unexpected invalid clinic ${clinic.name}`,
      );
    }
  });
}
